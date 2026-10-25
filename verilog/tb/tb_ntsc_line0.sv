// tb_ntsc_line0.sv - first-line / left-edge probe for the shipping NTSC pipeline
//
// Hardware (0.2.4, 2026-10-25) reported two artifacts on colour screens:
//   A) the 1st visible line of the screen is corrupted (Carnival/Jungle Hunt)
//   B) a faint magenta strip down the left edge (Oregon Trail)
//
// The pipeline's first active line after a machine-VBL falling edge is
// exactly the top line of the streamed frame (VBL_O falls inside that
// line's HBL window, VBL_ALIGN=32). This TB drives video_pipeline_q17
// (the shipping Quartus-17 tree) with MACHINE-TRUE geometry and checks:
//   1. The first active line after VBL decodes identically to the next
//      identical line (line-0 anomaly = hardware "1st line corruption").
//   2. Black lines carry no colour in the first pixels after HBL_O falls
//      (burst/porch leakage = the left-edge magenta strip).
//
// Machine-true geometry (timing_generator.v): the V counter runs 122..511
// (wraps to 122), VBL = V[6]&V[7] -> two 64-line VBL regions per cycle:
//   [70 active (V 122..191)][64 VBL (192..255)][192 active HGR (256..447)]
//   [64 VBL (448..511)] -> wrap.
// HGR block (the streamed frame): lines 256,257 white, 258,259 black, rest
// white - all colour (HGR + COLOR_LINE=1, Calibrated preset, shipping config).
//
// The monitor samples at the HBL_O falling edge (hb high->low = active start,
// the window the adapter streams), NOT at the stimulus HBL edge.
//
// Run: bash verilog/verilate_ntsc_line0.sh   (regenerates q17 first)

`timescale 1ns / 1ps
`default_nettype none

