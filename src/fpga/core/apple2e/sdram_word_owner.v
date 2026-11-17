//
// sdram_word_owner.v - explicit single-owner service for the io_sdram_pocket
// word port (M1 Unit 2 - pass-through discipline)
//
// M0's storage wrapper drove the word port directly from its clients:
//   word_rd   = verifier request level (2FF)
//   word_wr   = disk_store 1-cycle pulse (gated on port busy)
//   word_addr = req_kind ? verifier_addr : store_addr
// and the M0 read-data capture pipeline is calibrated to that exact
// op-start timing. Any re-latching of the drive signals by an
// intermediate service shifts op-start phases (measured: a 1-cycle
// additivity per op drifts the port phase over a 128-word load and
// breaks later read captures).
//
// This owner therefore drives the port as a PURE PASS-THROUGH:
//   * the read LEVEL is the requesting client's own level (combinational);
//   * the store PULSE is the store client's own pulse (combinational);
//   * the address/data mux is combinational (active client).
// Zero added cycles: op-start timing is bit-identical to M0 for the
// store and verifier clients, and the sector fetcher uses the same
// proven single-word level protocol (one read at a time, len 1).
//
// What the owner adds (on top of the pass-through):
//   * explicit ownership attribution: on op start (port busy rising)
//     the active client is latched; completion signals are routed to
//     that client only (no cross-client done/data);
//   * one read client at a time: the wrapper gates the fetcher level on
//     the verifier level being low, so at most one read level (and the
//     store pulse, which fires only while the port is idle) can arm the
//     port's single request queue at any time - the port's existing
//     single-queue discipline (inherited from M0) then guarantees one
//     op in flight with unambiguous attribution;
//   * fetcher bookkeeping: per-word valid/done/data with the latched
//     generation tag (the fetcher discards stale transfers by
//     generation, as designed).
//
// Domains: everything here is sdram_ctrl_clk (133.12 MHz). Machine-domain
// client levels are pre-synced by the storage wrapper, as in M0.
//
`timescale 1ns/10ps
module sdram_word_owner (
    input  wire        clk,        // sdram_ctrl_clk (133.12 MHz)
    input  wire        rst_n,      // core POR (async crossing; synced here)

    // ---- word port to io_sdram_pocket (same domain) ----
    output wire        word_rd,
    output wire        word_wr,
    output wire [23:0] word_addr,
    output wire [31:0] word_data,
    input  wire [31:0] word_q,
    input  wire        word_busy,
    input  wire        word_done,
    input  wire        word_rd_valid,
    input  wire        word_op_start,  // 2026-11-16: 1-cycle pulse at each word-op start
    input  wire        init_done,

    // ---- client: store (write, 1-cycle pulse while port idle) ----
    input  wire        st_req,
    input  wire [23:0] st_addr,
    input  wire [31:0] st_data,
    output wire        st_busy,    // port busy with any op
    output wire        st_done,    // 1-cycle: the in-flight store op completed

    // ---- client: verifier (level, read, one word at a time) ----
    input  wire        vr_req,     // level, pre-synced to this domain
    input  wire [23:0] vr_addr,    // stable while vr_req
    output wire        vr_done,    // level: this client's read completed
                                   // (held until the request deasserts, M0)
    output wire [31:0] vr_data,    // stable while vr_done

    // ---- client: sector fetcher (level, read, one word at a time,
    //         wrapper-gated so it never overlaps the verifier level) ----
    input  wire        fc_req,     // level; held until the word completes
    input  wire [23:0] fc_addr,    // stable while fc_req
    input  wire [7:0]  fc_gen,     // image generation tag (stable while fc_req)
    output wire        fc_active,  // fetcher owns the port right now
    output wire        fc_word_valid, // 1-cycle: a fetch-owned word completed
    output wire [31:0] fc_data,    // word just completed
    output wire        fc_done,    // 1-cycle: transfer (word) complete
    output wire [7:0]  fc_done_len, // always 1 (single-word protocol)
    output wire [7:0]  fc_done_gen, // generation tag of the completed transfer

    // ---- client: host bridge read (W0, PLAN_W0_2026-11-05) ----
    // SDRAM -> bridge bulk-read arm (nonvolatile slot read-back, savestate
    // blob). Same level protocol as verifier/fetcher. The request arrives
    // from the 74a-domain address FIFO's read side, which is already in
    // THIS domain (133.12) - no extra sync. Inert when hr_req=0: the three
    // legacy clients keep their exact op phases (WP1 gate).
    input  wire        hr_req,     // level; held until the word completes
    input  wire [23:0] hr_addr,    // stable while hr_req
    output wire        hr_done,    // 1-FF level: this client's read completed
    output wire [31:0] hr_data,    // stable while hr_done

    // ---- client: savestate manager read (W1, PLAN_SAVESTATES_2026-11-09) ----
    // Blob read for the LOAD path (machine-domain client, request pre-synced
    // to this domain by savestate_slot.v). Same level protocol as hr.
    // Inert when ssrd_req=0 (WP1 discipline, as CL_HOST_RD).
    input  wire        ssrd_req,   // level; held until the word completes
    input  wire [23:0] ssrd_addr,  // stable while ssrd_req
    output wire        ssrd_done,  // 1-FF level: this client's read completed
    output wire [31:0] ssrd_data,  // stable while ssrd_done

    // ---- client: savestate manager write (W1) ----
    // Blob write for the SAVE path. Pulse protocol like the store client:
    // one 1-cycle pulse while the port is idle, then wait for sswr_done
    // (the client re-pulses per word). Inert when sswr_req=0.
    input  wire        sswr_req,   // 1-cycle pulse while port idle
    input  wire [23:0] sswr_addr,  // stable while sswr_req
    input  wire [31:0] sswr_data,
    output wire        sswr_done,  // 1-cycle: the in-flight op completed
    output wire        sswr_busy,  // port busy with any op (re-pulse gate)
    // 2026-11-16 savestate SSD/SSX serial debug (REVERT for shipping):
    // in-flight client attribution for the tracer's SSX line.
    output wire [2:0]  dbg_inflight,

    // ---- client: host bridge blob write (W1) ----
    // LOAD path: the host writes the .sta blob via 0x40xxxxxx bridge
    // writes; savestate_bridge.v's 74a->ctrl FIFO read side pulses this
    // client one word at a time. Pulse protocol like the store client.
    // Inert when hwr_req=0.
    input  wire        hwr_req,    // 1-cycle pulse while port idle
    input  wire [23:0] hwr_addr,   // stable while hwr_req
    input  wire [31:0] hwr_data,
    output wire        hwr_done,   // 1-cycle: the in-flight op completed
    output wire        hwr_busy,   // port busy with any op (re-pulse gate)

    // ---- W1 write-issue gate ----
    // High when a write op can be issued right now (no read level armed,
    // SDRAM initialized). Pulse-write clients (sswr/hwr) must qualify their
    // pulses with this: while a read level is armed the owner drops write
    // pulses (word_wr masked), and a dropped pulse has no completion.
    output wire port_wr_idle
);

    localparam CL_NONE  = 3'd0;
    localparam CL_STORE = 3'd1;
    localparam CL_VERIFY= 3'd2;
    localparam CL_FETCH = 3'd3;
    localparam CL_HOST_RD = 3'd4;   // W0 host bridge read (3 bits: 4 needs 3; the old 2'd4 was 0 = CL_NONE)
    localparam CL_SS_RD   = 3'd5;   // W1 savestate manager blob read
    localparam CL_SS_WR   = 3'd6;   // W1 savestate manager blob write
    localparam CL_HOST_WR = 3'd7;   // W1 host bridge blob write

    reg         rst_n_s1;

    // ---- pass-through drive (zero added latency - M0 op phases) ----
    // At most one read level is high at any time (wrapper gates fc on
    // !vr). Writes are masked while ANY read client is armed: the port
    // dequeues reads before writes, so an armed read plus a store pulse
    // would queue both and the write op would start with a stale
    // read-client attribution (its word_done lost, store timeout) -
    // measured in TB T7/T9. The store client re-pulses on the next idle
    // cycle (disk_store protocol), so it simply waits out the transfer.
    // W0: the host read is a fourth read level. It joins the read priority
    // and masks the store pulse exactly like the other read clients; the
    // store client re-pulses on the next idle cycle (disk_store protocol).
    // W1: the savestate manager read (ssrd) is a fifth read level, and two
    // pulse-write clients (sswr = manager save, hwr = host load) join the
    // store. Write clients are mutually masked by FIXED PRIORITY
    // (st > sswr > hwr): only one write pulse can arm at a time, so the
    // port's single queue never holds two write ops (two queued writes
    // would make attribution at the start edge ambiguous and the second
    // client's word_done lost). When a client is unarmed its eff level is
    // 0 and every legacy op phase is bit-identical (WP1 gate).
    wire read_armed  = vr_req || fc_req || hr_req || ssrd_req;
    wire st_req_eff  = st_req && !read_armed;
    wire sswr_eff    = sswr_req && !read_armed && !st_req_eff;
    wire hwr_eff     = hwr_req && !read_armed && !st_req_eff && !sswr_eff;
    wire wr_armed    = st_req_eff || sswr_eff || hwr_eff;
    // W1: write-issue gate for external pulse clients (sswr/hwr). The owner
    // masks word_wr by read_armed, so a pulse issued while a read level is
    // armed is SILENTLY DROPPED (no op, no done) - pulse clients must check
    // this gate before pulsing (the store client instead re-pulses forever
    // per the disk_store protocol, so it needs no gate).
    assign port_wr_idle = init_done && !read_armed;
    // W1 read-grant driven (2026-11-15): see the rd_grant block at the end
    // of this module - the port's single 1-bit word_rd edge-latch queue
    // loses an op whenever a second read client arms while a read level
    // is already high, so at most ONE read client is presented at a time.
    // assign word_rd   = init_done && read_armed;   // RETIRED (raw OR)
    assign word_wr   = init_done && wr_armed;

    // ---- W1 write payload capture (2026-11-12, sector_fetch regression) ----
    // The port latches word_addr at the op-START edge but drives DQ from the
    // RAW word_data 2-3 cycles later (ST_WRITE_1/2). A write client's level
    // does NOT survive that window: the store's level falls one cycle after
    // the start edge, and sswr/hwr are 1-cycle pulses (gone 3 cycles before
    // the start edge). A level-driven data/addr mux therefore hands the port
    // the fall-through value (hwr_addr/hwr_data = 0 in sim, FLOATING in the
    // FPGA) for the DQ cycles - measured: every store word captured 0 in
    // tb_sector_fetch (W0 drove word_data = st_data unconditionally, which
    // is why it passed). Fix: latch the active write client's payload at arm
    // time (fixed priority st > sswr > hwr) and hold it until the op's
    // word_done. Op-start phases are unchanged (the payload is stable from
    // the arm edge, which precedes the start edge). Re-arms between the arm
    // and the start are absorbed (wcap_valid), matching the port's single
    // queue (its edge-latch swallows the same re-pulse). Capture does NOT
    // require !word_busy: the client's data level is held until its op
    // completes, and a pulse arriving while the port is busy (e.g. a
    // refresh) must still capture its payload - with the busy gate, the
    // lost pulse left the previous word's payload in wcap, which the
    // re-issued op then wrote (round-trip TB: stale-data words, 2026-11-12).
    reg         wcap_valid = 1'b0;
    reg [2:0]   wcap_client = 3'd0;
    reg [23:0]  wcap_addr = 24'd0;
    reg [31:0]  wcap_data = 32'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcap_valid <= 1'b0;
        end else if (!rst_n_s1) begin
            wcap_valid <= 1'b0;
        end else begin
            if (wr_armed && !wcap_valid) begin
                wcap_valid  <= 1'b1;
                wcap_client <= st_req_eff ? CL_STORE : (sswr_eff ? CL_SS_WR : CL_HOST_WR);
                wcap_addr   <= st_req_eff ? st_addr  : (sswr_eff ? sswr_addr : hwr_addr);
                wcap_data   <= st_req_eff ? st_data  : (sswr_eff ? sswr_data : hwr_data);
            end else if (word_done) begin
                wcap_valid  <= 1'b0;   // op complete: release for the next arm
            end
        end
    end
    // W1 read-grant driven (2026-11-15): the address of the op the port
    // starts is the GRANTED client's address (word_addr feeds the port's
    // start-edge latch). See the rd_grant block at the end of this module.
    // (old raw-level priority mux retired: it could present an ungranted
    // pending client's address to the port)
    assign word_addr = rd_granted_lvl
                     ? ((rd_grant == CL_VERIFY)  ? vr_addr
                        : (rd_grant == CL_FETCH)  ? fc_addr
                        : (rd_grant == CL_HOST_RD) ? hr_addr
                        : ssrd_addr)
                     : wcap_addr;
    assign word_data = wcap_data;

    // ---- ownership attribution (op-start edge, current levels) ----
    // Every op start (word_busy rising) is attributed from the client
    // levels CURRENT at that edge, read-priority. This is exact because
    // of the client protocols:
    //  * clients hold their levels through their own op (verifier level;
    //    fetcher holds fc_req until its word's done; the store holds
    //    word_wr until its op starts - still high pre-NBA at the edge);
    //  * there is always an IDLE cycle (word_busy low) between ops -
    //    including around refresh ops - so every op start presents a
    //    fresh word_busy rising edge and no attribution is ever missed;
    //  * if a write op starts, no read level was armed at the port's
    //    dequeue (read priority), and a read level rising in the 1-3
    //    cycles between dequeue and op start re-queues for the NEXT op
    //    (the port's edge-latch catch while IDLE/busy) - attributing the
    //    starting op from the current level at the start edge is still
    //    correct, because a level high at the start edge is either the
    //    starting op's client (held) or a client re-arming for the next
    //    op with read priority (read attributed first - correct order).
    // A refresh op: attribute from the held levels if any (the queued
    // client's op follows - "stale" attribution is the right client by
    // the held-level protocol), else hold.
    // A 3FF-synched queue mirror (the first attempt) was 3 cycles behind
    // the port's own sync and mis-attributed a store write to a fetcher
    // whose level had just fallen (measured T9).
    reg        busy_d;
    reg [2:0]  inflight;
    assign dbg_inflight = inflight;   // 2026-11-16 SSD/SSX tap
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_s1 <= 1'b0;
            inflight <= CL_NONE;
            busy_d   <= 1'b0;
        end else begin
            rst_n_s1 <= rst_n;
            busy_d   <= word_busy;
            if (!rst_n_s1) begin
                inflight <= CL_NONE;
            end else if (word_done && (inflight == CL_STORE)) begin
                // op completion: release (done routing below sees inflight
                // still set on this cycle - cleared by NBA)
                inflight <= CL_NONE;
            end else if (word_done && (inflight == CL_SS_WR)) begin
                inflight <= CL_NONE;
            end else if (word_done && (inflight == CL_HOST_WR)) begin
                inflight <= CL_NONE;
            end else if (word_rd_valid && (inflight == CL_VERIFY)) begin
                inflight <= CL_NONE;
            end else if (word_rd_valid && (inflight == CL_FETCH)) begin
                inflight <= CL_NONE;
            end else if (word_rd_valid && (inflight == CL_HOST_RD)) begin
                inflight <= CL_NONE;
            end else if (word_rd_valid && (inflight == CL_SS_RD)) begin
                inflight <= CL_NONE;
            end else if (word_op_start) begin
                // op start: attribute. 2026-11-16 (expert review): attribute
                // on the port's op-start PULSE, not the word_busy rising
                // edge. The edge is MISSED whenever the next op is pre-armed
                // (its queue set while the previous op is still in flight):
                // ST_IDLE then re-arms word_busy in the same cycle it clears
                // it, so word_busy never falls between back-to-back ops and
                // busy_d never drops. A host-read pre-armed during a
                // host-write is then never attributed -> hr_done never fires
                // -> rd_grant never releases -> read_armed holds ->
                // port_wr_idle (the hwr write gate) stays closed -> the hwr
                // FIFO starves and overflows on hardware (wr_ovf) and the
                // save/load blob never lands (SS LD -> SS ERR). The pulse
                // fires in the SAME cycle word_busy rises in the normal case
                // (bit-identical phase to the proven baseline) and only adds
                // attribution for the back-to-back case; it fires only for
                // word-client dequeues (never refresh/burst). The OP KIND is the
                // truth (the owner drives it: a read op runs with
                // word_rd held, a write op with word_wr held), so it
                // outranks the client levels - a read client re-arming
                // in the 1-3 cycles between a write's dequeue and its
                // start edge would otherwise steal the write's
                // attribution (read priority on raw levels) and lose
                // the store's word_done.
                if (word_rd) begin
                    // W1 read grant (2026-11-15): the op that starts is
                    // exactly the granted client's op (word_rd is the
                    // granted level only), so the grant IS the
                    // attribution. The old raw-level cascade here is
                    // WRONG under the grant: raw levels include PENDING
                    // (ungranted) clients, which would steal the
                    // attribution and the granted client's done would be
                    // lost (its level is still high, op completed, done
                    // routed elsewhere - the 20261115 hardware wedge).
                    inflight <= (rd_grant != CL_NONE) ? rd_grant : CL_FETCH;
                end else if (word_wr || wcap_valid) begin
                    // write op: attribute from the latched arm payload, not
                    // the levels - the client level may already have fallen
                    // (sswr/hwr are 1-cycle pulses; the store level falls one
                    // cycle after the start edge). wcap_client is stable
                    // through the op (held arm-to-done).
                    inflight <= wcap_client;
                end
                // else: refresh with no client armed - hold
            end
        end
    end
    // Attribution invariant (by construction): a read op's client must still
    // be armed at its completion (clients hold their levels through their own
    // op). The current-edge attribution model (op-kind + levels at word_busy
    // rising) makes this hold; a violation would mean the op was attributed
    // to the wrong client.

    assign st_busy = word_busy;

    // ---- client return routing (only the attributed client) ----
    // Done levels are the M0 shape exactly: a 1-cycle level set on the
    // op's completion pulse, held while the client request stays high,
    // falling with the request. Any extra sync stage here shifts the
    // client's per-word cycle and, over a verify sequence, drifts the
    // port op-start phase out of the read-capture window (measured).
    assign st_done = word_done && (inflight == CL_STORE);

    // W1 write clients: same shape as st_done - 1-cycle completion pulse
    // routed to the attributed client; busy = the whole port (re-pulse gate
    // for the client's pulse-while-idle protocol).
    assign sswr_done = word_done && (inflight == CL_SS_WR);
    assign sswr_busy = word_busy;
    assign hwr_done  = word_done && (inflight == CL_HOST_WR);
    assign hwr_busy  = word_busy;

    // W1 savestate manager blob read: same 1-FF level shape as the verifier;
    // data latched at the completion pulse; the client holds ssrd_req until
    // it retires the word, so the attribution invariant holds by
    // construction, exactly as for vr/fc/hr.
    reg ssrd_done_lvl;
    reg [31:0] ssrd_data_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ssrd_done_lvl <= 1'b0;
            ssrd_data_r   <= 32'd0;
        end else begin
            ssrd_done_lvl <= (word_rd_valid && (inflight == CL_SS_RD)) ? 1'b1
                                                                       : (ssrd_done_lvl & ssrd_req);
            if (word_rd_valid && (inflight == CL_SS_RD))
                ssrd_data_r <= word_q;
        end
    end
    assign ssrd_done = ssrd_done_lvl;
    assign ssrd_data = ssrd_data_r;

    reg vr_done_lvl;
    reg [31:0] vr_data_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vr_done_lvl <= 1'b0;
            vr_data_r   <= 32'd0;
        end else begin
            vr_done_lvl <= (word_rd_valid && (inflight == CL_VERIFY)) ? 1'b1
                                                                      : (vr_done_lvl & vr_req);
            if (word_rd_valid && (inflight == CL_VERIFY))
                vr_data_r <= word_q;
        end
    end
    assign vr_done = vr_done_lvl;
    assign vr_data = vr_data_r;

    // fetcher: same 1-FF level shape; data on the completion pulse; the
    // generation tag is latched at (re)acceptance
    reg fc_done_lvl;
    reg [7:0] fc_gen_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fc_done_lvl <= 1'b0;
            fc_gen_l    <= 8'd0;
        end else begin
            fc_done_lvl <= (word_rd_valid && (inflight == CL_FETCH)) ? 1'b1
                                                                     : (fc_done_lvl & fc_req);
            if (fc_req && !fc_done_lvl)
                fc_gen_l <= fc_gen;
        end
    end
    // active = the port is busy with this client's op (not the raw
    // attribution register, which holds its last armed client until the
    // next arm - a stale FETCH attribution after a discarded sector
    // would leave fc_active high forever, measured hang in TB T8).
    assign fc_active     = word_busy && (inflight == CL_FETCH);
    assign fc_word_valid = word_rd_valid && (inflight == CL_FETCH);
    assign fc_done       = fc_done_lvl;
    assign fc_data       = word_q;
    assign fc_done_len   = 8'd1;
    assign fc_done_gen   = fc_gen_l;

    // W0 host bridge read: same 1-FF level shape as the verifier; data
    // latched at the completion pulse; the client holds hr_req until it
    // retires the word (address-FIFO read-side protocol), so the
    // attribution invariant (client armed through its own op) holds by
    // construction, exactly as for vr/fc.
    reg hr_done_lvl;
    reg [31:0] hr_data_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hr_done_lvl <= 1'b0;
            hr_data_r   <= 32'd0;
        end else begin
            hr_done_lvl <= (word_rd_valid && (inflight == CL_HOST_RD)) ? 1'b1
                                                                       : (hr_done_lvl & hr_req);
            if (word_rd_valid && (inflight == CL_HOST_RD))
                hr_data_r <= word_q;
        end
    end
    assign hr_done = hr_done_lvl;
    assign hr_data = hr_data_r;

    // =====================================================================
    // W1 READ GRANT (2026-11-15)
    // =====================================================================
    // The port's word_rd queue is a single 1-bit EDGE latch on the
    // 3FF-synchronized word_rd level. When TWO read clients are armed at
    // the same time, the second client's arm does not re-edge the OR'd
    // level, so its op is never queued and its done never comes: dead
    // port (IDLE, level high, queue clear, the waiting client invisible
    // to the done attribution, which happens at op start). Measured on
    // hardware 2026-11-15 (save #2 frozen at W=0000 B1 S0: a preload/hr
    // op in flight while the manager's ssrd load-header arm is pending)
    // and in tb_savestate_integration (G5/G6 wedge: ssrd waits forever,
    // port IDLE, rd FIFO head stuck).
    // Fix: present AT MOST ONE read client to the port at a time. The
    // granted client's level drives word_rd; other armed clients are held
    // pending and are granted as soon as the current grant's op completes
    // (its completion pulse clears both the attribution and the grant).
    // Single-client configurations (all M0 builds: fc/vr/st only) see no
    // behavior change: the grant tracks the one level, and the arm edge is
    // merely re-timed one cycle inside the port's 3FF sync window (the
    // edge-latch catches it identically).
    // Priority follows the legacy mux order (vr > fc > hr > ssrd);
    // re-grant is first-pending, so a burst of ops from one client is not
    // interleaved with another client's single op.
    // =====================================================================
    wire rd_pend_vr = vr_req     && !vr_done_lvl;
    wire rd_pend_fc = fc_req     && !fc_done_lvl;
    wire rd_pend_hr = hr_req     && !hr_done_lvl;
    wire rd_pend_ss = ssrd_req   && !ssrd_done_lvl;
    reg  [2:0] rd_grant = CL_NONE;
    wire rd_granted_lvl = (rd_grant == CL_VERIFY)  ? vr_req
                         : (rd_grant == CL_FETCH)   ? fc_req
                         : (rd_grant == CL_HOST_RD) ? hr_req
                         : (rd_grant == CL_SS_RD)   ? ssrd_req
                         : 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_grant <= CL_NONE;
        else if (rd_grant != CL_NONE) begin
            // release exactly when the granted op's completion pulse clears
            // the attribution (same condition as the done routing below; the
            // grant falls the cycle after the pulse, the client's done_lvl is
            // set on the pulse itself)
            if (word_rd_valid && (inflight == rd_grant))
                rd_grant <= CL_NONE;
        end else begin
            if (rd_pend_vr)       rd_grant <= CL_VERIFY;
            else if (rd_pend_fc)  rd_grant <= CL_FETCH;
            else if (rd_pend_hr)  rd_grant <= CL_HOST_RD;
            else if (rd_pend_ss)  rd_grant <= CL_SS_RD;
            else                  rd_grant <= CL_NONE;
        end
    end
    assign word_rd = init_done && rd_granted_lvl;

endmodule
