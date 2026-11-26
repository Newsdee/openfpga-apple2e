// ============================================================================
// verilog/edge_probe/tb_video_edge.sv
//
// Video edge-probe harness for PLAN_VIDEO_40COL_ENCODER_EDGE_2026-11-25.
// Self-driving SystemVerilog TB (verilator --binary --timing): instantiates
// the SHIPPING stream_video_core_top (video_pipeline_q17, NTSC_EN=1, real
// video ROM, shipping APF adapter) with the proven pocket_boot environment
// (tb_dram_model + host bridge), boots the machine, deposits a 6502 fixture
// program (fixture_gen.py) into main RAM, patches the ROM reset vector, and
// re-resets so the CPU draws a known marker scene through normal soft-switch
// accesses. No video state is forced: HBL/DE/serializer/decoder all run free.
//
// Captures (opt-in via plusargs; without +EDGEPROBE nothing is deposited):
//   - one native-resolution frame (video_rgb/video_de at the shipping top)
//     -> PPM file
//   - one machine scanline sampled every 14.318 MHz clock at the four plan
//     boundaries -> CSV (tick signed vs machine-HBL fall of the captured line)
//   - automatic scoreboard: expected marker DE-sample windows (derived from
//     the fixture layout, not from the capture) vs measured lit windows.
//
// Plusargs:
//   +EDGEPROBE            enable fixture injection + capture
//   +FIX=<path.hex>       fixture program bytes (load address $6000)
//   +PRESET=<n>           colour preset word written to $01F00004 (default 0)
//   +CAPLINE=<n>          machine scanline to capture, 0-based from the first
//                         line after VBL fall (default 83)
//   +SETTLE=<n>           stable frames to wait after fixture reset (def 12)
//   +CSV=<path>           edge CSV output  (default edge_dump.csv)
//   +PPM=<path>           frame PPM output (default frame.ppm)
//   +MEXP=<a,b,c>         expected lit DE-sample windows "lo,hi;lo,hi;..."
//                         (scoreboard); omitted -> no marker checks
//   +EXPECT_DE=<n>        expected contiguous DE samples per line (default
//                         560; checked)
// ============================================================================
`timescale 1ns/1ps

module tb_video_edge;

    // ------------------------------------------------------------------
    // Clocks: 74.25 MHz pair (DUT treats the two domains as async)
    // ------------------------------------------------------------------
    reg clk_74a, clk_74b;
    initial begin
        clk_74a = 1'b0;
        forever #6.734 clk_74a = ~clk_74a;
    end
    initial begin
        clk_74b = 1'b0;
        forever #6.734 clk_74b = ~clk_74b;
    end

    // ------------------------------------------------------------------
    // Tie-offs / host bridge
    // ------------------------------------------------------------------
    reg  [7:0]  tie8  = 8'h00;
    reg  [7:4]  tie4w = 4'b0000;
    reg  [15:0] tie16 = 16'h0000;
    reg         tie1  = 1'b0;

    reg         bridge_wr;
    reg  [31:0] bridge_addr;
    reg  [31:0] bridge_wr_data;
    reg         bridge_rd;
    wire [31:0] bridge_rd_data;

    // ------------------------------------------------------------------
    // SDRAM pins + model (M0 reference geometry, as pocket_boot)
    // ------------------------------------------------------------------
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    reg         por_done;
    reg         fault_halt;
    reg         trace_req;

    tb_dram_model m0 (
        .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n), .cas(dram_cas_n),
        .we(dram_we_n), .por_done(por_done), .ba(dram_ba), .a(dram_a),
        .dq(dram_dq), .dqm(dram_dqm), .fault_halt(fault_halt),
        .trace_req(trace_req)
    );

    // ------------------------------------------------------------------
    // Video outputs (shipping top)
    // ------------------------------------------------------------------
    wire [23:0] video_rgb;
    wire        video_pclk, video_pclk90;
    wire        video_de, video_vs, video_hs, video_skip;

    // ------------------------------------------------------------------
    // DUT: shipping stream_video_core_top
    // ------------------------------------------------------------------
    stream_video_core_top dut (
        .clk_74a(clk_74a),
        .clk_74b(clk_74b),
        .cart_tran_bank2(tie8),   .cart_tran_bank2_dir(),
        .cart_tran_bank3(tie8),   .cart_tran_bank3_dir(),
        .cart_tran_bank1(tie8),   .cart_tran_bank1_dir(),
        .cart_tran_bank0(tie4w),  .cart_tran_bank0_dir(),
        .cart_tran_pin30(tie1),   .cart_tran_pin30_dir(),
        .cart_tran_pin31(tie1),   .cart_tran_pin31_dir(),
        .cart_pin30_pwroff_reset(),
        .port_ir_rx(tie1),        .port_ir_tx(),
        .port_ir_rx_disable(),
        .port_tran_si(tie1),      .port_tran_si_dir(),
        .port_tran_so(),          .port_tran_so_dir(),
        .port_tran_sck(tie1),     .port_tran_sck_dir(),
        .port_tran_sd(tie1),      .port_tran_sd_dir(),
        .cram0_a(), .cram0_dq(tie16), .cram0_wait(1'b0),
        .cram0_clk(), .cram0_adv_n(), .cram0_cre(),
        .cram0_ce0_n(), .cram0_oe_n(),
        .cram0_we_n(), .cram0_ub_n(), .cram0_lb_n(),
        .cram1_a(), .cram1_dq(tie16), .cram1_wait(1'b0),
        .cram1_clk(), .cram1_adv_n(), .cram1_cre(),
        .cram1_ce0_n(), .cram1_oe_n(),
        .cram1_we_n(), .cram1_ub_n(), .cram1_lb_n(),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq),
        .dram_dqm(dram_dqm), .dram_clk(dram_clk), .dram_cke(dram_cke),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .sram_a(), .sram_dq(tie16), .sram_oe_n(), .sram_we_n(),
        .sram_ub_n(), .sram_lb_n(),
        .vblank(tie1), .dbg_tx(), .dbg_rx(tie1),
        .user1(), .user2(tie1),
        .aux_sda(tie1), .aux_scl(), .vpll_feed(),
        .video_rgb(video_rgb),
        .video_rgb_clock(video_pclk),
        .video_rgb_clock_90(video_pclk90),
        .video_de(video_de),
        .video_skip(video_skip),
        .video_vs(video_vs),
        .video_hs(video_hs),
        .audio_mclk(), .audio_adc(tie1), .audio_dac(), .audio_lrck(),
        .bridge_endian_little(),
        .bridge_addr(bridge_addr),
        .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data),
        .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),
        .cont1_key(32'd0), .cont2_key(32'd0), .cont3_key(32'd0), .cont4_key(32'd0),
        .cont1_joy(32'd0), .cont2_joy(32'd0), .cont3_joy(32'd0), .cont4_joy(32'd0),
        .cont1_trig(16'd0), .cont2_trig(16'd0), .cont3_trig(16'd0), .cont4_trig(16'd0)
    );

    // ------------------------------------------------------------------
    // Host bridge tasks (copied from pocket_boot, proven sequence)
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

    // ------------------------------------------------------------------
    // Hierarchical taps (plan section 2 boundaries). TB-only observes.
    // ------------------------------------------------------------------
    wire        clk14    = dut.clk_core_14318;
    wire        d_reset_n = dut.reset_n;
    wire        d_pll     = dut.pll_core_locked;
    wire        d_mres    = dut.machine_reset;
    // Boundary 1: machine fetch/serializer
    wire        t_m_video = dut.m_video;
    wire        t_m_hbl   = dut.m_hbl;
    wire        t_m_vbl   = dut.m_vbl;
    wire [7:0]  t_shift   = dut.d1.video_display.video_shiftreg;
    wire [11:0] t_roma    = dut.d1.video_display.video_rom_addr;
    wire [7:0]  t_romd    = dut.d1.video_display.video_rom_out;
    wire        t_wndw_n  = dut.d1.WNDW_N;
    wire        t_ldps_n  = dut.d1.LDPS_N;
    wire [7:0]  t_dl      = dut.d1.VIDEO_DL;   // byte the serializer loads
    // Boundary 2/3: encoder admission + decoder output (inside u_comp)
    wire        t_vsamp   = dut.ntsc_pipe.u_comp.video_sample;
    wire        t_hb      = dut.ntsc_pipe.u_comp.hb;
    wire        t_hs      = dut.ntsc_pipe.u_comp.hs;
    wire        t_burst   = dut.ntsc_pipe.u_comp.in_burst;
    wire        t_fporch  = dut.ntsc_pipe.u_comp.in_fporch;
    wire        t_cline   = dut.ntsc_pipe.u_comp.color_line;
    wire signed [7:0] t_comp = dut.ntsc_pipe.u_comp.comp;
    wire [7:0]  t_r_comp  = dut.ntsc_pipe.r_comp;
    wire [7:0]  t_g_comp  = dut.ntsc_pipe.g_comp;
    wire [7:0]  t_b_comp  = dut.ntsc_pipe.b_comp;
    wire        t_hb_out  = dut.ntsc_pipe.u_comp.hb_out;
    wire        t_hb_i    = dut.ntsc_pipe.u_comp.u_dec.hb_i;
    // mode state (logged, not inferred)
    wire        t_text    = dut.m_text_mode;
    wire        t_hgr     = dut.m_hgr_mode;
    wire        t_hgr80   = dut.m_hgr80_mode;
    wire        t_col80   = dut.m_col80;
    wire        t_gr2     = dut.m_gr2;

    // ------------------------------------------------------------------
    // Frame capture at the shipping output (pocket_boot fb pattern)
    // ------------------------------------------------------------------
    localparam FBW = 720;
    localparam FBH = 256;
    reg  [23:0] fb [0:FBW*FBH-1];
    reg  [11:0] fb_w, fb_h;
    reg         frame_new;
    reg  [15:0] frame_cnt;
    reg  [10:0] fc_x, fc_y;
    reg         de_r;
    integer     fc_xmax, fc_ymax;
    always @(posedge video_pclk) begin
        frame_new <= 1'b0;
        if (video_de && fc_y < FBH) begin
            fb[fc_y*FBW + fc_x] <= video_rgb;
            fc_x <= fc_x + 1'b1;
        end
        if (de_r && !video_de) begin
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
    // Line counter: machine domain, 0-based from the first line after
    // VBL fall (the same landmark the APF adapter uses for vs_pulse).
    // ------------------------------------------------------------------
    reg        hbl_r, vbl_r;
    reg [15:0] line_cnt;
    always @(posedge clk14) begin
        hbl_r <= t_m_hbl;
        vbl_r <= t_m_vbl;
        if (vbl_r && !t_m_vbl)          // VBL fall: next line is line 0
            line_cnt <= 16'd0;
        else if (hbl_r && !t_m_hbl)     // machine HBL fall: line boundary
            line_cnt <= line_cnt + 1'b1;
    end

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    integer capline  = 83;
    integer settle_n = 12;
    integer preset   = 0;
    string  fix_path = "";
    string  csv_path = "edge_dump.csv";
    string  ppm_path = "frame.ppm";
    string  mexp     = "";
    integer expect_de = 560;

    reg [7:0] prog [0:8191];
    integer   prog_n;
    reg       edge_probe;

    integer fd, i;
    reg [15:0] r;
    initial n7f = 0;

    initial begin
        bridge_wr = 0; bridge_rd = 0; bridge_addr = 0; bridge_wr_data = 0;
        por_done = 0; fault_halt = 0; trace_req = 0;
        fb_w = 0; fb_h = 0; frame_cnt = 0; fc_x = 0; fc_y = 0; de_r = 0;
        fc_xmax = 0; fc_ymax = 0;
        line_cnt = 0; hbl_r = 0; vbl_r = 0;
        prog_n = 0;
        edge_probe = $test$plusargs("EDGEPROBE");
        void'($value$plusargs("FIX=%s",      fix_path));
        void'($value$plusargs("PRESET=%d",   preset));
        void'($value$plusargs("CAPLINE=%d",  capline));
        void'($value$plusargs("SETTLE=%d",   settle_n));
        void'($value$plusargs("CSV=%s",      csv_path));
        void'($value$plusargs("PPM=%s",      ppm_path));
        void'($value$plusargs("MEXP=%s",     mexp));
        void'($value$plusargs("EXPECT_DE=%d", expect_de));

        #200_000;                       // DRAM power-on settle (pocket_boot)
        por_done = 1'b1;

        // ---- host boot: Reset(0x0010) then Start(0x0011) releases reset_n ----
        hb_cmd(16'h0010, r);
        $display("EDGE: reset cmd res=%h t_ms=%0.3f", r, $time/1e6);
        hb_cmd(16'h0011, r);
        $display("EDGE: start cmd res=%h t_ms=%0.3f", r, $time/1e6);
        while (!(d_reset_n && d_pll)) @(negedge clk_74a);
        #5_000_000;                     // settle after reset release

        if (edge_probe) begin
            // ---- fixture injection (TB-only deposits; CPU runs the rest) ----
            if (fix_path == "") begin
                $display("EDGE: FAIL - +EDGEPROBE without +FIX=");
                $fatal(1);
            end
            $readmemh(fix_path, prog);
            // --binary zero-inits arrays (no X in this build), so count the
            // bytes from the file's lines instead.
            begin
                integer fh, lc;
                reg [1023:0] linebuf;
                fh = $fopen(fix_path, "r");
                if (fh == 0) begin
                    $display("EDGE: FAIL - cannot open %s", fix_path);
                    $fatal(1);
                end
                lc = 0;
                while (!$feof(fh)) begin
                    if ($fgets(linebuf, fh) > 1) lc = lc + 1;
                end
                $fclose(fh);
                prog_n = lc;
            end
            $display("EDGE: fixture %s: %0d bytes -> $6000", fix_path, prog_n);
            for (i = 0; i < prog_n; i = i + 1)
                dut.u_ram_bank.ram_main[16'h6000 + i[15:0]] = prog[i];
            // patch ROM reset vector $FFFC/D -> $6000 (rom a = A[13:0])
            dut.d1.roms.d[14'h3FFC] = 8'h00;
            dut.d1.roms.d[14'h3FFD] = 8'h60;
            // colour preset (bridge $01F00004)
            hb_wr(32'h01F00004, preset[31:0]);
            $display("EDGE: preset word %0d written", preset);
            // re-reset through the normal host path
            hb_cmd(16'h0010, r);
            #2_000_000;
            hb_cmd(16'h0011, r);
            $display("EDGE: fixture reset done res=%h t_ms=%0.3f", r, $time/1e6);
        end

        // ---- settle: wait for stable frames ----
        repeat (settle_n) @(posedge frame_new);
        $display("EDGE: settled at frame %0d t_ms=%0.3f", frame_cnt, $time/1e6);
        $display("EDGE: mode state TEXT=%b HGR=%b HGR80=%b COL80=%b GR2=%b",
                 t_text, t_hgr, t_hgr80, t_col80, t_gr2);
        if (t_m_vbl === 1'bx || t_m_hbl === 1'bx) begin
            $display("EDGE: FAIL - machine blanking is X (design not running)");
            $fatal(1);
        end

        // ---- arm line capture; wait for the target line in the NEXT frame ----
        scan_on = 1'b1;
        if ($test$plusargs("DLSCAN")) dlscan_on = 1'b1;
        @(posedge frame_new);                  // frame boundary (vs pulse)
        // wait for VBL fall to re-sync line_cnt, then the target line
        while (!(vbl_r && !t_m_vbl)) @(posedge clk14);
        while (line_cnt != capline[15:0]) @(posedge clk14);
        capture_line();

        // ---- PPM dump of the frame just captured ----
        dump_ppm();

        // ---- scoreboard ----
        score();
        $display("EDGE: done t_ms=%0.3f", $time/1e6);
        $finish;
    end

    // ------------------------------------------------------------------
    // One-line capture at 14.318 MHz, four boundaries per tick.
    // tick=0 is the first sample of the target line (just after machine
    // HBL fall); the capture starts there and spans a full line + margin,
    // so both blanking ends (>=32 clocks) are included.
    // ------------------------------------------------------------------
    localparam CAPN = 1000;
    task automatic capture_line();
        integer k;
        begin
            fd = $fopen(csv_path, "w");
            if (fd == 0) begin
                $display("EDGE: FAIL - cannot open %s", csv_path);
                $fatal(1);
            end
            $fwrite(fd, "tick,m_hbl,m_video,shift8,rom_addr,rom_data,wndw_n,ldps_n,");
            $fwrite(fd, "vsamp,enc_hb,enc_hs,in_burst,in_fporch,color_line,comp,");
            $fwrite(fd, "r_comp,g_comp,b_comp,dec_hb_out,dec_hb_i,");
            $fwrite(fd, "out_rgb,out_de,out_hs,out_vs\n");
            $display("EDGE: capturing line %0d, %0d ticks", capline, CAPN);
            for (k = 0; k < CAPN; k = k + 1) begin
                @(posedge clk14);
                #1;   // sample after outputs settle; edge convention: value
                      // at tick k is the state ~1ns after the k-th rising
                      // 14.318 MHz edge of the captured line
                $fwrite(fd, "%0d,%b,%b,%02x,%03x,%02x,%b,%b,",
                        k, t_m_hbl, t_m_video, t_shift, t_roma, t_romd,
                        t_wndw_n, t_ldps_n);
                $fwrite(fd, "%b,%b,%b,%b,%b,%b,%0d,",
                        t_vsamp, t_hb, t_hs, t_burst, t_fporch, t_cline,
                        t_comp);
                $fwrite(fd, "%0d,%0d,%0d,%b,%b,",
                        t_r_comp, t_g_comp, t_b_comp, t_hb_out, t_hb_i);
                $fwrite(fd, "%06x,%b,%b,%b\n",
                        video_rgb, video_de, video_hs, video_vs);
                cap_m_hbl[k]  = t_m_hbl;
                cap_mvid[k]   = t_m_video;
                cap_dl[k]     = t_dl;
                cap_ldps[k]   = t_ldps_n;
                cap_vsamp[k]  = t_vsamp;
                cap_comp[k]   = t_comp;
                cap_r[k]      = t_r_comp;
                cap_g[k]      = t_g_comp;
                cap_b[k]      = t_b_comp;
                cap_de[k]     = video_de;
                cap_rgb[k]    = video_rgb;
                cap_hbout[k]  = t_hb_out;
            end
            $fclose(fd);
            $display("EDGE: CSV written: %s", csv_path);
        end
    endtask

    // capture buffers
    reg        cap_m_hbl [0:CAPN-1];
    reg        cap_mvid [0:CAPN-1];
    reg [7:0]  cap_dl [0:CAPN-1];
    reg        cap_ldps [0:CAPN-1];
    reg        cap_vsamp [0:CAPN-1];
    reg signed [7:0] cap_comp [0:CAPN-1];
    reg [7:0]  cap_r [0:CAPN-1];
    reg [7:0]  cap_g [0:CAPN-1];
    reg [7:0]  cap_b [0:CAPN-1];
    reg        cap_de [0:CAPN-1];
    reg [23:0] cap_rgb [0:CAPN-1];
    reg        cap_hbout [0:CAPN-1];

    // ------------------------------------------------------------------
    // PPM dump of the captured native frame
    // ------------------------------------------------------------------
    task automatic dump_ppm();
        integer x, y, f2;
        begin
            f2 = $fopen(ppm_path, "wb");
            if (f2 == 0) begin
                $display("EDGE: FAIL - cannot open %s", ppm_path);
                $fatal(1);
            end
            $fwrite(f2, "P6\n%0d %0d\n255\n", fb_w, fb_h);
            for (y = 0; y < fb_h; y = y + 1)
                for (x = 0; x < fb_w; x = x + 1)
                    $fwrite(f2, "%c%c%c", fb[y*FBW+x][23:16],
                            fb[y*FBW+x][15:8], fb[y*FBW+x][7:0]);
            $fclose(f2);
            $display("EDGE: PPM written: %s (%0dx%0d)", ppm_path, fb_w, fb_h);
        end
    endtask

    // ------------------------------------------------------------------
    // Scoreboard: DE run geometry + expected marker windows (+MEXP="lo,hi;...")
    // ------------------------------------------------------------------
    task automatic score();
        integer k, nfail, de_start, de_end, de_run;
        integer nwin, wlo, whi, lit, p, q, code, cstart;
        byte ch;
        begin
            nfail = 0;
            // ---- DE geometry from the captured line (boundary 4): first
            // contiguous run only (the 1000-tick window spills into the
            // next line's DE start) ----
            de_start = -1; de_end = -1; de_run = 0;
            for (k = 0; k < CAPN; k = k + 1) begin
                if (cap_de[k] && de_start < 0) de_start = k;
                if (de_start >= 0 && cap_de[k]) begin
                    de_run = de_run + 1;
                    de_end = k;
                end else if (de_start >= 0)
                    break;   // first run complete
            end
            $display("SCORE: DE run on line %0d: start_tick=%0d end_tick=%0d samples=%0d (expect %0d)",
                     capline, de_start, de_end, de_run, expect_de);
            if (de_run != expect_de) begin
                $display("SCORE: FAIL - DE run %0d != %0d", de_run, expect_de);
                nfail = nfail + 1;
            end
            if (de_start < 0) begin
                $display("SCORE: FAIL - no DE on captured line");
                nfail = nfail + 1;
            end

            // ---- marker windows: DE sample index s = tick - de_start ----
            // lit criterion: luma (g_comp) above the midpoint of measured
            // black/white plateaus; raw values retained in the CSV.
            if (mexp != "" && de_start >= 0) begin
                // measure black/white plateaus from this line's DE samples
                blk = 255; wht = 0;
                for (k = de_start; k <= de_end; k = k + 1) begin
                    if (cap_g[k] < blk) blk = cap_g[k];
                    if (cap_g[k] > wht) wht = cap_g[k];
                end
                mid = (blk + wht) / 2;
                $display("SCORE: plateaus g_comp black=%0d white=%0d mid=%0d",
                         blk, wht, mid);
                if (wht - blk < 32) begin
                    $display("SCORE: FAIL - no contrast on captured line (black=%0d white=%0d): wrong line or blank scene", blk, wht);
                    nfail = nfail + 1;
                end
                // parse MEXP="lo,hi;lo,hi;..." (manual scan: Verilator 5.050
                // has no substr/atoi chaining on string here)
                nwin = 0;
                cstart = 0;
                forever begin
                    p = cstart;
                    wlo = 0; whi = 0;
                    while (p < mexp.len() && mexp[p] >= "0" && mexp[p] <= "9") begin
                        wlo = wlo * 10 + (mexp[p] - "0");
                        p = p + 1;
                    end
                    if (p == cstart) break;              // empty tail
                    if (p < mexp.len() && mexp[p] == ",") p = p + 1;
                    while (p < mexp.len() && mexp[p] >= "0" && mexp[p] <= "9") begin
                        whi = whi * 10 + (mexp[p] - "0");
                        p = p + 1;
                    end
                    if (p < mexp.len() && mexp[p] == ";") p = p + 1;
                    cstart = p;
                    // measure lit window [wlo..whi] and its flanks
                    lit = 0;
                    for (k = wlo; k <= whi; k = k + 1)
                        if (cap_g[de_start + k] > mid) lit = lit + 1;
                    $display("SCORE: window[%0d] DE %0d..%0d lit=%0d/%0d",
                             nwin, wlo, whi, lit, whi - wlo + 1);
                    // transition detail: first/last lit sample inside the
                    // window, and the 3 samples on each flank
                    begin
                        integer f, l;
                        integer fl1, fl2, fl3, fr1, fr2, fr3;
                        f = -1; l = -1;
                        fl1 = -1; fl2 = -1; fl3 = -1;
                        fr1 = -1; fr2 = -1; fr3 = -1;
                        if (wlo >= 3) fl3 = cap_g[de_start+wlo-3];
                        if (wlo >= 2) fl2 = cap_g[de_start+wlo-2];
                        if (wlo >= 1) fl1 = cap_g[de_start+wlo-1];
                        if (whi+1 < de_run) fr1 = cap_g[de_start+whi+1];
                        if (whi+2 < de_run) fr2 = cap_g[de_start+whi+2];
                        if (whi+3 < de_run) fr3 = cap_g[de_start+whi+3];
                        for (k = wlo; k <= whi; k = k + 1) begin
                            if (cap_g[de_start + k] > mid && f < 0) f = k;
                            if (cap_g[de_start + k] > mid) l = k;
                        end
                        $display("SCORE:   first_lit=%0d last_lit=%0d flanks g[L3..L1]=%0d,%0d,%0d g[R1..R3]=%0d,%0d,%0d",
                                 f, l, fl3, fl2, fl1, fr1, fr2, fr3);
                    end
                    if (lit == 0) begin
                        $display("SCORE: FAIL - window %0d (%0d..%0d) has NO lit samples (expected marker)",
                                 nwin, wlo, whi);
                        nfail = nfail + 1;
                    end
                    nwin = nwin + 1;
                end
                $display("SCORE: %0d marker windows checked", nwin);
            end

            // ---- left-edge boundary timeline: for the ticks around DE
            // start, show all four boundaries side by side (plan section 2:
            // where does the column-0 pixel first go missing?) ----
            if (de_start >= 0) begin
                integer t0, t1, kk;
                t0 = de_start - 10;
                t1 = de_start + 30;
                if (t0 < 0) t0 = 0;
                if (t1 > CAPN-1) t1 = CAPN-1;
                $display("SCORE: left-edge timeline (tick: m_video vsamp comp g_comp de rgb)");
                for (kk = t0; kk <= t1; kk = kk + 1)
                    $display("EDGE_T %0d hbl=%b mv=%b vs=%b comp=%0d g=%0d de=%b rgb=%06x hbout=%b",
                             kk, cap_m_hbl[kk], cap_mvid[kk], cap_vsamp[kk],
                             cap_comp[kk], cap_g[kk], cap_de[kk], cap_rgb[kk],
                             cap_hbout[kk]);
                // serialized-byte dump: the DL value at each LDPS_N fall
                // (the bytes the machine actually fetched for this line)
                $display("SCORE: DL bytes loaded on captured line (LDPS falls)");
                begin
                    integer bi;
                    bi = 0;
                    for (kk = 1; kk < CAPN; kk = kk + 1) begin
                        if (cap_ldps[kk-1] && !cap_ldps[kk]) begin
                            $display("DLB %0d tick=%0d dl=%02x", bi, kk, cap_dl[kk]);
                            bi = bi + 1;
                        end
                    end
                end
                // full-line g_comp transition map: every tick where g
                // changes by more than 8 from the previous tick
                $display("SCORE: g_comp transition map (whole captured line)");
                begin
                    integer pv, prev;
                    prev = cap_g[0];
                    for (kk = 1; kk < CAPN; kk = kk + 1) begin
                        pv = cap_g[kk];
                        if (pv > prev ? (pv - prev) > 8 : (prev - pv) > 8)
                            $display("GTRANS tick=%0d de_s=%0d g %0d -> %0d mv=%b comp=%0d",
                                     kk, kk - de_start, prev, pv, cap_mvid[kk], cap_comp[kk]);
                        prev = pv;
                    end
                end
            end

            if (nfail == 0)
                $display("TB VIDEO EDGE: ALL PASS (line=%0d nfail=0)", capline);
            else begin
                $display("TB VIDEO EDGE: FAIL (line=%0d nfail=%0d)", capline, nfail);
                $fatal(1);
            end
        end
    endtask

    integer blk, wht, mid;   // plateau measurement (score)

    // ------------------------------------------------------------------
    // Marker scanner (opt-in): log line_cnt whenever the serializer loads
    // the fixture marker byte $7F (HGR) - maps lines to memory content.
    // ------------------------------------------------------------------
    reg scan_on;
    initial scan_on = 1'b0;
    reg        dl7f_r;
    integer    n7f;
    always @(posedge clk14) begin
        dl7f_r <= scan_on && (t_dl == 8'h7F) && !t_ldps_n;
        if (dl7f_r && n7f < 40) begin
            n7f = n7f + 1;
            $display("SCAN7F: DL=$7F load at line_cnt=%0d t_ms=%0.3f",
                     line_cnt, $time/1e6);
        end
    end

    // ------------------------------------------------------------------
    // DL scan (opt-in +DLSCAN): for two frames, log every distinct DL byte
    // loaded per line_cnt - empirically maps line_cnt to memory content.
    // ------------------------------------------------------------------
    reg dlscan_on;
    initial dlscan_on = 1'b0;
    reg [7:0]  dls_line [0:255];
    reg [255:0] dls_mask [0:255];   // which distinct bytes seen (by value)
    integer si;
    reg [15:0] dls_frames;
    initial dls_frames = 0;
    always @(posedge clk14) begin
        if (dlscan_on && !t_ldps_n) begin
            if (!(|dls_mask[line_cnt[7:0]])) dls_line[line_cnt[7:0]] = 8'h00;
            if (!dls_mask[line_cnt[7:0]][t_dl]) begin
                dls_mask[line_cnt[7:0]][t_dl] <= 1'b1;
            end
        end
        if (dlscan_on && frame_new) begin
            dls_frames = dls_frames + 1;
            if (dls_frames == 2) begin
                for (si = 0; si < 256; si = si + 1)
                    if (|dls_mask[si])
                        $display("DLSCAN line=%0d bytes=%h", si, dls_mask[si]);
                dlscan_on = 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Watchdog
    // ------------------------------------------------------------------
    initial begin
        #400_000_000;   // 400 ms sim
        $display("EDGE: FAIL - watchdog timeout (frame_cnt=%0d line_cnt=%0d)",
                 frame_cnt, line_cnt);
        $fatal(1);
    end

endmodule
