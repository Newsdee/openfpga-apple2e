// tb_osk_rgb_transparency.sv
//
// Proves the two things the boot harness CANNOT prove about the NTSC colour
// path (plan §5 N2 step 2, "make OSK RGB input compatible with every caller"):
//
//   1. TRANSPARENCY / CHROMA PRESERVATION. With RGB_IN=1 and the OSK closed,
//      video_rgb24 must equal rgb_in EXACTLY - including pixels whose R/G/B
//      channels differ. virtual_keyboard_overlay.sv:719 is combinational
//      (rgb_out = panel_pixel ? blend_color(...) : rgb_in), so with the panel
//      off this is a same-cycle identity. If the OSK collapsed the background
//      to luma, or re-expanded it from video_out's 1-bit collapse, colour
//      would be destroyed here and no downstream measurement could recover it.
//
//   2. FALLBACK UNCHANGED. With RGB_IN=0 (the default every pre-existing
//      caller uses), video_rgb24 must still be the original 1-bit expansion
//      video_in ? 24'hFFFFFF : 24'h000000. This is the plan's fallback
//      equivalence requirement at the OSK boundary, and it is the half that
//      protects apf_stream_proto_top, apple2e_core_top, tb_apf_video,
//      tb_p2b_shots and tb_phase2_shots from the new parameter.
//
// Why not just use the boot harness: DOS 3.3 boots to 40-column TEXT, which is
// monochrome on a real Apple II. Measured on the integrated build -
// GRAY: distinct_gray_levels=2, CHROMA: chromatic=0, max_spread=0 - so a text
// screen cannot distinguish "colour works" from "colour was destroyed". This TB
// drives chroma directly instead.
//
// Run: bash verilog/verilate_osk_transparency.sh
`default_nettype none
`timescale 1ns / 1ps

