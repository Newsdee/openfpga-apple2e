// tb_ntsc_reset_recovery.sv
//
// Plan §4a identifies this as THE most important new interaction:
//
//   "machine_reset gained a fourth source: wire machine_reset =
//    machine_reset_base | cold_reset_m; ... The pipeline's reset input is
//    machine_reset, so the NTSC encoder/decoder is now reset on EVERY
//    disk-change cold reboot, not just at power-on. N1's reset-recovery test
//    must cover a cold-reboot pulse mid-video, and N4 must verify colour
//    re-acquires after a disk swap. The plan's 2-frame recovery bound applies
//    to this path too."
//
// and §5 N1 step 4 requires: "Test reset during active video and blanking".
//
// This is a SEPARATE testbench from tb_ntsc_parity on purpose. The parity test
// needs frame-varying stimulus (it sweeps presets and modes); a recovery
// measurement needs a FIXED, exactly repeating stimulus, otherwise "recovered"
// has no definition - you cannot tell a decoder that has re-acquired from one
// that is still chasing a moving target.
//
// What it measures, rather than assumes (§7: "measure reset recovery instead of
// assuming every register resets"):
//   1. Frame stability BEFORE any reset. If the design's steady-state output is
//      not frame-to-frame identical under fixed stimulus, the whole recovery
//      question is meaningless - so this is a gate, not a formality.
//   2. Frames-to-exact-recovery after a reset pulse injected MID-ACTIVE-VIDEO
//      and, separately, DURING VERTICAL BLANKING. Compared against the
//      proposed 2-frame bound.
//   3. Raster legality across the reset: HS/VS must keep pulsing every frame
//      (§7: "If recovery needs a validity gate, preserve a legal output raster
//      while recovering"), and RGB must never go X.
//   4. Reset equivalence of the q17 rewrite: golden and candidate see the SAME
//      reset at the SAME cycle and must stay identical through it. Parity under
//      steady state does not imply parity under reset - the rewrite touched
//      signedness and width at 15 sites, and reset values are exactly where a
//      width change could silently differ.
//
// Run: bash verilog/verilate_ntsc_reset_recovery.sh
`default_nettype none
`timescale 1ns / 1ps

