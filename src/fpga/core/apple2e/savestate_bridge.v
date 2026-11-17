//
// savestate_bridge.v - the host's 0x40xxxxxx savestate-blob window (W1)
//
// PLAN_SAVESTATES_2026-11-09 phase 3; EXPERT_BRIEF_SAVESTATE_MANAGER_2026-11-11.
//
// The openFPGA host owns the .sta file I/O; the core's job is to expose one
// 131,328-byte blob at BRIDGE address 0x40000000, backed by SDRAM word base
// 0x400000 (16 MB, past the WOZ max). This module is the window:
//
//   SAVE:  host reads the blob  -> rd FIFO (74a->ctrl) -> owner CL_HOST_RD
//         -> SDRAM -> response register -> bridge_rd_data arm. The response
//         register is PRELOADED with the (new) blob word 0 after each save
//         completes: the APF bridge's 1-word read buffer loses the first read
//         of a burst (EXPERT_BRIEF_SAVESTATE_PROBE rounds 3/3b), so the
//         preloaded value is what the first ST_READ_0 latches.
//   LOAD:  host writes the blob  -> wr FIFO (74a->ctrl) -> owner CL_HOST_WR
//         -> SDRAM. The drain flag (FIFO empty + no op in flight) gates the
//         manager's load start, so the manager never reads half-written data.
//
// Clocks: clk_74a (74.25, host/bridge), clk_ctrl (133.12, SDRAM controller
// domain, owner's clock). The two slot_fifos are the only CDC crossings
// (Clifford, same pattern as the image-load slot_fifo).
//
// Window decode: bridge_addr[31:26] == 4'b010000 (0x40xxxxxx, 16 MiB);
// blob SDRAM word = 0x400000 + bridge_addr[23:2]. The blob is 32,832 words;
// the rest of the window is legal SDRAM the host never touches.
//
`timescale 1ns/10ps
module savestate_bridge (
    // ---- 74a (host/bridge) domain ----
    input  wire        clk_74a,
    input  wire        rst_74a,          // active-high (sdram_path_rst)
    input  wire        bridge_rd,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    input  wire        preload_req,      // 1-cycle: fetch blob word 0 into the
                                         // response register (word-0 fix)
    output wire [31:0] rd_data,          // response register (the top's
                                         // 0x40xxxxxx bridge_rd_data arm)
    output wire        preload_done_74a, // 1-cycle: preload word captured
    output wire        wr_drained_74a,   // write FIFO empty + no op in flight
    output wire        rd_overflow_74a,  // sticky (cleared by reset)
    output wire        wr_overflow_74a,
    output wire [8:0]  dbg_rd_hw,        // rd-FIFO max occupancy (host status reg)
    // ---- ctrl (sdram_word_owner) domain ----
    input  wire        clk_ctrl,
    input  wire        rst_ctrl,         // active-LOW
    // owner CL_HOST_RD
    output wire        hr_req,
    output wire [23:0] hr_addr,
    input  wire        hr_done,
    input  wire [31:0] hr_data,
    // owner CL_HOST_WR
    output wire        hwr_req,
    output wire [23:0] hwr_addr,
    output wire [31:0] hwr_data,
    input  wire        hwr_done,
    input  wire        hwr_busy,
    input  wire        port_wr_idle
);

    localparam [23:0] BLOB_BASE = 24'h040_0000;   // SDRAM word 0x400000 (16 MB)

    // ======================================================================
    // 74a side: window decode + FIFO write ports + response register
    // ======================================================================
    wire        in_window = (bridge_addr[31:26] == 6'b010000);
    wire [23:0] win_word  = bridge_addr[25:2];
    wire [23:0] sd_word   = BLOB_BASE + win_word;

    // read push: a preload request wins over a concurrent bridge read (the
    // host never reads the window mid-handshake; the preload must stay first
    // in FIFO order, ahead of the burst's entries).
    wire rd_push_pre = preload_req;
    wire rd_push_hst = bridge_rd & in_window & ~preload_req;
    wire rd_fifo_wen = rd_push_pre | rd_push_hst;

    wire wr_fifo_wen = bridge_wr & in_window;

    // data-return path (ctrl -> 74a): the ctrl side pulses rd_ret_p on the
    // cycle it retires an hr op (hr_data stable); a 3FF pulse + parallel
    // 3FF data + 3FF pre-flag, latched when the pulse crosses.
    wire        rd_ret_p;
    wire        rd_ret_pre_flag_c;
    wire [31:0] rd_ret_data;
    reg  [3:0]  dret_s  = 4'd0;
    reg  [3:0]  dpre_s  = 4'd0;
    reg  [31:0] ddata_s = 32'd0;
    always @(posedge clk_74a) begin
        dret_s  <= {dret_s[2:0], rd_ret_p};
        dpre_s  <= {dpre_s[2:0], rd_ret_pre_flag_c};
        // hr_data is stable for the whole event (held while hr_done; the
        // next op is >= 10 ctrl cycles away), so a 1-stage mirror is aligned
        ddata_s <= rd_ret_data;
    end
    wire dret_cross = dret_s[3] & dret_s[2] & ~dret_s[1];
    reg  [31:0] rd_resp = 32'd0;
    reg         preload_done_r = 1'b0;
    always @(posedge clk_74a) begin
        preload_done_r <= 1'b0;
        if (dret_cross) begin
            // the pre-flag is stable across the event (one return per op,
            // >= 10 ctrl cycles apart), so both its top FFs carry the value
            rd_resp        <= ddata_s[31:0];
            preload_done_r <= dpre_s[3] & dpre_s[2];
        end
    end
    assign rd_data = rd_resp;
    assign preload_done_74a = preload_done_r;

    // write-drain flag (ctrl -> 74a): FIFO empty && no hwr op in flight.
    reg [1:0] drn_s = 2'd0;
    always @(posedge clk_74a)
        drn_s <= {drn_s[0], wr_drained_c};
    assign wr_drained_74a = drn_s[1];

    slot_fifo #(.DEPTH(16)) rdf (
        .wr_clk       ( clk_74a ),
        .rst          ( rst_74a ),
        .wr_en        ( rd_fifo_wen ),
        .wr_addr      ( rd_push_pre ? BLOB_BASE : sd_word ),
        .wr_data      ( 32'd0 ),
        .overflow_clr ( 1'b0 ),
        .full         ( ),
        .overflow     ( rd_overflow_74a ),
        .high_water   ( dbg_rd_hw ),
        .rd_clk       ( clk_ctrl ),
        .empty        ( rd_empty_c ),
        .rd_en        ( rd_fifo_ren_c ),
        .rd_valid     ( ),
        .rd_addr      ( rd_fifo_addr_c ),
        .rd_data      ( )
    );

    slot_fifo #(.DEPTH(16)) wrf (
        .wr_clk       ( clk_74a ),
        .rst          ( rst_74a ),
        .wr_en        ( wr_fifo_wen ),
        .wr_addr      ( sd_word ),
        .wr_data      ( bridge_wr_data ),
        .overflow_clr ( 1'b0 ),
        .full         ( ),
        .overflow     ( wr_overflow_74a ),
        .high_water   ( ),
        .rd_clk       ( clk_ctrl ),
        .empty        ( wr_empty_c ),
        .rd_en        ( wr_fifo_ren_c ),
        .rd_valid     ( ),
        .rd_addr      ( wr_fifo_addr_c ),
        .rd_data      ( wr_fifo_data_c )
    );

    // ======================================================================
    // ctrl side: owner client drives
    // ======================================================================
    // ---- CL_HOST_RD (level, held until the word completes) ----
    // rd_wait arms hr_req while the FIFO is non-empty; the owner's hr_done
    // (held while hr_req) retires the entry. If another read client is
    // armed (WOZ fetch, verifier) the op queues behind it - the level is
    // held until OUR op completes, per the owner attribution invariant.
    reg  rd_wait = 1'b0;
    wire rd_fifo_ren_c;
    // 2026-11-13: ren fires on the ARM edge (one cycle before rd_wait
    // rises), not on hr_done. The FIFO's rd_addr/rd_data are REGISTERED
    // on rd_en (one cycle behind the request), so firing ren on hr_done
    // made hr_addr the PREVIOUS entry's address: the first op read SDRAM
    // word 0 instead of the preload's BLOB_BASE, and every host read
    // returned the previous entry's data. Ren at arm: rd_addr presents
    // the head by the cycle rd_wait/hr_req rise and stays stable
    // through the op (owner contract: hr_addr stable while hr_req).
    wire rd_arm = !rd_wait & !rd_empty_c;
    assign rd_fifo_ren_c = rd_arm;
    always @(posedge clk_ctrl) begin
        if (!rst_ctrl)   // active-LOW (2026-11-13: the old `if (rst_ctrl)`
            rd_wait <= 1'b0;   // held this FSM in reset forever in operation)
        else if (!rd_wait && !rd_empty_c)
            rd_wait <= 1'b1;
        else if (rd_wait & hr_done)
            rd_wait <= 1'b0;
    end
    assign hr_req         = rd_wait;
    assign hr_addr        = rd_fifo_addr_c;

    // data return -> 74a (pulse + data; the pre-flag marks the preload entry)
    reg rd_ret_p_r = 1'b0;
    reg rd_ret_pre_flag_c_r = 1'b0;
    // 2026-11-13: hold the ret pulse for 4 ctrl cycles. One ctrl cycle
    // (7.5 ns) is SHORTER than one clk_74a cycle (13.5 ns), so the 74a
    // domain can sample it at most once - but dret_cross (the 1101
    // pattern in the 4-FF chain) needs the pulse to span >= 2 74a
    // samples, so a single sample can never trigger it: the return was
    // lost (phase-dependent on hardware, always lost in the sim's
    // irrational clock ratio). 4 ctrl cycles (30 ns) > 2 x 13.5 ns, so
    // the pulse always spans >= 2 74a samples and dret_cross fires
    // exactly once. The pre-flag shares the widened window (its 4-FF
    // chain has the same 2-sample requirement). Consecutive rets are
    // one hr op apart (>= 14 74a cycles), so windows never overlap.
    // 2026-11-13: widen the hold to 8 ctrl cycles. At the shipping 133.12
    // MHz ctrl rate 4 cycles (30 ns) already span >= 2 clk_74a periods,
    // but the sim harness (tb_sector_fetch lineage) runs ctrl at 266 MHz
    // (its PC=3.756 is a HALF period, not the 7.504 ns of the real PLL),
    // where 4 cycles = 15 ns = 1.1x the 74a period - a single 74a sample
    // that dret_cross (1101 in the 4-FF chain) can never see. 8 cycles is
    // 30 ns at 266 MHz (2.2x) and 60 ns at 133.12 MHz (4.5x): dret_cross
    // fires exactly once in both. The pre-flag shares the window; rets are
    // one hr op apart, so windows never overlap.
    reg [2:0] rd_ret_hold = 3'd0;
    always @(posedge clk_ctrl) begin
        if (rd_ret_p_r) begin
            rd_ret_hold <= rd_ret_hold + 3'd1;
            if (rd_ret_hold == 3'd7) begin
                rd_ret_p_r          <= 1'b0;
                rd_ret_pre_flag_c_r <= 1'b0;
            end
        end else if (rd_wait & hr_done) begin
            rd_ret_p_r          <= 1'b1;
            // preload entry = BLOB_BASE address (word 0)
            rd_ret_pre_flag_c_r <= (rd_fifo_addr_c == BLOB_BASE);
            rd_ret_hold         <= 3'd0;
        end
    end
    assign rd_ret_p          = rd_ret_p_r;
    assign rd_ret_pre_flag_c = rd_ret_pre_flag_c_r;
    assign rd_ret_data       = hr_data;

    // ---- CL_HOST_WR (fetch -> present -> pulse; one ren per record) ----
    // 2026-11-16 (expert review, finding 1): the old code issued hwr_req
    // whenever the FIFO was nonempty, used the FIFO's CURRENT output
    // registers, and dequeued (ren) only AFTER the write completed. But
    // slot_fifo is a REGISTERED-output FIFO: rd_en pops the head and the
    // record appears on rd_addr/rd_data one cycle later (rd_valid pulses
    // on that cycle). So the old path wrote the stale/reset output first,
    // trailed the FIFO contents by one record on every subsequent write,
    // and left the last record unwritten when empty went true. (Same
    // shape as the rd-side bug fixed 2026-11-13: ren belongs at the ARM
    // edge, not at completion.)
    //
    // Now: one FSM per record - IDLE (ren fires combinationally if
    // issueable) -> PRESENT (output settles, 1 cycle) -> REQ (1-cycle
    // hwr_req pulse carrying the settled head; the owner's wcap captures
    // it this cycle) -> INFLIGHT (wait hwr_done). The watchdog re-issues
    // REQ WITHOUT re-rening: a lost op (masked pulse / port-queue drop,
    // findings 2-3) must not advance the FIFO, and the rewrite is
    // idempotent (same addr/data, output still presents the head).
    // Pulse discipline unchanged: one op at a time, only while the port
    // is idle and no read level is armed (port_wr_idle).
    localparam [1:0] WR_IDLE     = 2'd0,
                     WR_PRESENT  = 2'd1,
                     WR_REQ      = 2'd2,
                     WR_INFLIGHT = 2'd3;
    reg  [1:0] wr_state = WR_IDLE;
    reg  [11:0] wr_watch = 12'd0;
    wire wr_can_issue = !wr_empty_c & !hwr_busy & port_wr_idle;
    wire wr_fifo_ren_c;
    assign wr_fifo_ren_c = (wr_state == WR_IDLE) && wr_can_issue;
    assign hwr_req   = (wr_state == WR_REQ);
    assign hwr_addr  = wr_fifo_addr_c;
    assign hwr_data  = wr_fifo_data_c;
    always @(posedge clk_ctrl) begin
        if (!rst_ctrl) begin   // active-LOW (2026-11-13: the old
            wr_state <= WR_IDLE;  // `if (rst_ctrl)` re-pulsed the FIFO head
            wr_watch <= 12'd0;    // forever)
        end else case (wr_state)
        WR_IDLE:
            if (wr_can_issue) wr_state <= WR_PRESENT;
        WR_PRESENT: begin
            // rd_addr/rd_data settled one cycle after ren - pulse next
            wr_state <= WR_REQ;
        end
        WR_REQ: begin
            // hwr_req is high this cycle (1-cycle pulse)
            wr_state <= WR_INFLIGHT;
            wr_watch <= 12'd0;
        end
        WR_INFLIGHT: begin
            wr_watch <= wr_watch + 12'd1;
            if (hwr_done)
                wr_state <= WR_IDLE;
            else if (wr_watch == 12'd4095)
                wr_state <= WR_REQ;   // re-issue SAME record (no re-ren)
        end
        default: wr_state <= WR_IDLE;
        endcase
    end

    wire wr_drained_c = wr_empty_c & (wr_state == WR_IDLE);
    // compat: the integration TB taps this name (hwr op in flight)
    wire wr_inflight = (wr_state == WR_INFLIGHT);

    // read-side FIFO state (driven by the instances above)
    wire        rd_empty_c;
    wire [23:0] rd_fifo_addr_c;
    wire        wr_empty_c;
    wire [23:0] wr_fifo_addr_c;
    wire [31:0] wr_fifo_data_c;

endmodule
