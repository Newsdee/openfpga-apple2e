// ============================================================================
// verilog/pocket_boot/tb_pocket_boot.sv
//
// Full-machine Verilator harness for the Apple IIe Pocket core:
// instantiates the real stream_video_core_top (machine + WOZ engine +
// SDRAM storage + video path), drives the APF host bridge with a WOZ
// image load/verify sequence, models the SDRAM chip (tb_dram_model),
// and captures video frames for on-screen / headless boot debugging.
//
// Reconstructed 2026-10-22 after the original file was lost in a botched
// in-place edit; the protocol details (0x10/0x82/0x8f/0x11 command
// sequence, byte addresses, polling, pacing) were recovered from the
// last generated Verilator code in obj_dir/.
//
// Public signals (read/written by pocket_main.cpp):
//   fb fb_w fb_h frame_new frame_cnt  - video frame capture
//   e74a                          - 74.25 MHz edge counter
//   seq_mode seq_mode_req action_go  - host cycle control (F9/F10)
//   reset_go do_quit               - key actions
//   host_state host_busy           - host cycle state
//   load_res82 load_res8f          - WOZ load/verify results
//   trace_req                      - DRAM command trace enable
//   d_mt d_ac d_mo d_st d_ack d_rdreq d_tf d_reads
//   d_machine_reset d_reset_n d_pll_lock d_init_done
// ============================================================================
`timescale 1ns/1ps

module tb_pocket_boot;

    // ------------------------------------------------------------------
    // Clocks: 74.25 MHz pair (DUT treats the two domains as async)
    // ------------------------------------------------------------------
    reg clk_74a;
    reg clk_74b;
    initial begin
        clk_74a = 1'b0;
        forever #6.734 clk_74a = ~clk_74a;  // 13.468 ns period = 74.25 MHz (1ns timescale!)
    end
    initial begin
        clk_74b = 1'b0;
        forever #6.734 clk_74b = ~clk_74b;  // 13.468 ns period = 74.25 MHz
    end

    // ------------------------------------------------------------------
    // APF physical port tie-offs
    // ------------------------------------------------------------------
    reg  [7:0] tie8  = 8'h00;
    reg  [7:4] tie4w = 4'b0000;   // cart_tran_bank0 is [7:4]
    reg  [15:0] tie16 = 16'h0000;
    reg        tie1  = 1'b0;

    // ------------------------------------------------------------------
    // Host bridge (synchronous to clk_74a)
    // ------------------------------------------------------------------
    reg         bridge_wr;
    reg  [31:0] bridge_addr;
    reg  [31:0] bridge_wr_data;
    reg         bridge_rd;
    wire [31:0] bridge_rd_data;

    // ------------------------------------------------------------------
    // SDRAM pins (DUT <-> tb_dram_model)
    // ------------------------------------------------------------------
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire        dram_clk;
    wire        dram_cke;
    wire        dram_ras_n;
    wire        dram_cas_n;
    wire        dram_we_n;
    reg         por_done;       // TB: power-on settle elapsed
    reg         fault_halt;     // TB-injected DRAM fault
    reg trace_req /* verilator public */;

    // DRAM model: the M0 reference geometry (coincident rising chip/ctrl
    // edge grid, see the altera_pll_sim SD_MODE comment). Model default
    // CAS=2 now matches the chip's power-up-default mode on silicon
    // (hardware fingerprint 2026-10-23); the controller's CAP_PIPE=3
    // capture window is calibrated to it. TB-only.
    tb_dram_model m0 (
        .clk        (dram_clk),
        .cke        (dram_cke),
        .ras        (dram_ras_n),
        .cas        (dram_cas_n),
        .we         (dram_we_n),
        .por_done   (por_done),
        .ba         (dram_ba),
        .a          (dram_a),
        .dq         (dram_dq),
        .dqm        (dram_dqm),
        .fault_halt (fault_halt),
        .trace_req  (trace_req)
    );

    // ------------------------------------------------------------------
    // Video
    // ------------------------------------------------------------------
    wire [23:0] video_rgb;
    wire        video_pclk;
    wire        video_pclk90;
    wire        video_de;
    wire        video_vs;
    wire        video_hs;
    wire        video_skip;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    stream_video_core_top dut (
        .clk_74a(clk_74a),
        .clk_74b(clk_74b),

        // cartridge / port (unused)
        .cart_tran_bank2(tie8),   .cart_tran_bank2_dir(),
        .cart_tran_bank3(tie8),   .cart_tran_bank3_dir(),
        .cart_tran_bank1(tie8),   .cart_tran_bank1_dir(),
        .cart_tran_bank0(tie4w),  .cart_tran_bank0_dir(),
        .cart_tran_pin30(tie1),   .cart_tran_pin30_dir(),
        .cart_pin30_pwroff_reset(),
        .cart_tran_pin31(tie1),   .cart_tran_pin31_dir(),
        .port_ir_rx(tie1),        .port_ir_tx(),
        .port_ir_rx_disable(),
        .port_tran_si(tie1),      .port_tran_si_dir(),
        .port_tran_so(tie1),      .port_tran_so_dir(),
        .port_tran_sck(tie1),     .port_tran_sck_dir(),
        .port_tran_sd(tie1),      .port_tran_sd_dir(),

        // CRAAM (unused)
        .cram0_a(), .cram0_dq(tie16), .cram0_wait(1'b0),
        .cram0_clk(), .cram0_adv_n(), .cram0_cre(),
        .cram0_ce0_n(), .cram0_ce1_n(), .cram0_oe_n(),
        .cram0_we_n(), .cram0_ub_n(), .cram0_lb_n(),
        .cram1_a(), .cram1_dq(tie16), .cram1_wait(1'b0),
        .cram1_clk(), .cram1_adv_n(), .cram1_cre(),
        .cram1_ce0_n(), .cram1_ce1_n(), .cram1_oe_n(),
        .cram1_we_n(), .cram1_ub_n(), .cram1_lb_n(),

        // SDRAM
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq),
        .dram_dqm(dram_dqm), .dram_clk(dram_clk), .dram_cke(dram_cke),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n),

        // SRAM (unused)
        .sram_a(), .sram_dq(tie16), .sram_oe_n(), .sram_we_n(),
        .sram_ub_n(), .sram_lb_n(),

        // misc physical
        .vblank(tie1), .dbg_tx(), .dbg_rx(tie1),
        .user1(), .user2(tie1),
        .aux_sda(tie1), .aux_scl(), .vpll_feed(),

        // video
        .video_rgb(video_rgb),
        .video_rgb_clock(video_pclk),
        .video_rgb_clock_90(video_pclk90),
        .video_de(video_de),
        .video_skip(video_skip),
        .video_vs(video_vs),
        .video_hs(video_hs),

        // audio
        .audio_mclk(), .audio_adc(tie1), .audio_dac(), .audio_lrck(),

        // host bridge
        .bridge_endian_little(),
        .bridge_addr(bridge_addr),
        .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data),
        .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),

        // controllers
        .cont1_key(32'd0), .cont2_key(32'd0), .cont3_key(32'd0), .cont4_key(32'd0),
        .cont1_joy(32'd0), .cont2_joy(32'd0), .cont3_joy(32'd0), .cont4_joy(32'd0),
        .cont1_trig(16'd0), .cont2_trig(16'd0), .cont3_trig(16'd0), .cont4_trig(16'd0)
    );

    // ------------------------------------------------------------------
    // Video frame capture (frame buffer stride 720, like pocket_main.cpp)
    // ------------------------------------------------------------------
    localparam FBW = 720;
    localparam FBH = 256;
    reg  [23:0] fb [0:FBW*FBH-1] /* verilator public */;
    reg  [11:0] fb_w /* verilator public */;
    reg  [11:0] fb_h /* verilator public */;
    reg         frame_new /* verilator public */;
    reg  [15:0] frame_cnt /* verilator public */;

    reg [10:0] fc_x;
    reg [10:0] fc_y;
    reg        de_r;
    integer    fc_xmax;
    integer    fc_ymax;
    always @(posedge video_pclk) begin
        frame_new <= 1'b0;
        if (video_de && fc_y < FBH) begin
            fb[fc_y*FBW + fc_x] <= video_rgb;
            fc_x <= fc_x + 1'b1;
        end
        if (de_r && !video_de) begin
            // row ended
            if (fc_x > fc_xmax) fc_xmax = fc_x;
            if (fc_y > fc_ymax) fc_ymax = fc_y;
            fc_x <= 11'd0;
            fc_y <= fc_y + 1'b1;
        end
        de_r <= video_de;
        if (video_vs) begin
            fb_w <= fc_xmax[11:0];
            fb_h <= fc_ymax[11:0];
            fc_x    <= 11'd0;
            fc_y    <= 11'd0;
            fc_xmax <= 0;
            fc_ymax <= 0;
            frame_new <= 1'b1;
            frame_cnt <= frame_cnt + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Diagnostic taps (public for pocket_main.cpp)
    // ------------------------------------------------------------------
    reg  [31:0] e74a /* verilator public */;
    initial e74a = 32'd0;
    always @(posedge clk_74a) e74a <= e74a + 32'd1;

    wire d_mt /* verilator public */ = dut.mc_img_mounted;
    wire d_ac /* verilator public */ = dut.drv_active;
    wire d_mo /* verilator public */ = dut.drv_motor;
    wire [2:0]  d_st /* verilator public */ = dut.mc_state;   // 3-bit (was 1-bit: truncated)
    wire d_ack /* verilator public */ = dut.woz_sd_ack;
    wire d_rdreq /* verilator public */ = dut.woz.drive_g[0].sd_rd;
    wire [23:0] d_reads /* verilator public */ = dut.drv_reads;  // 24-bit (was 1-bit: RD=234496 could never have been reported)
    wire d_pll_lock /* verilator public */ = dut.pll_core_locked;
    wire d_init_done /* verilator public */ = dut.stor.init_done_74;
    wire d_machine_reset /* verilator public */ = dut.machine_reset;
    wire d_reset_n /* verilator public */ = dut.reset_n;
    wire d_tf  /* verilator public */ = dut.woz_transport_fault;
    wire [31:0] d_crc /* verilator public */ = dut.stor_res_crc_m;

    // fault-source taps (ejection right after scan completion)
    wire        dbg_faultp   = dut.woz_mc.fault_pend;
    wire        dbg_tfail    = dut.woz_transport_fault;
    wire        dbg_wrfault  = dut.woz_wr_fault;
    wire        dbg_oorfault = dut.woz_oor_fault;
    reg         dbg_tfail_s;
    initial dbg_tfail_s = 1'b0;

    // WOZ parser state taps (why the scan never reaches parser_done)
    wire        dbg_pinfo   = dut.woz.drive_g[0].ctrl.have_info;
    wire        dbg_ptmap   = dut.woz.drive_g[0].ctrl.have_tmap;
    wire        dbg_ptrks   = dut.woz.drive_g[0].ctrl.have_trks;
    wire        dbg_pflux   = dut.woz.drive_g[0].ctrl.have_flux;
    wire [7:0]  dbg_pver    = dut.woz.drive_g[0].ctrl.info_version;
    wire        dbg_pdone   = dut.woz.drive_g[0].ctrl.parser_done;
    wire        dbg_pwvalid = dut.woz.drive_g[0].ctrl.woz_valid;
    wire        dbg_pfail   = dut.woz.drive_g[0].ctrl.scan_failed;
    wire [15:0] dbg_pblocks = dut.woz.drive_g[0].ctrl.scan_blocks;
    wire [31:0] dbg_plba    = dut.woz.drive_g[0].ctrl.sd_lba;
    reg  [63:0] dbg_pkey_s;
    wire [63:0] dbg_pkey = {dbg_pfail, dbg_pwvalid, dbg_pdone, dbg_pver,
                            dbg_pinfo, dbg_ptmap, dbg_ptrks, dbg_pflux,
                            dbg_pblocks[15:10], 4'd0, dbg_plba[31:24]};
    initial dbg_pkey_s = 64'd0;

    // host-domain coordinator state (74.25 MHz)
    wire        dbg_h_rv    = dut.stor.res_valid;
    wire [1:0]  dbg_h_rc    = dut.stor.res_code;
    wire [1:0]  dbg_h_rf    = dut.stor.res_fail;
    wire [2:0]  dbg_h_co    = dut.stor.co_st;
    reg         dbg_h_rv_s;
    reg  [1:0]  dbg_h_rc_s;
    reg  [2:0]  dbg_h_co_s;
    reg  [2:0]  dbg_mstate_r;
    // machine-domain storage result (mount-decision inputs)
    wire        dbg_rv      = dut.stor_res_valid_m;
    wire [1:0]  dbg_rc      = dut.stor_res_code_m;
    reg         dbg_rv_d;
    wire [2:0]  dbg_mstate  = dut.woz_mc.state;
    wire        dbg_pendv    = dut.woz_mc.pend_valid;
    wire [1:0]  dbg_pendcode = dut.woz_mc.pend_code;
    wire        dbg_nv       = dut.woz_mc.res_v_d;
    reg  [20:0] par_cnt;

    always @(posedge clk_74a) begin
        dbg_mstate_r <= dbg_mstate;
        dbg_rv_d     <= dbg_rv;
        if (dbg_mstate != dbg_mstate_r)
            $display("TB: mount_ctl state %0d->%0d rv=%b rc=%b pendv=%b pcode=%b nv=%b t=%t",
                     dbg_mstate_r, dbg_mstate, dbg_rv, dbg_rc,
                     dbg_pendv, dbg_pendcode, dbg_nv, $time);
        if (dbg_rv && !dbg_rv_d)
            $display("TB: RES RISE seen by ctl: rc=%b nbytes=%0d mstate=%0d t=%t",
                     dbg_rc, dut.stor_res_nbytes_m, dbg_mstate, $time);
        if (dbg_h_rv != dbg_h_rv_s || dbg_h_rc != dbg_h_rc_s || dbg_h_co != dbg_h_co_s)
            $display("TB: HOST rv %b->%b rc %b->%b rf=%b co %b->%b t=%t",
                     dbg_h_rv_s, dbg_h_rv, dbg_h_rc_s, dbg_h_rc,
                     dbg_h_rf, dbg_h_co_s, dbg_h_co, $time);
        dbg_h_rv_s <= dbg_h_rv;
        dbg_h_rc_s <= dbg_h_rc;
        dbg_h_co_s <= dbg_h_co;
        if (dbg_tfail != dbg_tfail_s)
            $display("TB: transport_fault %b->%b wr=%b oor=%b faultpend=%b mstate=%0d t=%t",
                     dbg_tfail_s, dbg_tfail, dbg_wrfault, dbg_oorfault,
                     dbg_faultp, dbg_mstate, $time);
        dbg_tfail_s <= dbg_tfail;
        if (dbg_pkey != dbg_pkey_s)
            $display("TB: WZPAR ver=%0d inf=%b tmap=%b trks=%b flx=%b done=%b valid=%b fail=%b blk=%0d lba=%0d t=%t",
                     dbg_pver, dbg_pinfo, dbg_ptmap, dbg_ptrks, dbg_pflux,
                     dbg_pdone, dbg_pwvalid, dbg_pfail, dbg_pblocks, dbg_plba, $time);
        dbg_pkey_s <= dbg_pkey;
        par_cnt <= par_cnt + 1'b1;
    end

    // (probe junk removed 2026-10-22: WAITCHK/T371US/T4983MS/waitchk2 were
    // never in the running binary - stale build; see review brief)

    // DQ phase log: 40 chip cycles from the first fetch-client op start
    // (raw lines + decoded cmd), to pin the DQ phase order vs the
    // io_sdram_pocket capture window (2026-10-22: sbuf = {16'h0, low16}).
    wire bnd_ctrlclk = dut.stor.ctrl_clk;
    reg [1:0] dqlog_rq_d;
    reg [6:0] dqlog_cnt;
    reg [6:0] cedge_cnt;
    reg [6:0] eedge_cnt;
    initial begin
        dqlog_rq_d = 2'b0; dqlog_cnt = 7'd0; cedge_cnt = 7'd0; eedge_cnt = 7'd0;
    end
    always @(posedge dram_clk) begin
        if (cedge_cnt < 7'd8)
            $display("TB: EDGE chip t=%t", $time);
        if (cedge_cnt < 7'd8) cedge_cnt = cedge_cnt + 7'd1;
        dqlog_rq_d <= {dqlog_rq_d[0], dut.stor.fetch0.fc_req};
        if (dqlog_rq_d[0] && !dqlog_rq_d[1] && dqlog_cnt == 7'd0)
            dqlog_cnt = 7'd1;
        if (dqlog_cnt > 7'd0 && dqlog_cnt < 7'd40) begin
            $display("TB: DQLOG c=%0d tick=%0d e4=%b e5=%b wq=%h rdv=%b ccmd=%b a=%0d dq=%h t=%t",
                     dqlog_cnt, m0.tick, dut.stor.isr0.enable_dq_read_4,
                     dut.stor.isr0.enable_dq_read_5, dut.stor.isr0.word_q,
                     dut.stor.isr0.word_rd_valid, m0.c_cmd, m0.c_a, dram_dq, $time);
            dqlog_cnt = dqlog_cnt + 7'd1;
        end
    end
    always @(posedge bnd_ctrlclk) begin
        if (eedge_cnt < 7'd8)
            $display("TB: EDGE ctrl t=%t", $time);
        if (eedge_cnt < 7'd8) eedge_cnt = eedge_cnt + 7'd1;
    end

    // ------------------------------------------------------------------
    // WOZ image (host-side copy; C++ generates pocket_boot.woz.hex)
    // ------------------------------------------------------------------
    reg  [31:0] img32 [0:4194303];   // 16 MiB word image
    reg  [31:0] woz_nbytes;
    integer     load_words;

    initial begin
        $readmemh("pocket_boot.woz.hex", img32);
        woz_nbytes = 32'd0;
        if (!$value$plusargs("WOZSIZE=%d", woz_nbytes))
            $display("TB: ERROR +WOZSIZE=<nbytes> missing");
        $display("TB: WOZ image %0d bytes (%0d words)",
                 woz_nbytes, (woz_nbytes + 32'd3) / 32'd4);
        // Fail fast on a corrupt hex (review 2026-10-22): the first four
        // 32-bit words of disk.woz must be exactly the WOZ2 header.
        if (img32[0] !== 32'h574F5A32 || img32[1] !== 32'hFF0A0D0A ||
            img32[2] !== 32'h6680666C || img32[3] !== 32'h494E464F) begin
            $fatal(1, "TB: WOZ hex words wrong: %h %h %h %h (want 574F5A32 FF0A0D0A 6680666C 494E464F) - pocket_boot.woz.hex corrupt",
                   img32[0], img32[1], img32[2], img32[3]);
        end
        $display("TB: WOZ words OK: %h %h %h %h", img32[0], img32[1], img32[2], img32[3]);
    end

    // ------------------------------------------------------------------
    // Engine-boundary byte checker (review 2026-10-22): every byte the
    // engine accepts (sd_ack && sd_buff_wr) must equal the original
    // image byte for the requested LBA (MSB-first word layout), with
    // addresses 0..511 strictly in order. Fails on the FIRST mismatch.
    // LBA >= 458 = read past end of image (234496 bytes = 458 sectors).
    // ------------------------------------------------------------------
    wire        bnd_clk  = dut.woz.drive_g[0].ctrl.clk;
    wire        bnd_rd   = dut.woz.drive_g[0].ctrl.sd_rd;
    wire        bnd_ack  = dut.woz.drive_g[0].ctrl.sd_ack;
    wire        bnd_wr   = dut.woz.drive_g[0].ctrl.sd_buff_wr;
    wire [8:0]  bnd_addr = dut.woz.drive_g[0].ctrl.sd_buff_addr;
    wire [7:0]  bnd_dout = dut.woz.drive_g[0].ctrl.sd_buff_dout;
    wire [31:0] bnd_lba  = dut.woz.drive_g[0].ctrl.sd_lba;

    // full-path snapshot taps (where is the +shift, 2026-10-22):
    wire [8:0]  bnd_taddr = dut.woz_tr.sector_byte_addr;
    wire [9:0]  bnd_bcnt  = dut.woz_tr.byte_cnt;
    wire [8:0]  bnd_faddr = dut.stor.fetch0.sector_byte_addr;
    wire [7:0]  bnd_fdata = dut.stor.fetch0.sector_byte_data;
    wire [31:0] bnd_fbuf0 = dut.stor.fetch0.sbuf[0];
    wire [31:0] bnd_fbuf1 = dut.stor.fetch0.sbuf[1];
    wire [31:0] bnd_fcdata = dut.stor.fetch0.fc_data;
    wire        bnd_fcval  = dut.stor.fetch0.fc_word_valid;
    wire [23:0] bnd_fcaddr = dut.stor.fetch0.fc_addr;

    // transport-state + engine-request interleaving (first 80 events):
    // does the engine rewrite sd_lba while the transport ACK is low?
    wire [2:0]  tr_st_m  = dut.woz_tr.state;
    reg  [2:0]  tr_st_h;
    reg         tr_rd_h;
    reg  [15:0] tr_lba_h;
    integer     tr_evt_n;
    initial begin tr_st_h = 3'd0; tr_rd_h = 1'b0; tr_lba_h = 16'd0; tr_evt_n = 0; end
    always @(posedge bnd_clk) begin
        if (tr_evt_n < 80 && (tr_st_m !== tr_st_h || bnd_rd !== tr_rd_h || bnd_lba[15:0] !== tr_lba_h)) begin
            $display("TB: TREVT#%0d st=%0d(%s) trlba=%0d erd=%b elba=%0d ready=%b busy=%b slba=%0d t=%t",
                     tr_evt_n, tr_st_m,
                     (tr_st_m == 3'd0) ? "IDLE" : (tr_st_m == 3'd1) ? "REQ" : (tr_st_m == 3'd2) ? "DATA" : (tr_st_m == 3'd3) ? "HOLD" : (tr_st_m == 3'd4) ? "REL" : "??",
                     dut.woz_tr.lba_l, bnd_rd, bnd_lba[15:0],
                     dut.woz_tr.sector_ready, dut.woz_tr.fetch_busy,
                     dut.woz_tr.sector_lba, $time);
            tr_evt_n = tr_evt_n + 1;
        end
        tr_st_h  <= tr_st_m;
        tr_rd_h  <= bnd_rd;
        tr_lba_h <= bnd_lba[15:0];
    end

    // periodic engine-parser state log (every 1 ms machine time, 200..500 ms window)
    reg  [24:0] par_t;
    integer      par_n;
    wire        par_clk = dut.woz.drive_g[0].ctrl.clk;
    initial begin par_t = 25'd0; par_n = 0; end
    always @(posedge par_clk) begin
        par_t <= par_t + 25'd1;
        if (par_t == 25'd14318) begin
            par_t <= 25'd0;
            if (par_n >= 200 && par_n < 500 && par_n < 320) begin
                par_n <= par_n + 1;
                $display("TB: PAR#%0d st=%0d chunk=%0d hdrpos=%0d sizeacc=%0d left=%0d cidx=%0d info=%b tmap=%b trks=%b flux=%b needflux=%b blocks=%0d rd=%b ack=%b done=%b trst=%0d t=%t",
                         par_n,
                         dut.woz.drive_g[0].ctrl.state,
                         dut.woz.drive_g[0].ctrl.chunk_id,
                         dut.woz.drive_g[0].ctrl.chunk_hdr_pos,
                         dut.woz.drive_g[0].ctrl.chunk_size_acc,
                         dut.woz.drive_g[0].ctrl.chunk_left,
                         dut.woz.drive_g[0].ctrl.chunk_index,
                         dut.woz.drive_g[0].ctrl.have_info,
                         dut.woz.drive_g[0].ctrl.have_tmap,
                         dut.woz.drive_g[0].ctrl.have_trks,
                         dut.woz.drive_g[0].ctrl.have_flux,
                         dut.woz.drive_g[0].ctrl.need_flux,
                         dut.woz.drive_g[0].ctrl.scan_blocks,
                         dut.woz.drive_g[0].ctrl.sd_rd,
                         dut.woz.drive_g[0].ctrl.sd_ack,
                         dut.woz.drive_g[0].ctrl.parser_done,
                         dut.woz_tr.state, $time);
            end else if (par_n < 200) begin
                par_n <= par_n + 1;
            end
        end
    end

    // engine request sequence (first 60 {sd_rd, sd_lba} changes):
    // pin down why the engine re-issued lba=0 after lba=1 was accepted.
    reg         bnd_rd_hist;
    reg [31:0]  bnd_lba_hist;
    integer     bnd_req_n;
    initial begin bnd_rd_hist = 1'b0; bnd_lba_hist = 32'd0; bnd_req_n = 0; end
    always @(posedge bnd_clk) begin
        if (bnd_req_n < 60 && (bnd_lba !== bnd_lba_hist || bnd_rd !== bnd_rd_hist)) begin
            $display("TB: REQ#%0d rd=%b lba=%0d t=%t",
                     bnd_req_n, bnd_rd, bnd_lba, $time);
            bnd_req_n = bnd_req_n + 1;
        end
        bnd_rd_hist <= bnd_rd;
        bnd_lba_hist <= bnd_lba;
    end

    // CPU bus activity 10 ms AFTER the last engine read (222..232 ms window):
    // is the 6502 stuck polling one address (wait loop) or running code?
    // Log every address change (capped) + a 1 ms WOZ softswitch status tick.
    wire [15:0] cpu_a   = dut.d1.ADDR;
    wire        cpu_we  = dut.d1.CPU_WE;
    wire [7:0]  cpu_pd  = dut.d1.PD;
    reg  [15:0] cb_a_h;
    reg         cb_we_h;
    integer     cb_n;
    reg  [24:0] cb_ms;
    reg  [24:0] cb_ms_t;
    integer     cb_tick_n;
    initial begin cb_a_h = 16'd0; cb_we_h = 1'b0; cb_n = 0; cb_ms = 25'd0; cb_ms_t = 25'd0; cb_tick_n = 0; end
    always @(posedge dut.d1.CLK_14M) begin
        cb_ms_t <= cb_ms_t + 25'd1;
        if (cb_ms_t == 25'd14318) begin
            cb_ms_t <= 25'd0;
            cb_ms   <= cb_ms + 25'd1;
        end
        if (cb_ms >= 222 && cb_ms < 232) begin
            if (cb_n < 300 && (cpu_a !== cb_a_h || cpu_we !== cb_we_h)) begin
                $display("TB: CB#%0d a=%04h we=%b pd=%02h t=%t",
                         cb_n, cpu_a, cpu_we, cpu_pd, $time);
                cb_n = cb_n + 1;
            end
            if (cb_tick_n < 12 && cb_ms_t == 25'd0) begin
                $display("TB: CBS ms=%0d woz: don=%b sel2=%b q6=%b q7=%b spin=%b active=%b motor=%b A=%04h pd=%02h",
                         cb_ms,
                         dut.woz.drive_on, dut.woz.drive2_select,
                         dut.woz.q6, dut.woz.q7,
                         dut.woz.motor_spinning, dut.woz.drive_g[0].ctrl.active,
                         dut.woz.drive_g[0].ctrl.busy, cpu_a, cpu_pd);
                cb_tick_n = cb_tick_n + 1;
            end
        end
        cb_a_h  <= cpu_a;
        cb_we_h <= cpu_we;
    end

    reg         bnd_snap_done;
    reg         wzb_fatal;
    integer     wzb_miss_cnt;
    integer     wzb_nf_arg;
    initial begin
        bnd_snap_done = 1'b0;
        wzb_fatal    = 1'b1;
        wzb_miss_cnt = 0;
        if ($value$plusargs("WZBOUND_NF=%d", wzb_nf_arg)) wzb_fatal = 1'b0;
    end

    reg  [8:0]  bnd_exp_addr;
    reg  [15:0] bnd_lba_cur;
    reg  [23:0] bnd_wordidx;
    reg  [7:0]  bnd_expected;
    reg         bnd_rd_d;
    integer     bnd_blocks;

    initial begin
        bnd_exp_addr = 9'd0;
        bnd_lba_cur  = 16'd0;
        bnd_wordidx  = 24'd0;
        bnd_expected = 8'd0;
        bnd_rd_d     = 1'b0;
        bnd_blocks   = 0;
    end

    // 2026-10-22 checker fix: byte 0 of a new sector must be checked
    // against the CURRENT sd_lba (the bnd_lba_cur latch is nonblocking -
    // it only takes effect the NEXT cycle, so byte 0 was compared against
    // the previous sector's expected byte -> false mismatch at every
    // sector boundary while the transport stream was correct).
    wire [15:0] bnd_lba_eff = (bnd_exp_addr == 9'd0) ? bnd_lba[15:0] : bnd_lba_cur;

    always @(*) begin
        bnd_wordidx  = {bnd_lba_eff, 7'd0} + {16'd0, bnd_exp_addr[8:2]};
        case (bnd_exp_addr[1:0])
            2'd0:       bnd_expected = img32[bnd_wordidx] >> 24;
            2'd1:       bnd_expected = img32[bnd_wordidx] >> 16;
            2'd2:       bnd_expected = img32[bnd_wordidx] >> 8;
            default:    bnd_expected = img32[bnd_wordidx];
        endcase
    end

    always @(posedge bnd_clk) begin
        bnd_rd_d <= bnd_rd;
        if (bnd_rd && !bnd_rd_d && bnd_lba >= 32'd458)
            $display("TB: WZBOUND OOR READ request lba=%0d (image ends at 457) t=%t",
                     bnd_lba, $time);
        if (bnd_ack && bnd_wr) begin
            if (bnd_exp_addr == 9'd0) begin
                bnd_lba_cur <= bnd_lba[15:0];
            end
            if (bnd_addr !== bnd_exp_addr)
                $fatal(1, "TB: WZBOUND addr out-of-order lba=%0d got=%0d exp=%0d t=%t",
                       bnd_lba_cur, bnd_addr, bnd_exp_addr, $time);
            if (bnd_dout !== bnd_expected) begin
                wzb_miss_cnt = wzb_miss_cnt + 1;
                if (!bnd_snap_done) begin
                    bnd_snap_done = 1'b1;
                    $display("TB: WZBOUND SNAPSHOT engine(lba=%0d addr=%0d got=%02x exp=%02x) | transport(bcnt=%0d taddr=%0d) | fetch(faddr=%0d fdata=%02x fcdata=%h fcval=%b fcaddr=%0d sbuf0=%h sbuf1=%h) t=%t",
                             bnd_lba_eff, bnd_exp_addr, bnd_dout, bnd_expected,
                             bnd_bcnt, bnd_taddr, bnd_faddr, bnd_fdata,
                             bnd_fcdata, bnd_fcval, bnd_fcaddr,
                             bnd_fbuf0, bnd_fbuf1, $time);
                end
                if (wzb_fatal)
                    $fatal(1, "TB: WZBOUND byte mismatch lba=%0d addr=%0d got=%02x exp=%02x (word=%0d) t=%t",
                           bnd_lba_cur, bnd_exp_addr, bnd_dout, bnd_expected, bnd_wordidx, $time);
                else if (wzb_miss_cnt <= 8)
                    $display("TB: WZBOUND mismatch #%0d lba=%0d addr=%0d got=%02x exp=%02x t=%t",
                             wzb_miss_cnt, bnd_lba_cur, bnd_exp_addr, bnd_dout, bnd_expected, $time);
            end
            bnd_exp_addr <= bnd_exp_addr + 9'd1;
            if (bnd_exp_addr == 9'd511) begin
                bnd_blocks = bnd_blocks + 1;
                $display("TB: WZBOUND block %0d complete (lba=%0d) t=%t",
                         bnd_blocks, bnd_lba_cur, $time);
            end
        end
    end

    // ------------------------------------------------------------------
    // Host bridge transaction primitives (74.25 MHz, negedge phase)
    // ------------------------------------------------------------------
    task automatic hb_wr(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk_74a);
            bridge_wr      = 1'b1;
            bridge_addr    = a;
            bridge_wr_data = d;
            @(negedge clk_74a);
            bridge_wr      = 1'b0;
            @(negedge clk_74a);
        end
    endtask

    task automatic hb_rd(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk_74a);
            bridge_rd   = 1'b1;
            bridge_addr = a;
            @(negedge clk_74a);
            bridge_rd   = 1'b0;
            @(posedge clk_74a);
            d = bridge_rd_data;
        end
    endtask

    // Command: write {16'h434D, code} to 0xF8000000, poll for OK status.
    task automatic hb_cmd(input [15:0] code, output [15:0] res);
        reg [31:0] st;
        integer    pc;
        begin
            res = 16'hFFFF;
            hb_wr(32'hF8000000, {16'h434D, code});
            pc = 0;
            while (pc < 4000 && res == 16'hFFFF) begin
                hb_rd(32'hF8000000, st);
                if (st[31:16] == 16'h4F4B)
                    res = st[15:0];
                pc = pc + 1;
            end
        end
    endtask

    // Load word to the storage FIFO with pacing (the store path drains
    // ~1 word / ~22 ctrl cycles; 7 + load_pace 74a cycles keeps the host
    // safely under that).
    reg [7:0] load_pace;
    initial load_pace = 8'd40;
    task automatic hb_word(input [31:0] data, input integer idx);
        integer rep;
        begin
            @(negedge clk_74a);
            bridge_wr      = 1'b1;
            bridge_addr    = (idx * 32'd4) & 32'hFFFFFFFC;
            bridge_wr_data = data;
            @(negedge clk_74a);
            bridge_wr = 1'b0;
            rep = 7 + load_pace;
            while (rep > 0) begin
                @(posedge clk_74a);
                rep = rep - 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Host control (pocket_main.cpp: F9=action_go, F10=seq_mode_req)
    // ------------------------------------------------------------------
    reg  [1:0] seq_mode      /* verilator public */;
    reg [1:0] seq_mode_req  /* verilator public */;
    reg        action_go     /* verilator public */;
    reg        reset_go      /* verilator public */;
    reg        do_quit       /* verilator public */;
    reg  [2:0] host_state    /* verilator public */;
    reg        host_busy     /* verilator public */;
    reg [15:0] load_res82    /* verilator public */;
    reg [15:0] load_res8f    /* verilator public */;

    initial begin
        seq_mode     = 2'd0;
        seq_mode_req = 2'b0;
        action_go    = 1'b0;
        reset_go     = 1'b0;
        do_quit      = 1'b0;
        host_state   = 3'd0;
        host_busy    = 1'b0;
        load_res82   = 16'd0;
        load_res8f   = 16'd0;
        bridge_wr    = 1'b0;
        bridge_rd    = 1'b0;
        bridge_addr  = 32'd0;
        bridge_wr_data = 32'd0;
        por_done     = 1'b0;
        fault_halt   = 1'b0;
        trace_req    = 1'b0;
        fb_w = 12'd0; fb_h = 12'd0; frame_cnt = 16'd0;
    end

    // auto-boot: fire the host cycle at 2 ms (unless the C++ side poked
    // action_go first)
    initial begin
        #2_000_000;
        if (!action_go) action_go = 1'b1;
    end

    // DRAM power-on settle: the M0-proven io_sdram_pocket issues its
    // power-on sequence ~892us after chip-clock start; real SDRAM t_AVI
    // (power-up to first command) is 100us, so 200us gives 2x margin.
    // (Was 4ms - that gate preceded the DUT's actual power-on command
    // and fataled the model; TB-only relaxation, 2026-10-22 review.)
    initial begin
        #200_000;
        por_done = 1'b1;
    end

    // probe: 74a edge count in the first 5 ms (expect ~371250)
    initial begin
        #5_000_000;
        $display("TB: PROBE clk_74a edges in 5ms = %0d (expect ~371250)", e74a);
    end

    // late video warning
    initial begin
        #50_000_000;
        if (frame_cnt == 0)
            $display("TB: WARNING no video frames yet (t=%0t, machine_reset=%b reset_n=%b pll=%b init=%b)",
                     $time, d_machine_reset, d_reset_n, d_pll_lock, d_init_done);
    end

    // ------------------------------------------------------------------
    // Host cycle: seq_mode 0 = "around" (load crosses reset release),
    //              1 = "after" (wait for reset release, then load),
    //              2 = "before" (load during reset, wait for release),
    //              3 = "none" (no load)
    // ------------------------------------------------------------------
    initial begin
        reg [15:0] r82;
        reg [15:0] r8f;
        integer    i;
        wait (action_go);
        forever begin
            seq_mode  = seq_mode_req;
            host_busy = 1'b1;

            if (seq_mode == 2'd0) begin
                // init/reset command, then the load starts while the
                // machine reset is still pending (release mid-load)
                host_state = 3'd1;
                hb_cmd(16'h0010, r82);
                #20_000_000;   // 20 ms: let the load start before release
            end else if (seq_mode == 2'd1) begin
                host_state = 3'd1;
                wait (d_reset_n);
                #2_000_000;
            end
            // seq_mode 2: load immediately (during reset)

            if (seq_mode != 2'd3) begin
                host_state = 3'd2;
                load_words = (woz_nbytes + 32'd3) / 32'd4;
                // WOZ load: id -> 0xF8000020, size -> 0xF8000024, cmd 0x82
                hb_wr(32'hF8000020, 32'd1);
                hb_wr(32'hF8000024, woz_nbytes);
                hb_cmd(16'h0082, r82);
                load_res82 = r82;
                if (r82 != 16'd0)
                    $display("TB: 0082 result %h (nonzero)", r82);
                for (i = 0; i < load_words; i = i + 1)
                    hb_word(img32[i], i);
                // verify: cmd 0x8f
                hb_cmd(16'h008f, r8f);
                load_res8f = r8f;
                $display("TB: WOZ load complete: res82=%h res8f=%h words=%0d t=%0t",
                         r82, r8f, load_words, $time);
            end

            if (seq_mode == 2'd2) begin
                wait (d_reset_n);
            end

            host_state = 3'd3;
            hb_cmd(16'h0011, r82);
            host_state = 3'd4;
            host_busy = 1'b0;
            $display("TB: cycle done (mode=%0d) t=%0t", seq_mode, $time);

            #200_000_000;   // 200 ms between cycles
            action_go = 1'b0;   // cycle consumed; F9 re-arms
            wait (action_go);
        end
    end

endmodule