module tb_ntsc_reset_recovery;

  // ---- geometry: identical to tb_ntsc_parity (machine-like, not hcnt-exact) ----
  localparam int LINE_CLKS   = 912;
  localparam int HBL_CLOCKS  = 352;   // pre-sync 132 + post-sync 220
  localparam int ACTIVE      = LINE_CLKS - HBL_CLOCKS;   // 560
  localparam int LINES_FRAME = 262;
  localparam int VBL_LINES   = 54;    // must be >= 36 for vsync to regenerate
  localparam int FRAME_CYC   = LINE_CLKS * LINES_FRAME;

  // ---- reset injection parameters ----
  localparam int RST_CYCLES  = 16;    // a cold-reboot pulse, not a long hold
  localparam int WARM_FRAMES = 3;
  localparam int RST_LINE_ACT = 100;  // mid-active-video injection point
  localparam int RST_PX_ACT   = 300;
  localparam int RST_LINE_VB  = LINES_FRAME - 20;   // inside the VBL tail
  localparam int RST_PX_VB    = 40;
  localparam int POST_FRAMES  = 6;    // frames observed after each injection
  localparam int PROPOSED_BOUND = 2;  // plan's proposed recovery bound

  reg clk = 1'b0;
  always #34.9 clk = ~clk;            // ~14.318 MHz

  // ---- FIXED stimulus: never varies with frame index ----
  reg         reset       = 1'b1;
  reg         machine_ce  = 1'b1;
  reg         video       = 1'b0;
  reg         hbl         = 1'b0;
  reg         vbl         = 1'b0;
  // HGR with colour on: the mode that actually produces NTSC artefact colour.
  reg         color_line  = 1'b1;
  reg         text_mode   = 1'b0;
  reg         hgr_mode    = 1'b1;
  reg         hgr80_mode  = 1'b0;
  reg         gr2         = 1'b0;
  reg         col80       = 1'b0;
  reg         dhires_mode = 1'b0;
  reg         early_video = 1'b0;
  reg         run_fill_ok = 1'b0;
  // The two user-facing knobs held constant: Colour + Calibrated.
  wire [1:0]  screen_mode = 2'b00;
  wire [1:0]  comp_preset = 2'b00;

  wire [7:0] g_r, g_g, g_b, c_r, c_g, c_b;
  wire       g_hs, g_vs, g_hbl, g_vbl, c_hs, c_vs, c_hbl, c_vbl;
  wire       g_wait, c_wait;

  video_pipeline golden (
    .CLK_14M(clk), .VIDEO(video), .HBL(hbl), .VBL(vbl),
    .COLOR_LINE(color_line), .TEXT_MODE(text_mode), .LO_RES_TEXT(1'b1),
    .SCREEN_MODE(screen_mode), .COLOR_PALETTE(2'd0),
    .RUN_FILL_OK(run_fill_ok), .NTSC_VERTICAL_COMB(1'b1),
    .EARLY_VIDEO(early_video), .HGR_MODE(hgr_mode), .HGR80_MODE(hgr80_mode),
    .GR2(gr2), .COL80(col80), .DHIRES_MODE(dhires_mode),
    .ioctl_addr(25'd0), .ioctl_data(8'd0), .ioctl_index(8'd0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_wait(g_wait),
    .reset(reset), .machine_ce(machine_ce),
    .use_composite(1'b1), .comp_preset(comp_preset), .comp_hue_adj(5'd0),
    .comp_bright_st(2'd0), .comp_sat_st(2'd0), .comp_contrast_st(2'd0),
    .R(g_r), .G(g_g), .B(g_b), .HS(g_hs), .VS(g_vs),
    .HBL_O(g_hbl), .VBL_O(g_vbl)
  );

  video_pipeline_q17 candidate (
    .CLK_14M(clk), .VIDEO(video), .HBL(hbl), .VBL(vbl),
    .COLOR_LINE(color_line), .TEXT_MODE(text_mode), .LO_RES_TEXT(1'b1),
    .SCREEN_MODE(screen_mode), .COLOR_PALETTE(2'd0),
    .RUN_FILL_OK(run_fill_ok), .NTSC_VERTICAL_COMB(1'b1),
    .EARLY_VIDEO(early_video), .HGR_MODE(hgr_mode), .HGR80_MODE(hgr80_mode),
    .GR2(gr2), .COL80(col80), .DHIRES_MODE(dhires_mode),
    .ioctl_addr(25'd0), .ioctl_data(8'd0), .ioctl_index(8'd0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_wait(c_wait),
    .reset(reset), .machine_ce(machine_ce),
    .use_composite(1'b1), .comp_preset(comp_preset), .comp_hue_adj(5'd0),
    .comp_bright_st(2'd0), .comp_sat_st(2'd0), .comp_contrast_st(2'd0),
    .R(c_r), .G(c_g), .B(c_b), .HS(c_hs), .VS(c_vs),
    .HBL_O(c_hbl), .VBL_O(c_vbl)
  );

  // ---- one frame of reference RGB (238,944 x 24 bits ~ 717 KB) ----
  logic [23:0] ref_px [0:LINES_FRAME*LINE_CLKS-1];

  longint cycles = 0;
  // steady-state / recovery bookkeeping
  longint pre_mismatch   = 0;   // frames 4-5 vs ref: must be 0 (stability gate)
  longint x_seen         = 0;   // any X on RGB/HS/VS/HBL/VBL, ever
  longint parity_reset_mismatch = 0;  // golden vs candidate divergence
  longint first_parity_mismatch = -1;
  // raster legality per frame
  int     hs_this_frame  = 0;
  int     vs_this_frame  = 0;
  longint raster_bad_frames = 0;
  // recovery measurement, per injection site
  int     recov_active   = -1;  // frames after release until an exact full frame
  int     recov_blank    = -1;
  longint recov_active_mismatch_first = 0;
  longint recov_blank_mismatch_first  = 0;
  // ---- non-vacuity: the injection must PROVABLY perturb the output ----
  // "Recovered in 1 frame" is worthless if the reset changed nothing. Count the
  // pixels in the injection frame that differ from the reference after release,
  // and the cycle offset of the LAST such pixel, which gives line-level recovery
  // precision instead of whole-frame granularity.
  longint inject_bad        = 0;   // bad pixels in the current injection frame
  longint inject_bad_active = 0;   //   ... site 0 (active video)
  longint inject_bad_blank  = 0;   //   ... site 1 (vertical blanking)
  longint inject_last_bad   = -1;  // last differing idx after release
  longint inject_last_active = -1;
  longint inject_last_blank  = -1;
  bit     release_seen      = 1'b0;

  reg g_hs_d = 0, g_vs_d = 0;

  // fixed per-line pattern: depends on line and pixel ONLY, never on frame
  function automatic bit pat_bit(input int line, input int px);
    case (line % 8)
      0:       pat_bit = 1'b0;
      1:       pat_bit = 1'b1;
      2:       pat_bit = px[0];                 // colour phase 0
      3:       pat_bit = px[1];                 // colour phase 1
      4:       pat_bit = ((px + 1) & 2) != 0;   // phase-shifted
      5:       pat_bit = (px < 4 || px > 555);  // edge markers
      6:       pat_bit = ((px / 7) & 1) != 0;   // text-like groups
      default: pat_bit = ((px / 4) & 1) != 0;   // HGR-like groups
    endcase
  endfunction

  // ---- mode/state of the current frame, expressed as an enum for clarity ----
  typedef enum { PH_WARM, PH_RECORD, PH_STABLE, PH_INJECT, PH_RECOVER } phase_e;
  phase_e phase = PH_WARM;

  int  f, l, p, idx;
  int  inject_at_line, inject_at_px, frames_since_release;
  int  site;                       // 0 = active video, 1 = vertical blanking
  longint frame_mismatches;
  bit  recovered_yet;
  longint mismatch_at_recovery;

  task automatic check_x();
    if (^{g_r, g_g, g_b} === 1'bx || ^{c_r, c_g, c_b} === 1'bx ||
        g_hs === 1'bx || g_vs === 1'bx || g_hbl === 1'bx || g_vbl === 1'bx)
      x_seen++;
  endtask

  task automatic check_parity();
    if (g_r !== c_r || g_g !== c_g || g_b !== c_b ||
        g_hs !== c_hs || g_vs !== c_vs || g_hbl !== c_hbl || g_vbl !== c_vbl) begin
      parity_reset_mismatch++;
      if (first_parity_mismatch < 0) first_parity_mismatch = cycles;
    end
  endtask

  initial begin
    // ---- release the power-on reset, then warm up ----
    site = 0;                       // injection site 0 = mid-active-video
    repeat (LINE_CLKS * 3) @(posedge clk);
    reset <= 1'b0;

    for (f = 0; f < WARM_FRAMES + 2 + 1 + POST_FRAMES; f++) begin
      // decide this frame's role
      if (f < WARM_FRAMES)            phase = PH_WARM;
      else if (f == WARM_FRAMES)      phase = PH_RECORD;
      else if (f <= WARM_FRAMES + 1)  phase = PH_STABLE;
      else if (f == WARM_FRAMES + 2)  phase = PH_INJECT;
      else                            phase = PH_RECOVER;

      hs_this_frame = 0;
      vs_this_frame = 0;
      frame_mismatches = 0;

      for (l = 0; l < LINES_FRAME; l++) begin
        vbl <= (l >= LINES_FRAME - VBL_LINES);
        for (p = 0; p < LINE_CLKS; p++) begin
          hbl   <= (p < HBL_CLOCKS);
          video <= (p < HBL_CLOCKS) ? 1'b0 : pat_bit(l, p - HBL_CLOCKS);

          // ---- reset injection: mid-frame, site 0 (active video) ----
          if (phase == PH_INJECT && site == 0 &&
              l == RST_LINE_ACT && p == RST_PX_ACT) begin
            reset <= 1'b1;
            repeat (RST_CYCLES) @(posedge clk);
            reset <= 1'b0;
            frames_since_release = 0;
            recovered_yet = 1'b0;
            release_seen = 1'b1;
            inject_bad = 0;
            inject_last_bad = -1;
          end

          @(posedge clk);
          cycles++;
          idx = l * LINE_CLKS + p;

          check_x();
          check_parity();

          g_hs_d <= g_hs; g_vs_d <= g_vs;
          if (g_hs && !g_hs_d) hs_this_frame++;
          if (g_vs && !g_vs_d) vs_this_frame++;

          case (phase)
            PH_RECORD: ref_px[idx] <= {g_r, g_g, g_b};
            PH_STABLE, PH_RECOVER: begin
              if ({g_r, g_g, g_b} !== ref_px[idx]) begin
                frame_mismatches++;
                if (phase == PH_STABLE) pre_mismatch++;
              end
            end
            PH_INJECT: begin
              // measure the damage the reset actually did (post-release only)
              if (release_seen && {g_r, g_g, g_b} !== ref_px[idx]) begin
                inject_bad++;
                inject_last_bad = idx;
              end
            end
            default: ;
          endcase
        end
      end

      // ---- end-of-frame accounting ----
      if (hs_this_frame == 0 || vs_this_frame == 0) begin
        raster_bad_frames++;
        $display("RASTER ILLEGAL in frame %0d (phase %0s): hs_pulses=%0d vs_pulses=%0d",
                 f, phase.name(), hs_this_frame, vs_this_frame);
      end

      if (phase == PH_INJECT && site == 0) begin
        inject_bad_active = inject_bad;
        inject_last_active = inject_last_bad;
      end

      if (phase == PH_STABLE && frame_mismatches != 0)
        $display("UNSTABLE pre-reset frame %0d: %0d pixels differ from the reference",
                 f, frame_mismatches);

      if (phase == PH_RECOVER) begin
        frames_since_release++;
        if (!recovered_yet) begin
          if (frame_mismatches == 0) begin
            recovered_yet = 1'b1;
            recov_active = frames_since_release;
          end else if (frames_since_release == 1) begin
            recov_active_mismatch_first = frame_mismatches;
          end
        end
      end
    end

    // ================= site 1: reset during vertical blanking ==============
    // Same sequence, injected inside the VBL tail. Resetting during blanking is
    // the easier case, so if it is WORSE than the active-video case something is
    // wrong with the model of the design.
    site = 1;
    for (f = 0; f < WARM_FRAMES + 2 + 1 + POST_FRAMES; f++) begin
      if (f < WARM_FRAMES)            phase = PH_WARM;
      else if (f == WARM_FRAMES)      phase = PH_RECORD;
      else if (f <= WARM_FRAMES + 1)  phase = PH_STABLE;
      else if (f == WARM_FRAMES + 2)  phase = PH_INJECT;
      else                            phase = PH_RECOVER;

      hs_this_frame = 0;
      vs_this_frame = 0;
      frame_mismatches = 0;

      for (l = 0; l < LINES_FRAME; l++) begin
        vbl <= (l >= LINES_FRAME - VBL_LINES);
        for (p = 0; p < LINE_CLKS; p++) begin
          hbl   <= (p < HBL_CLOCKS);
          video <= (p < HBL_CLOCKS) ? 1'b0 : pat_bit(l, p - HBL_CLOCKS);

          if (phase == PH_INJECT &&
              l == RST_LINE_VB && p == RST_PX_VB) begin
            reset <= 1'b1;
            repeat (RST_CYCLES) @(posedge clk);
            reset <= 1'b0;
            frames_since_release = 0;
            recovered_yet = 1'b0;
            release_seen = 1'b1;
            inject_bad = 0;
            inject_last_bad = -1;
          end

          @(posedge clk);
          cycles++;
          idx = l * LINE_CLKS + p;

          check_x();
          check_parity();

          g_hs_d <= g_hs; g_vs_d <= g_vs;
          if (g_hs && !g_hs_d) hs_this_frame++;
          if (g_vs && !g_vs_d) vs_this_frame++;

          case (phase)
            PH_RECORD: ref_px[idx] <= {g_r, g_g, g_b};
            PH_STABLE, PH_RECOVER: begin
              if ({g_r, g_g, g_b} !== ref_px[idx]) begin
                frame_mismatches++;
                if (phase == PH_STABLE) pre_mismatch++;
              end
            end
            PH_INJECT: begin
              if (release_seen && {g_r, g_g, g_b} !== ref_px[idx]) begin
                inject_bad++;
                inject_last_bad = idx;
              end
            end
            default: ;
          endcase
        end
      end

      if (hs_this_frame == 0 || vs_this_frame == 0) begin
        raster_bad_frames++;
        $display("RASTER ILLEGAL in blanking-site frame %0d (phase %0s): hs=%0d vs=%0d",
                 f, phase.name(), hs_this_frame, vs_this_frame);
      end

      if (phase == PH_INJECT) begin
        inject_bad_blank = inject_bad;
        inject_last_blank = inject_last_bad;
      end

      if (phase == PH_RECOVER) begin
        frames_since_release++;
        if (!recovered_yet) begin
          if (frame_mismatches == 0) begin
            recovered_yet = 1'b1;
            recov_blank = frames_since_release;
          end else if (frames_since_release == 1) begin
            recov_blank_mismatch_first = frame_mismatches;
          end
        end
      end
    end

    // ============================ report ==================================
    $display("---- tb_ntsc_reset_recovery ----");
    $display("cycles simulated          = %0d", cycles);
    $display("reset pulse               = %0d cycles, site0 = line %0d px %0d (ACTIVE VIDEO)",
             RST_CYCLES, RST_LINE_ACT, RST_PX_ACT);
    $display("                          site1 = line %0d px %0d (VERTICAL BLANKING)",
             RST_LINE_VB, RST_PX_VB);
    $display("pre-reset stability       = %0d mismatching pixels (MUST be 0)", pre_mismatch);
    $display("X values observed         = %0d", x_seen);
    $display("frames with dead raster   = %0d (hs or vs never pulsed)", raster_bad_frames);
    $display("recovery, active video    = %0d frames  (first post-reset frame had %0d bad pixels)",
             recov_active, recov_active_mismatch_first);
    $display("recovery, vertical blank  = %0d frames  (first post-reset frame had %0d bad pixels)",
             recov_blank, recov_blank_mismatch_first);
    // damage the injection actually caused, and where output last differed
    $display("damage, active-video site = %0d bad pixels in the injection frame; last bad idx=%0d (line %0d px %0d)",
             inject_bad_active, inject_last_active,
             inject_last_active < 0 ? -1 : inject_last_active / LINE_CLKS,
             inject_last_active < 0 ? -1 : inject_last_active % LINE_CLKS);
    $display("damage, blanking site     = %0d bad pixels in the injection frame; last bad idx=%0d (line %0d px %0d)",
             inject_bad_blank, inject_last_blank,
             inject_last_blank < 0 ? -1 : inject_last_blank / LINE_CLKS,
             inject_last_blank < 0 ? -1 : inject_last_blank % LINE_CLKS);
    $display("proposed bound            = %0d frames", PROPOSED_BOUND);
    $display("q17 parity mismatches     = %0d  (first at cycle %0d)",
             parity_reset_mismatch, first_parity_mismatch);
    $display("ioctl_wait golden/cand    = %b/%b (must both be 0)", g_wait, c_wait);

    // ---- gates: an empty or degenerate run must FAIL, not pass ----
    // NON-VACUITY: if the mid-active-video reset perturbed nothing, "recovered in
    // 1 frame" is a statement about a design that was never disturbed, and the
    // plan's most-important interaction (§4a: the pipeline is reset on every
    // disk-change cold reboot) would remain untested while looking tested.
    if (inject_bad_active == 0) begin
      $display("FAIL: the mid-active-video reset changed no output pixel - the recovery result is vacuous");
      $fatal(1);
    end
    if (pre_mismatch != 0) begin
      $display("FAIL: steady state is not frame-stable, so 'recovered' is undefined");
      $fatal(1);
    end
    if (x_seen != 0) begin
      $display("FAIL: X propagated to the output across reset");
      $fatal(1);
    end
    if (raster_bad_frames != 0) begin
      $display("FAIL: raster not preserved across reset (plan requires a legal raster while recovering)");
      $fatal(1);
    end
    if (recov_active < 0) begin
      $display("FAIL: never recovered exactly after a mid-active-video reset within %0d frames",
               POST_FRAMES);
      $fatal(1);
    end
    if (recov_blank < 0) begin
      $display("FAIL: never recovered exactly after a vertical-blanking reset within %0d frames",
               POST_FRAMES);
      $fatal(1);
    end
    if (parity_reset_mismatch != 0) begin
      $display("FAIL: q17 rewrite diverges from the donor under reset - steady-state parity does not cover this");
      $fatal(1);
    end
    if (g_wait !== 1'b0 || c_wait !== 1'b0) begin
      $display("FAIL: ioctl_wait asserted with no host transfer in progress");
      $fatal(1);
    end
    if (recov_active > PROPOSED_BOUND || recov_blank > PROPOSED_BOUND)
      $display("NOTE: measured recovery EXCEEDS the proposed %0d-frame bound - the plan asks for this to be measured and any required relaxation reviewed, not silently accepted",
               PROPOSED_BOUND);

    $display("PASS: reset recovery measured - active video %0d frame(s), blanking %0d frame(s); raster legal throughout; q17 rewrite reset-equivalent",
             recov_active, recov_blank);
    $finish;
  end

  initial begin
    #(60_000_000_000);   // generous: ~2 x 26 frames x 239k cycles x 70ns
    $display("FAIL: watchdog timeout");
    $fatal(1);
  end

endmodule

`default_nettype wire