module tb_ntsc_line0;

  localparam int LINE_CLKS  = 912;
  localparam int HBL_CLOCKS = 352;
  localparam int V_MIN      = 122;
  localparam int V_WRAP     = 511;
  localparam int CYCLES     = 6;
  localparam int NSAMP      = 12;   // pixels captured from each line start

  // ---- clocks / stimulus ----
  reg clk = 1'b0;
  always #5 clk = ~clk;                   // 100 MHz sim clock (absolute value irrelevant)

  reg         reset        = 1'b1;
  reg         machine_ce   = 1'b1;
  reg         video        = 1'b0;
  reg         hbl          = 1'b1;
  reg         vbl          = 1'b1;
  // HGR + colour, Calibrated preset - the shipping configuration:
  reg         text_mode    = 1'b0;
  reg         hgr_mode     = 1'b1;
  reg         hgr80_mode   = 1'b0;
  reg         gr2          = 1'b0;
  reg         col80        = 1'b0;
  reg         dhires_mode  = 1'b0;
  reg         early_video  = 1'b0;
  reg         color_line   = 1'b1;
  reg         run_fill_ok  = 1'b1;
  reg [8:0]   v_cnt        = 9'd0;        // visible for the monitor's fall index

  // ---- DUT: the shipping q17 pipeline ----
  wire [7:0] r, g, b;
  wire       hs, vs, hbl_o, vbl_o;
  wire       ioctl_wait;

  video_pipeline_q17 dut (
      .CLK_14M          (clk),
      .VIDEO            (video),
      .HBL              (hbl),
      .VBL              (vbl),
      .COLOR_LINE       (color_line),
      .TEXT_MODE        (text_mode),
      .LO_RES_TEXT      (1'b1),
      .SCREEN_MODE      (2'b00),        // Colour
      .COLOR_PALETTE    (2'd0),
      .RUN_FILL_OK      (run_fill_ok),
      .NTSC_VERTICAL_COMB(1'b1),
      .EARLY_VIDEO      (early_video),
      .HGR_MODE         (hgr_mode),
      .HGR80_MODE       (hgr80_mode),
      .GR2              (gr2),
      .COL80            (col80),
      .DHIRES_MODE      (dhires_mode),
      .ioctl_addr       (25'd0),
      .ioctl_data       (8'd0),
      .ioctl_index      (8'd0),
      .ioctl_download   (1'b0),
      .ioctl_wr         (1'b0),
      .ioctl_wait       (ioctl_wait),
      .reset            (reset),
      .machine_ce       (machine_ce),
      .use_composite    (1'b1),
      .comp_preset      (2'd0),         // Calibrated (shipping default)
      .comp_hue_adj     (5'd0),
      .comp_bright_st   (2'd0),
      .comp_sat_st      (2'd0),
      .comp_contrast_st (2'd0),
      .R                (r),
      .G                (g),
      .B                (b),
      .HS               (hs),
      .VS               (vs),
      .HBL_O            (hbl_o),
      .VBL_O            (vbl_o)
  );

  // ---- monitor: after each machine-VBL fall, capture first 4 active lines,
  //      NSAMP pixels from each HBL_O falling edge. Capture index is the
  //      stimulus line offset (v_cnt - fall_base) - glitch-immune. HBL_O
  //      falling edges per stimulus line are counted (expect exactly 1).
  //      cap[c][f][l][px]: c = cycle; f = fall (0: V 255->256 before the
  //      192-HGR block; 1: V 511->122 before the 70-line text block);
  //      l = line offset from the fall (0..3).
  reg [23:0] cap [0:CYCLES-1][0:1][0:3][0:NSAMP-1];
  reg        hbl_d;
  reg        vbl_prev;
  integer    fall_cnt;         // 0 or 1, set at each VBL fall
  integer    fall_base;        // v_cnt of the fall line (256 or 122)
  integer    smp_cnt;
  integer    cycles;
  integer    vs_pulses;
  integer    hbl_falls_tot;
  integer    hbl_falls_bad;    // extra HBL_O falls within one stimulus line
  reg        vs_d;
  integer    last_fall_v;

  always @(posedge clk) begin
    cycles   <= cycles + 1;
    hbl_d    <= hbl_o;
    vs_d     <= vs;
    if (vs && !vs_d) vs_pulses <= vs_pulses + 1;

    if (vbl_prev && !vbl) begin                    // machine-VBL fall (frame start)
      fall_cnt  = (v_cnt == V_MIN) ? 1 : 0;
      fall_base = v_cnt;
      smp_cnt   <= 0;
    end else if (!vbl) begin
      if (hbl_d && !hbl_o) begin                   // HBL_O falling edge
        smp_cnt <= 0;
        hbl_falls_tot <= hbl_falls_tot + 1;
        if (v_cnt == last_fall_v) begin
          hbl_falls_bad <= hbl_falls_bad + 1;
          $display("HBL-GLITCH v=%0d fall=%0d off=%0d rgb=%h (2nd fall this line)",
                   v_cnt, fall_cnt, v_cnt - fall_base, {r, g, b});
        end
        last_fall_v = v_cnt;
      end
      else if (!hbl_o && smp_cnt < NSAMP && (v_cnt - fall_base) < 4 && (v_cnt - fall_base) >= 0) begin
        cap[0][fall_cnt][v_cnt - fall_base][smp_cnt] <= {r, g, b};
        smp_cnt <= smp_cnt + 1'b1;
      end
    end
    vbl_prev <= vbl;
  end

  initial begin
    integer fail;
    integer c, v, p;
    cycles = 0; vs_pulses = 0; fail = 0; fall_cnt = 0; fall_base = 0;
    hbl_falls_tot = 0; hbl_falls_bad = 0; last_fall_v = 0;
    vbl_prev = 1'b1;

    repeat (LINE_CLKS * 3) @(posedge clk);
    reset <= 1'b0;

    for (c = 0; c < CYCLES; c++) begin
      for (v = V_MIN; v <= V_WRAP; v++) begin
        v_cnt   = 9'(v);
        vbl     = (v >= 192 && v <= 255) || (v >= 448);
        // HGR block: 256,257 white, 258,259 black, rest white; text block white
        video   = (v >= 256 && v <= 447) ? ((v == 258 || v == 259) ? 1'b0 : 1'b1) : 1'b1;
        for (p = 0; p < LINE_CLKS; p++) begin
          hbl   = (p < HBL_CLOCKS);
          @(posedge clk);
        end
      end
      // copy cap[0] -> cap[c]
      for (int f2 = 0; f2 < 2; f2++)
        for (int l2 = 0; l2 < 4; l2++)
          for (int k2 = 0; k2 < NSAMP; k2++)
            cap[c][f2][l2][k2] = cap[0][f2][l2][k2];
    end

    // ---- report ----
    $display("---- tb_ntsc_line0 ----");
    $display("cycles = %0d  vs_pulses = %0d  hbl_falls = %0d  hbl_glitches = %0d",
             cycles, vs_pulses, hbl_falls_tot, hbl_falls_bad);
    $display("fall0 = first line after VBL 255->256 (the streamed frame's top line)");
    $display("fall1 = first line after VBL 511->122 (70-line text block)");
    for (int c2 = 0; c2 < CYCLES; c2++) begin
      for (int f2 = 0; f2 < 2; f2++) begin
        for (int l2 = 0; l2 < 4; l2++) begin
          $write("C%0d F%0d L%0d ", c2, f2, l2);
          for (int k2 = 0; k2 < NSAMP; k2++)
            $write("%06h ", cap[c2][f2][l2][k2]);
          $display("");
        end
      end
    end

    // ---- checks (steady state = cycles 1..5; cycle 0 follows reset) ----
    for (int c2 = 1; c2 < CYCLES; c2++) begin
      for (int f2 = 0; f2 < 2; f2++) begin
        for (int k2 = 0; k2 < NSAMP; k2++) begin
          if (cap[c2][f2][0][k2] !== cap[c2][f2][1][k2]) begin
            $display("LINE0-DIFF C%0d F%0d px%0d: L0=%h L1=%h", c2, f2, k2,
                     cap[c2][f2][0][k2], cap[c2][f2][1][k2]);
            fail = fail + 1;
          end
          // black lines (L2/L3 of the HGR fall0 block) must stay near-black
          if (f2 == 0 && (k2 == 0 || k2 == 1 || k2 == 2 || k2 == 3)) begin
            if (cap[c2][0][2][k2] > 24'd96 || cap[c2][0][3][k2] > 24'd96) begin
              $display("EDGE-COLOUR C%0d px%0d: L2=%h L3=%h (black line too bright)",
                       c2, k2, cap[c2][0][2][k2], cap[c2][0][3][k2]);
              fail = fail + 1;
            end
          end
        end
      end
    end
    if (vs_pulses < 2*CYCLES) begin $display("FAIL: too few vs pulses (%0d)", vs_pulses); fail = fail + 1; end
    if (fail == 0) $display("TB: LINE0 PASS");
    else           $display("TB: LINE0 FAIL (%0d)", fail);
    $finish;
  end

endmodule
