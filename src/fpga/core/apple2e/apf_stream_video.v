// apf_stream_video.v - Phase 2 streaming video adapter (NO frame buffer).
//
// Replaces the apf_video frame-buffer path. Takes the OSK's composited
// 24-bit RGB (machine video + full-color OSK, with transparency) and the
// machine's native HBL/VBL, and streams them directly to the APF DDR
// video pad on the 14.318 MHz machine clock. No M10K, no PSRAM, no
// clock-domain crossing.
//
// APF video contract (from the Pocket platform docs):
//   - video_de: 1 during active pixels, 0 during blanking.
//   - video_hs: 1-cycle pulse at the start of each line (HSYNC).
//   - video_vs: 1-cycle pulse at the start of each frame (VSYNC).
//   - video_rgb: 24-bit RGB888, valid during video_de.
//   - All signals synchronous to video_rgb_clock (the 14.318 MHz clock).
//
// The machine's native raster is 560 active px x 192 visible lines,
// 910 clocks/line, 262 lines/frame @ 14.318 MHz (~60 Hz). This is within
// the APF contract (active <= 800x720, 47-61 Hz, pixel clock <= 50 MHz).
//
// DE/HS/VS derivation:
//   - DE = ~hbl & ~vbl (active pixels, not blanking).
//   - HS = 1-cycle pulse at the HBL falling edge (start of active line).
//   - VS = 1-cycle pulse at the VBL falling edge (start of visible frame).
//   - HS and VS do not overlap (the VBL falling edge is not during HBL).
//
// This module is clocked by the 14.318 MHz machine clock (the same clock
// that drives the machine + OSK). No clock-domain crossing is needed.

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

    // --- blanking tracking (for HS/VS edge detection) ---
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

    // HBL rising edge = line start (always inside the 350-clock HBL).
    wire hbl_rise = ~hbl_r & hbl;

    // HS fires a fixed delay (5 clocks) AFTER the HBL rising edge - still
    // inside horizontal blanking, so HS never overlaps DE and keeps a
    // >=3-clock gap after VS (VS sits at the frame-start line boundary).
    // Machine-anchored: no free-running raster, no dropped pixels.
    reg [2:0] hs_dly;
    always @(posedge clk or posedge reset) begin
        if (reset)              hs_dly <= 3'd0;
        else if (hbl_rise)      hs_dly <= 3'd1;
        else if (hs_dly < 3'd6) hs_dly <= hs_dly + 3'd1;
        // else hold at 6
    end
    wire hs_pulse = (hs_dly == 3'd5);   // exactly one cycle

    // VBL falling edge = start of visible frame -> 1-cycle VS pulse.
    // Gated to HBL-high so a VS can only ever fire during blanking
    // (the frame-start line boundary is HBL-high by construction).
    wire vs_pulse = (vbl_r & ~vbl) & hbl;

    // --- APF output (registered) ---
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

            // DE: active pixels (not blanking).
            if (!hbl && !vbl) begin
                video_de  <= 1'b1;
                video_rgb <= rgb_in;
            end
        end
    end

endmodule
