// tb_ovl_dbgrect.sv - verify the DBG_RECT hardware-diagnostic rectangle
//
// Instantiates sdram_status_overlay with .DBG_RECT(1) and checks:
//   1. rows 10..12, cols 100..149 are all white (50x3 rectangle)
//   2. every other captured pixel on those rows is black (rgb_in = 0)
//   3. the rectangle persists across two consecutive frames
//   4. the unconditional marker (rows 0..6) is still drawn alongside
//
// Raster model: same wide-blanking machine raster as tb_ovl_status
// (336 HBL + 560 active per line, 40 VBL lines at frame start,
// 40 visible lines; hbl/vbl registered one cycle).
//
// Self-driving; $fatal(1) on any violation (nonzero exit).

`timescale 1ns/10ps

module tb_ovl_dbgrect;

    localparam T_CLK  = 69.844;   // 14.31818 MHz
    localparam HBL_W  = 336;
    localparam ACT_W  = 560;
    localparam LINE   = HBL_W + ACT_W;   // 896
    localparam VBL_L  = 40;
    localparam FRAME  = 80 * LINE;       // 71680

    reg clk = 1'b0;
    reg reset;
    always #(T_CLK/2) clk = ~clk;

    // ---- wide-blanking raster (registered hbl/vbl) ----
    reg [16:0] fcyc;
    wire [15:0] lidx = fcyc / LINE;
    wire [15:0] ccyc = fcyc % LINE;
    wire in_vbl = (lidx < VBL_L);
    wire in_hbl = !in_vbl && (ccyc < HBL_W);
    reg hbl, vbl;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hbl  <= 1'b1;
            vbl  <= 1'b1;
            fcyc <= 17'd0;
        end else begin
            hbl  <= in_hbl;
            vbl  <= in_vbl;
            fcyc <= (fcyc == FRAME - 17'd1) ? 17'd0 : fcyc + 17'd1;
        end
    end

    // ---- DUT under test ----
    reg        res_valid_m;
    reg [1:0]  res_code_m, res_fail_m;
    reg [31:0] res_crc_m;
    reg [31:0] res_nbytes_m;
    reg [47:0] dbg_rc_m;
    reg [2:0]  dbg_fl_m;
    reg [2:0]  stage_m;
    wire [23:0] rgb_out;

    sdram_status_overlay #(.SHOW_CYCLES(4_000_000), .DBG_RECT(1)) dut (
        .clk(clk), .reset(reset),
        .rgb_in(24'd0), .hbl(hbl), .vbl(vbl), .rgb_out(rgb_out),
        .res_valid_m(res_valid_m), .res_code_m(res_code_m),
        .res_fail_m(res_fail_m), .res_crc_m(res_crc_m),
        .res_nbytes_m(res_nbytes_m),
        .dbg_rc_m(dbg_rc_m), .dbg_fl_m(dbg_fl_m), .stage_m(stage_m)
    );

    // ---- TB-side mirror of the DUT's counters ----
    reg hbl_md, vbl_mr;
    reg [9:0] m_col;
    reg [7:0] m_row;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hbl_md <= 1'b1; vbl_mr <= 1'b1;
            m_col <= 10'd0; m_row <= 8'd0;
        end else begin
            hbl_md <= hbl;
            vbl_mr <= vbl;
            if (vbl_mr && !vbl) begin
                m_col <= 10'd0;
                m_row <= 8'd0;
            end else begin
                if (hbl) m_col <= 10'd0;
                else     m_col <= m_col + 10'd1;
                if (!vbl && !hbl_md && hbl && m_row != 8'd191)
                    m_row <= m_row + 1;
            end
        end
    end

    integer errors;
    integer c;
    reg [23:0] px [0:559];

    // capture one physical line V (559 visible columns 1..559)
    task sample_line(input [7:0] V);
        integer i;
        integer wait_cyc;
        begin
            i = 0;
            wait_cyc = 0;
            while (i < 559) begin
                if (m_row == V && !hbl && m_col != 10'd0) begin
                    px[m_col] = rgb_out;
                    i = i + 1;
                    wait_cyc = 0;
                end else begin
                    wait_cyc = wait_cyc + 1;
                    if (wait_cyc > 150000) begin
                        $fatal(1, "sample_line timeout V=%0d m_row=%0d", V, m_row);
                    end
                end
                @(negedge clk);
            end
        end
    endtask

    // check rectangle row: cols 100..149 white, all others black
    task check_rect_row(input [7:0] V);
        integer x;
        begin
            sample_line(V);
            for (x = 0; x < 560; x = x + 1) begin
                if (x >= 100 && x < 150) begin
                    if (px[x] != 24'hFFFFFF) begin
                        errors = errors + 1;
                        $display("F rect row%0d col%0d: expected white, got %h",
                                 V, x, px[x]);
                    end
                end else begin
                    if (px[x] == 24'hFFFFFF) begin
                        errors = errors + 1;
                        $display("F rect row%0d col%0d: stray white", V, x);
                    end
                end
            end
        end
    endtask

    // check the marker box on row R: no white outside cols 4..27,
    // and at least one white pixel inside (marker is non-empty rows 0..6)
    task check_marker_row(input [7:0] R);
        integer x;
        reg any;
        begin
            sample_line(R);
            any = 1'b0;
            for (x = 0; x < 560; x = x + 1) begin
                if (x < 4 || x > 27) begin
                    if (px[x] == 24'hFFFFFF) begin
                        errors = errors + 1;
                        $display("F marker row%0d col%0d: stray white", R, x);
                    end
                end else begin
                    if (px[x] == 24'hFFFFFF) any = 1'b1;
                end
            end
            if (!any) begin
                errors = errors + 1;
                $display("F marker row%0d: no marker pixels (expected some)", R);
            end
        end
    endtask

    initial begin
        errors = 0;
        reset = 1'b1;
        res_valid_m = 1'b0; res_code_m = 2'd0; res_fail_m = 2'd0;
        res_crc_m = 32'd0; res_nbytes_m = 32'd0;
        dbg_rc_m = 48'd0; dbg_fl_m = 3'd0; stage_m = 3'd0;
        repeat (80) @(negedge clk);
        reset = 1'b0;
        // wait for the first visible line (before that m_row==0 is stale)
        while (vbl) @(negedge clk);
        repeat (2000) @(negedge clk);

        // frame 1: rectangle rows 10..12
        check_rect_row(8'd10);
        check_rect_row(8'd11);
        check_rect_row(8'd12);
        // marker rows 0..6 still drawn alongside (all 7 glyph rows)
        check_marker_row(8'd0);
        check_marker_row(8'd1);
        check_marker_row(8'd3);
        check_marker_row(8'd5);
        check_marker_row(8'd6);
        // row 8 (L1 band, no result) must be clean
        sample_line(8'd8);
        for (c = 0; c < 560; c = c + 1)
            if (px[c] == 24'hFFFFFF) begin
                errors = errors + 1;
                $display("F row8 col%0d: stray white (no result)", c);
            end

        // frame 2: rectangle persists (rows 11 + marker row 2)
        check_rect_row(8'd11);
        check_marker_row(8'd2);

        if (errors != 0)
            $fatal(1, "DBGRECT FAIL: %0d pixel violations", errors);
        $display("DBGRECT PASS: 50x3 rectangle on rows 10-12 (2 frames), marker intact, no strays");
        $finish;
    end

    initial begin
        #2_000_000_000;   // 2 s of simulation
        $fatal(1, "DBGRECT FAIL: watchdog");
    end

endmodule
