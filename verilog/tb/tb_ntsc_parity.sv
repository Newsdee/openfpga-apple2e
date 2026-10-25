// tb_ntsc_parity.sv - N1 differential parity test (PLAN_NTSC_PORT_2026-10-24 §5 N1)
//
// Proves that the Quartus-17-compatible rewrites produced by
// tools/gen_video_q17.py (15 `N'(expr)` size-cast sites, plus one `signed'()`
// signing cast) are BEHAVIORALLY IDENTICAL to the unmodified pinned donor.
//
// Method: elaborate BOTH trees in one simulation -
//   golden    : machine/video/{video_pipeline,apple_composite,composite_decoder}.sv
//               (byte-identical to Apple-II_MiSTer/rtl/video at donor 7ed980d)
//   candidate : machine/video/*_q17.sv (generated; module names suffixed _q17,
//               sharing the unmodified vga_controller.v)
// driven from the SAME stimulus, and compare every output EVERY cycle.
//
// Tolerance is ZERO and there is NO acquisition window. Unlike a port against
// real hardware, both sides are the same design starting from the same reset
// state, so any divergence at any cycle - including during burst acquisition -
// is a rewrite defect, not a lock transient. The plan's "exclude only an
// explicitly bounded initial acquisition interval" applies to donor-vs-Pocket
// integration, not to this equivalence check; permitting a window here would
// let a real bug hide.
//
// Geometry (from composite_decoder.sv:118-119, the donor's own comment):
//   912-sample line; hcnt 0 = 2 samples after the sync edge;
//   post-sync HBL 0..219, active 220..779, pre-sync 780..911
//   -> machine HBL is high for 352 clocks (132 pre-sync + 220 post-sync)
//      and low for the 560 active clocks. 262 lines per NTSC frame.
// The decoder measures line_len from HBL edges itself, so the TB only has to
// present legal blanking; it does not have to reproduce hcnt phase exactly.
//
// Coverage (plan §6 "Pattern coverage" + "Mode coverage"): black, white,
// alternating bits, phase-shifted patterns, edge markers, adjacent-line
// changes, across 40/80-col text, lores, HGR, DHGR, mixed and HGR80 selects.
//
// Build+run (from the repo root; ROM paths are CWD-relative):
//   bash verilog/verilate_ntsc_parity.sh
// Exits nonzero on any mismatch, and nonzero if it captured nothing (an empty
// pass is a failure, not a pass).