module tb_osk_rgb_transparency;

  localparam int HBL_CLOCKS = 132;   // machine-like horizontal blanking
  localparam int LINE_CLKS  = 912;   // 14.318 MHz line
  localparam int LINES      = 262;

  reg clk = 1'b0;
  always #34.9 clk = ~clk;           // ~14.318 MHz

  reg         reset = 1'b1;
  reg  [31:0] cont1_key = 32'd0;     // never opened: keeps panel_pixel = 0
  reg         video_in = 1'b0;
  reg         hblank = 1'b0;
  reg         vblank = 1'b0;
  reg  [23:0] rgb_in = 24'd0;
  reg         reads = 1'b0;

  wire        vout_a, vout_b;
  wire [23:0] rgb_a, rgb_b;          // a = RGB_IN 1 (NTSC), b = RGB_IN 0 (legacy)
  wire [7:0]  K_a, K_b;
  wire        akd_a, akd_b, oa_a, oa_b, ca_a, ca_b, cr_a, cr_b;

  // ---- DUT A: the NTSC glue path -----------------------------------------
  apple2e_osk #(.RGB_IN(1'b1)) u_rgb (
      .clk(clk), .reset(reset), .cont1_key(cont1_key),
      .video_in(video_in), .hblank(hblank), .vblank(vblank), .rgb_in(rgb_in),
      .video_out(vout_a), .video_rgb24(rgb_a),
      .K(K_a), .reads(reads), .akd(akd_a),
      .open_apple(oa_a), .closed_apple(ca_a), .command_reset(cr_a));

  // ---- DUT B: the legacy default every other caller uses ------------------
  apple2e_osk #(.RGB_IN(1'b0)) u_mono (
      .clk(clk), .reset(reset), .cont1_key(cont1_key),
      .video_in(video_in), .hblank(hblank), .vblank(vblank), .rgb_in(24'hzz_zzzz),
      .video_out(vout_b), .video_rgb24(rgb_b),
      .K(K_b), .reads(reads), .akd(akd_b),
      .open_apple(oa_b), .closed_apple(ca_b), .command_reset(cr_b));

  longint checked      = 0;
  longint fail_chroma  = 0;   // RGB_IN=1 did not pass rgb_in through
  longint fail_legacy  = 0;   // RGB_IN=0 did not match the 1-bit expansion
  longint chromatic_px = 0;   // non-vacuity: pattern pixels with real spread
  longint max_spread   = 0;
  reg [23:0] first_chroma = 24'd0;
  reg        got_first    = 1'b0;
  reg [23:0] first_fail_a = 24'd0, first_fail_b = 24'd0;
  reg [23:0] exp_b;

  int r, g, b, mx, mn, sp;

  // Chromatic test pattern: cycles through colours with large channel spread so
  // a luma-only collapse is caught immediately. Deliberately includes hues that
  // are NOT gray and NOT pure primaries, so a stuck channel also fails.
  function automatic [23:0] chroma_pat(input int x, input int y);
    case ((x + y * 7) % 6)
      0:       chroma_pat = 24'hFF0040;   // red-pink
      1:       chroma_pat = 24'h00C0FF;   // cyan-blue
      2:       chroma_pat = 24'h40FF00;   // green
      3:       chroma_pat = 24'h8040C0;   // violet
      4:       chroma_pat = 24'hFFA000;   // orange
      default: chroma_pat = 24'h2060A0;   // steel blue
    endcase
  endfunction

  int line_no, px;
  initial begin
    repeat (8) @(posedge clk);
    reset <= 1'b0;

    for (line_no = 0; line_no < LINES; line_no++) begin
      vblank <= (line_no >= LINES - 20);
      for (px = 0; px < LINE_CLKS; px++) begin
        hblank   <= (px < HBL_CLOCKS);
        video_in <= ((px + line_no) % 3) == 0;   // exercises the legacy expansion
        rgb_in   <= chroma_pat(px, line_no);
        @(posedge clk);
        // combinational overlay: compare in the same cycle the inputs are held
        if (!hblank && !vblank) begin
          checked++;
          // --- A: RGB_IN=1 must be an exact identity on the background ---
          if (rgb_a !== rgb_in) begin
            fail_chroma++;
            if (!got_first) first_fail_a <= rgb_a;
          end
          // --- B: RGB_IN=0 must be the original 1-bit expansion ---
          exp_b = video_in ? 24'hFFFFFF : 24'h000000;
          if (rgb_b !== exp_b) begin
            fail_legacy++;
            if (!got_first) first_fail_b <= rgb_b;
          end
          // --- non-vacuity bookkeeping on the pattern itself ---
          r = int'(rgb_in[23:16]); g = int'(rgb_in[15:8]); b = int'(rgb_in[7:0]);
          mx = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b);
          mn = (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b);
          sp = mx - mn;
          if (sp > max_spread) max_spread = sp;
          if (sp > 8) begin
            chromatic_px++;
            if (!got_first) begin first_chroma <= rgb_in; got_first <= 1'b1; end
          end
        end
      end
    end

    $display("---- tb_osk_rgb_transparency ----");
    $display("active pixels checked      = %0d", checked);
    $display("pattern chromatic pixels   = %0d  max_spread = %0d  first = %06X",
             chromatic_px, max_spread, first_chroma);
    $display("RGB_IN=1 identity failures = %0d", fail_chroma);
    $display("RGB_IN=0 expansion failures= %0d", fail_legacy);

    if (checked == 0) begin
      $display("FAIL: no active pixels sampled - test is vacuous"); $fatal(1);
    end
    if (chromatic_px == 0 || max_spread < 64) begin
      $display("FAIL: test pattern is not chromatic (max_spread=%0d) - cannot prove colour preservation",
               max_spread); $fatal(1);
    end
    if (fail_chroma != 0) begin
      $display("FAIL: RGB_IN=1 does not pass the background through - chroma destroyed by the OSK");
      $fatal(1);
    end
    if (fail_legacy != 0) begin
      $display("FAIL: RGB_IN=0 changed the legacy 1-bit expansion - existing callers would regress");
      $fatal(1);
    end
    $display("PASS: OSK preserves chroma with RGB_IN=1 and is bit-identical with RGB_IN=0");
    $finish;
  end

  // Watchdog
  initial begin
    #(200_000_000);
    $display("FAIL: watchdog timeout"); $fatal(1);
  end

endmodule

`default_nettype wire
