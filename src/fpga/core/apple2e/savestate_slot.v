//
// savestate_slot.v - the savestate manager's Pocket-side wrapper (W1)
//
// PLAN_SAVESTATES_2026-11-09 phase 3; EXPERT_BRIEF_SAVESTATE_MANAGER_2026-11-11.
//
// Instantiates the byte-identical donor savestate_manager (machine domain,
// 14.318 MHz) and adapts it to the Pocket:
//
//  * slot_* port (64-bit words) <-> SDRAM blob (32-bit SDRAM words) via the
//    owner clients CL_SS_RD (level read) and CL_SS_WR (pulse write). One
//    64-bit slot word = TWO SDRAM words (low 32 bits first): SAVE writes
//    slot_addr a -> SDRAM {BLOB_BASE + 2a, BLOB_BASE + 2a + 1}; LOAD reads
//    slot_addr a -> SDRAM {BLOB_BASE + 1 + 2a, BLOB_BASE + 2 + 2a} - the +1
//    word is the host's transport shift (2026-11-15, decoded from real .sta
//    files + the EXPERT_BRIEF_SAVESTATE_PROBE host-protocol round):
//    the host's read burst latches ONE WORD BEHIND (APF read buffer):
//    stored blob = [stale, data(B), data(B+1), ..., data(B+32831)], and the
//    host's load-write puts stored[k] back at B+k. So after a host
//    round-trip the savestate sits at B+1.. (word B = the stale slot), and
//    the manager's load must read from B+1. The save keeps writing at B:
//    its word B (the counter) becomes the file's stored[1].
//  * core_bridge_cmd handshake contract (proven on hardware by the W0 probe,
//    EXPERT_BRIEF_SAVESTATE_PROBE rounds 1-3b): ack one cycle after the
//    start/load rising edge; ok/err latched on manager completion, held
//    until the next process; busy high from the command until completion
//    (host polls 0x00A0/0x00A4 resultcode: 0 idle, 1 busy, 2 ok, 3 err).
//  * freeze: the manager's `stall` output drives the machine .STALL port
//    (REQUIRED here - the Pocket machine computes cpu_frozen = STALL &&
//    !CPU_EN_RAW; the MiSTer donor leaves the manager's stall open).
//  * load gating: the manager's LOAD is held (load_pending) until the host's
//    blob writes have drained into SDRAM (blob_wr_drained_74a from
//    savestate_bridge), so it never reads a half-written blob.
//  * word-0 preload: after a SAVE completes, preload_req pulses the
//    savestate_bridge so the host's first burst read (lost by the APF
//    bridge's 1-word read buffer) latches the NEW blob word 0.
//
// Clocks: clk_74a (74.25, host/bridge), clk_mach (14.318, machine),
// clk_ctrl (133.12, SDRAM controller / owner).
//
// CDC notes (read before touching the adapters):
//  - ctrl->mach done signals are LEVELS (set at op completion, cleared by a
//    machine-side ack), never 1-ctrl-cycle pulses: a 7.5 ns pulse is <<
//    one 70 ns machine cycle and a 2FF would miss it.
//  - the manager's slot_rdata is sampled in the same machine cycle it sees
//    slot_ready; the 32-bit half-words are "set once per op, then static"
//    ctrl regs, mirrored in the machine domain with 2-stage syncs that are
//    quiescent long before the (level) done arrives.
//
`timescale 1ns/10ps
module savestate_slot (
    // ---- 74a (host/bridge) domain ----
    input  wire        clk_74a,
    input  wire        rst_74a,              // active-high (sdram_path_rst)
    input  wire        savestate_start,      // level: 0x00A0 start transaction
    input  wire        savestate_load,       // level: 0x00A4 load transaction
    input  wire        blob_wr_drained_74a,  // host blob writes landed in SDRAM
    output wire        savestate_start_ack,
    output wire        savestate_start_busy,
    output wire        savestate_start_ok,
    output wire        savestate_start_err,
    output wire        savestate_load_ack,
    output wire        savestate_load_busy,
    output wire        savestate_load_ok,
    output wire        savestate_load_err,
    output wire        preload_req,          // 1-cycle, 74a -> savestate_bridge
    // ---- diagnostics (2026-11-14: host-readable progress/status, see
    //      core_bridge_cmd host_4C; EXPERT_BRIEF_SAVESTATE_HARDWARE_SAVEFAIL)
    output wire        dbg_sswr_stall,       // fatal: save walk gave up
    output wire [3:0]  dbg_sswr_retry,       // re-pulse attempts in flight
    output wire [15:0] dbg_word_idx,         // active save-walk SDRAM word
    // 2026-11-16 savestate SSD/SSX serial debug (REVERT for shipping):
    // ctrl-domain state word for the tracer's SSX line.
    output wire [15:0] dbg_ss_state,
    // ---- machine domain ----
    input  wire        clk_mach,
    input  wire        rst_mach,             // active-LOW (machine reset)
    input  wire        cpu_type,
    input  wire        cpu_frozen,           // machine core output
    output wire        stall,                // -> machine .STALL
    output wire        machine_ce,           // -> machine .machine_ce
    output wire [9:0]  ss_addr,
    output wire [63:0] ss_wdata,
    output wire        ss_wren,
    input  wire [63:0] ss_rdata,
    output wire        ram_bank,
    output wire [15:0] ram_addr,
    output wire        ram_rd,
    output wire        ram_wr,
    output wire [7:0]  ram_wdata,
    input  wire [7:0]  ram_rdata,
    // ---- ctrl (sdram_word_owner) domain ----
    input  wire        clk_ctrl,
    input  wire        rst_ctrl,             // active-LOW
    output wire        ssrd_req,
    output wire [23:0] ssrd_addr,
    input  wire        ssrd_done,
    input  wire [31:0] ssrd_data,
    output wire        sswr_req,
    output wire [23:0] sswr_addr,
    output wire [31:0] sswr_data,
    input  wire        sswr_done,
    input  wire        sswr_busy,
    input  wire        port_wr_idle
);

    localparam [23:0] BLOB_BASE = 24'h040_0000;   // SDRAM word 0x400000 (16 MB)

    // ======================================================================
    // manager (machine domain) - byte-identical donor import
    // ======================================================================
    wire        mgr_busy_m, mgr_done_m, mgr_err_m;
    wire [1:0]  mgr_errcode_m;
    wire        mgr_request_save, mgr_request_load;
    wire [14:0] mgr_slot_addr_m;
    wire        mgr_slot_rd, mgr_slot_wr;
    wire [63:0] mgr_slot_wdata_m, mgr_slot_rdata_m;
    wire        mgr_slot_ready_m;

    savestate_manager u_mgr (
        .clk(clk_mach),
        .reset(!rst_mach),
        .request_save(mgr_request_save),
        .request_load(mgr_request_load),
        .allow_save_state(1'b1),   // 1.0.0: document-only disk fingerprint
                                   // (plan decision #5 step 2 wires this)
        .cpu_type(cpu_type),
        .cpu_frozen(cpu_frozen),
        .stall(stall),
        .machine_ce(machine_ce),
        .busy(mgr_busy_m),
        .done(mgr_done_m),
        .error(mgr_err_m),
        .error_code(mgr_errcode_m),
        .dbg_state(mgr_dbg_state_m),
        .locked_cpu_type(),
        .ss_addr(ss_addr),
        .ss_wdata(ss_wdata),
        .ss_wren(ss_wren),
        .ss_rdata(ss_rdata),
        .ram_bank(ram_bank),
        .ram_addr(ram_addr),
        .ram_rd(ram_rd),
        .ram_wr(ram_wr),
        .ram_wdata(ram_wdata),
        .ram_rdata(ram_rdata),
        .slot_addr(mgr_slot_addr_m),
        .slot_rd(mgr_slot_rd),
        .slot_wr(mgr_slot_wr),
        .slot_wdata(mgr_slot_wdata_m),
        .slot_rdata(mgr_slot_rdata_m),
        .slot_ready(mgr_slot_ready_m)
    );

    // ======================================================================
    // machine side: command pending + request gating
    // ======================================================================
    wire start_rise_m, load_rise_m;
    wire start_lev_m, load_lev_m;   // synced LEVELS (pender input, 2026-11-16)
    wire blob_drained_m;
    wire wd_err_m;                  // sticky watchdog error (mach domain)
    synch_3 s_start (.i(savestate_start),     .o(start_lev_m), .clk(clk_mach),
                     .rise(start_rise_m), .fall());
    synch_3 s_load  (.i(savestate_load),      .o(load_lev_m), .clk(clk_mach),
                     .rise(load_rise_m), .fall());
    synch_3 s_drain (.i(blob_wr_drained_74a), .o(blob_drained_m),
                     .clk(clk_mach), .rise(), .fall());
    // NOTE: s_wde is declared below with the watchdog (forward reference -
    // legal at module scope); it gates the pender in the sticky-err state.
    synch_3 s_wde (.i(wd_err_sticky), .o(wd_err_m), .clk(clk_mach),
                   .rise(), .fall());

    // Command pender, captured-token semantics (2026-11-16, EXPERT_BRIEF_
    // SAVESTATE_WEDGE_MACH_SIDE §9 Steps 2-3 + §10 adjudication).
    //
    // History: the original pender latched on start_rise_m (a synch_3 pulse
    // catch). A level narrower than one mach period - which the host
    // contract produces for every command after the first (stale ack) -
    // misses phase-dependently (L0 race; verified on hardware and in
    // tb_ss_cmdrace: 3/6 phases lost). Level-latching fixes the capture,
    // but a plain `pend <= lev | pend & ~go` re-fires go on a stale pend
    // after completion (ghost save - §10). The captured token: the level
    // latches the pend; the token latches once the pend has been held under
    // the level (i.e. the handoff has fired); the token suppresses re-
    // latching while the level stays high; a level fall releases both. One
    // handoff per level, for both the verified host contract and a
    // hypothetical hold-through-op host.
    reg start_pend, load_pend;
    reg start_seen_m, load_seen_m;   // captured token (mach domain)
    wire start_go = start_pend & ~mgr_busy_m;
    wire load_go  = load_pend  & ~mgr_busy_m & blob_drained_m;
    always @(posedge clk_mach) begin
        if (!rst_mach) begin
            start_pend   <= 1'b0;
            load_pend    <= 1'b0;
            start_seen_m <= 1'b0;
            load_seen_m  <= 1'b0;
        end else begin
            // start (load is symmetric): go clears; the token holds pend
            // (no re-latch on a still-high level); otherwise the level
            // latches the pend (a sticky watchdog error takes no new ops).
            // The token clears on a level fall.
            if (start_go)
                start_pend <= 1'b0;
            else if (start_seen_m)
                ;
            else if (start_lev_m && !wd_err_m)
                start_pend <= 1'b1;
            if (~start_lev_m)
                start_seen_m <= 1'b0;
            else if (start_pend)
                start_seen_m <= 1'b1;
            if (load_go)
                load_pend <= 1'b0;
            else if (load_seen_m)
                ;
            else if (load_lev_m && !wd_err_m)
                load_pend <= 1'b1;
            if (~load_lev_m)
                load_seen_m <= 1'b0;
            else if (load_pend)
                load_seen_m <= 1'b1;
        end
    end
    assign mgr_request_save = start_go;
    assign mgr_request_load = load_go;

    // ======================================================================
    // slot adapter: 64-bit slot words <-> 2x 32-bit SDRAM words
    // ======================================================================
    // ---- read (manager LOAD path) ----
    // The manager holds slot_rd (level) until slot_ready. One 64-bit slot
    // word = TWO sequential SDRAM reads; between them ssrd_req must fall and
    // re-rise (the owner's ssrd_done level is held while ssrd_req, so a
    // continuous level would re-trigger on the stale done).
    reg  [1:0] ssrd_lvl_c = 2'd0;
    reg  [14:0] ssrd_addr_c = 15'd0;
    reg  [14:0] ssrd_addr_d1 = 15'd0;   // sync stage 1 (raw) -> stage 2 (used)
    reg  [1:0] ssrd_st = 2'd0;        // 0=IDLE 1=RD_LO 2=GAP 3=RD_HI
    reg  [23:0] ssrd_base_c = 24'd0;
    reg  [31:0] ssrd_lo_r = 32'd0;    // static from its op's completion
    reg  ssrd_done_lvl = 1'b0;        // level: set at hi completion, cleared
                                       // by the machine-side ack
    reg         ssrd_last_v = 1'b0;   // word-boundary gate: the trigger is
    reg  [14:0] ssrd_last_a = 15'd0;  // allowed only when the manager's
                                       // slot_addr differs from the last
                                       // triggered word. The manager holds
                                       // slot_rd (level) across consecutive
                                       // words and advances slot_addr only on
                                       // slot_ready; re-arming on the held
                                       // level with the OLD addr re-runs the
                                       // same word and delivers a second done
                                       // level = a double advance in the
                                       // manager (corrupted shadow/RAM).
    wire ssrd_addr_stable_c = (ssrd_addr_c == ssrd_addr_d1);
    wire [23:0] ssrd_word_hi_c = ssrd_base_c + 24'd1;
    // +1 word: the host's load-write places the blob at B.. with stored[0]
    // (its stale first-latch word) at B, so the savestate proper sits at
    // B+1 (2026-11-15; see the header's host-transport note). The SAVE
    // (sswr) base is NOT shifted - it writes at B and the host's one-word
    // behind latch captures it as the file's word 1.
    wire [24:0] ssrd_base_sum  = {1'b0, BLOB_BASE + 24'd1} + {9'd0, ssrd_addr_c, 1'b0};
    always @(posedge clk_ctrl) begin
        ssrd_lvl_c   <= {ssrd_lvl_c[0], mgr_slot_rd};
        // 2FF vector sync (mach -> ctrl): the manager holds slot_addr
        // stable through each slot word (it advances only on slot_ready),
        // and the stability check requires two consecutive equal samples.
        // (The earlier bit-serial shift loaded only bit 14: the ctrl side
        // never saw the real address - round-trip TB hang, 2026-11-12.)
        ssrd_addr_d1 <= mgr_slot_addr_m;
        ssrd_addr_c  <= ssrd_addr_d1;
        if (!rst_ctrl) begin
            ssrd_st       <= 2'd0;
            ssrd_done_lvl <= 1'b0;
            ssrd_last_v   <= 1'b0;
        end else begin
            case (ssrd_st)
                2'd0: if (ssrd_lvl_c[1] && ssrd_addr_stable_c
                         && (!ssrd_last_v || ssrd_addr_c != ssrd_last_a)) begin
                          ssrd_base_c <= ssrd_base_sum[23:0];   // carry always 0
                          ssrd_st     <= 2'd1;
                          ssrd_last_v <= 1'b1;
                          ssrd_last_a <= ssrd_addr_c;
                      end
                2'd1: if (ssrd_done) begin
                          ssrd_lo_r <= ssrd_data;
                          ssrd_st   <= 2'd2;      // GAP: req falls
                      end
                2'd2: ssrd_st <= 2'd3;            // req re-arms here
                2'd3: if (ssrd_done) begin
                          ssrd_st       <= 2'd0;
                          ssrd_done_lvl <= 1'b1;  // hi done -> level
                      end
                default: ssrd_st <= 2'd0;
            endcase
            // clear by machine-side ack (2FF of the level, mach domain)
            if (ssrd_ack_c)
                ssrd_done_lvl <= 1'b0;
        end
    end
    assign ssrd_req  = (ssrd_st == 2'd1) || (ssrd_st == 2'd3);
    assign ssrd_addr = (ssrd_st == 2'd3) ? ssrd_word_hi_c : ssrd_base_c;

    // machine-side view of the read done level + the half-word mirrors
    reg  [1:0] ssrd_done_s = 2'd0;
    reg  [31:0] ssrd_lo_m = 32'd0;
    reg  [31:0] ssrd_hi_m = 32'd0;
    reg  ssrd_ack_m = 1'b0;
    reg  slot_ready_r_m;
    always @(posedge clk_mach) begin
        ssrd_done_s <= {ssrd_done_s[0], ssrd_done_lvl};
        // half-words: continuously mirrored; each is static well before the
        // done level rises (lo: one full op earlier; hi: 1 ctrl cycle), so
        // these syncs only ever sample quiescent values.
        ssrd_lo_m   <= ssrd_lo_r;
        ssrd_hi_m   <= ssrd_data;
        // ready pulse = level rising as seen in the machine domain
        slot_ready_r_m <= ssrd_done_s[1] & ~ssrd_done_s[0];
        // ack: once the level is visible, hold ack until it has fully
        // decayed (lets the ctrl side re-arm cleanly for the next op)
        if (ssrd_done_s[1])
            ssrd_ack_m <= 1'b1;
        else if (!ssrd_done_s[0])
            ssrd_ack_m <= 1'b0;
    end
    // ack back to ctrl (2FF)
    reg [1:0] ssrd_ack_s;
    wire      ssrd_ack_c;
    always @(posedge clk_ctrl)
        ssrd_ack_s <= {ssrd_ack_s[0], ssrd_ack_m};
    assign ssrd_ack_c = ssrd_ack_s[1];

    // the manager samples slot_rdata in the slot_ready cycle; both halves
    // are quiescent machine-domain mirrors by then.
    assign mgr_slot_rdata_m = {ssrd_hi_m, ssrd_lo_m};

    // ---- write (manager SAVE path) ----
    // The manager holds slot_wr (level) until slot_ready. Each 64-bit slot
    // word = two SDRAM write ops (low then high). Pulse discipline as the
    // bridge's hwr client: one pulse per word while the port is idle and no
    // read level is armed (port_wr_idle); an in-flight latch blocks
    // re-pulsing; a watchdog recovers from a stolen op-start attribution
    // (read level rising in the pulse->start gap) by re-issuing - the
    // rewrite is idempotent.
    reg  [1:0] sswr_lvl_c = 2'd0;
    reg  [14:0] sswr_addr_c = 15'd0;
    reg  [14:0] sswr_addr_d1 = 15'd0;  // sync stage 1 (raw) -> stage 2 (used)
    reg  [31:0] sswr_lo_c = 32'd0;   // static latches for the two ops
    reg  [31:0] sswr_hi_c = 32'd0;
    reg  [1:0] sswr_st = 2'd0;      // 0=IDLE 1=WR_LO 2=WR_HI
    reg  [23:0] sswr_base_c = 24'd0;
    reg  sswr_inflight = 1'b0;
    reg  [11:0] sswr_watch = 12'd0;
    reg  [3:0] sswr_retry = 4'd0;   // 2026-11-14: 16 re-pulse attempts
    reg  sswr_stall = 1'b0;          // 2026-11-13: give up (no advance, no done)
    reg  sswr_done_lvl = 1'b0;      // level, as the read side
    reg         sswr_last_v = 1'b0; // word-boundary gate, as the read side:
    reg  [14:0] sswr_last_a = 15'd0; // the 0->1 trigger needs a NEW
    wire sswr_addr_stable_c = (sswr_addr_c == sswr_addr_d1);
    wire [23:0] sswr_word_hi_c = sswr_base_c + 24'd1;
    wire [24:0] sswr_base_sum  = {1'b0, BLOB_BASE} + {9'd0, sswr_addr_c, 1'b0};
    always @(posedge clk_ctrl) begin
        sswr_lvl_c   <= {sswr_lvl_c[0], mgr_slot_wr};
        // 2FF vector sync (mach -> ctrl), as the read side (the bit-serial
        // shift only loaded bit 14 - see the ssrd note).
        sswr_addr_d1 <= mgr_slot_addr_m;
        sswr_addr_c  <= sswr_addr_d1;
        if (!rst_ctrl) begin
            sswr_st <= 2'd0; sswr_inflight <= 1'b0;
            sswr_watch <= 12'd0; sswr_done_lvl <= 1'b0;
            sswr_retry <= 4'd0; sswr_stall <= 1'b0;
            sswr_last_v <= 1'b0;
            sswr_lo_c <= 32'd0;
            sswr_hi_c <= 32'd0;
        end else begin
            if (sswr_inflight) begin
                // 2026-11-14 (hardware save failure): count IDLE cycles only.
                // A pulse can be silently dropped when a read arms in the
                // arm->pulse gap (the owner masks word_wr by read_armed - no
                // op, no done). With a mounted disk the WOZ flux reads arm
                // continuously, so drops were frequent: the old free-running
                // 64-cycle watch + 3-retry budget burned through on healthy
                // contention and sswr_stall froze the machine mid-save.
                // Now: a BUSY port means our op is queued or in flight
                // (legitimate wait - no budget); only port-IDLE cycles with
                // no done count toward a lost pulse (re-pulse when idle
                // again). 16 attempts cover a sustained track-read gap.
                if (!sswr_busy)
                    sswr_watch <= sswr_watch + 12'd1;
                if (sswr_done) begin
                    // healthy completion: advance, reset the retry budget
                    sswr_inflight <= 1'b0;
                    sswr_retry    <= 4'd0;
                    if (sswr_st == 2'd1)
                        sswr_st <= 2'd2;             // low done -> high word
                    else begin
                        sswr_st       <= 2'd0;
                        sswr_done_lvl <= 1'b1;       // both done -> level
                    end
                end else if (sswr_watch == 12'd64) begin
                    // lost op (pulse dropped while the port went idle):
                    // re-pulse, do NOT advance. Drop inflight; the arm
                    // re-fires next idle cycle (a fresh sswr_req rising edge
                    // -> a new port queue arm). Writes are idempotent (same
                    // addr/data), so re-issuing is safe. After 15 re-pulses
                    // stall (no advance, no done_lvl): a save that reports
                    // failure beats a silently corrupt blob.
                    sswr_inflight <= 1'b0;
                    if (sswr_retry == 4'd15)
                        sswr_stall <= 1'b1;
                    else
                        sswr_retry <= sswr_retry + 4'd1;
                end
            end else if (sswr_lvl_c[1] && !sswr_stall) begin
                if (sswr_st == 2'd0 && sswr_addr_stable_c
                    && (!sswr_last_v || sswr_addr_c != sswr_last_a)) begin
                    sswr_base_c <= sswr_base_sum[23:0];   // carry always 0
                    sswr_st     <= 2'd1;                  // -> WR_LO
                    sswr_retry  <= 4'd0;
                    sswr_last_v <= 1'b1;
                    sswr_last_a <= sswr_addr_c;
                    // latch the payload at the word trigger: the manager
                    // holds slot_wdata until its slot_ready for this word
                    // (which comes only AFTER both ops), and it drops
                    // slot_wdata to 0 the cycle it advances (FINISH has no
                    // wdata branch). Per-cycle re-latching raced the HI-op
                    // arm when a refresh delayed it past the manager's
                    // advance - the last word's HI half then wrote 0
                    // (round-trip TB, 2026-11-12).
                    sswr_lo_c <= mgr_slot_wdata_m[31:0];
                    sswr_hi_c <= mgr_slot_wdata_m[63:32];
                end
                if ((sswr_st == 2'd1 || sswr_st == 2'd2) && !sswr_busy
                    && port_wr_idle) begin
                    sswr_inflight <= 1'b1;           // pulse next cycle
                    // 2026-11-13 (expert review): sswr_watch was free-running
                    // (only cleared by rst_ctrl), so watch==4095 fired every
                    // ~4096 cumulative inflight cycles and watchdog-killed
                    // healthy ops mid-flight. Reset it per op arm.
                    sswr_watch    <= 12'd0;
                end
            end
            // clear by machine-side ack
            if (sswr_ack_c)
                sswr_done_lvl <= 1'b0;
        end
    end
    // the pulse is the in-flight LATCH EDGE: one ctrl cycle per word.
    // (sswr_req high for >1 cycle would hold word_wr through the op's idle
    // tail; the port single-queues so no duplicate op starts, but a 1-cycle
    // pulse is the store-client protocol shape anyway.)
    reg sswr_pulse_d = 1'b0;
    assign sswr_req  = sswr_inflight & ~sswr_pulse_d;
    always @(posedge clk_ctrl)
        sswr_pulse_d <= sswr_inflight;
    assign sswr_addr = (sswr_st == 2'd2) ? sswr_word_hi_c : sswr_base_c;
    assign sswr_data = (sswr_st == 2'd2) ? sswr_hi_c : sswr_lo_c;

    // diagnostics (host-readable progress/status) - taps only, no logic change
    assign dbg_sswr_stall = sswr_stall;
    assign dbg_sswr_retry = sswr_retry;
    // 2026-11-16 SSD/SSX: ctrl-domain state word (REVERT for shipping):
    //   [4:0] manager FSM state   [5] sswr_inflight   [6] sswr_stall
    //   [10:7] sswr_retry         [11:10] ssrd_st     [13:12] sswr_st
    //   [15] spare
    wire [4:0] mgr_dbg_state_m;
    assign dbg_ss_state = {1'b0, sswr_st, ssrd_st, sswr_retry,
                           sswr_stall, sswr_inflight, mgr_dbg_state_m};
    assign dbg_word_idx   = sswr_addr[15:0];

    // machine-side done level + ack (same pattern as the read side)
    reg  [1:0] sswr_done_s = 2'd0;
    reg  sswr_ack_m = 1'b0;
    reg  slot_ready_w_m;
    always @(posedge clk_mach) begin
        sswr_done_s <= {sswr_done_s[0], sswr_done_lvl};
        slot_ready_w_m <= sswr_done_s[1] & ~sswr_done_s[0];
        if (sswr_done_s[1])
            sswr_ack_m <= 1'b1;
        else if (!sswr_done_s[0])
            sswr_ack_m <= 1'b0;
    end
    reg  [1:0] sswr_ack_s;
    wire       sswr_ack_c;
    always @(posedge clk_ctrl)
        sswr_ack_s <= {sswr_ack_s[0], sswr_ack_m};
    assign sswr_ack_c = sswr_ack_s[1];

    // the manager only ever drives slot_rd or slot_wr, never both
    assign mgr_slot_ready_m = slot_ready_r_m | slot_ready_w_m;

    // ======================================================================
    // 74a side: core_bridge_cmd handshake contract (W0-proven shape)
    // ======================================================================
    reg start_d1, load_d1;
    always @(posedge clk_74a) begin
        if (rst_74a) begin
            start_d1 <= 1'b0;
            load_d1  <= 1'b0;
        end else begin
            start_d1 <= savestate_start;
            load_d1  <= savestate_load;
        end
    end
    wire start_rise = savestate_start & ~start_d1;
    wire load_rise  = savestate_load  & ~load_d1;

    wire mgr_done_74, mgr_done_rise_74, mgr_err_74, mgr_busy_74;
    synch_3 s_done (.i(mgr_done_m), .o(mgr_done_74), .clk(clk_74a),
                    .rise(mgr_done_rise_74), .fall());
    synch_3 s_err  (.i(mgr_err_m),  .o(mgr_err_74),  .clk(clk_74a),
                    .rise(), .fall());
    synch_3 s_busy (.i(mgr_busy_m), .o(mgr_busy_74), .clk(clk_74a),
                    .rise(), .fall());

    reg start_ok_r, start_err_r, load_ok_r, load_err_r;
    reg start_inflight_r, load_inflight_r;
    reg op_is_load_r;
    always @(posedge clk_74a) begin
        if (rst_74a) begin
            start_ok_r         <= 1'b0;
            start_err_r        <= 1'b0;
            load_ok_r          <= 1'b0;
            load_err_r         <= 1'b0;
            start_inflight_r   <= 1'b0;
            load_inflight_r    <= 1'b0;
            op_is_load_r       <= 1'b0;
        end else begin
        // contract: ok/err clear when a new process starts (a sticky
        // watchdog error keeps its err visible - no new op may clear it)
        if (start_rise && !wd_err_sticky) begin
            start_ok_r  <= 1'b0;
            start_err_r <= 1'b0;
        end
        if (load_rise && !wd_err_sticky) begin
            load_ok_r  <= 1'b0;
            load_err_r <= 1'b0;
        end
        // manager completion (done and error asserted together on the FAIL
        // path; one op at a time, so the op type at done is the last command)
        if (mgr_done_rise_74) begin
            if (op_is_load_r) begin
                load_ok_r  <= ~mgr_err_74;
                load_err_r <= mgr_err_74;
            end else begin
                start_ok_r  <= ~mgr_err_74;
                start_err_r <= mgr_err_74;
            end
        end
        if (start_rise && !wd_err_sticky) op_is_load_r <= 1'b0;
        if (load_rise  && !wd_err_sticky) op_is_load_r <= 1'b1;
        // inflight window: from the command until completion (drives busy);
        // the sticky watchdog state takes no new ops
        if (start_rise && !wd_err_sticky)
            start_inflight_r <= 1'b1;
        else if (start_ok_r | start_err_r)
            start_inflight_r <= 1'b0;
        if (load_rise && !wd_err_sticky)
            load_inflight_r <= 1'b1;
        else if (load_ok_r | load_err_r)
            load_inflight_r <= 1'b0;
        // watchdog expiry: slot-level transport error for the stuck op
        if (wd_fire_q) begin
            if (op_is_load_r) begin
                load_err_r        <= 1'b1;
                load_inflight_r   <= 1'b0;
            end else begin
                start_err_r       <= 1'b1;
                start_inflight_r  <= 1'b0;
            end
        end
        end  // if (rst_74a) else
    end

    // ---- containment watchdog (2026-11-16, Step 4) ----
    // Counts ONLY the dead window: a 74a-side inflight op with no mach-side
    // activity (the exact wedge state: busy=1, mgr IDLE, zero SDRAM traffic).
    // ~100 ms at 74.25 MHz. On expiry: latched slot-level transport error
    // (the manager's 2-bit error_code is NOT reused), inflight cleared, fast
    // ERR to the host; a sticky flag blocks new ops (fast-err path) until
    // rst_74a (host core reset/re-init). A partially-applied LOAD abort is
    // out of scope - an ERR after load-start requires a reboot.
    // The err/inflight INJECTION lives in the ok/err block below (single
    // writer per register); this block owns only its own state + the
    // one-cycle fire pulse.
    localparam [22:0] WD_LIMIT = 23'd7_425_000;   // ~100 ms @ 74.25 MHz
    reg  [22:0] wd_cnt;
    reg         wd_err_sticky;
    reg         wd_fire_q;
    wire        wd_run  = (start_inflight_r | load_inflight_r) & ~mgr_busy_74;
    always @(posedge clk_74a) begin
        if (rst_74a) begin
            wd_cnt        <= 23'd0;
            wd_err_sticky <= 1'b0;
            wd_fire_q     <= 1'b0;
        end else begin
            if (wd_run) begin
                if (wd_cnt != WD_LIMIT)
                    wd_cnt <= wd_cnt + 23'd1;
            end else
                wd_cnt <= 23'd0;
            wd_fire_q     <= wd_run && (wd_cnt == WD_LIMIT);
            if (wd_run && (wd_cnt == WD_LIMIT))
                wd_err_sticky <= 1'b1;
        end
    end

    // ---- start / load ack (per-command lifecycle, 2026-11-16) ----
    // The ack asserts only after the MACH-side captured token has crossed
    // back (2FF) - so the host holds the level across the mach-domain
    // capture BY CONSTRUCTION (the level-based pender then cannot miss) -
    // and returns LOW with the level: NO stale self-hold. The stale-high
    // ack was the L0 race: for every command after the first the host
    // released the level after ~2 74a cycles (27 ns), narrower than one
    // mach period, and the pulse-catcher missed phase-dependently
    // (tb_ss_cmdrace: 3/6 phases lost; field: save #N wedge).
    // In the sticky watchdog-err state the ack responds immediately
    // (fast-err path: the host exits the request, polls, and sees err).
    reg start_tok_74_c0, start_tok_74_c1;   // 2FF mach->74a of the token
    reg load_tok_74_c0,  load_tok_74_c1;
    reg start_ack_r, load_ack_r;
    always @(posedge clk_74a) begin
        start_tok_74_c1 <= start_tok_74_c0;
        start_tok_74_c0 <= start_seen_m;
        load_tok_74_c1  <= load_tok_74_c0;
        load_tok_74_c0  <= load_seen_m;
        if (rst_74a) begin
            start_ack_r <= 1'b0;
            load_ack_r  <= 1'b0;
        end else begin
            if (savestate_start)
                start_ack_r <= (start_tok_74_c1 | wd_err_sticky);
            else
                start_ack_r <= 1'b0;
            if (savestate_load)
                load_ack_r <= (load_tok_74_c1 | wd_err_sticky);
            else
                load_ack_r <= 1'b0;
        end
    end

    // busy: in flight (command accepted, op not complete) or the manager is
    // running - the host polls resultcode 1 until ok/err.
    assign savestate_start_ack  = start_ack_r;
    assign savestate_start_busy = start_inflight_r | mgr_busy_74;
    assign savestate_start_ok   = start_ok_r;
    assign savestate_start_err  = start_err_r;
    assign savestate_load_ack   = load_ack_r;
    assign savestate_load_busy  = load_inflight_r | mgr_busy_74;
    assign savestate_load_ok    = load_ok_r;
    assign savestate_load_err   = load_err_r;

    // word-0 preload after a SAVE completes (the host's first burst read
    // latches whatever the response register holds - it must be the NEW
    // blob word 0, not the pre-capture one).
    reg start_ok_d1;
    always @(posedge clk_74a)
        start_ok_d1 <= start_ok_r;
    wire start_ok_rise = start_ok_r & ~start_ok_d1;
    assign preload_req = start_ok_rise & ~op_is_load_r;

endmodule
