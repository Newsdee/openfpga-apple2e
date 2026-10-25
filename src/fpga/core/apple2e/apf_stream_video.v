// apf_stream_video.v - Phase 2 streaming video adapter.
//
// Streams the OSK's composited 24-bit RGB (machine video + full-color OSK,
// with transparency) directly to the APF DDR video pad on the 14.318 MHz
// machine clock. No full-frame buffer, no PSRAM, no clock-domain crossing.
//
// DEC2X:
//   1 (default) - 2:1 horizontal decimation: the machine's 560-sample
//     raster is downsampled to 280 DE px/line (even samples), so the APF
//     sees the Apple II's logical 280x192 raster (better aspect on the
//     portrait Pocket screen; manifest must declare 280x192).
//     Implemented with a 280x24 ONE-LINE buffer: even samples are written
//     during the machine's active window and read back as a CONTIGUOUS
//     280-clock DE window during the following line's HBL. A strobed
//     (non-contiguous) DE was REJECTED on hardware (pink screen), so the
//     DE window must be contiguous like the Phase 1 pattern generator's.
//     Cost: ~1 M10K (line buffer only - no full-frame storage).
//   0 - native 560 px/line, direct passthrough (the proven Phase 2 path).
//
// APF video contract (verified in sim by tb_phase2_shots.sv and on
// hardware by the Phase 1 prototype):
//   - video_de: contiguous run of active pixels, 0 during blanking.
//   - video_hs: 1-cycle pulse, during blanking, never overlapping DE,
//     with a blank gap before the next DE.
//   - video_vs: 1-cycle pulse per frame, during blanking.
//   - video_rgb: 0 outside DE; RGB888 valid during DE.
//   - 16x16..800x720 active, 47-~61 Hz, pixel clock <= ~50 MHz.