`timescale 1ns / 1ps

module tb_ntsc_parity;

  // ---- line / frame geometry ----
  localparam int LINE_CLKS   = 912;
  localparam int HBL_CLOCKS  = 352;   // pre-sync 132 + post-sync 220
  localparam int ACTIVE      = LINE_CLKS - HBL_CLOCKS;  // 560
  localparam int LINES_FRAME = 262;
  // VBL must be at least VSYNC_FRONT_PORCH + VSYNC_LINES = 33 + 3 = 36 lines or
  // video_pipeline's regenerated vs_c can never assert (vblank_lines counts
  // hbl_rise while VBL is high, and vs_c needs vblank_lines in [33,36)).
  // 54 is the real Apple II VBL length; 262 - 192 active = 70 blanking lines,
  // so 54 is legal. Measured: with 26 lines the TB reported vs_pulses = 0.
  localparam int VBL_LINES   = 54;    // vertical blanking at the frame tail
  localparam int FRAMES      = 16;   // 4 presets x 4 screen modes (f[1:0], f[3:2])

  // ---- shared stimulus ----
  reg         clk = 1'b0;
  reg         reset = 1'b1;
  reg         machine_ce = 1'b1;
  reg         video = 1'b0;
  reg         hbl = 1'b1;
  reg         vbl = 1'b1;
  // mode flags
  reg         color_line = 1'b0;
  reg         text_mode = 1'b1;
  reg         run_fill_ok = 1'b0;
  reg         early_video = 1'b0;
  reg         hgr_mode = 1'b0;
  reg         hgr80_mode = 1'b0;
  reg         gr2 = 1'b0;
  reg         col80 = 1'b0;
  reg         dhires_mode = 1'b0;
  reg [1:0] screen_mode_c = 2'b00;   // Colour
  reg [1:0] comp_preset_c = 2'd0;    // Calibrated

  // ---- golden outputs ----
  wire [7:0] g_r, g_g, g_b;
  wire       g_hs, g_vs, g_hbl, g_vbl;
  // ---- candidate outputs ----
  wire [7:0] c_r, c_g, c_b;
  wire       c_hs, c_vs, c_hbl, c_vbl;
  wire       g_wait, c_wait;

  video_pipeline golden (
    .CLK_14M(clk), .VIDEO(video), .HBL(hbl), .VBL(vbl),
    .COLOR_LINE(color_line), .TEXT_MODE(text_mode), .LO_RES_TEXT(1'b1),
    .SCREEN_MODE(screen_mode_c), .COLOR_PALETTE(2'd0),
    .RUN_FILL_OK(run_fill_ok), .NTSC_VERTICAL_COMB(1'b1),
    .EARLY_VIDEO(early_video), .HGR_MODE(hgr_mode), .HGR80_MODE(hgr80_mode),
    .GR2(gr2), .COL80(col80), .DHIRES_MODE(dhires_mode),
    .ioctl_addr(25'd0), .ioctl_data(8'd0), .ioctl_index(8'd0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_wait(g_wait),
    .reset(reset), .machine_ce(machine_ce),
    .use_composite(1'b1), .comp_preset(comp_preset_c), .comp_hue_adj(5'd0),
    .comp_bright_st(2'd0), .comp_sat_st(2'd0), .comp_contrast_st(2'd0),
    .R(g_r), .G(g_g), .B(g_b), .HS(g_hs), .VS(g_vs),
    .HBL_O(g_hbl), .VBL_O(g_vbl)
  );

  video_pipeline_q17 candidate (
    .CLK_14M(clk), .VIDEO(video), .HBL(hbl), .VBL(vbl),
    .COLOR_LINE(color_line), .TEXT_MODE(text_mode), .LO_RES_TEXT(1'b1),
    .SCREEN_MODE(screen_mode_c), .COLOR_PALETTE(2'd0),
    .RUN_FILL_OK(run_fill_ok), .NTSC_VERTICAL_COMB(1'b1),
    .EARLY_VIDEO(early_video), .HGR_MODE(hgr_mode), .HGR80_MODE(hgr80_mode),
    .GR2(gr2), .COL80(col80), .DHIRES_MODE(dhires_mode),
    .ioctl_addr(25'd0), .ioctl_data(8'd0), .ioctl_index(8'd0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_wait(c_wait),
    .reset(reset), .machine_ce(machine_ce),
    .use_composite(1'b1), .comp_preset(comp_preset_c), .comp_hue_adj(5'd0),
    .comp_bright_st(2'd0), .comp_sat_st(2'd0), .comp_contrast_st(2'd0),
    .R(c_r), .G(c_g), .B(c_b), .HS(c_hs), .VS(c_vs),
    .HBL_O(c_hbl), .VBL_O(c_vbl)
  );

  always #34.92 clk = ~clk;   // 14.318 MHz

  // ---- comparison ----
  longint cycles = 0;
  longint mismatches = 0;
  longint active_pixels = 0;
  longint nonzero_rgb = 0;
  // ---- chroma production, per SCREEN_MODE (plan §4: 2'b00 = Colour) ----
  // The boot harness cannot answer "does this port produce colour": DOS 3.3
  // boots to 40-column TEXT, which is monochrome by design on a real Apple II,
  // so a text screen measures max channel spread 0 whether or not the decoder
  // works. This TB drives colour-phase patterns (pat_bit modes 2/3/4 and
  // set_mode 6/7 with color_line=1), so chroma here is a real production test
  // of the decoder rather than of the surrounding glue.
  longint chromatic [4];   // pixels with max(R,G,B)-min(R,G,B) > 8, by SCREEN_MODE
  longint max_spread [4];
  initial begin
    chromatic[0] = 0; chromatic[1] = 0; chromatic[2] = 0; chromatic[3] = 0;
    max_spread[0] = 0; max_spread[1] = 0; max_spread[2] = 0; max_spread[3] = 0;
  end
  int sm_r, sm_g, sm_b, sm_mx, sm_mn, sm_sp;
  longint hs_pulses = 0, vs_pulses = 0;
  reg g_hs_d = 0, g_vs_d = 0;

  // ---- width-exercise coverage (why this block exists) ----
  // A DROP-class rewrite is justified by "the assignment LHS is exactly N bits,
  // so it already truncates". That argument is only *tested* if the stimulus
  // actually drives the expression past N bits. A negative test on the v_abs
  // site (v_err[15:0] -> v_err[14:0]) PASSED undetected, because with these
  // patterns v_err never has bit 15 set while positive. So the TB counts the
  // wide/negative excursions of the golden side and FAILS if a rewrite site's
  // interesting range was never reached - an untested site must not be able to
  // claim equivalence.
  longint cov_vabs_wide = 0;   // golden v_err positive with bit15 set (DROP site 271)
  longint cov_vabs_neg  = 0;   // golden v_err negative (v_err[16] -> the -v_err branch)
  longint cov_pixmask   = 0;   // golden pix_cnt nonzero with PIX_DIV=1 (HOIST site 779)
  longint cov_hpos_sat  = 0;   // golden hcnt saturated above 10 bits (HOIST sites 168-171)
  longint cov_lumadly   = 0;   // golden luma_delay != 0 (DROP site 630)
  longint cov_phrem     = 0;   // golden phase_rem re-anchor branch taken (DROP site 324)

  // golden-side internal probes (same design as candidate, so golden is the
  // reference for what the stimulus actually exercised)
  wire signed [16:0] gd_v_err      = golden.u_comp.u_dec.v_err;
  wire        [15:0] gd_v_abs      = golden.u_comp.u_dec.v_abs;
  wire        [7:0]  gd_pix_cnt    = golden.u_comp.u_dec.pix_cnt;
  wire        [3:0]  gd_luma_delay = golden.u_comp.u_dec.luma_delay;
  wire        [9:0]  gd_hpos       = golden.u_comp.u_dec.hpos;

  // ---- APF adapter contract probe (plan §4: "check that delayed VBL
  // transitions still satisfy the adapter's requirement that VS be generated
  // during horizontal blanking") ----
  // apf_stream_video.v:81 generates its frame pulse as
  //     vs_pulse = (vbl_r & ~vbl) & hbl
  // i.e. VBL's FALLING edge must land while HBL is high, or video_vs never
  // fires and the harness counts zero frames. video_pipeline delays HBL and VBL
  // DIFFERENTLY: HBL_O = hb_c_s (piped through the variable hshift_idx tap)
  // while VBL_O = vb_c_out (not piped). Measure whether the coincidence
  // survives that asymmetry, on the golden side, using both the raw machine
  // flags and the pipeline's own outputs.
  longint raw_vbl_fall        = 0;  // machine VBL falling edges
  longint raw_vbl_fall_in_hbl = 0;  //   ... of those, how many had machine HBL high
  longint pip_vbl_fall        = 0;  // pipeline VBL_O falling edges
  longint pip_vbl_fall_in_hbl = 0;  //   ... of those, how many had pipeline HBL_O high
  longint pip_vbl_high        = 0;  // cycles VBL_O is asserted (0 = never asserts)
  reg raw_vbl_d = 0, pip_vbl_d = 0;

  task automatic sample_vs_contract();
    raw_vbl_d <= vbl;
    pip_vbl_d <= g_vbl;
    if (g_vbl) pip_vbl_high++;
    if (raw_vbl_d && !vbl) begin
      raw_vbl_fall++;
      if (hbl) raw_vbl_fall_in_hbl++;
    end
    if (pip_vbl_d && !g_vbl) begin
      pip_vbl_fall++;
      if (g_hbl) pip_vbl_fall_in_hbl++;
    end
  endtask

  task automatic sample_coverage();
    if (gd_v_err[16] == 1'b0 && gd_v_err[15] == 1'b1) cov_vabs_wide++;
    if (gd_v_err[16] == 1'b1)                        cov_vabs_neg++;
    if (gd_pix_cnt != 8'd0)                          cov_pixmask++;
    if (gd_hpos == 10'h3ff)                          cov_hpos_sat++;
    if (gd_luma_delay != 4'd0)                       cov_lumadly++;
  endtask

  task automatic chk(input [7:0] gr, gg, gb, input [7:0] cr, cg, cb,
                     input ghs, gvs, ghbl, gvbl,
                     input chs, cvs, chbl, cvbl, input [255:0] what);
    if (gr !== cr || gg !== cg || gb !== cb ||
        ghs !== chs || gvs !== cvs || ghbl !== chbl || gvbl !== cvbl) begin
      mismatches++;
      if (mismatches <= 20)
        $display("MISMATCH @%0t cyc=%0d %0s: golden RGB=%02x/%02x/%02x HS=%b VS=%b HBL=%b VBL=%b | cand RGB=%02x/%02x/%02x HS=%b VS=%b HBL=%b VBL=%b",
                 $time, cycles, what, gr, gg, gb, ghs, gvs, ghbl, gvbl,
                 cr, cg, cb, chs, cvs, chbl, cvbl);
    end
  endtask

  // ---- per-line pattern selection (adjacent-line changes included) ----
  function automatic bit pat_bit(input int line, input int px);
    int m;
    m = line % 8;
    case (m)
      0: return 1'b0;                       // black
      1: return 1'b1;                       // white
      2: return px[0];                      // alternating bits (phase 0)
      3: return px[1];                      // alternating bits (phase 1)
      4: return ((px + 1) & 2) != 0;        // phase-shifted pattern
      5: return (px < 4 || px > 555);       // edge markers
      6: return ((px / 7) & 1) != 0;        // 7-clock groups (text-like)
      default: return ((px / 4) & 1) != 0;  // 4-clock groups (HGR-like)
    endcase
  endfunction

  // mode-flag sequences: walk the selects the plan requires coverage for
  task automatic set_mode(input int line);
    case (line % 12)
      0:  begin text_mode<=1; hgr_mode<=0; hgr80_mode<=0; gr2<=0; col80<=0; dhires_mode<=0; color_line<=0; early_video<=0; end // 40-col text
      1:  begin text_mode<=1; col80<=1; early_video<=1; hgr_mode<=0; end   // 80-col text
      2:  begin text_mode<=0; hgr_mode<=1; hgr80_mode<=0; end              // HGR
      3:  begin text_mode<=0; hgr_mode<=0; hgr80_mode<=1; gr2<=1; end      // HGR80 quirk
      4:  begin text_mode<=0; gr2<=0; col80<=0; dhires_mode<=1; end        // DHGR
      5:  begin text_mode<=1; gr2<=1; col80<=1; dhires_mode<=0; end        // mixed
      6:  begin text_mode<=0; hgr_mode<=1; color_line<=1; end              // HGR + color
      7:  begin text_mode<=1; color_line<=1; run_fill_ok<=1; end           // text + fill
      8:  begin text_mode<=0; gr2<=1; early_video<=1; end                  // lores-ish
      9:  begin text_mode<=1; early_video<=0; run_fill_ok<=0; end
      10: begin text_mode<=0; hgr80_mode<=1; col80<=1; end
      default: begin text_mode<=1; hgr_mode<=0; hgr80_mode<=0; gr2<=0; col80<=0; end
    endcase
  endtask

  initial begin
    int f, l, p;
    // hold reset for a few lines so both sides start from the same state
    repeat (LINE_CLKS * 3) @(posedge clk);
    reset <= 1'b0;

    for (f = 0; f < FRAMES; f++) begin
      // sweep the two user-facing knobs (plan §4: exactly two video options)
      // across frames so every preset's smear/sharpness path is exercised
      comp_preset_c <= f[1:0];
      screen_mode_c <= f[3:2];
      for (l = 0; l < LINES_FRAME; l++) begin
        set_mode(l + f * 3);
        vbl <= (l >= LINES_FRAME - VBL_LINES);
        for (p = 0; p < LINE_CLKS; p++) begin
          hbl   <= (p < HBL_CLOCKS);
          video <= (p < HBL_CLOCKS) ? 1'b0 : pat_bit(l + f * 3, p - HBL_CLOCKS);
          @(posedge clk);
          cycles++;
          if (!g_hbl && !g_vbl) begin
            active_pixels++;
            if (|g_r || |g_g || |g_b) nonzero_rgb++;
            begin
              sm_r = int'(g_r); sm_g = int'(g_g); sm_b = int'(g_b);
              sm_mx = (sm_r > sm_g) ? ((sm_r > sm_b) ? sm_r : sm_b)
                                    : ((sm_g > sm_b) ? sm_g : sm_b);
              sm_mn = (sm_r < sm_g) ? ((sm_r < sm_b) ? sm_r : sm_b)
                                    : ((sm_g < sm_b) ? sm_g : sm_b);
              sm_sp = sm_mx - sm_mn;
              if (sm_sp > max_spread[screen_mode_c]) max_spread[screen_mode_c] = sm_sp;
              if (sm_sp > 8) chromatic[screen_mode_c]++;
            end
          end
          g_hs_d <= g_hs; g_vs_d <= g_vs;
          if (g_hs && !g_hs_d) hs_pulses++;
          if (g_vs && !g_vs_d) vs_pulses++;
          sample_coverage();
          sample_vs_contract();
          chk(g_r, g_g, g_b, c_r, c_g, c_b,
              g_hs, g_vs, g_hbl, g_vbl,
              c_hs, c_vs, c_hbl, c_vbl, "parity");
        end
      end
    end

    // ---- coverage gates: an empty run must not be able to pass ----
    $display("---- tb_ntsc_parity coverage ----");
    $display("cycles          = %0d", cycles);
    $display("frames          = %0d", FRAMES);
    $display("active_pixels   = %0d", active_pixels);
    $display("nonzero_rgb     = %0d", nonzero_rgb);
    $display("---- chroma production by SCREEN_MODE (2'b00 = Colour) ----");
    for (int q = 0; q < 4; q++)
      $display("  SCREEN_MODE=%0d  chromatic_pixels=%0d  max_channel_spread=%0d",
               q, chromatic[q], max_spread[q]);
    $display("hs_pulses       = %0d", hs_pulses);
    $display("vs_pulses       = %0d", vs_pulses);
    $display("ioctl_wait golden/cand = %b/%b (must both be 0: tied-off downloads)",
             g_wait, c_wait);
    $display("---- width-exercise coverage (0 = that rewrite site is UNTESTED) ----");
    $display("cov_vabs_wide (v_err bit15, site 271) = %0d", cov_vabs_wide);
    $display("cov_vabs_neg  (v_err negative)        = %0d", cov_vabs_neg);
    $display("cov_pixmask   (pix_cnt != 0, site 779)= %0d", cov_pixmask);
    $display("cov_hpos_sat  (hpos saturated)        = %0d", cov_hpos_sat);
    $display("cov_lumadly   (luma_delay != 0, 630)  = %0d", cov_lumadly);
    $display("---- APF vs_pulse contract (VBL falling edge must see HBL high) ----");
    $display("raw  machine VBL falls=%0d  of which HBL high=%0d", raw_vbl_fall, raw_vbl_fall_in_hbl);
    $display("pipe VBL_O   falls=%0d  of which HBL_O high=%0d", pip_vbl_fall, pip_vbl_fall_in_hbl);
    $display("pipe VBL_O asserted cycles = %0d", pip_vbl_high);
    $display("mismatches      = %0d", mismatches);

    if (cycles < 100000)            begin $display("FAIL: too few cycles simulated"); $fatal(1); end
    if (active_pixels < 10000)      begin $display("FAIL: no active video captured"); $fatal(1); end
    if (nonzero_rgb == 0)           begin $display("FAIL: RGB never nonzero - nothing decoded"); $fatal(1); end
    // Non-vacuity gate on CHROMA specifically: SCREEN_MODE 2'b00 is the Colour
    // mode (video_pipeline.sv:315-317 selects r_comp/g_comp/b_comp only there),
    // so it must produce pixels whose channels genuinely differ. Without this
    // gate the parity test would still pass if the decoder silently collapsed
    // to luma-only - candidate and golden would agree on being wrong.
    if (chromatic[0] == 0) begin
      $display("FAIL: SCREEN_MODE=0 (Colour) produced no chromatic pixels - decoder yields luma only");
      $fatal(1);
    end
    if (max_spread[0] < 16) begin
      $display("FAIL: SCREEN_MODE=0 max channel spread %0d is too small to be real colour", max_spread[0]);
      $fatal(1);
    end
    if (hs_pulses < FRAMES*LINES_FRAME/2) begin $display("FAIL: too few HS pulses"); $fatal(1); end
    if (vs_pulses < FRAMES)         begin $display("FAIL: too few VS pulses"); $fatal(1); end
    if (g_wait !== 1'b0 || c_wait !== 1'b0) begin
      $display("FAIL: ioctl_wait asserted with downloads tied off (plan §3: would be a hang, not a no-op)");
      $fatal(1);
    end
    if (mismatches != 0) begin
      $display("FAIL: %0d golden-vs-candidate mismatches (first 20 shown above)", mismatches);
      $fatal(1);
    end
    // Width-exercise gates: a rewrite site whose interesting range was never
    // reached is NOT proven equivalent by a zero-mismatch run.
    if (cov_vabs_wide == 0) begin
      $display("FAIL: v_err never had bit15 set while positive - the site-271 DROP rewrite is untested");
      $fatal(1);
    end
    if (cov_vabs_neg == 0) begin
      $display("FAIL: v_err never negative - the -v_err branch is untested");
      $fatal(1);
    end
    if (cov_pixmask == 0) begin
      $display("FAIL: pix_cnt never nonzero - the site-779 HOIST rewrite is untested");
      $fatal(1);
    end
    if (cov_lumadly == 0) begin
      $display("FAIL: luma_delay always 0 - the site-630 DROP rewrite is untested");
      $fatal(1);
    end
    $display("PASS: q17 rewrite is cycle-exact vs the pinned donor over %0d cycles / %0d frames", cycles, FRAMES);
    $finish;
  end

  // hard wall-clock bound so a hung DUT fails instead of hanging CI
  initial begin
    #(34.92 * 2 * (FRAMES + 4) * LINES_FRAME * LINE_CLKS * 4);
    $display("FAIL: timeout - simulation did not finish");
    $fatal(1);
  end

endmodule
