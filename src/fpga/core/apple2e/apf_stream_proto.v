//
// apf_stream_proto.v - Phase 1 streaming-pattern prototype (EXPERIMENTAL)
//
// A separately-selectable test pattern generator that exercises the NATIVE
// Apple II raster streamed straight to the APF DDR pad (no frame buffer), per
// docs/NES_REFERENCE_STREAMING_RECOMMENDATION_2026-10-19.md.
//
// It is NOT part of the working core. The working path stays apf_video.v.
// This module is only instantiated by the Phase 1 prototype build / testbench.
//
// Geometry (measured from the P2a sim, hardware-verified): the machine's
// native raster is 560 active samples x 910 total/line x 262 lines at the
// 14.318 MHz master clock = 60.15 Hz. That sits inside the APF contract
// (active <= 800, pixel clock 1-50 MHz, 47-61 Hz), so it can be forwarded
// directly as the APF pixel stream.
//
// APF video rules honoured (see hardware-video-audio-input.md):
//   - video_rgb[23:0] : RGB888, all signals synchronous to video_rgb_clock.
//   - DE asserted once per line for exactly the active pixels.
//   - HS one-cycle pulse per line; not until 3 cycles after the VS pulse.
//   - VS one-cycle pulse per frame.
//   - >= 1 clock gap between HS and DE, and between DE fall and next HS.
//   - RGB must be 0 whenever DE is low, except the sideband word during VS.
//
// Pattern: seven SMPTE-ish colour bars (each ACTIVE/7 = 80 px wide) plus a
// 3-bit line id and a 12-bit frame id in the right-hand 40 px, so a capture
// can verify edges, colour channels, line cadence and frame count.
//
`timescale 1ns / 10ps

module apf_stream_proto (
    input  wire clk,      // 14.318 MHz machine master clock (APF pixel clock)
    input  wire clk_90,   // 90-degree phase-shifted copy (APF DDR clock pad)
    input  wire reset,    // async active-high reset

    output reg  [23:0] video_rgb,
    output reg  video_de,
    output reg  video_hs,
    output reg  video_vs,
    output reg  video_skip
);

    // ---- native raster geometry (measured, hardware-verified) ----
    localparam [9:0] LINE_CLKS  = 10'd910;  // total clocks per line
    localparam [9:0] ACTIVE_PX  = 10'd560;  // active pixels per line
    localparam [8:0] FRM_LINES  = 9'd262;   // total lines per frame
    localparam [8:0] VISIBLE    = 9'd192;   // visible (active) lines
    // VBL = FRM_LINES - VISIBLE = 70 lines (vertical blanking at top of frame)
    localparam [8:0] VBL_LINES  = FRM_LINES - VISIBLE; // 70

    localparam [9:0] HBLANK_PX  = LINE_CLKS - ACTIVE_PX; // 350

    // sync placement within a line:
    //   HS at clock 0 (or 3 for the first line after VS), gap at 1,
    //   DE from 2 .. 2+ACTIVE_PX-1, gap after DE, blanking to end of line.
    localparam [9:0] DE_START   = 10'd2;

    reg [9:0] clk_cnt;  // 0..LINE_CLKS-1
    reg [8:0] line_cnt; // 0..FRM_LINES-1

    // pattern ids
    reg [11:0] frame_id;

    // combinational (derived from the counters) - net types for Quartus 17
    wire        vbl;      // in vertical blanking (first VBL_LINES lines)

    // ---- counters ----
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            clk_cnt  <= 10'd0;
            line_cnt <= 9'd0;
            frame_id <= 12'd0;
        end else begin
            clk_cnt <= (clk_cnt == LINE_CLKS - 1) ? 10'd0 : clk_cnt + 10'd1;
            if (clk_cnt == LINE_CLKS - 1) begin
                line_cnt <= (line_cnt == FRM_LINES - 1) ? 9'd0 : line_cnt + 9'd1;
                if (line_cnt == FRM_LINES - 1)
                    frame_id <= frame_id + 12'd1;
            end
        end
    end

    assign vbl     = (line_cnt < VBL_LINES);
    // DE-relative pixel index (0..ACTIVE_PX-1) and bar selector.
    // 64-px bars (power-of-2, no divider): 7 bars = 448 px, then a
    // 112-px id region (line/frame counters) fills the remaining 112 px.
    wire [9:0] de_px   = clk_cnt - DE_START;
    wire [3:0] region  = de_px[9:6];   // 0..6 = 7 colour bars (64 px each),
                                       // 7..8 = id region (112 px)
    reg [23:0] bar_rgb;
    always @(*) begin
        case (region)
            4'd0: bar_rgb = 24'hFF0000; // red
            4'd1: bar_rgb = 24'h00FF00; // green
            4'd2: bar_rgb = 24'h0000FF; // blue
            4'd3: bar_rgb = 24'hFFFF00; // yellow
            4'd4: bar_rgb = 24'h00FFFF; // cyan
            4'd5: bar_rgb = 24'hFF00FF; // magenta
            4'd6: bar_rgb = 24'hFFFFFF; // white
            default: bar_rgb = 24'h000000; // id region (overwritten below)
        endcase
    end
    // id region colour: line id (low, changes each line) + frame id (high,
    // changes each frame), so a still capture shows one line's id and the
    // frame count, and the pattern shifts line-to-line and frame-to-frame.
    wire [23:0] id_rgb = {frame_id[7:0], line_cnt[7:0], 8'h00};

    // ---- sideband word (RGB during the VS pulse): frame-feature bits ----
    // [0] rescan previous frame, [1] interlaced, [2] odd field, [3] last field
    // All zero = rescan off, progressive, last field.
    localparam [23:0] VS_SIDE = 24'h0;

    // ---- APF output (registered) ----
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            video_rgb  <= 24'h0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;
        end else begin
            // defaults: blanking
            video_rgb  <= 24'h0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;

            // HS: one-cycle pulse. First line after VS at clock 3, else clock 0.
            if ((line_cnt == 9'd0 && clk_cnt == 10'd3) ||
                (line_cnt != 9'd0 && clk_cnt == 10'd0))
                video_hs <= 1'b1;

            // VS: one-cycle pulse at frame start (line 0, clock 0) + sideband.
            if (line_cnt == 9'd0 && clk_cnt == 10'd0) begin
                video_vs  <= 1'b1;
                video_rgb <= VS_SIDE;
            end

            // DE: active pixels, only on visible lines. (The DE is a
            // registered output, so the high run is (count of true cycles);
            // use ACTIVE_PX true cycles -> exactly ACTIVE_PX high cycles.)
            if (!vbl && clk_cnt >= DE_START && clk_cnt < DE_START + ACTIVE_PX) begin
                video_de <= 1'b1;
                if (region < 4'd7)
                    video_rgb <= bar_rgb;   // 7 colour bars (64 px each)
                else
                    video_rgb <= id_rgb;    // id region: line id + frame id
            end
        end
    end

endmodule
