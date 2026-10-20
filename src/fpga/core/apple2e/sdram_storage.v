//
// sdram_storage.v - the SDRAM image-storage path (M0 rework, Units 1-4)
//
//   host (clk_74a) --bridge word write--> slot_fifo --(CDC)--> disk_store
//     --word port (ctrl domain)--> io_sdram_pocket --> 64MiB DRAM
//   disk_verifier (machine domain) reads the image back through the same
//   word port (level handshakes; M0 protocol: load phase and verify
//   phase never overlap - M1 adds the machine fetcher under arbitration).
//
// Clocks (all inputs; the top provides them from the mp2 PLL):
//   clk_74a      74.25 MHz  host/bridge domain (FIFO write side, config)
//   ctrl_clk    133.12 MHz  io_sdram controller domain
//   chip_clk    133.12 MHz  SDRAM chip clock (180 deg vs ctrl)
//   clk_90      133.12 MHz  (unused, kept for the Pocket controller)
//   clk_mach    14.318 MHz  machine domain (verifier)
//
// Reset: sdram_path_rst (active-HIGH, from core power/PLL-por in the
// host domain) resets FIFO/store/verifier. A MACHINE reset must NOT be
// routed in here - the resident image survives host resets.
//
// Host protocol:
//   1. wait status_setup_done (top: machine PLL lock AND boot_done);
//   2. write the image: bridge word writes to the 64MiB window
//      (bridge_addr[31:26]==0; word address = bridge_addr[25:2]);
//   3. read flags until load_drained;
//   4. write cfg: n_bytes (0xF9000004), then start (0xF9000024[0]);
//   5. read flags until verifier_done; compare crc/first/last against
//      PC-computed fixture values.
//
`timescale 1ns/10ps
module sdram_storage (
    // ---- host domain ----
    input  wire        clk_74a,
    input  wire        sdram_path_rst,      // active-high, core POR
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output wire        init_done,           // boot_done (synced to 74.25)
    output wire        load_drained,
    output wire        store_busy,
    output wire        store_timeout,
    output wire [23:0] words_received,
    output wire [23:0] words_committed,
    output wire        fifo_overflow,       // native 74.25
    output wire [8:0]  fifo_high_water,     // native 74.25
    input  wire [31:0] diag_addr,           // 0xF9xxxxxx offset (top routes)
    input  wire        diag_rd,
    output reg  [31:0] diag_rd_data,
    input  wire        diag_wr,             // top pre-decoded 0xF9 writes
    input  wire [3:0]  diag_wr_sel,         // 4=n_bytes, 9=start
    // ---- APF data-slot handshake (core_bridge_cmd; already on clk_74a) ----
    input  wire        ds_requestwrite,     // 0082 pulse (1-2 cycles)
    input  wire [15:0] ds_requestwrite_id,  // slot id from 0082
    input  wire [31:0] ds_requestwrite_size,// exact file size (bytes)
    input  wire        ds_allcomplete,      // 008F level (cleared by next 0082)
    input  wire [31:0] timeout_override,    // verifier test hook (top ties 32'd0)
    // ---- machine domain ----
    input  wire        clk_mach,
    input  wire        rst_n_mach,          // = ~sdram_path_rst
    output wire        ver_done,
    output wire        ver_ok,
    output wire        ver_stuck,
    output wire [31:0] ver_crc32,
    output wire [31:0] ver_first_word,
    output wire [31:0] ver_last_word,
    output wire [15:0] ver_words_readout,
    output wire [31:0] n_bytes_m,           // config in machine domain
    output wire        store_timeout_m,     // for the on-screen overlay
    output wire        fifo_overflow_m,     // for the on-screen overlay

    // ---- M1 sector service (WOZ engine transport) ----
    // Machine-domain ports for the Unit-3 emitter; the top wires them
    // to the WOZ engine's block transport (Unit 5).
    input  wire        fetch_req,
    input  wire [15:0] fetch_lba,           // 512-byte sector number
    output wire        fetch_busy,
    output wire        sector_ready,
    input  wire [8:0]  sector_byte_addr,
    output wire [7:0]  sector_byte_data,
    input  wire        sector_done,
    output wire        fetch_fault,
    // ---- load/verify coordinator result (machine domain, for overlay) ----
    output wire        res_valid_m,         // result latched (rising edge -> show)
    output wire [1:0]  res_code_m,          // 0=OK, 1=FAIL, 2=NOFILE
    output wire [1:0]  res_fail_m,          // subcode: 0=ST(uck), 1=OV, 2=TO, 3=IN
    output wire [31:0] res_crc_m,
    output wire [31:0] res_nbytes_m,
    output wire        new_load_m,          // 1-mach-cycle pulse: a new 0082
                                            // generation started (proactive
                                            // unmount so the engine stops
                                            // scanning the old image during
                                            // the new load, freeing the port)
    output wire [2:0]  stage_m,             // furthest stage 0..6 (overlay marker)
    // ---- SDRAM clocks + pads ----
    input  wire        ctrl_clk,
    input  wire        chip_clk,
    input  wire        clk_90,
    output wire [12:0] dram_a,
    output wire [1:0]  dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [1:0]  dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n
);

    // ==================================================================
    // host -> FIFO (74.25 MHz)
    // 64MiB window per the basicassets reference mapping:
    // bridge_addr[31:26]==0, word address = bridge_addr[25:2] -> full chip.
    // ==================================================================
    wire fifo_wr_en = bridge_wr && (bridge_addr[31:26] == 5'b0);

    wire        fifo_full;
    wire        fifo_empty, fifo_rd_valid;
    wire        fifo_rd_en;
    wire [23:0] fifo_rd_addr;
    wire [31:0] fifo_rd_data;

    slot_fifo #(.DEPTH(256)) sf0 (
        .wr_clk    ( clk_74a ),
        .rst       ( sdram_path_rst ),
        .wr_en     ( fifo_wr_en ),
        .wr_addr   ( bridge_addr[25:2] ),
        .wr_data   ( bridge_wr_data ),
        .overflow_clr( ovf_clr_74 ),
        .full      ( fifo_full ),
        .overflow  ( fifo_overflow ),
        .high_water( fifo_high_water ),
        .rd_clk    ( ctrl_clk ),
        .empty     ( fifo_empty ),
        .rd_en     ( fifo_rd_en ),
        .rd_valid  ( fifo_rd_valid ),
        .rd_addr   ( fifo_rd_addr ),
        .rd_data   ( fifo_rd_data )
    );

    // ==================================================================
    // store owner (ctrl domain)
    // ==================================================================
    wire        sdram_init_done;   // io_sdram_pocket.boot_done
    wire        sw_word_wr, sw_word_done;
    wire [23:0] sw_word_addr;
    wire [31:0] sw_word_data;
    wire        store_busy_i, load_drained_i, store_timeout_i;
    wire [23:0] words_received_i, words_committed_i;

    disk_store #(.TIMEOUT_CYCLES(4096)) dst0 (
        .clk              ( ctrl_clk ),
        .rst_n            ( ~sdram_path_rst ),
        .fifo_empty       ( fifo_empty ),
        .fifo_rd_en       ( fifo_rd_en ),
        .fifo_rd_valid    ( fifo_rd_valid ),
        .fifo_rd_addr     ( fifo_rd_addr ),
        .fifo_rd_data     ( fifo_rd_data ),
        .word_wr          ( sw_word_wr ),
        .word_addr        ( sw_word_addr ),
        .word_data        ( sw_word_data ),
        .word_busy        ( ov_st_busy ),
        .word_done        ( ov_st_done ),
        .init_done        ( sdram_init_done ),
        .store_busy       ( store_busy_i ),
        .load_drained     ( load_drained_i ),
        .words_received   ( words_received_i ),
        .words_committed  ( words_committed_i ),
        .timeout          ( store_timeout_i ),
        .timeout_clr      ( to_clr_c )
    );

    // Per-generation fault scoping (coordinator, below): on each new 0082
    // the sticky FIFO-overflow flag is cleared in its own (write = clk_74a)
    // domain, and the store's sticky timeout latch via a 2FF level into
    // the (faster) ctrl domain. Each load generation reports only its own
    // faults; the slot is reloadable, so stale flags must not poison the
    // next result.
    wire       ovf_clr_74 = ds0082;   // 1-2 cycle pulse, write domain
    reg  [1:0] toclr_s;
    wire       to_clr_c;             // ctrl-domain level (~1-3 cycles)
    always @(posedge ctrl_clk)
        toclr_s <= {toclr_s[0], ds0082};
    assign to_clr_c = toclr_s[1];

    // ==================================================================
    // word-port read shim (verifier <-> owner, levels only)
    // ==================================================================
    wire        v_req;
    wire [23:0] v_req_addr;

    reg  [1:0] vreq_s;
    reg  [23:0] var_s;
    always @(posedge ctrl_clk) begin
        vreq_s <= {vreq_s[0], v_req};
        var_s  <= v_req_addr;     // stable while v_req is high
    end

    // The M0 req_kind address mux is replaced by the explicit word-port
    // OWNER: it latches each accepted request's {client, address, length,
    // generation} and routes read data only to the latched owner (expert
    // M1 review: the convention serializer was not a general arbiter).
    // M1 serialization: load (store) -> verify -> mounted fetch.
    wire        ov_st_busy, ov_st_done, ov_vr_done, ov_fc_active, ov_fc_done;
    wire        ov_word_rd, ov_word_wr, ov_word_busy, ov_word_done, ov_word_rd_valid;
    wire [23:0] ov_word_addr, ov_fc_addr;
    wire [31:0] ov_word_data, ov_word_q, ov_vr_data, ov_fc_data;
    wire [7:0]  ov_fc_gen, ov_fc_done_len, ov_fc_done_gen;
    wire        ov_fc_word_valid;
    wire        fc_req_w;
    wire [23:0] fc_addr_w;
    wire [7:0]  fc_gen_w;
    // one read client at a time: the fetcher level is masked while the
    // verifier level is high (the M0 invariant that kept the port's
    // single queue unambiguous, now explicit)
    wire fc_req_eff = fc_req_w && !vreq_s[1];

    // image generation + live size: 74.25 -> ctrl (133.12) crossings.
    // A torn multi-bit sync only ever looks like a different generation
    // (worst case: one in-flight sector is discarded a cycle early - the
    // safe direction).
    reg [7:0]  gen_74;
    always @(posedge clk_74a)
        if (ds0082)
            gen_74 <= gen_74 + 8'd1;   // new slot load accepted
    reg [31:0] ldsize_c1, ldsize_c2;
    reg [7:0]  gen_c1, gen_c2;
    always @(posedge ctrl_clk) begin
        ldsize_c1 <= ld_size;
        ldsize_c2 <= ldsize_c1;
        gen_c1    <= gen_74;
        gen_c2    <= gen_c1;
    end

    // 74.25 -> machine: new-load generation pulse. gen_74 is stable for the
    // whole load (>> a machine sync), so a torn multi-bit sync can only
    // manifest as a spurious single change - a safe direction, since the
    // only consumer (the mount controller) reacts to a change by ejecting
    // the mounted drive, which is exactly what a reload wants.
    reg [7:0] gen_m1, gen_m2, gen_m3, gen_m3_d;
    always @(posedge clk_mach) begin
        gen_m1   <= gen_74;
        gen_m2   <= gen_m1;
        gen_m3   <= gen_m2;
        gen_m3_d <= gen_m3;
    end
    assign new_load_m = (gen_m3 !== gen_m3_d);

    sdram_word_owner owner0 (
        .clk        ( ctrl_clk ),
        .rst_n      ( ~sdram_path_rst ),
        .word_rd    ( ov_word_rd ),
        .word_wr    ( ov_word_wr ),
        .word_addr  ( ov_word_addr ),
        .word_data  ( ov_word_data ),
        .word_q     ( ov_word_q ),
        .word_busy  ( ov_word_busy ),
        .word_done  ( ov_word_done ),
        .word_rd_valid( ov_word_rd_valid ),
        .init_done  ( sdram_init_done ),
        .st_req     ( sw_word_wr ),
        .st_addr    ( sw_word_addr ),
        .st_data    ( sw_word_data ),
        .st_busy    ( ov_st_busy ),
        .st_done    ( ov_st_done ),
        .vr_req     ( vreq_s[1] ),
        .vr_addr    ( var_s ),
        .vr_done    ( ov_vr_done ),
        .vr_data    ( ov_vr_data ),
        .fc_req     ( fc_req_eff ),
        .fc_addr    ( fc_addr_w ),
        .fc_gen     ( fc_gen_w ),
        .fc_active  ( ov_fc_active ),
        .fc_word_valid( ov_fc_word_valid ),
        .fc_done    ( ov_fc_done ),
        .fc_data    ( ov_fc_data ),
        .fc_done_len( ov_fc_done_len ),
        .fc_done_gen( ov_fc_done_gen )
    );

    sdram_sector_fetch fetch0 (
        .clk_mach      ( clk_mach ),
        .rst_n_mach    ( rst_n_mach ),
        .clk_ctrl      ( ctrl_clk ),
        .rst_n_ctrl    ( ~sdram_path_rst ),
        .fetch_req     ( fetch_req ),
        .fetch_lba     ( fetch_lba ),
        .fetch_busy    ( fetch_busy ),
        .sector_ready  ( sector_ready ),
        .sector_byte_addr ( sector_byte_addr ),
        .sector_byte_data ( sector_byte_data ),
        .sector_done   ( sector_done ),
        .fetch_fault   ( fetch_fault ),
        .init_done     ( sdram_init_done ),
        .img_nbytes    ( ldsize_c2 ),
        .img_gen       ( gen_c2 ),
        .fc_req        ( fc_req_w ),
        .fc_addr       ( fc_addr_w ),
        .fc_gen        ( fc_gen_w ),
        .fc_active     ( ov_fc_active ),
        .fc_word_valid ( ov_fc_word_valid ),
        .fc_done       ( ov_fc_done ),
        .fc_data       ( ov_fc_data ),
        .fc_done_gen   ( ov_fc_done_gen )
    );

    // owner-level read completion + data -> machine (3FF + 2FF, as M0)
    reg  [2:0]  vdone_sync;
    reg  [31:0] vdata_s1, vdata_s2;
    always @(posedge clk_mach) begin
        vdone_sync <= {vdone_sync[1:0], ov_vr_done};
        vdata_s1   <= ov_vr_data;
        vdata_s2   <= vdata_s1;
    end
    wire v_rd_done    = vdone_sync[1];
    wire v_rd_data_ok = vdone_sync[2] & vdone_sync[1] & vdone_sync[0];

    // ==================================================================
    // config (74.25) + machine-domain syncs
    // ==================================================================
    reg  [31:0] v_n_bytes_host;
    reg         v_start_host;
    wire        v_start_sync;   // net: driven by synch_3 output port (Q17 10663)
    wire        v_start_pulse;
    wire        v_start_done;

    // Config writes: explicit 0xF9 diag writes win; otherwise the
    // load/verify coordinator drives the verifier start/n_bytes
    // (single procedural driver for both registers).
    always @(posedge clk_74a) begin
        if (diag_wr) begin
            if (diag_wr_sel == 4'd4)
                v_n_bytes_host <= bridge_wr_data;
            else if (diag_wr_sel == 4'd9)
                v_start_host   <= bridge_wr_data[0];
        end else if (ds0082 && v_start_host) begin
            v_start_host <= 1'b0;      // new generation: release any held start
        end else if (co_start_release) begin
            v_start_host <= 1'b0;      // verifier done: release start level
        end else if (co_start_arm) begin
            v_start_host   <= 1'b1;    // 0->1: synch_3 pulses the verifier
            v_n_bytes_host <= ld_size; // exact size (partial words masked in CRC)
        end
    end
    synch_3 s_vstart (v_start_host, v_start_sync, clk_mach, v_start_pulse, );

    wire        v_busy, v_done_i, v_ok_i, v_stuck;
    wire [31:0] v_crc32, v_first_word, v_last_word;
    wire [15:0] v_words_read, v_words_readout;
    wire [31:0] v_nbytes_m;
    wire        store_timeout_m_i, fifo_overflow_m_i;

    synch_3 #(.WIDTH(32)) s_vnbytes (v_n_bytes_host, v_nbytes_m, clk_mach, , );
    synch_3        s_vto     (store_timeout_i, store_timeout_m_i, clk_mach, , );
    synch_3        s_vovf    (fifo_overflow,   fifo_overflow_m_i, clk_mach, , );

    disk_verifier #(.TIMEOUT_CYCLES(20000)) ver0 (
        .clk(clk_mach), .rst_n(rst_n_mach),
        .n_bytes(v_nbytes_m), .start(v_start_pulse), .start_done(v_start_done),
        .req(v_req), .req_addr(v_req_addr),
        .rd_done(v_rd_done), .rd_data_ok(v_rd_data_ok), .rd_data(vdata_s2),
        .busy(v_busy), .done(v_done_i), .ok(v_ok_i), .stuck(v_stuck),
        .timeout_override(timeout_override),
        .crc32(v_crc32), .first_word(v_first_word), .last_word(v_last_word),
        .words_read(v_words_read), .words_readout(v_words_readout)
    );

    // ==================================================================
    // diagnostics: 74.25-domain syncs + 0xF9 readout
    // ==================================================================
    wire        init_done_74, load_drained_74, store_busy_74, store_timeout_74;
    wire [23:0] words_received_74, words_committed_74;
    wire        v_done_74, v_ok_74, v_stuck_74, v_busy_74;
    wire [31:0] v_crc32_74, v_first_word_74, v_last_word_74;
    wire [15:0] v_words_readout_74;
    wire        v_done_rise_74;

    synch_3 s_sd0 (sdram_init_done, init_done_74, clk_74a, , );
    synch_3 s_sd1 (load_drained_i,  load_drained_74, clk_74a, , );
    synch_3 s_sd2 (store_busy_i,    store_busy_74,   clk_74a, , );
    synch_3 s_sd3 (store_timeout_i, store_timeout_74, clk_74a, , );
    synch_3 #(.WIDTH(24)) s_sd4 (words_received_i,  words_received_74,  clk_74a, , );
    synch_3 #(.WIDTH(24)) s_sd5 (words_committed_i, words_committed_74, clk_74a, , );
    synch_3 s_v0  (v_done_i,      v_done_74,      clk_74a, v_done_rise_74, );
    synch_3 s_v1  (v_ok_i,        v_ok_74,        clk_74a, , );
    synch_3 s_v2  (v_stuck,       v_stuck_74,     clk_74a, , );
    synch_3 s_v3  (v_busy,        v_busy_74,      clk_74a, , );
    synch_3 #(.WIDTH(32)) s_v4  (v_crc32,        v_crc32_74,        clk_74a, , );
    synch_3 #(.WIDTH(32)) s_v5  (v_first_word,   v_first_word_74,   clk_74a, , );
    synch_3 #(.WIDTH(32)) s_v6  (v_last_word,    v_last_word_74,    clk_74a, , );
    synch_3 #(.WIDTH(16)) s_v7  (v_words_readout, v_words_readout_74, clk_74a, , );

    // ==================================================================
    // Load/verify coordinator (host domain)
    //
    // Event-driven on the APF data-slot handshake (0082 request pulse /
    // 008F allcomplete level, both on clk_74a from core_bridge_cmd).
    // Contract: pulse-start / result-latch. Re-arms on every new disk
    // 0082 (the slot is reloadable); a machine reset does NOT re-arm
    // (the resident image survives; the result is simply held).
    //
    // Failure policy: transport errors, invalid size, and incomplete
    // transfers are REJECTED (FAIL) - never reported as success.
    // ==================================================================
    localparam [15:0] DISK_SLOT_ID = 16'd1;        // data.json "disk" slot
    localparam [31:0] SDRAM_CAP    = 32'h0400_0000; // 64 MiB

    // NOTE: 5 states need 3 bits (2'd4 truncated to 0 in a 2-bit reg -
    // that made CO_RES alias CO_IDLE and broke the result guard).
    localparam [2:0] CO_IDLE  = 3'd0,
                     CO_LOAD  = 3'd1,
                     CO_DRAIN = 3'd2,
                     CO_WAITV = 3'd3,
                     CO_RES   = 3'd4;

    reg  [2:0]  co_st;
    reg  [31:0] ld_size;      // exact byte size latched from 0082
    reg  [23:0] exp_words;    // (ld_size + 3) >> 2
    reg  [23:0] gen_words;    // words accepted into FIFO this generation
    reg         allc_s;

    wire        ds0082    = ds_requestwrite && (ds_requestwrite_id == DISK_SLOT_ID);
    wire        allc_edge = ds_allcomplete && !allc_s;

    // Result latch (host domain; synced to machine domain below)
    reg         res_valid;
    reg  [1:0]  res_code;   // 0=OK, 1=FAIL, 2=NOFILE
    reg  [1:0]  res_fail;   // 0=ST(uck), 1=OV(eflow), 2=TO, 3=IN(complete/invalid)
    reg  [31:0] res_crc;
    reg  [31:0] res_nbytes;

    // Start handshake to the config block. The done condition uses the
    // RISING edge of the synced done (not the level): a held done from an
    // earlier (manual or previous-generation) verify must not be accepted
    // for a new run.
    wire        co_start_arm    = (co_st == CO_DRAIN) && load_drained_74 &&
                                  (gen_words >= exp_words) &&
                                  !fifo_overflow && !store_timeout_74;
    // Release the held start on done OR stuck: on a readback timeout the
    // verifier returns to IDLE without asserting done, so a done-only
    // release would hold the start level forever.
    wire        co_start_release = (co_st == CO_WAITV) &&
                                   (v_done_rise_74 | v_stuck_74);

    always @(posedge clk_74a) begin
        allc_s <= ds_allcomplete;

        if (ds0082) begin
            // New load generation: re-arm regardless of current state.
            ld_size   <= ds_requestwrite_size;
            exp_words <= (ds_requestwrite_size + 32'd3) >> 2;
            gen_words <= 24'd0;                // per-generation write count
            res_valid <= 1'b0;                 // clear the previous result
            if (ds_requestwrite_size == 32'd0) begin
                co_st <= CO_RES;               // empty slot: decided at 008F
            end else if (ds_requestwrite_size > SDRAM_CAP) begin
                res_valid  <= 1'b1;
                res_code   <= 2'd1;
                res_fail   <= 2'd3;            // invalid size
                res_nbytes <= ds_requestwrite_size;
                res_crc    <= 32'd0;
                co_st      <= CO_RES;
            end else begin
                co_st <= CO_LOAD;
            end
        end else begin
            if (fifo_wr_en)
                gen_words <= gen_words + 24'd1;
            case (co_st)
            CO_IDLE:
                if (allc_edge && !res_valid) begin // 008F with no load this generation
                    res_valid  <= 1'b1;
                    res_code   <= 2'd2;        // NOFILE
                    res_fail   <= 2'd0;
                    res_nbytes <= 32'd0;
                    res_crc    <= 32'd0;
co_st      <= CO_RES;
                end
            CO_LOAD:
                if (fifo_overflow) begin
                    res_valid <= 1'b1; res_code <= 2'd1; res_fail <= 2'd1;
                    res_nbytes <= ld_size; res_crc <= 32'd0;
                    co_st <= CO_RES;
                end else if (store_timeout_74) begin
                    res_valid <= 1'b1; res_code <= 2'd1; res_fail <= 2'd2;
                    res_nbytes <= ld_size; res_crc <= 32'd0;
                    co_st <= CO_RES;
                end else if (allc_edge) begin
                    co_st <= CO_DRAIN;
                end
            CO_DRAIN:
                if (fifo_overflow) begin
                    res_valid <= 1'b1; res_code <= 2'd1; res_fail <= 2'd1;
                    res_nbytes <= ld_size; res_crc <= 32'd0;
                    co_st <= CO_RES;
                end else if (store_timeout_74) begin
                    res_valid <= 1'b1; res_code <= 2'd1; res_fail <= 2'd2;
                    res_nbytes <= ld_size; res_crc <= 32'd0;
                    co_st <= CO_RES;
                end else if (load_drained_74) begin
                    if (gen_words < exp_words) begin
                        // Incomplete transfer: host declared N bytes, sent fewer
                        res_valid <= 1'b1; res_code <= 2'd1; res_fail <= 2'd3;
                        res_nbytes <= ld_size; res_crc <= 32'd0;
                        co_st <= CO_RES;
                    end else begin
                        // Arm the verifier (config block pulses start with the
                        // EXACT latched size; partial words are byte-masked).
                        res_crc    <= 32'd0;
                        res_nbytes <= ld_size;
                        co_st <= CO_WAITV;
                    end
                end
            CO_WAITV:
                if (v_done_rise_74) begin
                    res_valid <= 1'b1;
                    res_crc   <= v_crc32_74;   // stable during done-high
                    if (v_ok_74) begin
                        res_code <= 2'd0;      // OK
                        res_fail <= 2'd0;      // clear any stale subcode
                    end else begin
                        res_code <= 2'd1;      // readback error
                        res_fail <= v_stuck_74 ? 2'd2 : 2'd0;
                    end
                    co_st <= CO_RES;
                end else if (v_stuck_74) begin
                    // Readback timeout: the verifier latches stuck and
                    // returns to IDLE without asserting done, so the done
                    // edge never comes. Latch FAIL TO here - otherwise
                    // the coordinator waits forever and the storage fault
                    // is invisible on screen.
                    res_valid  <= 1'b1;
                    res_code   <= 2'd1;
                    res_fail   <= 2'd2;        // TO
                    res_crc    <= 32'd0;
                    res_nbytes <= ld_size;
                    co_st      <= CO_RES;
                end
            CO_RES:
                if (allc_edge && !res_valid) begin // 008F without a load, and no result latched this generation
                    res_valid <= 1'b1;
                    res_code   <= 2'd2;        // NOFILE
                    res_fail   <= 2'd0;
                    res_nbytes <= 32'd0;
                    res_crc    <= 32'd0;
                end
            default: ;    // states 5-7 unreachable (5 states in 3 bits)
            endcase
        end
    end

    // Host -> machine: coordinator result (on-screen overlay inputs)
    synch_3          s_rv  (res_valid,  res_valid_m,  clk_mach, , );
    synch_3 #(.WIDTH(2)) s_rc  (res_code,   res_code_m,   clk_mach, , );
    synch_3 #(.WIDTH(2)) s_rf  (res_fail,   res_fail_m,   clk_mach, , );
    synch_3 #(.WIDTH(32)) s_rca (res_crc,    res_crc_m,    clk_mach, , );
    synch_3 #(.WIDTH(32)) s_rnb (res_nbytes, res_nbytes_m, clk_mach, , );

    // ---- stage indicator (per generation, for the overlay marker) ----
    // bit0 = first data word seen, bit1 = 008F seen, bit2 = drain
    // complete, bit3 = verifier start armed. Set-only within a
    // generation; cleared on the next 0082.
    reg  [3:0] stg;
    wire       ev_drain = (co_st == CO_DRAIN) && load_drained_74;
    always @(posedge clk_74a) begin
        if (ds0082)
            stg <= 4'd0;
        else begin
            if (fifo_wr_en)    stg[0] <= 1'b1;
            if (allc_edge)     stg[1] <= 1'b1;
            if (ev_drain)      stg[2] <= 1'b1;
            if (co_start_arm)  stg[3] <= 1'b1;
        end
    end
    // Furthest stage: 0 none, 1 request, 2 data, 3 all-complete,
    // 4 drain, 5 verify, 6 result latched.
    wire [2:0] stage_74 = res_valid ? 3'd6 :
                          stg[3]    ? 3'd5 :
                          stg[2]    ? 3'd4 :
                          stg[1]    ? 3'd3 :
                          stg[0]    ? 3'd2 :
                          (co_st == CO_IDLE) ? 3'd0 : 3'd1;
    synch_3 #(.WIDTH(3)) s_stg (stage_74, stage_m, clk_mach, , );

    reg [31:0] diag_rd_data_r;
    always @(*) begin
        case (diag_addr[15:0])
            16'h0000: diag_rd_data_r = {init_done_74, load_drained_74,
                                        store_busy_74, store_timeout_74,
                                        fifo_overflow, v_busy_74, v_ok_74,
                                        v_done_74, 24'd0};
            16'h0004: diag_rd_data_r = v_n_bytes_host;
            16'h0008: diag_rd_data_r = {8'd0, words_received_74};
            16'h000C: diag_rd_data_r = {8'd0, words_committed_74};
            16'h0010: diag_rd_data_r = {23'd0, fifo_high_water};
            16'h0014: diag_rd_data_r = v_crc32_74;
            16'h0018: diag_rd_data_r = v_first_word_74;
            16'h001C: diag_rd_data_r = v_last_word_74;
            16'h0020: diag_rd_data_r = {16'd0, v_words_readout_74};
            16'h0024: diag_rd_data_r = {27'd0, co_st, res_fail, res_code, res_valid};
            16'h0028: diag_rd_data_r = res_crc;
            16'h002C: diag_rd_data_r = res_nbytes;
            default:  diag_rd_data_r = 32'd0;
        endcase
    end
    always @(posedge clk_74a)
        if (diag_rd) diag_rd_data <= diag_rd_data_r;

    assign init_done      = init_done_74;
    assign load_drained   = load_drained_74;
    assign store_busy     = store_busy_74;
    assign store_timeout  = store_timeout_74;
    assign words_received = words_received_74;
    assign words_committed= words_committed_74;
    assign n_bytes_m      = v_nbytes_m;
    assign store_timeout_m= store_timeout_m_i;
    assign fifo_overflow_m= fifo_overflow_m_i;
    assign ver_done       = v_done_i;
    assign ver_ok         = v_ok_i;
    assign ver_stuck      = v_stuck;
    assign ver_crc32      = v_crc32;
    assign ver_first_word = v_first_word;
    assign ver_last_word  = v_last_word;
    assign ver_words_readout = v_words_readout;

    // ==================================================================
    // SDRAM controller (Pocket-local: +word_done/word_rd_valid/boot_done)
    // Word port owned by sdram_word_owner (store/verifier/fetch clients).
    // ==================================================================
    wire [31:0] sw_word_q;

    io_sdram_pocket isr0 (
        .controller_clk   ( ctrl_clk ),
        .chip_clk         ( chip_clk ),
        .clk_90           ( clk_90 ),
        .reset_n          ( 1'b1 ),  // internal boot FSM owns power-on

        .phy_cke          ( dram_cke ),
        .phy_clk          ( dram_clk ),
        .phy_cas          ( dram_cas_n ),
        .phy_ras          ( dram_ras_n ),
        .phy_we           ( dram_we_n ),
        .phy_ba           ( dram_ba ),
        .phy_a            ( dram_a ),
        .phy_dq           ( dram_dq ),
        .phy_dqm          ( dram_dqm ),

        // burst ports unused (word port serves host load + verifier + M1 fetch)
        .burst_rd         ( 1'b0 ),
        .burst_addr       ( 25'd0 ),
        .burst_len        ( 11'd0 ),
        .burst_32bit      ( 1'b0 ),
        .burst_data       ( ),
        .burst_data_valid ( ),
        .burst_data_done  ( ),

        .burstwr          ( 1'b0 ),
        .burstwr_addr     ( 15'd0 ),
        .burstwr_ready    ( ),
        .burstwr_strobe   ( 1'b0 ),
        .burstwr_data     ( 16'd0 ),
        .burstwr_done     ( 1'b0 ),

        .word_rd          ( ov_word_rd ),
        .word_wr          ( ov_word_wr ),
        .word_addr        ( ov_word_addr ),
        .word_data        ( ov_word_data ),
        .word_q           ( ov_word_q ),
        .word_busy        ( ov_word_busy ),
        .word_done        ( ov_word_done ),
        .word_rd_valid    ( ov_word_rd_valid ),
        .boot_done        ( sdram_init_done )
    );

endmodule
