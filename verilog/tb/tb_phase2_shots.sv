// ============================================================================
// tb/tb_phase2_shots.sv — render the PHASE 2 video path (machine + OSK +
// apf_stream_video) to 24-bit color images, and check the APF video
// contract on the streamed signals.
//
// Dumps (verilog/shots/):
//   phase2_frameA.ppm : ~frame 30 (~0.64 s): machine boot screen, OSK closed
//   phase2_frameB.ppm : ~frame 82 (~1.75 s): machine + full-color OSK open
//                       (Q + Enter pressed per the P2b stimulus)
//
// APF contract checks (displayed at end, $fatal on violation):
//   - video_rgb == 0 outside video_de            (rgb_nonde_violations == 0)
//   - video_hs / video_vs are 1-cycle pulses     (pulse_width_violations == 0)
//   - first HS after each VS is >= 3 cycles later (hs_vs_gap_min >= 3)
//   - 560 active px per line, 192 lines per frame
//
// Same machine wiring as tb_p2b_shots.sv; the DUT is apf_stream_video
// (no frame buffer, 14.318 MHz domain) fed with the OSK's 24-bit
// composited output (video_rgb24).
//
// Run with CWD = Apple-II_MiSTer/ (ROM paths are CWD-relative).
// ============================================================================

`timescale 1ns / 1ps

module tb_phase2_shots;

  localparam string SHOT_DIR = "E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/shots/";

  // DEC=1: 280-px decimated capture (the DEC2X=1 experiment)
  // DEC=0: native 560-px capture (shipping path) - -G DEC=0
  parameter DEC = 1;

  // ------------------------------------------------------------------
  // Clocks (same as tb_p2b_shots)
  // ------------------------------------------------------------------
  reg clk_14m = 1'b0;
  always #35.0 clk_14m = ~clk_14m;        // 70 ns period = 14.286 MHz

  // ------------------------------------------------------------------
  // Machine core wiring (identical to tb_p2b_shots)
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
  wire [23:0] osk_rgb24;
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
    .video_rgb24(osk_rgb24),
    .K(k_K), .reads(read_key), .akd(k_akd),
    .open_apple(), .closed_apple(),
    .command_reset(k_cmd_rst)
  );

  // ------------------------------------------------------------------
  // DUT: Phase 2 streaming adapter (no frame buffer)
  // ------------------------------------------------------------------
  reg  [23:0] o_rgb;
  wire        o_de, o_vs, o_hs, o_skip;
  apf_stream_video #(.DEC2X(DEC)) dut (
    .clk(clk_14m), .reset(reset),
    .rgb_in(osk_rgb24), .hbl(w_hbl), .vbl(w_vbl),
    .video_rgb(o_rgb), .video_de(o_de), .video_vs(o_vs),
    .video_hs(o_hs), .video_skip(o_skip)
  );

  // ------------------------------------------------------------------
  // APF contract checks (all hard-fail at the end)
  //   1. video_rgb == 0 outside video_de
  //   2. HS / VS are 1-cycle pulses
  //   3. HS never overlaps DE            <- the Phase-2 failure mode
  //   4. >= 1 blank clock between HS and the next DE
  //   5. >= 3 clocks between VS and the first HS after it
  //   6. every line carries exactly 280 active pixels (DEC2X=1)
  //   7. every frame carries exactly 192 active lines
  //   8. a VS is seen within the first 10M clocks (watchdog; the TB holds
  //      reset for ~4.2M clocks, so nothing can sync before that)
  // ------------------------------------------------------------------
  reg  o_de_d, o_hs_d, o_vs_d;
  integer rgb_nonde_viol, pulse_viol, hsde_overlap_viol;
  integer hs_sep, hs_sep_min;        // cycles from HS to next DE (expect >= 1)
  integer vs2hs_gap, vs2hs_gap_min;  // cycles from VS to next HS (expect >= 3)
  integer line_px_err, frame_lines_err;
  integer lines_this_frame;
  integer first_vs_cycle, no_vs_yet, cycles;

  initial begin
    rgb_nonde_viol = 0; pulse_viol = 0; hsde_overlap_viol = 0;
    hs_sep = 0; hs_sep_min = 1000;
    vs2hs_gap = 0; vs2hs_gap_min = 1000;
    line_px_err = 0; frame_lines_err = 0; lines_this_frame = 0;
    first_vs_cycle = 0; no_vs_yet = 1; cycles = 0;
  end

  always @(posedge clk_14m) begin
    o_de_d <= o_de; o_hs_d <= o_hs; o_vs_d <= o_vs;
    cycles <= cycles + 1;

    // watchdog: first VS within 10M clocks (TB holds reset for ~4.2M,
    // so no sync can appear before reset release)
    if (no_vs_yet == 1 && cycles > 10000000) no_vs_yet <= 2;   // 2 = timeout
    if (o_vs && no_vs_yet == 1) begin
      first_vs_cycle <= cycles;
      no_vs_yet <= 0;
    end

    // 1. RGB must be 0 outside DE
    if (!o_de && o_rgb != 24'h0) rgb_nonde_viol <= rgb_nonde_viol + 1;

    // 2. HS/VS must be 1-cycle pulses
    if (o_hs && o_hs_d) pulse_viol <= pulse_viol + 1;
    if (o_vs && o_vs_d) pulse_viol <= pulse_viol + 1;

    // 3. HS must never overlap DE
    if (o_hs && o_de) hsde_overlap_viol <= hsde_overlap_viol + 1;

    // 4. separation from HS to the next DE (>= 1 blank clock between)
    if (o_hs) hs_sep <= 0;
    else if (hs_sep < 1000 && !o_de) hs_sep <= hs_sep + 1;
    else if (hs_sep < 1000 && o_de) begin
      if (hs_sep < hs_sep_min) hs_sep_min <= hs_sep;
      hs_sep <= 1000;                       // done for this line
    end

    // 5. separation from VS to the first HS after it (>= 3)
    if (o_vs) vs2hs_gap <= 0;
    else if (vs2hs_gap < 1000 && !o_hs) vs2hs_gap <= vs2hs_gap + 1;
    else if (vs2hs_gap < 1000 && o_hs) begin
      if (vs2hs_gap < vs2hs_gap_min) vs2hs_gap_min <= vs2hs_gap;
      vs2hs_gap <= 1000;                    // done for this frame
    end
  end

  // ------------------------------------------------------------------
  // Frame capture (24-bit) + one-shot dump of frames 30 and 82.
  // The DEC2X=1 line buffer makes DE contiguous again (one 280-clock
  // window per visible line), so line tracking is DE-based.
  // ------------------------------------------------------------------
  reg [23:0] cur [0:191][0:559];
  reg [9:0]  cx, cy;
  reg [9:0]  fc;
  reg        cap_a, cap_b, de_d;

  initial begin
    cur = '{default: 24'h0}; cx = 0; cy = 0; fc = 0;
    cap_a = 1'b0; cap_b = 1'b0; de_d = 1'b0;
  end

  task dump_ppm(input string fname);
    integer f, y, x;
    begin
      f = $fopen(fname, "wb");
      $fwrite(f, "P6\n%0d 192\n255\n", DEC ? 280 : 560);
      for (y = 0; y < 192; y = y + 1)
        for (x = 0; x < (DEC ? 280 : 560); x = x + 1) begin
          $fwrite(f, "%c", cur[y][x][23:16]);
          $fwrite(f, "%c", cur[y][x][15:8]);
          $fwrite(f, "%c", cur[y][x][7:0]);
        end
      $fclose(f);
      $display("PHASE2 dumped %s", fname);
    end
  endtask

  always @(posedge clk_14m) begin
    if (o_vs) begin
      // 7. previous frame must have had exactly 192 active lines
      if (fc >= 1 && fc <= 5) $display("DBG lines in frame %0d = %0d", fc, lines_this_frame);
      if (fc >= 1 && lines_this_frame != 192) frame_lines_err <= frame_lines_err + 1;
      lines_this_frame <= 0;
      cy <= 0; cx <= 0;
      // one-shot captures (survive frame-counter wraps)
      if (!cap_a && fc == 30) begin
        cap_a <= 1'b1;
        dump_ppm({SHOT_DIR, "phase2_frameA.ppm"});
      end
      if (!cap_b && fc == 82) begin
        cap_b <= 1'b1;
        dump_ppm({SHOT_DIR, "phase2_frameB.ppm"});
      end
      fc <= fc + 1;
    end else if (o_de) begin
      cur[cy][cx] = o_rgb;
      cx <= cx + 1;
    end else if (de_d) begin
      // 6. line end: exactly 280 contiguous DE pixels (DEC2X=1)
      if (cx != (DEC ? 280 : 560)) line_px_err <= line_px_err + 1;
      lines_this_frame <= lines_this_frame + 1;
      cx <= 0;
      cy <= (cy == 191) ? 10'd191 : cy + 10'd1; // clamp
    end
    de_d <= o_de;
  end

  // ------------------------------------------------------------------
  // Stimulus (same as tb_p2b_shots)
  // ------------------------------------------------------------------
  initial begin
    #1_250_000_000;                       // t = 1.25 s: open the OSK (start)
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

    #600_000_000;                         // t = 2.65 s: bounded completion
    $display("PHASE2 frames seen: %0d (first VS @ cycle %0d, %0d cycles total)",
             fc, first_vs_cycle, cycles);
    $display("PHASE2 rgb-nonde violations:   %0d (expect 0)", rgb_nonde_viol);
    $display("PHASE2 pulse-width violations: %0d (expect 0)", pulse_viol);
    $display("PHASE2 HS/DE overlap viol.:    %0d (expect 0)", hsde_overlap_viol);
    $display("PHASE2 min HS->DE separation:  %0d (expect >= 1)", hs_sep_min);
    $display("PHASE2 min VS->HS gap:         %0d (expect >= 3)", vs2hs_gap_min);
    $display("PHASE2 bad line widths:        %0d (expect 0)", line_px_err);
    $display("PHASE2 bad frame line counts:  %0d (expect 0)", frame_lines_err);
    if (no_vs_yet != 0)
      $fatal(1, "PHASE2 FAILED: no VS seen within 10M clocks (watchdog)");
    if (rgb_nonde_viol != 0 || pulse_viol != 0 || hsde_overlap_viol != 0 ||
        hs_sep_min == 1000 || hs_sep_min < 1 ||
        vs2hs_gap_min == 1000 || vs2hs_gap_min < 3 ||
        line_px_err != 0 || frame_lines_err != 0)
      $fatal(1, "PHASE2 APF contract FAILED");
    $display("PHASE2 APF contract PASS");
    $finish;
  end

endmodule
