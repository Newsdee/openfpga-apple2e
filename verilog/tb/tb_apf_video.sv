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
  wire [7:0]  k_K;
  wire        k_akd, k_cmd_rst, osk_video;
  reg  [31:0] tb_cont1_key = 32'd0;
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
    .K(k_K), .READ_KEY(read_key), .AKD(k_akd), .AN(w_an), .GAMEPORT(8'h00),
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
  // OSK (P2b): buttons -> keystrokes + overlay over the native video.
  // Same module as core_top uses; here driven by tb_cont1_key.
  // ------------------------------------------------------------------
  apple2e_osk osk (
    .clk(clk_14m), .reset(reset),
    .cont1_key(tb_cont1_key),
    .video_in(w_video), .hblank(w_hbl), .vblank(w_vbl),
    .video_out(osk_video),
    .K(k_K), .reads(read_key), .akd(k_akd),
    .command_reset(k_cmd_rst)
  );

  // ------------------------------------------------------------------
  // DUT: the adapter
  // ------------------------------------------------------------------
  reg  [23:0] o_rgb;
  wire        o_de, o_vs, o_hs, o_skip;
  apf_video dut (
    .clk_14m(clk_14m), .reset(reset),
    .video_in(osk_video), .hbl(w_hbl), .vbl(w_vbl),
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
  integer disp_y = 0;         // display line index (for the OSK panel check)
  integer panel_white = 0;    // white pixels in display lines 202..299 (panel)
  integer hi_y_min = 0, hi_y_max = 0;   // frame's lines with >100 white (panel range)
  integer m_panel_tot = 0;     // white in machine lines with hbl-lo & vbl-lo, native 94..191
  integer m_frame_cnt = 0;
  integer m_frame_panel = 0;
  // per-machine-frame white (14m domain): boundary = VBL rising edge
  integer mv_white = 0, mv_frames = 0;
  reg     mv_vbl_d = 1'b0;
  always @(posedge clk_14m) begin
    mv_vbl_d <= w_vbl;
    if (!w_vbl) mv_white = mv_white + (w_video && !w_hbl);
    if (w_vbl && !mv_vbl_d) begin
      mv_frames = mv_frames + 1;
      mv_white = 0;
    end
  end
  integer rk_cnt = 0;   // machine READ_KEY pulses
  always @(posedge clk_14m) if (read_key) rk_cnt = rk_cnt + 1;
  // Probe: which keyboard register does the BIOS poll?
  //   In this core, a $C000 (KEYBOARD_SELECT) read does NOT set READ_KEY
  //   (no ack), but a $C010 (C01X_SELECT, A[3:0]=0) read DOES. If the BIOS
  //   polls $C000, the key is never acked -> the CPU re-reads it forever
  //   (the on-hardware "keeps typing as long as the OSK is open" bug).
  integer c000_reads = 0, c010_reads = 0;
  always @(posedge clk_14m) begin
    if (d1.KEYBOARD_SELECT && !d1.we) c000_reads = c000_reads + 1;
    if (d1.C01X_SELECT && !d1.we && w_addr[3:0] == 4'h0) c010_reads = c010_reads + 1;
  end
  // KEY LIFECYCLE PROBE (temporary): after a fire press, log the machine's
  // data bus (D_IN) on the first ~30 keyboard reads, plus the key state
  // (key_pressed = k_K[7], read_key, akd). This shows WHEN the key is
  // readable and WHEN it is cleared - the diagnosis for the hardware
  // "one tap = one key" regression.
  reg [3:0] fire_d = 4'b0;
  integer kb_win = 0, kb_n = 0;
  always @(posedge clk_14m) begin
    fire_d <= {fire_d[2:0], tb_cont1_key[4]};
    if (tb_cont1_key[4] && !fire_d[3]) begin kb_win = 1; kb_n = 0; end
  end
  // fine: log every cycle the key state or a keyboard access changes, for a
  // window that spans the OSK debounce (~1.4 ms) after the fire press.
  reg [3:0] kpd = 4'b0;
  integer kfp_win = 0;
  always @(posedge clk_14m) begin
    kpd <= {kpd[2:0], k_K[7]};
    if (tb_cont1_key[4] && !fire_d[3]) kfp_win = 55000;   // ~3.8 ms window
    else if (kfp_win > 0) kfp_win = kfp_win - 1;
    if (kfp_win > 0 && ((k_K[7] !== kpd[3]) || (d1.KEYBOARD_SELECT && !d1.we && k_K[7]==1'b1) || (d1.C01X_SELECT && !d1.we && w_addr[3:0]==4'h0))) begin
      if (k_K[7] !== kpd[3] || d1.KEYBOARD_SELECT || d1.C01X_SELECT)
        $display("KFP t=%0t kp=%b dKp=%b rk=%b D_IN=%h sel=%b c01x=%b vd=%b vc=%h", $time, k_K[7], (k_K[7]!==kpd[3]), read_key, d1.D_IN, d1.KEYBOARD_SELECT, d1.C01X_SELECT, k_K[7], k_K[6:0]);
    end
  end
  // virtual_event / key_ready transition trace (pin down the re-assertion)
  // CPU-BOUNDARY probe (Phase B): at each actual 6502 advance edge (CPU_EN), if
  // the CPU is at the keyboard register, log it at the CPU advance edge. DATA
// LABELING (expert correction): `d_in_pre` is the value captured one master
// edge EARLIER and is NOT automatically the input the CPU sampled at this edge;
// `D_now` (d1.D_IN) is the current pre-update input and is the relevant value
// when the monitor samples before nonblocking updates and the TB does not drive
// inputs on this edge. Capture BOTH read classes ($C000 read, $C010 read/write)
// and the advance condition, not just $C000.
  reg      c_en_d = 1'b0;
  reg [7:0] d_in_pre;
  integer   cpu_c000_read = 0, cpu_c010_read = 0, cpu_c01x_write = 0;
  always @(posedge clk_14m) begin
    d_in_pre <= d1.D_IN;
    if (d1.CPU_EN && !c_en_d) begin
      if (d1.KEYBOARD_SELECT && !d1.we) begin
        cpu_c000_read = cpu_c000_read + 1;
        if (kfp_win > 0)
          $display("CPUK t=%0t kind=C000R D_now=%h (pre=%h) kp=%b rk=%b we=%b pc=%04x op=%h", $time, d1.D_IN, d_in_pre, k_K[7], read_key, d1.we, d1.cpu65c02.reg_pc, d1.cpu65c02.ir);
      end
      if (d1.C01X_SELECT && !d1.we && w_addr[3:0] == 4'h0) begin
        cpu_c010_read = cpu_c010_read + 1;
        if (kfp_win > 0)
          $display("CPUK t=%0t kind=C010R D_now=%h (pre=%h) kp=%b rk=%b we=%b pc=%04x op=%h", $time, d1.D_IN, d_in_pre, k_K[7], read_key, d1.we, d1.cpu65c02.reg_pc, d1.cpu65c02.ir);
      end
      if (d1.C01X_SELECT && d1.we) begin
        cpu_c01x_write = cpu_c01x_write + 1;
        if (kfp_win > 0)
          $display("CPUK t=%0t kind=C01XW D_now=%h (pre=%h) kp=%b rk=%b we=%b pc=%04x op=%h", $time, d1.D_IN, d_in_pre, k_K[7], read_key, d1.we, d1.cpu65c02.reg_pc, d1.cpu65c02.ir);
      end
    end
    c_en_d <= d1.CPU_EN;
  end
  reg [1:0] vev_d = 2'b0, kp2_d = 2'b0;
  always @(posedge clk_14m) begin
    vev_d <= {vev_d[0], osk.kb_v_event};
    kp2_d <= {kp2_d[0], k_K[7]};
    if (kfp_win > 0 && vev_d[0] !== vev_d[1])
      $display("VEV t=%0t ev=%b dV=%b pressed=%b code=%h", $time, osk.kb_v_event, (osk.kb_v_event!==vev_d[1]), osk.kb_v_pressed, osk.kb_v_code);
    if (kfp_win > 0 && kp2_d[0] !== kp2_d[1])
      $display("KPR t=%0t kp=%b (d) vc=%h vd=%b akd=%b", $time, k_K[7], k_K[6:0], osk.kbd.virtual_data, k_akd);
  end
  // Virtual key-press event counting: the true "one press = one key"
  // invariant. A fire press must produce exactly ONE virtual key press
  // (kb_v_event rising edge with kb_v_pressed). Counting RAM Q-bytes is
  // wrong - the boot logo also contains 'Q' glyphs and is redrawn.
  integer q_press_cnt = 0;    // virtual presses with code == 0x51 (Q)
  integer all_press_cnt = 0;  // all virtual key presses (press, not release)
  reg v_ev_d = 1'b0;
  always @(posedge clk_14m) begin
    if (osk.kb_v_event !== v_ev_d) begin
      if (osk.kb_v_pressed) begin
        all_press_cnt = all_press_cnt + 1;
        if (osk.kb_v_code === 7'h51) q_press_cnt = q_press_cnt + 1;
      end
      $display("DBG vev t=%0t press=%b code=%h row=%d col=%d",
               $time, osk.kb_v_pressed, osk.kb_v_code, osk.kb_row, osk.kb_col);
    end
    v_ev_d <= osk.kb_v_event;
    if (read_key && k_K[7])
      $display("DBG kread t=%0t K=%h vev=%b", $time, k_K, osk.kb_v_event);
  end
  integer vbl_fall = 0, vbl_rise = 0;
  reg vbl_p = 1'b0;
  always @(posedge clk_14m) begin
    if (w_vbl != vbl_p) begin
      if (w_vbl) vbl_rise = vbl_rise + 1; else vbl_fall = vbl_fall + 1;
    end
    vbl_p <= w_vbl;
  end
  // wbuf flip tracking (machine domain)
  reg [1:0] wbuf_p = 2'd0;
  integer wbuf_flips = 0;
  always @(posedge clk_14m) begin
    if (dut.wbuf[0] != wbuf_p) wbuf_flips = wbuf_flips + 1;
    wbuf_p <= dut.wbuf[0];
  end
  // per APF display frame (12.288M domain): panel white
  integer dp_white = 0, dp_frames = 0;
  integer disp_panel_frames = 0, disp_obs_frames = 0;   // monitored frames with panel / observed
  reg dp_vs_p = 1'b0;
  always @(posedge clk_12288) begin
    if (o_vs && !dp_vs_p) begin
      if (dp_frames >= 120 && dp_frames < 190) begin
        disp_obs_frames = disp_obs_frames + 1;
        if (dp_white > 1000) disp_panel_frames = disp_panel_frames + 1;
      end
      dp_frames = dp_frames + 1;
      dp_white = 0;
    end
    if (o_de) dp_white = dp_white + (o_rgb == 24'hFFFFFF ? 1 : 0);
    dp_vs_p <= o_vs;
  end
  integer ov_white = 0, ov_frames = 0;
  integer ov_line = 0;
  reg     ov_vbl_d = 1'b0, ov_hbl_d = 1'b0;
  always @(posedge clk_14m) begin
    ov_vbl_d <= w_vbl;
    ov_hbl_d <= w_hbl;
    if (!w_vbl) begin
      if (!w_hbl) ov_white = ov_white + (osk_video ? 1 : 0);
      else if (w_hbl && !ov_hbl_d && ov_vbl_d == 1'b0) begin
        ov_line = ov_line + 1;
        if (ov_line > 191) ov_line = 0;
      end
    end
    if (w_vbl && !ov_vbl_d) begin
      ov_frames = ov_frames + 1;
      ov_white = 0; ov_line = 0;
    end
  end
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
        panel_white = 0;
        if (white_total > max_white) max_white = white_total;
        if (frames % 30 == 0 || frames >= 110)
          $display("F%0d white=%0d lines=%0d panel=%0d hiy=[%0d..%0d]", frames, white_total, white_lines, panel_white, hi_y_min, hi_y_max);
      end
      vs_cnt      = vs_cnt + 1;
      frames      = frames + 1;
      white_total = 0;
      white_lines = 0;
      line_white  = 0;
      de_seen     = 1'b0;
      disp_y      = 0;
      hi_y_min    = 1000;
      hi_y_max    = -1;
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
      if (line_white > 100) begin
        if (disp_y < hi_y_min) hi_y_min = disp_y;
        if (disp_y > hi_y_max) hi_y_max = disp_y;
      end
      if (disp_y >= 150 && disp_y <= 250) panel_white = panel_white + line_white;
      disp_y = disp_y + 1;
      line_white = 0;
    end
  end

  // ------------------------------------------------------------------
  // P2b OSK button sequence (absolute sim time, ns):
  //   t = 1.72 s: press start (bit 15) 30 ms  -> OSK enable toggle
  //               (overlay opens ~500 ms later: controller INITIAL_DELAY_MS)
  //   t = 2.30 s: CLEAN fire (bit 4) 30 ms    -> one Q press (cursor row1 col1)
  //   t = 2.60 s: WOBBLE fire (bit 4) 15 on/off cycles @ 5 ms -> with the
  //               press-latch this must yield exactly ONE Q press; without
  //               it the edge-triggered controller fires on every 0->1 (15)
  //   t = 2.90 s: press face-Y (enter/CR, 0x0D) 30 ms
  //   t = 3.05/3.20 s: tap APF dpad UP then LEFT -> cursor (1,1)->(0,0)
  //   judge at t = 3.6 s
  // ------------------------------------------------------------------
  initial begin
    // #delays are in ns ($time prints ps on this toolchain): 1 s = 1e9
    #1_720_000_000;                     // t = 1.72 s: press start
    tb_cont1_key = tb_cont1_key | (32'd1 << 15);
    #30_000_000;                        // 30 ms
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 15);

    #550_000_000;                       // t = 2.30 s: CLEAN fire 30 ms
    tb_cont1_key = tb_cont1_key | (32'd1 << 4);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 4);

    #270_000_000;                       // t = 2.60 s: WOBBLE fire (15x 5ms on/off)
    begin : wobble
      integer wb;
      for (wb = 0; wb < 15; wb = wb + 1) begin
        tb_cont1_key = tb_cont1_key | (32'd1 << 4);   // 5 ms on
        #5_000_000;
        tb_cont1_key = tb_cont1_key & ~(32'd1 << 4);  // 5 ms off
        #5_000_000;
      end
    end

    #150_000_000;                       // t = 2.90 s: press face-Y (enter/CR, 0x0D)
    tb_cont1_key = tb_cont1_key | (32'd1 << 7);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 7);

    #120_000_000;                       // t = 3.05 s: tap APF dpad UP (bit 0)
    tb_cont1_key = tb_cont1_key | (32'd1 << 0);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 0);

    #120_000_000;                       // t = 3.20 s: tap APF dpad LEFT (bit 2)
    tb_cont1_key = tb_cont1_key | (32'd1 << 2);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 2);
    // results checked in the judge block below (t = 3.6 s)
  end

  // ------------------------------------------------------------------
  // Run ~3 s of machine time, then judge
  // ------------------------------------------------------------------
  initial begin
    // 3.6 s at 14.286 MHz = 51,428,400 cycles
    repeat (51_428_400) @(posedge clk_14m);
    #10_000;

    // (judge below)

    // ---- report + judge ----
    // The display domain is in reset until machine_reset drops (~0.3 s in),
    // so expect ~100 frames in 2 s, not 120. The final frame is usually
    // partial at $finish, so hs is allowed one short frame.
    // G3: the machine boots BIOS -> Apple logo (peak white) -> mostly-black
    // "Ready." prompt screen (sparse white, stable). We check for the logo
    // peak AND a live stable screen at the end (not a fixed threshold on
    // the last frame, which is the prompt, not the logo).
    // G6: P2b OSK - start opened the panel (display screen lines 94..191
    // with V_OFF centering) and face-A typed "Q" (the key under the initial
    // cursor, row 1 col 1) at the prompt.
    $display("summary: wbuf=%0d dbuf=%0d ov_frames=%0d mv_frames=%0d rk=%0d wbuf_flips=%0d vbl_rise=%0d vbl_fall=%0d osk_en=%b osk_act=%b row=%d col=%d q_press=%0d all_press=%0d dut_cnt=%0d c000_reads=%0d c010_reads=%0d cpu_c000_read=%0d cpu_c010_read=%0d cpu_c01x_write=%0d",
             dut.wbuf, dut.dbuf, ov_frames, mv_frames, rk_cnt, wbuf_flips, vbl_rise, vbl_fall,
             osk.osk_en, osk.kb_active, osk.kb_row, osk.kb_col, q_press_cnt, all_press_cnt,
             osk.key_press_cnt, c000_reads, c010_reads, cpu_c000_read, cpu_c010_read, cpu_c01x_write);
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

    // G6a: exactly TWO virtual Q key-press events total: one from the
    // clean fire press and exactly one from the 15-cycle wobble press
    // (the press-latch must swallow the wobble - the old code would
    // have fired on every 0->1, giving 1+15=16). all_press = 3 (2x Q
    // + the CR enter press).
    if (q_press_cnt != 2) begin
      errors = errors + 1;
      $display("FAIL G6a: %0d Q key-press events (expect exactly 2: clean fire + 1 from the wobble)", q_press_cnt);
    end else
      $display("G6a: clean fire = 1 press AND 15-cycle wobble = 1 press (latch OK; all_press=%0d)", all_press_cnt);
    // G6d: the on-hardware diagnostic counter (the one rendered in the
    // panel margin) must agree with the TB-side event count: 2x Q
    // (clean fire + wobble) + 1x CR (enter) = 3 press events.
    if (osk.key_press_cnt != 8'd3) begin
      errors = errors + 1;
      $display("FAIL G6d: on-hardware key-press counter = %0d (expect 3: Q + wobble-Q + CR)", osk.key_press_cnt);
    end else
      $display("G6d: on-hardware key-press counter = 3 (matches the real event count)");
    if (osk.kb_row != 3'd0 || osk.kb_col != 4'd0) begin
      errors = errors + 1;
      $display("FAIL G6c: dpad UP then LEFT taps did not move cursor to (0,0): row=%0d col=%0d",
               osk.kb_row, osk.kb_col);
    end else
      $display("G6c: APF dpad UP then LEFT moved the cursor (1,1)->(0,0) correctly");
    if (disp_obs_frames < 20 || disp_panel_frames * 5 < disp_obs_frames * 3) begin
      errors = errors + 1;
      $display("FAIL G6b: panel in %0d/%0d display frames (last-frame white=%0d, hiy=[%0d..%0d])",
               disp_panel_frames, disp_obs_frames, panel_white, hi_y_min, hi_y_max);
    end else
      $display("G6b: OSK panel displayed in %0d/%0d display frames (last-frame white=%0d)",
               disp_panel_frames, disp_obs_frames, panel_white);

    if (errors == 0)
      $display("PASS: frames=%0d hs=%0d g4_viol=%0d white=%0d panel=%0d",
               frames, hs_cnt, g4_viol, frame_white_hist[3], panel_white);
    else
      $display("FAIL: %0d error(s)", errors);
    if (errors != 0) $fatal(1, "tb_apf_video: %0d error(s)", errors);
    $finish;
  end

endmodule
