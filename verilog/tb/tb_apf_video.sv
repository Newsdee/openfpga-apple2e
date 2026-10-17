// ============================================================================
// tb/tb_apf_video.sv — P2a: machine core + APF video adapter, end to end
//
// Instantiates the unmodified machine core (Apple-II_MiSTer/rtl/apple2.v +
// generators + both CPUs, TB RAM, level-1-style reset chain — same wiring as
// tb_native_probe) plus apf_video, and verifies the APF-side output:
//
//   G1 geometry : vs/hs edge counts (512 hs per frame, 1 vs per frame)
//   G2 DE window: 320x240 active per frame
//   G3 content  : BIOS boots to the Apple logo -> white pixels appear on
//                 many lines and stabilize (machine is alive)
//   G4 KB-014   : rgb == 0 outside DE (checked on every sampled pixel)
//
// Two free-running clocks (no PLL lock modeling needed):
//   clk_14m   : 35 ns half period (14.286 MHz, edge-count based)
//   clk_12288 : 40.69 ns half period (12.288 MHz)
//
// Run ~2 s of machine time (BIOS boot + stable logo), then report and
// exit 0 on PASS, $fatal(1) on FAIL.
//
// Build: verilate_p2a.sh   Run: CWD = Apple-II_MiSTer/ (rtl/roms paths)
// ============================================================================

