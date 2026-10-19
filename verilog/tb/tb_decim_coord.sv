// tb_decim_coord.sv - DETERMINISTIC PIXEL-CONTENT test for the DEC2X=1
// line-buffer decimator in apf_stream_video.v (per expert review
// EXPERT_BRIEF_PHASE2_280_SHIFT: "sim-clean" must mean pixel-correct,
// not just timing-clean).
//
// Drives a synthetic machine raster (no machine needed):
//   line  = 910 clocks: HBL(350) + ACTIVE(560)
//   frame = 262 lines:  VBL(70) + VISIBLE(192)
//   during ACTIVE of visible line L: rgb_in = {8'h00, L[7:0], s[9:0]}
//     where s = 0..559 is the machine sample index.
//
// The decimator must output, for displayed line L, pixel k (0..279):
//   {8'h00, L[7:0], 2k}   (even machine samples only, in order)
//
// ALL 280*192 = 53,760 pixels of each captured frame are checked
// (emphasis on k = 0,23,24,255,256,279 and first/last lines). Any
// mismatch is $fatal (first 10 reported). Also re-checks the APF
// contract basics (280 px/line, 192 lines/frame, HS/VS 1-cycle,
// RGB=0 outside DE).

`timescale 1ns / 1ps

module tb_decim_coord;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #1 clk = ~clk;   // period irrelevant; geometry counted in cycles

  // ------------------------------------------------------------------
  // synthetic machine raster
  // ------------------------------------------------------------------
  reg  [9:0] hc;
  reg  [8:0] vc;
  wire       hbl = (hc < 10'd350);
  wire       vbl = (vc < 9'd70);

  initial begin hc = 0; vc = 0; end
  always @(posedge clk) begin
    if (hc == 10'd909) begin
      hc <= 10'd0;
      vc <= (vc == 9'd261) ? 9'd0 : vc + 9'd1;
    end else begin
      hc <= hc + 10'd1;
    end
  end

  wire        act  = !hbl && !vbl;
  wire [9:0]  s    = hc - 10'd350;              // 0..559 during active
  wire [7:0]  lid  = vbl ? 8'd0 : vc[7:0] - 8'd70; // visible line 0..191
  wire [23:0] rgb_drv = act ? {8'h00, lid, s} : 24'h0;

  // ------------------------------------------------------------------
  // DUT (DEC2X=1: 280-px experiment)
  // ------------------------------------------------------------------
  reg  [23:0] o_rgb;
  wire        o_de, o_hs, o_vs, o_skip;
  apf_stream_video #(.DEC2X(1)) dut (
    .clk(clk), .reset(reset),
    .rgb_in(rgb_drv), .hbl(hbl), .vbl(vbl),
    .video_rgb(o_rgb), .video_de(o_de), .video_hs(o_hs),
    .video_vs(o_vs), .video_skip(o_skip)
  );

  // ------------------------------------------------------------------
  // APF-side capture (line = 280 contiguous DE px; frame = 192 lines)
  // ------------------------------------------------------------------
  reg [23:0] cur [0:191][0:279];
  reg [9:0]  cx, cy, fc;
  reg        de_d, pulse_err, overlap_err, nonde_err;
  reg [9:0]  bad_lines, bad_frames;

  initial begin
    cx = 0; cy = 0; fc = 0; de_d = 1'b0;
    pulse_err = 1'b0; overlap_err = 1'b0; nonde_err = 1'b0;
    bad_lines = 0; bad_frames = 0;
  end

  // HS/VS pulse width + HS/DE overlap + RGB outside DE
  reg hs_d, vs_d, o_de_d;
  always @(posedge clk) begin
    if (o_hs && hs_d) pulse_err <= 1'b1;
    if (o_vs && vs_d) pulse_err <= 1'b1;
    if (o_hs && o_de) overlap_err <= 1'b1;
    if (!o_de && o_de_d && o_rgb !== 24'h0) nonde_err <= 1'b1;
    hs_d <= o_hs; vs_d <= o_vs; o_de_d <= o_de;
  end

  integer pxerr, i, j;
  reg [23:0] exp_px, got;
  reg [9:0]  k;
  reg [7:0]  L;

  task check_frame;
    begin
      pxerr = 0;
      for (i = 0; i < 192; i = i + 1) begin
        L = i[7:0];
        for (j = 0; j < 280; j = j + 1) begin
          k = j[9:0];
          exp_px = {8'h00, L, k + k};   // even machine sample 2k
          got = cur[i][j];
          if (got !== exp_px) begin
            pxerr = pxerr + 1;
            if (pxerr <= 10)
              $display("  MISMATCH line=%0d px=%0d (emph=%0b) expect=%h got=%h",
                       i, j, (j==0)||(j==23)||(j==24)||(j==255)||(j==256)||(j==279),
                       exp_px, got);
          end
        end
      end
    end
  endtask

  always @(posedge clk) begin
    if (o_vs) begin
      if (fc >= 1) begin
        check_frame;
        if (pxerr > 0) begin
          $display("COORD frame %0d: %0d pixel mismatches", fc, pxerr);
          $fatal(1, "tb_decim_coord: pixel content FAILED");
        end
        if (bad_lines_n != 0 || frame_lines_n != 192)
          $fatal(1, "tb_decim_coord: geometry FAILED");
        $display("COORD frame %0d: 53,760/53,760 pixels correct", fc);
      end
      bad_lines_n <= 0; frame_lines_n <= 0;
      cy <= 0; cx <= 0;
      fc <= fc + 1;
    end else if (o_de) begin
      cur[cy][cx] = o_rgb;
      cx <= cx + 1;
    end else if (de_d) begin
      if (cx != 280) begin
        bad_lines_n <= bad_lines_n + 1;
        if (bad_lines_n < 3) $display("  bad line width: %0d", cx);
      end else frame_lines_n <= frame_lines_n + 1;
      cx <= 0;
      cy <= (cy == 191) ? 10'd191 : cy + 10'd1;
    end
    de_d <= o_de;
  end

  reg [9:0] bad_lines_n, frame_lines_n;

  // ------------------------------------------------------------------
  // run: reset ~1.5 lines, 3 full frames, then finish
  // ------------------------------------------------------------------
  initial begin
    repeat (1500) @(posedge clk);
    reset <= 1'b0;
  end

  initial begin
    @(posedge clk);
    repeat (3 * 262 * 910 + 1000) @(posedge clk);
    $display("COORD done: frames_checked=%0d pulse_err=%0b overlap_err=%0b nonde_err=%0b",
             fc - 1, pulse_err, overlap_err, nonde_err);
    if (pulse_err || overlap_err || nonde_err)
      $fatal(1, "tb_decim_coord: APF contract FAILED");
    $display("APF STREAM COORD PASS: pixel content verified (all 280 px x 192 lines per frame)");
    $finish;
  end

endmodule
