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

    // ---- ownership attribution ----
    // Latch the client at its ARM event (level/pulse high while the port
    // is idle - the M0 req_kind pattern, generalized to three clients).
    // The port's queue latches the arm 3 cycles before the op starts, so
    // the armed-client state at op start is already gone; the latched
    // arm client is the op's client by the wrapper invariant (at most
    // one client arms at a time: the fetcher level is masked while the
    // verifier level is high, and the store pulse fires only while the
    // port is idle).
    reg [1:0] inflight;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_s1 <= 1'b0;
            inflight <= CL_NONE;
        end else begin
            rst_n_s1 <= rst_n;
            if (!rst_n_s1) begin
                inflight <= CL_NONE;
            end else if (!word_busy) begin
                // last client to arm while idle owns the next op
                if (vr_req && !vr_done_lvl)
                    inflight <= CL_VERIFY;
                else if (fc_req && !fc_done_lvl)
                    inflight <= CL_FETCH;
                else if (st_req_eff)
                    inflight <= CL_STORE;
            end
        end
    end

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
