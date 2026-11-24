//
// tb_woz_mb_control.sv - WOZ multi-block port: CONTROL harness (plan step 1)
//
// Measures the WOZ track-load path on the FULL Pocket stack (no instant host):
//   woz_floppy_controller -> sdram_woz_transport -> sdram_sector_fetch
//   -> sdram_word_owner -> io_sdram_pocket -> tb_dram_model
//
// PORT parameter selects the engine variant (the transport is the 0.4.4
// single-block service in both; the burst transport joins in step 3):
//   PORT=0 : 0.4.4 controller (9-bit sd_buff_addr)         <- BASELINE
//   PORT=1 : ported multi-block controller (14-bit addr; [13:9]=0 on the
//            old transport, so it still gets one block per request)
//
// Image: verilog/woz_mb/mb_image2.hex (gen_mb_image2.py) - WOZ2 5.25",
// meta 3 blocks, track 0 = 13 blocks/51200 bits (donor shape),
// track 1 = 4 blocks/20480 bits.
//
// Sequence (machine-clock phases, per-phase metrics reported):
//   P0 boot    : SDRAM init + store the 10240-byte image
//   P1 mount   : img_mounted -> header scan (3 blocks) -> disk_mounted
//   P2 seek t0 : initial track-0 load after settle (50000 cyc)
//   P3 seek t1 : track-1 load (4 blocks)
//   P4 seek t0 : RELOAD of a previously loaded track - the "protected
//                loader" milestone: software re-seeks a track that was
//                just read; on MiSTer the 13 per-block round trips here
//                timed out copy-protected loaders
//   P5 verify  : all track bytes in BRAM match the image (byte oracle)
//
// Per-phase metrics: machine-cycle count (1 cyc = 69.844 ns), engine ACK
// count (= host round trips), fetch count (= SDRAM window fills), cycles
// with fetch_req high awaiting sector_ready.
//
// Build: see run_control.sh (MSYS2 ucrt64 Verilator --binary --timing).
//
`timescale 1ns/1ps
module tb_woz_mb_control;
    // Engine variant is selected at PREPROCESS time (Verilator 5.050 does not
    // prune -G-overridden generate branches before pin checking, verified):
    //   default      : 0.4.4 controller (9-bit sd_buff_addr)   <- BASELINE
    //   -DPORT_NEW   : ported multi-block controller (14-bit addr; [13:9]=0
    //                  on the old transport, so it still gets one block/request)
`ifdef PORT_NEW
    localparam int PORTV = 1;