module apf_stream_video (
    input  wire        clk,        // 14.318 MHz machine master clock
    input  wire        reset,      // async active-high reset
    input  wire [23:0] rgb_in,     // OSK-composited 24-bit RGB (machine + OSK)
    input  wire        hbl,        // machine HBL (1 = horizontal blanking)
    input  wire        vbl,        // machine VBL (1 = vertical blanking)

    // APF video outputs (14.318 MHz domain)
    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_hs,
    output reg         video_vs,
    output reg         video_skip
);

    // 1: 2:1 horizontal decimation (560 -> 280 DE px/line, even samples)
    // 0: native 560 px/line passthrough
    parameter DEC2X = 1;

    // ------------------------------------------------------------------
    // sync generation (identical for both modes - machine-anchored)
    // ------------------------------------------------------------------
    reg hbl_r, vbl_r;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hbl_r <= 1'b0;
            vbl_r <= 1'b0;
        end else begin
            hbl_r <= hbl;
            vbl_r <= vbl;
        end
    end

    // HBL rising edge = line start (always inside the ~350-clock HBL).
    wire hbl_rise = ~hbl_r & hbl;

    // HS fires 60 clocks AFTER the HBL rising edge (line start).
    //
    // 2026-10-25 (0.2.5): moved from 5 to 60 clocks to satisfy the APF
    // video contract "HS: one-cycle pulse per line, not until 3 cycles
    // after VS". Measured in the boot harness (run_vs4.log): the frame
    // line's VS pulse lands at ~hpos 42-47 (VBL_ALIGN=32 + pipeline
    // latency), which was AFTER the old hpos-5 HS - a contract violation.
    // The owner's 0.2.4 hardware test showed the first visible line
    // replaced by a fixed, content-independent subcarrier rainbow strip
    // (identical pixels on every colour screen) while lines 1..191 were
    // correct - consistent with the framework mis-tracking the frame
    // start on an HS-before-VS line. HS at hpos 60 keeps >= 13 cycles
    // after the latest observed VS position, stays well inside the
    // ~350-clock HBL window, and keeps a >= 300-clock gap before DE.
    // HS/VS never overlap, DE never overlaps HS, and the >=1-clock
    // DE-fall-to-next-HS gap grows to ~50 clocks.
    reg [6:0] hs_dly;
    always @(posedge clk or posedge reset) begin
        if (reset)                hs_dly <= 7'd0;
        else if (hbl_rise)        hs_dly <= 7'd1;
        else if (hs_dly < 7'd61)  hs_dly <= hs_dly + 7'd1;
        // else hold at 61
    end
    wire hs_pulse = (hs_dly == 7'd60);   // exactly one cycle

    // VBL falling edge = start of visible frame -> 1-cycle VS pulse.
    // Gated to HBL-high so a VS can only ever fire during blanking
    // (the frame-start line boundary is HBL-high by construction).
    wire vs_pulse = (vbl_r & ~vbl) & hbl;

    wire de_active = !hbl && !vbl;

    // ------------------------------------------------------------------
    // DEC2X line buffer: write even samples during the machine's active
    // window; read back a contiguous 280-clock window during the
    // following line's HBL (20 clocks after HS, inside the ~350-clock HBL,
    // finishing BEFORE the next line's writes start - no read/write
    // overlap). One display line of latency (constant, invisible).
    // ------------------------------------------------------------------
    reg [9:0]  wcnt;          // active-sample index within the line (0..559)
    wire [8:0] waddr = wcnt[9:1];   // 0..279 (full range, resets each line)
    wire       wr_en = de_active && !wcnt[0] && DEC2X;

    always @(posedge clk or posedge reset) begin
        if (reset)        wcnt <= 10'd0;
        else if (de_active) wcnt <= wcnt + 10'd1;
        else             wcnt <= 10'd0;
    end

    // The window opens RD_START clocks after HS (H=70..350 with the 0.2.5
    // hpos-60 HS): fully inside HBL, disjoint from the write phase (H=352+).
    // NOTE: RD_START was 20 with the old hpos-5 HS (H=25..304); it shrank to
    // 10 so the 280-clock window still ends before the HBL window closes at
    // hpos ~352 (60 + 10 + 280 = 350). DEC2X=1 is NOT the shipping mode
    // (DEC2X=0 ships); re-verify this window if DEC2X=1 is ever enabled.
    localparam [8:0] RD_START = 9'd10;   // read window opens RD_START clocks after HS
    localparam [8:0] RD_END   = RD_START + 280;
    reg [8:0]  rw;                      // read window position
    reg [8:0]  rptr;                     // buffer read pointer (0..279)
    wire       rd_win = (rw >= RD_START) && (rw < RD_END);

    // The window on machine line L displays the content written during
    // line L-1. Exactly 192 windows must appear per period: visible lines
    // 1..191 (content lines 0..190) plus the FIRST VBL line (content line
    // 191, the last visible line). The first visible line (the VS line) is
    // suppressed so no stale line is ever displayed. HS still fires on
    // every machine line (unchanged from the proven Phase 2 path).
    reg win_en_line;
    always @(posedge clk or posedge reset) begin
        if (reset)            win_en_line <= 1'b0;
        else if (hbl_rise)    win_en_line <= ~vbl_r | vbl_rise;
        // else hold for the duration of the line
    end
    wire vbl_rise = vbl & ~vbl_r;

    always @(posedge clk or posedge reset) begin
        if (reset)          rw <= 9'd0;
        else if (hs_pulse)  rw <= 9'd0;
        else if (rw < RD_END) rw <= rw + 9'd1;
        else             rw <= RD_END;   // hold until next HS
    end
    always @(posedge clk or posedge reset) begin
        if (reset)        rptr <= 9'd0;
        else if (rd_win)  rptr <= (rptr == 279) ? 9'd0 : rptr + 9'd1;
        else              rptr <= 9'd0;
    end

    // ------------------------------------------------------------------
    // APF output (registered)
    // ------------------------------------------------------------------
    // 280 x 24-bit one-line buffer: synchronous write, async (combinational)
    // read - Quartus infers an M10K from this idiom. Write the CURRENT
    // pixel directly (no wr_data staging register - that off-by-one was a
    // bug: the RAM would receive the previous even sample).
    reg  [23:0] line_ram [0:279];
    always @(posedge clk) begin
        if (wr_en) line_ram[waddr] <= rgb_in;
    end

    wire [23:0] buf_out;
    assign buf_out = DEC2X ? line_ram[rptr] : 24'h0;

    wire       de_out = DEC2X ? (rd_win & win_en_line) : de_active;
    wire [23:0] rgb_out = DEC2X ? buf_out : rgb_in;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            video_rgb  <= 24'h0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;
        end else begin
            // defaults: blanking (RGB=0 outside DE, per APF contract)
            video_rgb  <= 24'h0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;

            // HS: 1-cycle pulse during horizontal blanking, 5 clocks after
            // the line-start HBL rising edge; never overlaps DE.
            if (hs_pulse)
                video_hs <= 1'b1;

            // VS: 1-cycle pulse at the frame-start line boundary (blanking
            // by construction).
            if (vs_pulse)
                video_vs <= 1'b1;

            // DE: contiguous active window (560 native or 280 decimated).
            if (de_out) begin
                video_de  <= 1'b1;
                video_rgb <= rgb_out;
            end
        end
    end

    // 280 x 24-bit one-line buffer (declared above with the sync-write
    // always block; inferred M10K).

endmodule
