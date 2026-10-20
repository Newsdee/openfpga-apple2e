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
    output wire [7:0]  fc_done_gen  // generation tag of the completed transfer
);

    localparam CL_NONE  = 2'd0;
    localparam CL_STORE = 2'd1;
    localparam CL_VERIFY= 2'd2;
    localparam CL_FETCH = 2'd3;

    reg         rst_n_s1;

    // ---- pass-through drive (zero added latency - M0 op phases) ----
    // At most one read level is high at any time (wrapper gates fc on
    // !vr). Writes are masked while ANY read client is armed: the port
    // dequeues reads before writes, so an armed read plus a store pulse
    // would queue both and the write op would start with a stale
    // read-client attribution (its word_done lost, store timeout) -
    // measured in TB T7/T9. The store client re-pulses on the next idle
    // cycle (disk_store protocol), so it simply waits out the transfer.
    wire read_armed  = vr_req || fc_req;
    wire st_req_eff  = st_req && !read_armed;
    assign word_rd   = init_done && read_armed;
    assign word_wr   = init_done && st_req_eff;
    assign word_addr = read_armed ? (vr_req ? vr_addr : fc_addr) : st_addr;
    assign word_data = st_data;

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
    reg [1:0]  inflight;
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
            end else if (word_rd_valid && (inflight == CL_VERIFY)) begin
                inflight <= CL_NONE;
            end else if (word_rd_valid && (inflight == CL_FETCH)) begin
                inflight <= CL_NONE;
            end else if (word_busy && !busy_d) begin
                // op start (or refresh): attribute. The OP KIND is the
                // truth (the owner drives it: a read op runs with
                // word_rd held, a write op with word_wr held), so it
                // outranks the client levels - a read client re-arming
                // in the 1-3 cycles between a write's dequeue and its
                // start edge would otherwise steal the write's
                // attribution (read priority on raw levels) and lose
                // the store's word_done.
                if (word_rd) begin
                    if (vr_req && !vr_done_lvl)
                        inflight <= CL_VERIFY;
                    else if (fc_req && !fc_done_lvl)
                        inflight <= CL_FETCH;
                    else
                        inflight <= CL_FETCH;   // anomalous: no read level
                                                // visible; fetcher is the
                                                // M1 per-word read client
                end else if (word_wr)
                    inflight <= CL_STORE;
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

endmodule