`else
    localparam int PORTV = 0;
`endif
    parameter PORT = PORTV;

    localparam real PHASE = 3.756;
    localparam real PM = 69.844;    // 14.318 MHz machine
    localparam real PC = 3.756;     // 133.12 MHz ctrl

    // ==================================================================
    // clocks (pattern: tb_woz_transport)
    // ==================================================================
    reg ctrl_clk, chip_clk, clk90, clk_mach;
    always begin
        ctrl_clk = 1'b0; #4000;
        forever #(PC/2.0) ctrl_clk = ~ctrl_clk;
    end
    always begin
        chip_clk = 1'b0; #4000; #PHASE;
        forever #(PC/2.0) chip_clk = ~chip_clk;
    end
    always begin
        clk90 = 1'b0; #4000; #(PHASE + PC/2.0);
        forever #(PC/2.0) clk90 = ~clk90;
    end
    always begin
        clk_mach = 1'b0; #4000;
        forever #(PM/2.0) clk_mach = ~clk_mach;
    end

    // ==================================================================
    // DRAM model + SDRAM controller
    // ==================================================================
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    reg por_done = 1'b0;
    reg fault_halt = 1'b0;

    tb_dram_model m0 (
        .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
        .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
        .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
        .fault_halt(fault_halt)
    );

    wire        sdram_init_done;
    wire        ov_word_rd, ov_word_wr, ov_word_busy, ov_word_done, ov_word_rd_valid;
    wire        ov_word_op_start;
    wire [23:0] ov_word_addr;
    wire [31:0] ov_word_data, ov_word_q;

    io_sdram_pocket isr0 (
        .controller_clk   ( ctrl_clk ),
        .chip_clk         ( chip_clk ),
        .clk_90           ( clk90 ),
        .reset_n          ( 1'b1 ),
        .phy_cke          ( dram_cke ),
        .phy_clk          ( dram_clk ),
        .phy_cas          ( dram_cas_n ),
        .phy_ras          ( dram_ras_n ),
        .phy_we           ( dram_we_n ),
        .phy_ba           ( dram_ba ),
        .phy_a            ( dram_a ),
        .phy_dq           ( dram_dq ),
        .phy_dqm          ( dram_dqm ),
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
        .word_busy        ( ov_word_busy),
        .word_done        ( ov_word_done),
        .word_rd_valid    ( ov_word_rd_valid ),
        .word_op_start    ( ov_word_op_start ),
        .boot_done        ( sdram_init_done )
    );

    // ==================================================================
    // word owner + sector fetcher
    // ==================================================================
    reg         st_req;
    reg  [23:0] st_addr;
    reg  [31:0] st_data;
    wire        st_busy, st_done;

    reg         vr_req = 1'b0;
    reg  [23:0] vr_addr = 24'd0;
    wire        vr_done;
    wire [31:0] vr_data;

    wire        fc_req_w;
    wire [23:0] fc_addr_w;
    wire [7:0]  fc_gen_w;
    wire        fc_active_w, fc_word_valid_w, fc_done_w;
    wire [31:0] fc_data_w;
    wire [7:0]  fc_done_len_w, fc_done_gen_w;

    wire        fetch_busy, sector_ready, fetch_fault;
    wire [15:0] sector_lba;
    wire [7:0]  sector_byte_data;
    wire        fetch_req;
    wire [15:0] fetch_lba;
    wire [8:0]  sector_byte_addr;
    wire        sector_done;
    reg         img_gen_tb = 1'b1;

    sdram_word_owner owner0 (
        .clk        ( ctrl_clk ),
        .rst_n      ( 1'b1 ),
        .word_rd    ( ov_word_rd ),
        .word_wr    ( ov_word_wr ),
        .word_addr  ( ov_word_addr ),
        .word_data  ( ov_word_data ),
        .word_q     ( ov_word_q ),
        .word_busy  ( ov_word_busy),
        .word_done  ( ov_word_done ),
        .word_rd_valid( ov_word_rd_valid ),
        .word_op_start( ov_word_op_start ),
        .init_done  ( sdram_init_done ),
        .st_req     ( st_req ),
        .st_addr    ( st_addr ),
        .st_data    ( st_data ),
        .st_busy    ( st_busy ),
        .st_done    ( st_done ),
        .vr_req     ( vr_req ),
        .vr_addr    ( vr_addr ),
        .vr_done    ( vr_done ),
        .vr_data    ( vr_data ),
        .fc_req     ( fc_req_w ),
        .fc_addr    ( fc_addr_w ),
        .fc_gen     ( fc_gen_w ),
        .fc_active  ( fc_active_w),
        .fc_word_valid( fc_word_valid_w ),
        .fc_done    ( fc_done_w ),
        .fc_data    ( fc_data_w ),
        .fc_done_len( fc_done_len_w ),
        .fc_done_gen( fc_done_gen_w )
    );

    sdram_sector_fetch fetch0 (
        .clk_mach      ( clk_mach ),
        .rst_n_mach    ( 1'b1 ),
        .clk_ctrl      ( ctrl_clk ),
        .rst_n_ctrl    ( 1'b1 ),
        .fetch_req     ( fetch_req ),
        .fetch_lba     ( fetch_lba ),
        .fetch_busy    ( fetch_busy ),
        .sector_ready  ( sector_ready ),
        .sector_lba    ( sector_lba ),
        .sector_byte_addr ( sector_byte_addr ),
        .sector_byte_data ( sector_byte_data ),
        .sector_done   ( sector_done ),
        .fetch_fault   ( fetch_fault),
        .init_done     ( sdram_init_done ),
        .img_nbytes    ( 32'd11264 ),
        .img_gen       ( img_gen_tb ),
        .fc_req        ( fc_req_w ),
        .fc_addr       ( fc_addr_w ),
        .fc_gen        ( fc_gen_w ),
        .fc_active     ( fc_active_w ),
        .fc_word_valid ( fc_word_valid_w ),
        .fc_done       ( fc_done_w ),
        .fc_data       ( fc_data_w ),
        .fc_done_gen   ( fc_done_gen_w )
    );

    // ==================================================================
    // WOZ engine + transport
    // ==================================================================
    reg         reset = 1'b1;
    reg         img_mounted = 1'b0;
    reg  [7:0]  track_id = 8'd0;

    wire [31:0] sd_lba;
    wire        sd_rd, sd_wr, sd_ack;
    wire [13:0] eng_buff_addr;
    wire [7:0]  sd_buff_din;
    wire [7:0]  sd_buff_dout;
    wire        sd_buff_wr;
    wire [5:0]  sd_blk_cnt_w;

    // transport: 0.4.4 single-block service (step 3 swaps in the burst service)
    wire        tr_wr_fault, tr_oor_fault, tr_fault;
    reg         tr_fault_clr = 1'b0;

    `ifndef TRANSPORT_MB
sdram_woz_transport woz_tr (
        .clk            ( clk_mach ),
        .rst_n          ( 1'b1 ),
        .sd_rd          ( sd_rd ),
        .sd_lba         ( sd_lba ),
        .sd_ack         ( sd_ack ),
        .sd_wr          ( sd_wr ),
        .sd_buff_addr   ( eng_buff_addr[8:0] ),
        .sd_buff_din    ( sd_buff_din ),
        .sd_buff_dout   ( sd_buff_dout ),
        .sd_buff_wr     ( sd_buff_wr ),
        .fetch_req      ( fetch_req ),
        .fetch_lba      ( fetch_lba ),
        .fetch_busy     ( fetch_busy ),
        .sector_ready   ( sector_ready),
        .sector_lba     ( sector_lba ),
        .sector_byte_data( sector_byte_data ),
        .fetch_fault    ( fetch_fault),
        .sector_byte_addr( sector_byte_addr ),
        .sector_done    ( sector_done ),
        .drive_active   ( img_mounted ),
        .fault_clr      ( tr_fault_clr ),
        .wr_fault       ( tr_wr_fault ),
        .oor_fault      ( tr_oor_fault),
        .transport_fault( tr_fault )
    );
`else
    // multi-block burst service (PLAN_WOZ_GS_MULTIBLOCK step 3)
    sdram_woz_transport_mb woz_tr (
        .clk            ( clk_mach ),
        .rst_n          ( 1'b1 ),
        .sd_rd          ( sd_rd ),
        .sd_lba         ( sd_lba ),
        .sd_blk_cnt_in  ( sd_blk_cnt_w ),
        .sd_ack         ( sd_ack ),
        .sd_wr          ( sd_wr ),
        .sd_buff_addr   ( eng_buff_addr ),
        .sd_buff_din    ( sd_buff_din ),
        .sd_buff_dout   ( sd_buff_dout ),
        .sd_buff_wr     ( sd_buff_wr ),
        .fetch_req      ( fetch_req ),
        .fetch_lba      ( fetch_lba ),
        .fetch_busy     ( fetch_busy ),
        .sector_ready   ( sector_ready),
        .sector_lba     ( sector_lba ),
        .sector_byte_data( sector_byte_data ),
        .fetch_fault    ( fetch_fault),
        .sector_byte_addr( sector_byte_addr ),
        .sector_done    ( sector_done ),
        .drive_active   ( img_mounted ),
        .fault_clr      ( tr_fault_clr ),
        .wr_fault       ( tr_wr_fault ),
        .oor_fault      ( tr_oor_fault),
        .transport_fault( tr_fault )
    );
`endif

    wire        ready, disk_mounted, busy, track_load_complete;
    wire [31:0] bit_count;
    reg  [15:0] bit_addr = 16'd0;
    wire [7:0]  bit_data;
    wire        is_flux_track, track_data_valid, disk_type_mismatch;
    wire        disk_write_protected;
    wire [31:0] flux_data_size, flux_total_ticks;
    wire [7:0]  optimal_bit_timing;
    wire [15:0] dbg_load_sum;
    wire [13:0] dbg_load_bytes;
    wire [7:0]  dbg_load_blocks;

`ifndef PORT_NEW
        woz_floppy_controller #(.IS_35_INCH(0)) dut (
            .clk                 ( clk_mach ),
            .reset               ( reset ),
            .sd_lba              ( sd_lba ),
            .sd_rd               ( sd_rd ),
            .sd_wr               ( sd_wr ),
            .sd_ack              ( sd_ack ),
            .sd_buff_addr        ( eng_buff_addr[8:0] ),
            .sd_buff_dout        ( sd_buff_dout ),
            .sd_buff_din         ( sd_buff_din ),
            .sd_buff_wr          ( sd_buff_wr ),
            .img_mounted         ( img_mounted ),
            .img_readonly        ( 1'b1 ),
            .img_size            ( 64'd11264 ),
            .track_id            ( track_id ),
            .ready               ( ready ),
            .disk_mounted        ( disk_mounted ),
            .busy                ( busy ),
            .active              ( 1'b1 ),
            .bit_count           ( bit_count ),
            .bit_addr            ( bit_addr ),
            .stable_side         ( 1'b0 ),
            .bit_data            ( bit_data ),
            .bit_data_in         ( 8'd0 ),
            .bit_we              ( 1'b0 ),
            .bit_wr_addr         ( 16'd0 ),
            .track_load_complete ( track_load_complete ),
            .is_flux_track       ( is_flux_track ),
            .flux_data_size      ( flux_data_size ),
            .flux_total_ticks    ( flux_total_ticks ),
            .track_data_valid    ( track_data_valid ),
            .disk_type_mismatch  ( disk_type_mismatch ),
            .disk_write_protected( disk_write_protected ),
            .optimal_bit_timing  ( optimal_bit_timing ),
            .dbg_load_sum        ( dbg_load_sum ),
            .dbg_load_bytes      ( dbg_load_bytes ),
            .dbg_load_blocks     ( dbg_load_blocks )
        );
`endif
`ifdef PORT_NEW
        woz_floppy_controller #(.IS_35_INCH(0)) dut (
            .clk                 ( clk_mach ),
            .reset               ( reset ),
            .sd_lba              ( sd_lba ),
            .sd_rd               ( sd_rd ),
            .sd_wr               ( sd_wr ),
            .sd_ack              ( sd_ack ),
            .sd_buff_addr        ( eng_buff_addr ),
            .sd_buff_blk         ( eng_buff_addr[13:9] ),
            .sd_blk_cnt          ( sd_blk_cnt_w ),
            .sd_buff_dout        ( sd_buff_dout ),
            .sd_buff_din         ( sd_buff_din ),
            .sd_buff_wr          ( sd_buff_wr ),
            .img_mounted         ( img_mounted ),
            .img_readonly        ( 1'b1 ),
            .img_size            ( 64'd11264 ),
            .track_id            ( track_id ),
            .ready               ( ready ),
            .disk_mounted        ( disk_mounted ),
            .busy                ( busy ),
            .active              ( 1'b1 ),
            .bit_count           ( bit_count ),
            .bit_addr            ( bit_addr ),
            .stable_side         ( 1'b0 ),
            .bit_data            ( bit_data ),
            .bit_data_in         ( 8'd0 ),
            .bit_we              ( 1'b0 ),
            .bit_wr_addr         ( 16'd0 ),
            .track_load_complete ( track_load_complete ),
            .is_flux_track       ( is_flux_track ),
            .flux_data_size      ( flux_data_size ),
            .flux_total_ticks    ( flux_total_ticks ),
            .track_data_valid    ( track_data_valid ),
            .disk_type_mismatch  ( disk_type_mismatch ),
            .disk_write_protected( disk_write_protected ),
            .optimal_bit_timing  ( optimal_bit_timing ),
            .dbg_load_sum        ( dbg_load_sum ),
            .dbg_load_bytes      ( dbg_load_bytes ),
            .dbg_load_blocks     ( dbg_load_blocks )
        );
`endif

    // ==================================================================
    // image (byte oracle) + store client
    // ==================================================================
    localparam IMG_BYTES = 11264;
    localparam IMG_WORDS = 2816;
    localparam T2_START  = 20;
    localparam T2_CNT    = 2;
    localparam T0_START  = 3;
    localparam T0_CNT    = 13;
    localparam T1_START  = 16;
    localparam T1_CNT    = 4;

    reg [7:0] image [0:IMG_BYTES-1];
    initial $readmemh("verilog/woz_mb/mb_image2.hex", image);

    reg  [11:0] st_wi = 12'd0;
    reg         st_go = 1'b0;
    always @(posedge ctrl_clk) begin
        st_req <= 1'b0;
        if (st_go && !st_busy && st_wi < 12'd2816) begin
            st_addr <= st_wi;
            st_data <= {image[4*st_wi], image[4*st_wi+1], image[4*st_wi+2], image[4*st_wi+3]};
            st_req  <= 1'b1;
        end
        if (st_done)
            st_wi <= st_wi + 12'd1;
    end
    reg store_complete = 1'b0;
    always @(posedge ctrl_clk)
        store_complete <= (st_wi >= 12'd2816);

    // ==================================================================
    // instrumentation (machine domain)
    // ==================================================================
    integer mc_cnt = 0;     // machine cycle counter
    integer ack_cnt = 0;    // engine request count (sd_ack rises)
    integer fch_cnt = 0;    // SDRAM window fills (fetch_req rises)
    integer wait_cnt = 0;   // cycles with fetch_req high awaiting ready
    integer tst_cnt = 0;    // transport strobes (sd_buff_wr rises)
    integer ewr_cnt = 0;    // engine BRAM writes (track_load_we rises)
    reg sd_ack_d1 = 1'b0;
    reg fetch_req_d1 = 1'b0;
    reg sd_buff_wr_d1 = 1'b0;
    always @(posedge clk_mach) begin
        mc_cnt <= mc_cnt + 1;
        sd_ack_d1    <= sd_ack;
        fetch_req_d1 <= fetch_req;
        sd_buff_wr_d1 <= sd_buff_wr;
        if (sd_ack & ~sd_ack_d1)    ack_cnt = ack_cnt + 1;
        if (fetch_req & ~fetch_req_d1) fch_cnt = fch_cnt + 1;
        if (sd_buff_wr & ~sd_buff_wr_d1) tst_cnt = tst_cnt + 1;
        if (fetch_req && !sector_ready && !fetch_fault) wait_cnt = wait_cnt + 1;
    end
    always @(posedge clk_mach)
        if (dut.track_load_we) ewr_cnt = ewr_cnt + 1;

    integer nfail = 0;
    integer mc_s, ack_s, fch_s, wait_s, tst_s, ewr_s;
    task phase_mark;
        begin
            mc_s = mc_cnt; ack_s = ack_cnt; fch_s = fch_cnt; wait_s = wait_cnt;
            tst_s = tst_cnt; ewr_s = ewr_cnt;
            $display("MARK mc=%0d ack=%0d fch=%0d wait=%0d tst=%0d ewr=%0d",
                     mc_cnt, ack_cnt, fch_cnt, wait_cnt, tst_cnt, ewr_cnt);
        end
    endtask
    task phase_end(input [31:0] label);
        begin
            $display("METRIC PORT=%0d %-12d mc=%-7d cyc=%-7d ack=%-3d fetch=%-3d rw=%-5d tstrb=%-5d ewr=%-5d",
                     PORT, label, mc_cnt, mc_cnt - mc_s, ack_cnt - ack_s,
                     fch_cnt - fch_s, wait_cnt - wait_s,
                     tst_cnt - tst_s, ewr_cnt - ewr_s);
        end
    endtask

    // P3 debug log: 120 machine cycles from the first transport strobe of P3
    // (byte 0 of track 1's first block). Armed once via p3_arm at phase start;
    // the capture starts on the first sd_buff_wr posedge.
    integer p3_log = 0;
    reg p3_arm = 1'b0;
    always @(posedge clk_mach) begin
        if (p3_arm && sd_buff_wr & ~sd_buff_wr_d1) p3_log = 1;
        if (p3_log > 0 && p3_log < 120) begin
            $display("P3L %0d rd=%b ack=%b wrs=%b addr=%0d ready=%b freq=%b lba=%0d blkwe=%b laddr=%0d ldata=%02x",
                     p3_log, sd_rd, sd_ack, sd_buff_wr, eng_buff_addr[8:0],
                     sector_ready, fetch_req, sector_lba,
                     dut.track_load_we, dut.track_load_addr, dut.track_load_data);
            p3_log = p3_log + 1;
        end
    end

    // P1-only: wait for the internal scan-complete (hierarchical - woz_valid
    // is not a port; disk_mounted is deliberately immediate media-present)
    task wait_phase_hier(input integer budget);
        integer t;
        begin
            t = 0;
            while (!dut.woz_valid && t < budget) begin
                @(posedge clk_mach);
                t = t + 1;
            end
            if (!dut.woz_valid) begin
                $display("FAIL: timeout waiting for scan (woz_valid)");
                nfail = nfail + 1;
            end
        end
    endtask

    // P7 guard watch: flag any track_data_valid rise while invalid ids are
    // applied (armed between P7a..P7c windows)
    reg p7_watch = 1'b0;
    reg p7_valid_rises = 1'b0;
    always @(posedge clk_mach)
        if (p7_watch && track_data_valid & ~tdv_d1)
            p7_valid_rises = 1'b1;

    // event time-stamps (debug the phase bookkeeping)
    reg tdv_d1 = 1'b0;
    always @(posedge clk_mach) begin
        tdv_d1 <= track_data_valid;
        if (track_data_valid & ~tdv_d1)
            $display("EV mc=%0d tdv RISE track_id=%0d", mc_cnt, track_id);
        if (tdv_d1 & !track_data_valid)
            $display("EV mc=%0d tdv FALL track_id=%0d", mc_cnt, track_id);
        if (busy & ~busy_d1w) $display("EV mc=%0d busy RISE", mc_cnt);
    end
    reg busy_d1w = 1'b0;
    always @(posedge clk_mach) busy_d1w <= busy;

    // settle state probe (hierarchical) - dump at key events
    reg [6:0]  lp_d1;
    reg [19:0] sc_d1;
    always @(posedge clk_mach) begin
        lp_d1 <= dut.last_physical_track;
        sc_d1 <= dut.settle_counter;
        if (dut.last_physical_track != lp_d1)
            $display("EV mc=%0d phys %0d -> %0d settle=0", mc_cnt, lp_d1, dut.last_physical_track);
        if (track_data_valid & ~tdv_d1)
            $display("EV mc=%0d RISE phys=%0d settle=%0d", mc_cnt, dut.last_physical_track, dut.settle_counter);
    end
    reg fr_d1p = 1'b0;
    reg tlw_d1p = 1'b0;
    integer fr_ev, ewr_ev;
    always @(posedge clk_mach) begin
        fr_d1p  <= fetch_req;
        tlw_d1p <= dut.track_load_we;
        if (mc_cnt > 118000) begin
            if (fetch_req & ~fr_d1p) begin
                fr_ev = fr_ev + 1;
                $display("EV mc=%0d FR ev#%0d lba=%0d", mc_cnt, fr_ev, fetch_lba);
            end
            if (mc_cnt > 123000 && (dut.track_load_we & ~tlw_d1p) && (ewr_ev < 8)) begin
                ewr_ev = ewr_ev + 1;
                $display("EV mc=%0d EWR ev#%0d addr=%0d", mc_cnt, ewr_ev, dut.track_load_addr);
            end
        end
    end

    // wait for track_data_valid after a track_id change. The DUT must first
    // SAMPLE the new track_id (the old valid is stale until then) - so wait
    // for valid to drop or to be already 0, then for it to rise again.
    task wait_phase(input integer which, input integer budget);
        integer t;
        reg ok;
        begin
            t = 0; ok = 0;
            if (which == 3) begin
                // drain the stale valid from the previous track
                while (track_data_valid && t < budget) begin
                    @(posedge clk_mach); t = t + 1;
                end
            end
            while (!ok && t < budget) begin
                case (which)
                1: ok = disk_mounted;
                2: ok = ready;
                default: ok = track_data_valid;
                endcase
                @(posedge clk_mach);
                t = t + 1;
            end
            if (!ok) begin
                $display("FAIL: timeout phase=%0d budget=%0d", which, budget);
                nfail = nfail + 1;
            end
        end
    endtask

    // verify one track's BRAM bytes against the image
    task check_track(input integer tstart, input integer nbytes, input integer tag);
        integer i, errs;
        begin
            errs = 0;
            for (i = 0; i < nbytes; i = i + 1) begin
                bit_addr <= i[15:0];
                repeat (3) @(posedge clk_mach);
                #1;
                if (bit_data !== image[tstart*512 + i]) begin
                    if (1)
                        $display("FAIL T%0d: BRAM[%0d] = %02x want %02x",
                                 tag, i, bit_data, image[tstart*512 + i]);
                    errs = errs + 1;
                end
            end
            if (errs) begin
                $display("FAIL: track %0d byte verify: %0d errors", tag, errs);
                nfail = nfail + 1;
            end else
                $display("OK  : track %0d: all %0d BRAM bytes exact", tag, nbytes);
        end
    endtask

    // ==================================================================
    // sequencing
    // ==================================================================
    initial begin
        // P0: boot - SDRAM power-on settle, init, store the image
        // (por_done must be released before the SDRAM controller issues
        // its first command - pattern: tb_woz_transport)
        #1000;
        por_done = 1'b1;
        phase_mark();
        while (!sdram_init_done) @(posedge clk_mach);
        st_go = 1'b1;
        while (!store_complete) @(posedge ctrl_clk);
        repeat (100) @(posedge ctrl_clk);
        phase_end(32'd0);   // label 0 = P0 boot/store

        // P1: mount -> header scan (3 blocks) -> scan complete (woz_valid;
        // disk_mounted is deliberately immediate media-present, not scan done)
        reset = 1'b0;
        repeat (20) @(posedge clk_mach);
        phase_mark();
        img_mounted = 1'b1;
        wait_phase_hier(2_000_000);
        phase_end(32'd1);   // label 1 = P1 mount/scan

        if (disk_type_mismatch) begin
            $display("FAIL: disk_type_mismatch asserted");
            nfail = nfail + 1;
        end
        if (is_flux_track) begin
            $display("FAIL: unexpected FLUX track");
            nfail = nfail + 1;
        end

        // P2: initial track-0 load (track_id already 0; settle 50000 + load)
        phase_mark();
        wait_phase(3, 2_000_000);   // track_data_valid
        phase_end(32'd2);           // label 2 = P2 load t0
        check_track(T0_START, T0_CNT*512, 0);

        // P3: seek to track 1
        phase_mark();
        p3_arm = 1'b1;
        track_id = 8'd1;
        wait_phase(3, 2_000_000);
        phase_end(32'd3);           // label 3 = P3 load t1
        check_track(T1_START, T1_CNT*512, 1);

        // P4: the protected-loader milestone - re-seek track 0 (reload)
        p3_arm = 1'b0;
        phase_mark();
        track_id = 8'd0;
        wait_phase(3, 2_000_000);
        phase_end(32'd4);           // label 4 = P4 reload t0 (HEADLINE, in-pair hop)
        check_track(T0_START, T0_CNT*512, 0);

        // P5: cross-physical-pair seek (qtr 0 -> qtr 2) - the 50000-cycle
        // settle path plus a fresh 2-block load
        phase_mark();
        track_id = 8'd2;
        wait_phase(3, 2_000_000);
        phase_end(32'd5);           // label 5 = P5 load t2 (cross-pair + settle)
        phase_mark();
        check_track(T2_START, T2_CNT*512, 2);

        phase_end(32'd6);           // label 6 = check-track t2 duration

        // -------------------------------------------------------------
        // P7/P8: TMAP range guard (ported controller only, step-2 gate):
        //   P7a: track_id=160 (out of range) - must NOT load, fetch, write
        //        BRAM, or assert valid/ready
        //   P7b: track_id=255 (out of range)
        //   P7c: track_id=159 (legal index, TMAP entry empty/unmapped) -
        //        in-range: a seek may happen, but no data exists
        //   P8 : back to track 0 - full reload + byte-exact verify
        if (PORTV == 1) begin
            // P7a: id 160
            phase_mark();
            track_id = 8'd160;
            p7_watch = 1'b1;
            repeat (2000) @(posedge clk_mach);
            p7_watch = 1'b0;
            phase_end(32'd7);           // label 7 = P7a id160 (want: fetch=0 ewr=0)

            // P7b: id 255
            phase_mark();
            track_id = 8'd255;
            p7_watch = 1'b1;
            repeat (2000) @(posedge clk_mach);
            p7_watch = 1'b0;
            phase_end(32'd8);           // label 8 = P7b id255 (want: fetch=0 ewr=0)

            // P7c: id 159 (legal, unmapped) - a valid rise here is LEGAL
            // (in-range index, cached-as-empty); the watch stays disarmed.
            phase_mark();
            track_id = 8'd159;
            repeat (2000) @(posedge clk_mach);
            phase_end(32'd9);           // label 9 = P7c id159 (want: ewr=0)

            // P8: back to track 0 - reload + verify
            phase_mark();
            track_id = 8'd0;
            wait_phase(3, 2_000_000);
            phase_end(32'd10);          // label 10 = P8 reload t0 after invalid IDs
            check_track(T0_START, T0_CNT*512, 0);
            if (p7_valid_rises) begin
                $display("FAIL P7: track_data_valid rose during an invalid-id window");
                nfail = nfail + 1;
            end else
                $display("OK  : no spurious track_data_valid during invalid ids");
        end
        if (nfail) begin
            $display("TB WOB MB CONTROL: FAIL nfail=%0d (PORT=%0d)", nfail, PORT);
            $fatal(1);
        end
        $display("TB WOB MB CONTROL: ALL PASS (PORT=%0d)", PORT);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
