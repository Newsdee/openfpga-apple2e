// ============================================================================
// tb/tb_p2b_shots.sv — render the P2b machine/OSK/APF video to images
//
// Same wiring as tb_apf_video (machine core + OSK + apf_video), but instead
// of pixel counts it dumps four PPM images (P6, 1-bit content):
//
//   shots/frame.ppm    : one APF output frame (400x512) - what the Pocket
//                        screen shows
//   shots/machine.ppm  : the last machine frame as the OSK-composited 1-bit
//                        video (560x192) - what the machine produced
//   shots/buf0.ppm /   : the apf_video ping-pong capture buffers (560x192)
//   shots/buf1.ppm
//
// Stimulus: boot ~1.2 s, start (OSK open) at 1.25 s, face-A (press key,
// Q) at 1.5 s, face-Y (enter) at 1.7 s, stop at 2.35 s.
//
// Run with CWD = Apple-II_MiSTer/ (ROM paths are CWD-relative).
// ============================================================================

`timescale 1ns / 1ps

module tb_p2b_shots;

  localparam string SHOT_DIR = "E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/shots/";

  // ------------------------------------------------------------------
  // Clocks (same as tb_apf_video)
  // ------------------------------------------------------------------
  reg clk_14m   = 1'b0;
  reg clk_12288 = 1'b0;
  always #35.0   clk_14m   = ~clk_14m;   // 70 ns period = 14.286 MHz
  always #40.69  clk_12288 = ~clk_12288; // 81.38 ns period = 12.288 MHz

  // ------------------------------------------------------------------
  // Machine core wiring (identical to tb_apf_video)
  // ------------------------------------------------------------------
  wire [15:0] w_addr;
  wire [17:0] w_ram_addr;
  wire [7:0]  w_ram_di;
  wire [15:0] ram_do;
  wire        w_ram_aux, w_ram_we;
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
    .reset(reset), .cpu(1'b1),
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

  apple2e_osk osk (
    .clk(clk_14m), .reset(reset),
    .cont1_key(tb_cont1_key),
    .video_in(w_video), .hblank(w_hbl), .vblank(w_vbl),
    .video_out(osk_video),
    .K(k_K), .reads(read_key), .akd(k_akd),
    .command_reset(k_cmd_rst)
  );

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
  // Stimulus
  // ------------------------------------------------------------------
  initial begin
    #1_250_000_000;                       // t = 1.25 s: open the OSK
    tb_cont1_key = tb_cont1_key | (32'd1 << 15);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 15);

    #220_000_000;                         // t = 1.50 s: press key (Q)
    tb_cont1_key = tb_cont1_key | (32'd1 << 4);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 4);

    #170_000_000;                         // t = 1.70 s: enter
    tb_cont1_key = tb_cont1_key | (32'd1 << 7);
    #30_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 7);

    // t = 1.81 s: press fire while the captured machine frame is on screen
    // (capture spans ~1.802-1.819 s) - lights block 4 of the debug button
    // strip (start/L1 excluded: start would close the panel, L1 would move
    // it mid-frame)
    #80_000_000;
    tb_cont1_key = tb_cont1_key | (32'd1 << 4);
    #40_000_000;
    tb_cont1_key = tb_cont1_key & ~(32'd1 << 4);

    #500_000_000;                         // t = 2.35 s: stop
    $display("shots: stimulus done, finishing after frame dump");
  end

  // flip-event probe
  integer flip_ev = 0;
  always @(posedge clk_14m) begin
    if (dut.vbl_r && !w_vbl && $time > 2_000_000_000 && flip_ev < 12) begin
      $display("DBG flip %0d t=%0t hbl=%b hbl_r=%b line_end=%b line_start=%b vline=%0d wbuf=%b",
               flip_ev, $time, w_hbl, dut.hbl_r, dut.line_end, dut.line_start, dut.vline, dut.wbuf);
      flip_ev = flip_ev + 1;
    end
  end
  // write-value probe: per buffer, count nonzero words actually written
  integer nz_b0 = 0, nz_b1 = 0, z_b0 = 0, z_b1 = 0;
  always @(posedge clk_14m) begin
    if ($time > 2_000_000_000 && !w_hbl && !w_vbl && dut.xcap < 560 && dut.px_bit == 3'd7) begin
      if (dut.wbuf[0]) begin
        if ({dut.video_in, dut.px_acc[7:1]} != 0) nz_b1 = nz_b1 + 1; else z_b1 = z_b1 + 1;
      end else begin
        if ({dut.video_in, dut.px_acc[7:1]} != 0) nz_b0 = nz_b0 + 1; else z_b0 = z_b0 + 1;
      end
    end
  end
  // per-frame osk_video white (first 10 frames after 2.0 s)
  integer ov_w = 0, ov_f = 0;
  reg ov_vbl_p = 1'b0;
  integer vin_mismatch = 0;
  always @(posedge clk_14m) begin
    if (!w_vbl && !w_hbl) begin
      ov_w = ov_w + (osk_video ? 1 : 0);
      if ($time > 2_000_000_000 && dut.video_in !== osk_video && vin_mismatch < 20)
        $display("DBG VIN mismatch t=%0t dut.video_in=%b osk_video=%b", $time, dut.video_in, osk_video);
      if (dut.video_in !== osk_video) vin_mismatch = vin_mismatch + 1;
    end
    if (w_vbl && !ov_vbl_p) begin
      if ($time > 2_000_000_000 && ov_f < 10) $display("DBG oskv frame=%0d t=%0t white=%0d", ov_f, $time, ov_w);
      ov_w = 0;
      if ($time > 2_000_000_000) ov_f = ov_f + 1;
    end
    ov_vbl_p <= w_vbl;
  end
  // At each of the first 12 frame boundaries after 2.0s, scan both buffers
  // and report how many non-zero 8-pixel words each holds.
  integer bscan = 0;
  integer nzscan_b0 = 0, nzscan_b1 = 0;
  integer sl, sw;
  always @(posedge clk_14m) begin
    if (dut.vbl_r && !w_vbl && $time > 2_000_000_000 && bscan < 12) begin
      nzscan_b0 = 0; nzscan_b1 = 0;
      for (sl = 0; sl < 192; sl = sl + 1) begin
        for (sw = 0; sw < 70; sw = sw + 1) begin
          if (dut.pix_ram[{1'b0, sl[7:0], sw[6:0]}] != 0) nzscan_b0 = nzscan_b0 + 1;
          if (dut.pix_ram[{1'b1, sl[7:0], sw[6:0]}] != 0) nzscan_b1 = nzscan_b1 + 1;
        end
      end
      $display("DBG scan t=%0t vline=%0d wbuf=%b b0_nzwords=%0d b1_nzwords=%0d",
               $time, dut.vline, dut.wbuf, nzscan_b0, nzscan_b1);
      bscan = bscan + 1;
    end
  end
  reg apf_pix [0:511][0:399];
  reg  apf_arm = 1'b0;
  reg  apf_done = 1'b0;
  reg  apf_vs_p = 1'b0;
  integer apf_frames = 0;
  always @(posedge clk_12288) begin
    if (o_vs && !apf_vs_p) apf_frames = apf_frames + 1;
    apf_vs_p <= o_vs;
    // arm the frame that starts between 2.05 s and 2.25 s
    if (o_vs && !apf_vs_p && $time > 2_050_000_000 && $time < 2_250_000_000)
      apf_arm = 1'b1;
    if (apf_arm && !apf_done) begin
      if (dut.video_de)
        apf_pix[dut.y_count][dut.x_count] = (o_rgb != 24'd0);
      if (o_vs && apf_vs_p) begin   // end of the armed frame
        apf_done = 1'b1;
        apf_arm  = 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // Machine frame capture (14m domain): last frame before 2.35 s
  // ------------------------------------------------------------------
  reg [559:0] mach_pix [0:191];           // 560 px per line, bit x = pixel x
  reg  mach_arm = 1'b0, mach_done = 1'b0;
  reg  mach_vbl_p = 1'b0;
  reg [9:0] ml = 10'd0, mx = 10'd0;
  reg  hbl_p = 1'b0;
  always @(posedge clk_14m) begin
    if (w_vbl && !mach_vbl_p && $time > 1_800_000_000 && !mach_done) begin
      mach_arm = 1'b1;
      ml = 10'd0;
      mx = 10'd0;
      $display("DBG mach arm t=%0t", $time);
      for (int mi = 0; mi < 192; mi = mi + 1) mach_pix[mi] = 560'd0;
    end
    mach_vbl_p <= w_vbl;
    if (mach_arm && !mach_done) begin
      if (!w_vbl) begin
        if (hbl_p && !w_hbl) begin        // HBL falling: start of an active line
          if (ml < 10'd191) ml = ml + 1'b1;
          else begin
            mach_done = 1'b1; mach_arm = 1'b0;
            $display("DBG mach done t=%0t", $time);
          end
          mx = 10'd0;
        end else if (!w_hbl) begin
          if (osk_video) mach_pix[ml] = mach_pix[ml] | (1'b1 << mx);
          mx = mx + 1'b1;
        end
      end
      hbl_p <= w_hbl;
    end
  end

  // ------------------------------------------------------------------
  // Dump (at the end): 1-bit text grids (row = string of 0/1),
  // converted to PNG by a small script after the run.
  // ------------------------------------------------------------------
  initial begin
    #2_360_000_000;
    $display("shots: writing images to %s", SHOT_DIR);
    begin : dump_apf
      integer f, x, y;
      string p, row;
      p = {SHOT_DIR, "frame.txt"};
      f = $fopen(p, "w");
      for (y = 0; y < 512; y = y + 1) begin
        row = "";
        for (x = 0; x < 400; x = x + 1)
          row = {row, apf_pix[y][x] ? "1" : "0"};
        $fwrite(f, "%s\n", row);
      end
      $fclose(f);
    end
    begin : dump_mach
      integer f, x, y;
      string p, row;
      p = {SHOT_DIR, "machine.txt"};
      f = $fopen(p, "w");
      for (y = 0; y < 192; y = y + 1) begin
        row = "";
        for (x = 0; x < 560; x = x + 1)
          row = {row, mach_pix[y][x] ? "1" : "0"};
        $fwrite(f, "%s\n", row);
      end
      $fclose(f);
    end
    begin : dump_bufs
      integer f, x, y, w;
      reg [7:0] word;
      integer b;
      string p, row;
      for (b = 0; b < 2; b = b + 1) begin
        p = b ? {SHOT_DIR, "buf1.txt"} : {SHOT_DIR, "buf0.txt"};
        f = $fopen(p, "w");
        for (y = 0; y < 192; y = y + 1) begin
          row = "";
          for (w = 0; w < 70; w = w + 1) begin
            word = dut.pix_ram[{b[0], y[7:0], w[6:0]}];
            for (x = 0; x < 8; x = x + 1)
              row = {row, word[x] ? "1" : "0"};
          end
          $fwrite(f, "%s\n", row);
        end
        $fclose(f);
      end
    end
    $display("shots: done (apf_frames=%0d)", apf_frames);
    $display("DBG writes after 2.0s: b0 nz=%0d z=%0d | b1 nz=%0d z=%0d", nz_b0, z_b0, nz_b1, z_b1);
    $display("DBG video_in mismatch cycles: %0d", vin_mismatch);
    $finish;
  end

endmodule