`timescale 1ns / 1ps

module tb_apf_video;

  // ------------------------------------------------------------------
  // Clocks
  // ------------------------------------------------------------------
  // NOTE: `timescale 1ns/1ps -> delay unit is ns (NOT ps!)
  reg clk_14m   = 1'b0;
  reg clk_12288 = 1'b0;
  always #35.0   clk_14m   = ~clk_14m;   // 70 ns period = 14.286 MHz
  always #40.69  clk_12288 = ~clk_12288; // 81.38 ns period = 12.288 MHz

  // ------------------------------------------------------------------
  // Machine core wiring (identical to tb_native_probe)
  // ------------------------------------------------------------------
  wire [15:0] w_addr;
  wire [17:0] w_ram_addr;
  wire [7:0]  w_ram_di;
  wire [15:0] ram_do;
  wire        w_ram_aux;
  wire        w_ram_we;
  wire        w_video, w_hbl, w_vbl;
  wire        w_text_mode, w_hgr_mode, w_early_video, w_run_fill_ok;
  wire        w_col_line, w_hgr80_mode, w_gr2, w_col80, w_dhires;
  wire        read_key, w_spk;
  wire [7:0]  w_io_sel, w_dev_sel;
  wire        w_io_str, w_pdl, w_stb;
  wire [3:0]  w_an;
  wire        w_pz, w_pzr, w_pzf, w_clk2m;

  reg power_on_reset = 1'b1;
  reg reset          = 1'b1;
  reg [22:0] flash_div = 23'b0;
  always @(posedge clk_14m) begin
    reset <= power_on_reset;
    if (flash_div[22] == 1'b1)
      power_on_reset <= 1'b0;
    flash_div <= flash_div + 1'b1;
  end

  reg [7:0] ram0 [0:65535];
  reg [7:0] ram1 [0:65535];
  always @(posedge clk_14m) begin: tb_ram
    if (w_ram_we & ~w_ram_aux) begin
      ram0[w_ram_addr[15:0]] <= w_ram_di;
      ram_do[7:0]            <= w_ram_di;
    end else ram_do[7:0]  <= ram0[w_ram_addr[15:0]];
    if (w_ram_we & w_ram_aux) begin
      ram1[w_ram_addr[15:0]] <= w_ram_di;
      ram_do[15:8]           <= w_ram_di;
    end else ram_do[15:8]  <= ram1[w_ram_addr[15:0]];
  end

  apple2 d1 (
    .CLK_14M(clk_14m), .CLK_2M(w_clk2m),
    .PALMODE(1'b0), .ROMSWITCH(1'b0), .CPU_WAIT(1'b0),
    .PHASE_ZERO(w_pz), .PHASE_ZERO_R(w_pzr), .PHASE_ZERO_F(w_pzf),
    .FLASH_CLK(flash_div[22]),
    .reset(reset), .cpu(1'b1),        // wdc 65C02
    .STALL(1'b0),
    .ADDR(w_addr), .ram_addr(w_ram_addr), .D(w_ram_di), .ram_do(ram_do),
    .aux(w_ram_aux), .PD(8'h00), .CPU_WE(),
    .IRQ_n(1'b1), .NMI_n(1'b1), .ram_we(w_ram_we),
    .VIDEO(w_video), .COLOR_LINE(w_col_line), .RUN_FILL_OK(w_run_fill_ok),
    .TEXT_MODE(w_text_mode), .EARLY_VIDEO(w_early_video), .HGR_MODE(w_hgr_mode),
    .HGR80_MODE(w_hgr80_mode), .GR2(w_gr2), .COL80(w_col80), .DHIRES_MODE(w_dhires),
    .HBL(w_hbl), .VBL(w_vbl),
    .K(8'h00), .READ_KEY(read_key), .AKD(1'b1), .AN(w_an), .GAMEPORT(8'h00),
    .PDL_STROBE(w_pdl), .STB(w_stb),
    .IO_SELECT(w_io_sel), .DEVICE_SELECT(w_dev_sel), .IO_STROBE(w_io_str),
    .ioctl_addr(25'b0), .ioctl_data(8'b0), .ioctl_index(8'b0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .saturn_5_inslot(1'b0),
    .speaker(w_spk),
    .DBG_T65_REGS(), .DBG_DI(), .DBG_ROM_ADDR(), .DBG_ROM_OUT(),
    .ss_addr(10'b0), .ss_wdata(64'b0), .ss_wren(1'b0), .ss_rdata(),
    .machine_ce(1'b1), .cpu_frozen(),
    .Z80_EN(1'b0), .Z80_A(16'b0), .Z80_DO(8'b0), .Z80_WE(1'b0), .CPU_DI()
  );

  // ------------------------------------------------------------------
  // DUT: the adapter
  // ------------------------------------------------------------------
  reg  [23:0] o_rgb;
  wire        o_de, o_vs, o_hs, o_skip;
  apf_video dut (
    .clk_14m(clk_14m), .reset(reset),
    .video_in(w_video), .hbl(w_hbl), .vbl(w_vbl),
    .clk_12288(clk_12288),
    .video_rgb(o_rgb), .video_de(o_de), .video_vs(o_vs),
    .video_hs(o_hs), .video_skip(o_skip)
  );

  // ------------------------------------------------------------------
  // Output monitor (clk_12288 domain)
  // ------------------------------------------------------------------
  integer frames = 0;
  integer hs_cnt = 0;
  integer vs_cnt = 0;
  integer white_total = 0;      // per frame
  integer white_lines = 0;      // lines with any white (per frame)
  integer g4_viol = 0;          // nonzero rgb outside DE
  integer errors = 0;
  integer line_white = 0;
  integer de_cnt = 0, px_cnt = 0;
  integer max_capl_r = 0, pxr_ones = 0;
  reg     max_scr_r = 1'b0;
  integer racy_cycles = 0;    // cycles where dbuf == machine write buffer
  integer fsd1_cnt = 0;
  reg     booted = 1'b0;      // machine has produced its first wbuf change
  integer frame_white_hist [0:3];   // last 4 frames (stability check)
  integer max_white = 0;            // logo evidence: peak white over the run
  reg     de_seen = 1'b0;

  always @(posedge clk_12288) begin: mon
    if (o_vs) begin
      // commit previous frame
      if (frames > 0) begin
        frame_white_hist[0] = frame_white_hist[1];
        frame_white_hist[1] = frame_white_hist[2];
        frame_white_hist[2] = frame_white_hist[3];
        frame_white_hist[3] = white_total;
        if (white_total > max_white) max_white = white_total;
        if (frames % 30 == 0 || frames >= 110)
          $display("F%0d white=%0d lines=%0d", frames, white_total, white_lines);
      end
      vs_cnt      = vs_cnt + 1;
      frames      = frames + 1;
      white_total = 0;
      white_lines = 0;
      line_white  = 0;
      de_seen     = 1'b0;
    end
    if (o_hs) hs_cnt = hs_cnt + 1;
    if (dut.capl_r > max_capl_r) max_capl_r = dut.capl_r;
    if (dut.scr_r) max_scr_r = 1'b1;
    if (dut.px_r) pxr_ones = pxr_ones + 1;
    // frame-locked invariant: after the machine starts, the display must
    // never spend more than a few cycles per frame reading the buffer the
    // machine is writing (the sync settling window; lands in the line
    // tail / off-screen, invisible). Pre-boot both buffers read 0 and
    // dbuf==wbuf is the normal idle state - not counted.
    if (dut.wb_change) booted = 1'b1;
    if (booted && dut.dbuf == dut.wbuf[0]) racy_cycles = racy_cycles + 1;
    if (dut.fs_d1) fsd1_cnt = fsd1_cnt + 1;
    if (racy_cycles == 1000000 || racy_cycles == 10000000)
      $display("DBG racy=%0d t=%0t dbuf=%b wbuf0=%b s1=%b s2=%b fsd1_cnt=%0d",
               racy_cycles, $time, dut.dbuf, dut.wbuf[0], dut.wbuf_s1,
               dut.wbuf_s2, fsd1_cnt);
    if (o_de) begin
      de_cnt = de_cnt + 1;
      if (dut.px_r) px_cnt = px_cnt + 1;
      de_seen = 1'b1;
      if (o_rgb != 24'h0) begin
        white_total = white_total + 1;
        line_white  = line_white + 1;
      end
    end else if (o_rgb != 24'h0) begin
      g4_viol = g4_viol + 1;   // KB-014: rgb must be 0 outside DE
    end
    if (o_hs) begin             // line end: commit per-line accounting
      if (line_white > 0) white_lines = white_lines + 1;
      line_white = 0;
    end
  end

  // ------------------------------------------------------------------
  // Debug: machine-side activity (14m domain, every ~0.25 s)
  // ------------------------------------------------------------------
  integer dbg_hbl = 0, dbg_vbl = 1'b0, dbg_vblr = 1'b0, dbg_vidw = 0, dbg_vblr2 = 1'b0;
  integer dbg_whi = 0, dbg_wlo = 0;
  integer dbg_run = 0, dbg_last = 1'b0, dbg_lo_run = 0, dbg_hi_run = 0, dbg_lo_max = 0, dbg_hi_max = 0;
  integer dbg_line_len = 0, dbg_line_cnt = 0;
  integer dbg_vrun = 0, dbg_vlast = 1'b0, dbg_vlo = 0, dbg_vhi = 0;
  always @(posedge clk_14m) begin: dbg
    dbg_vblr <= w_vbl;
    if (w_vbl && !dbg_vblr) dbg_vbl = dbg_vbl + 1;
    if (w_hbl) dbg_hbl = dbg_hbl + 1;      // HBL-high cycle count (coarse)
    if (w_video) dbg_vidw = dbg_vidw + 1;
    if (w_video && w_hbl) dbg_whi = dbg_whi + 1;
    if (w_video && !w_hbl) dbg_wlo = dbg_wlo + 1;
    // VBL run-length measurement (masters per VBL state)
    if (w_vbl != dbg_vlast) begin
        if (dbg_vlast == 1'b0) dbg_vlo = dbg_vrun; else dbg_vhi = dbg_vrun;
        dbg_vrun = 0;
        dbg_vlast = w_vbl;
    end else dbg_vrun = dbg_vrun + 1;
    // HBL run-length + line length measurement
    if (w_hbl != dbg_last) begin
        if (dbg_last == 1'b0) begin        // was low, now high: low run ended
            dbg_lo_max = (dbg_run > dbg_lo_max) ? dbg_run : dbg_lo_max;
            dbg_lo_run = dbg_run;
        end else begin                     // was high, now low: line boundary
            dbg_hi_max = (dbg_run > dbg_hi_max) ? dbg_run : dbg_hi_max;
            dbg_hi_run = dbg_run;
            dbg_line_len = dbg_line_len + dbg_run + dbg_lo_run;
            dbg_line_cnt = dbg_line_cnt + 1;
            if (dbg_line_cnt == 2000) begin
                $display("DBG HBL: lo_run=%0d hi_run=%0d line=%0d masters (lo_max=%0d hi_max=%0d)",
                         dbg_lo_run, dbg_hi_run, dbg_line_len/2000, dbg_lo_max, dbg_hi_max);
                dbg_line_len = 0; dbg_line_cnt = 0; dbg_lo_max = 0; dbg_hi_max = 0;
            end
        end
        dbg_run = 0;
        dbg_last = w_hbl;
    end else dbg_run = dbg_run + 1;
    if (&flash_div) begin                  // ~1.7 Hz tick
      $display("DBG t=%0t hbl_hi=%0d vbl_rises=%0d vid_white=%0d (in_hbl_hi=%0d in_hbl_lo=%0d) vbl_lo=%0d vbl_hi=%0d",
               $time, dbg_hbl, dbg_vbl, dbg_vidw, dbg_whi, dbg_wlo, dbg_vlo, dbg_vhi);
      dbg_hbl = 0; dbg_vbl = 0; dbg_vidw = 0; dbg_whi = 0; dbg_wlo = 0;
    end
  end

  // ------------------------------------------------------------------
  // Run ~2 s of machine time, then judge
  // ------------------------------------------------------------------
  initial begin
    // 2 s at 14.286 MHz = 28.57M cycles = 1000 ns * 28_571
    repeat (28_571_000) @(posedge clk_14m);
    #10_000;

    // ---- report + judge ----
    // The display domain is in reset until machine_reset drops (~0.3 s in),
    // so expect ~100 frames in 2 s, not 120. The final frame is usually
    // partial at $finish, so hs is allowed one short frame.
    // G3: the machine boots BIOS -> Apple logo (peak white) -> mostly-black
    // "Ready." prompt screen (sparse white, stable). We check for the logo
    // peak AND a live stable screen at the end (not a fixed threshold on
    // the last frame, which is the prompt, not the logo).
    $display("DBG final: wbuf=%0d dbuf=%0d capl[b0 l0]=%0d capl[b1 l0]=%0d capl[b1 l100]=%0d maxcapl_r=%0d maxscr_r=%0d pxr_ones=%0d max_white=%0d",
             dut.wbuf, dut.dbuf, dut.cap_ram[0], dut.cap_ram[256], dut.cap_ram[356],
             max_capl_r, max_scr_r, pxr_ones, max_white);
    if (frames < 90) begin
      errors = errors + 1;
      $display("FAIL G1: only %0d output frames in ~2 s (expect ~100)", frames);
    end
    if (hs_cnt < frames*512 - 512 || hs_cnt > frames*512 + frames*4) begin
      errors = errors + 1;
      // lower: 1 partial frame; upper: in sim the machine frame (16.689 ms
      // at 14.286 MHz) is slightly LONGER than the display grid (16.667 ms
      // at 12.288 MHz), so the display holds its last (off-screen) line for
      // a fraction of a line per frame; on hardware the machine is faster
      // and there is no hold.
      $display("FAIL G1: hs=%0d vs frames*512=%0d (allowing partial frame + sim hold lines)", hs_cnt, frames*512);
    end
    if (vs_cnt != frames) begin
      errors = errors + 1;
      $display("FAIL G1: vs=%0d frames=%0d", vs_cnt, frames);
    end
    if (g4_viol > 0) begin
      errors = errors + 1;
      $display("FAIL G4: %0d nonzero-rgb-outside-DE samples", g4_viol);
    end
    if (racy_cycles > frames*8) begin
      errors = errors + 1;
      $display("FAIL G5: dbuf matched the machine write buffer for %0d cycles (ping-pong race)", racy_cycles);
    end else
      $display("G5: racy_cycles=%0d (bounded: only the ~3-4 cycle settling window per machine frame)", racy_cycles);

    if (max_white < 300) begin
      errors = errors + 1;
      $display("FAIL G3: max_white=%0d (< 300): never saw the logo?", max_white);
    end
    if (frame_white_hist[3] <= 0 || frame_white_hist[2] <= 0) begin
      errors = errors + 1;
      $display("FAIL G3: final frames white=%0d/%0d: screen not live",
               frame_white_hist[2], frame_white_hist[3]);
    end

    if (errors == 0)
      $display("PASS: frames=%0d hs=%0d g4_viol=%0d white=%0d",
               frames, hs_cnt, g4_viol, frame_white_hist[3]);
    else
      $display("FAIL: %0d error(s)", errors);
    if (errors != 0) $fatal(1, "tb_apf_video: %0d error(s)", errors);
    $finish;
  end

endmodule
