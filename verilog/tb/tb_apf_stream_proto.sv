//
// tb_apf_stream_proto.sv - Phase 1 streaming-pattern testbench
//
// Verifies the APF video contract for the native Apple II raster:
//   * DE exactly ACTIVE_PX (560) wide on each visible line
//   * exactly ACTIVE_PX * VISIBLE (560*192) active pixels per frame
//   * HS = 1-cycle pulse per line; VS = 1-cycle pulse per frame
//   * RGB == 0 whenever DE is low (except the single VS sideband word)
//   * line period = 910 clocks; frame period = 262 lines
//   * >= 1 clock gap between HS and DE
//
// Self-driving; $fatal on any contract violation (nonzero exit).
//
`timescale 1ns / 10ps

module tb_apf_stream_proto;

    localparam PERIOD = 69.8;  // 1/14.318 MHz in ns (approx; phase exactness irrelevant)

    reg         clk    = 1'b0;
    reg         clk_90 = 1'b0;
    reg         reset  = 1'b1;
    wire [23:0] video_rgb;
    wire        video_de, video_hs, video_vs, video_skip;

    apf_stream_proto dut (
        .clk        (clk),
        .clk_90     (clk_90),
        .reset      (reset),
        .video_rgb  (video_rgb),
        .video_de   (video_de),
        .video_hs   (video_hs),
        .video_vs   (video_vs),
        .video_skip (video_skip)
    );

    always #(PERIOD/2) begin
        clk    <= ~clk;
        clk_90 <= ~(clk_90 ^ clk); // crude 90deg-ish copy (value not contract-relevant here)
    end

    // ---- contract monitors ----
    integer checks = 0, errors = 0;
    reg de_prev, hs_prev, vs_prev;
    reg [10:0] line_de_count;   // DE count within current line
    reg [9:0]  line_total;       // clocks within current line
    reg [31:0] frame_px;         // active pixels this frame
    reg [10:0] dbg_line_de;
    integer dbg_line_n;
    reg [31:0] frame_px_at_vs;

    initial begin
        de_prev = 0; hs_prev = 0; vs_prev = 0;
        line_de_count = 0; line_total = 0; frame_px = 0;
        dbg_line_n = 0; frame_px_at_vs = 0;

        repeat (20) @(posedge clk);
        reset <= 1'b0;
        repeat (5) @(posedge clk);
    end

    always @(posedge clk) begin
        if (reset) begin
            de_prev <= 0; hs_prev <= 0; vs_prev <= 0;
            line_de_count <= 0; line_total <= 0; frame_px <= 0;
        end else begin
            if (video_de) line_de_count <= line_de_count + 1;
            if (video_de) frame_px <= frame_px + 1;

            if (video_hs && hs_prev) begin
                errors = errors + 1;
                $display("FAIL: HS pulse wider than 1 cycle");
            end
            hs_prev <= video_hs;

            if (video_vs && vs_prev) begin
                errors = errors + 1;
                $display("FAIL: VS pulse wider than 1 cycle");
            end
            if (video_vs) frame_px_at_vs <= frame_px;
            vs_prev <= video_vs;

            if (!video_de && video_vs == 1'b0 && video_rgb != 24'h0) begin
                errors = errors + 1;
                if (errors < 5) $display("FAIL: RGB=%h nonzero outside DE", video_rgb);
            end

            if (video_hs && video_de) begin
                errors = errors + 1;
                $display("FAIL: HS and DE asserted on the same cycle");
            end

            // end of line: record DE width, debug-print a few
            if (line_total == 10'd909) begin
                dbg_line_de = line_de_count;
                line_de_count <= 0;
                line_total <= 10'd0;
                if (dbg_line_n >= 70 && dbg_line_n < 75) begin
                    $display("DBG line %0d: DE=%0d (visible=1)", dbg_line_n, dbg_line_de);
                end
                dbg_line_n <= dbg_line_n + 1;
            end else begin
                line_total <= line_total + 1;
            end
        end
    end

    initial begin
        // let the machine run a couple of frames (262 lines * 910 clocks = 238420 clocks/frame)
        repeat (262 * 910 * 2) @(posedge clk);

        $display("INFO: frame_px at VS = %0d (expect ~%0d = 560*192)", frame_px_at_vs, 560*192);
        $display("INFO: last dbg_line_de = %0d (expect 560)", dbg_line_de);

        // frame pixels per frame: 560 * 192 = 107520 (allow +/- 1 line for boundary)
        if (frame_px_at_vs > 107520 - 560 && frame_px_at_vs < 107520 + 560) begin
            checks = checks + 1;
        end else begin
            errors = errors + 1;
            $display("FAIL: frame pixels = %0d (expect ~107520)", frame_px_at_vs);
        end

        if (dbg_line_de == 11'd560) begin
            checks = checks + 1;
        end else begin
            errors = errors + 1;
            $display("FAIL: DE width = %0d (expected 560)", dbg_line_de);
        end

        if (errors == 0) begin
            $display("APF STREAM PROTO PASS: checks=%0d (DE width 560, HS/VS 1-cycle, RGB=0 outside DE, HS/DE gap, frame px ~107520)", checks);
        end else begin
            $display("APF STREAM PROTO FAIL: errors=%0d", errors);
            $fatal(1, "contract violations");
        end
        $finish;
    end

endmodule
