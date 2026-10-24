//
// tb_ovl_status.sv - raster-level test for sdram_status_overlay
//
// Replaces the Unit-7 TB, whose raster model was WRONG: it drove a
// one-clock hbl pulse, but the machine's m_hbl is a WIDE blanking
// interval (~336 machine clocks/line, 24 H-slots x 14 masters - see
// machine/timing_generator.v: HBL = ~(H[5] | (H[3] & H[4])) with the H
// counter ticking per H-slot, and apf_video.v MAX_CAP = 560 = "40
// H-slots x 14 masters"). The overlay's row counter must therefore be
// edge-based (once per HBL rising edge) exactly like the
// hardware-verified OSK overlay and apf_video's vline counter. This TB
// drives the real shape: 336-cycle blank + 560 active samples/line,
// 40-line VBL at frame start, 40 visible lines.
//
// Exact-pixel checking (per the 2026-10-20 expert review): every
// rendered glyph is compared pixel-for-pixel against an INDEPENDENT
// 5x7 reference transcription (not a white-pixel count), all 16 hex
// digits are exercised in one result, counter values include a
// low-nibble case (128 -> "000080"), and each fault flag is tested
// individually.
//
`timescale 1ns/10ps

module tb_ovl_status;

    localparam HBL_W = 336;      // wide blanking (machine H-slots x 14)
    localparam ACT_W = 560;      // active samples/line (apf_video MAX_CAP)
    localparam LINE  = HBL_W + ACT_W;
    localparam VBL_L = 40;       // vbl lines at frame start
    localparam VIS_L = 110;      // visible lines per frame (must reach the
                                 // fingerprint rows 65..95 for T7)
    localparam FRAME = (VBL_L + VIS_L) * LINE;

    localparam T_CLK = 69.844;   // 14.31818 MHz

    reg clk = 1'b0;
    reg reset = 1'b1;
    always #(T_CLK/2) clk = ~clk;

    // ---- raster driver (free-running) ----
    reg [16:0] fcyc;
    wire [15:0] lidx = fcyc / LINE;
    wire [15:0] ccyc = fcyc % LINE;
    wire in_vbl = (lidx < VBL_L);
    wire in_hbl = !in_vbl && (ccyc < HBL_W);
    reg hbl, vbl;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hbl <= 1'b1;
            vbl <= 1'b1;
            fcyc <= 17'd0;
        end else begin
            hbl <= in_hbl;
            vbl <= in_vbl;
            fcyc <= (fcyc == FRAME - 17'd1) ? 17'd0 : fcyc + 17'd1;
        end
    end



    // ---- DUT (short window: ~33 lines) ----
    reg        res_valid_m;
    reg [1:0]  res_code_m, res_fail_m;
    reg [31:0] res_crc_m, res_nbytes_m;
    reg [47:0] dbg_rc_m;
    reg [2:0]  dbg_fl_m;
    reg [2:0]  stage_m;
    reg [127:0] fp_first_r, fp_last_r, fp_w_r;
    wire [23:0] rgb_out;

    sdram_status_overlay #(.SHOW_CYCLES(4_000_000), .SHOW_FP(1)) dut (
        .clk(clk), .reset(reset),
        .rgb_in(24'd0), .hbl(hbl), .vbl(vbl), .rgb_out(rgb_out),
        .res_valid_m(res_valid_m), .res_code_m(res_code_m),
        .res_fail_m(res_fail_m), .res_crc_m(res_crc_m),
        .res_nbytes_m(res_nbytes_m),
        .dbg_rc_m(dbg_rc_m), .dbg_fl_m(dbg_fl_m), .stage_m(stage_m),
        .fp_first(fp_first_r), .fp_last(fp_last_r), .fp_w(fp_w_r)
    );

    // ---- T8 DUT: default parameters (SHOW_FP=0 - the shipping build) ----
    // Same inputs as the main DUT; the fingerprint lines (rows 65..95) must
    // be blank while every other line stays pixel-identical.
    wire [23:0] rgb_off;
    sdram_status_overlay dut_off (
        .clk(clk), .reset(reset),
        .rgb_in(24'd0), .hbl(hbl), .vbl(vbl), .rgb_out(rgb_off),
        .res_valid_m(res_valid_m), .res_code_m(res_code_m),
        .res_fail_m(res_fail_m), .res_crc_m(res_crc_m),
        .res_nbytes_m(res_nbytes_m),
        .dbg_rc_m(dbg_rc_m), .dbg_fl_m(dbg_fl_m), .stage_m(stage_m),
        .fp_first(fp_first_r), .fp_last(fp_last_r), .fp_w(fp_w_r)
    );

    // ---- TB-side mirror of the DUT's counters (from the hbl/vbl the
    // DUT actually sees) ----
    reg hbl_md, vbl_mr;
    reg [9:0] m_col;
    reg [7:0] m_row;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hbl_md <= 1'b1; vbl_mr <= 1'b1; m_col <= 10'd0; m_row <= 8'd0;
        end else begin
            hbl_md <= hbl;
            vbl_mr <= vbl;
            if (vbl_mr && !vbl) begin
                m_col <= 10'd0;
                m_row <= 8'd0;
            end else begin
                if (hbl) m_col <= 10'd0;
                else     m_col <= m_col + 10'd1;
                // DUT counts on the HBL RISING edge (active->blank, end
                // of the line): !prev && cur
                if (!vbl && !hbl_md && hbl && m_row != 8'd191)
                    m_row <= m_row + 8'd1;
            end
        end
    end


    // ---- independent 5x7 reference font (transcribed row by row;
    // bit 4 = leftmost pixel). Only the glyphs the DUT must show. ----
    function [4:0] refg;
        input [4:0] g;
        input [2:0] r;
        begin
            case (g)
                5'd0  : refg = (r==0)?5'b00111:(r==1)?5'b01001:(r==2)?5'b01010:
                          (r==3)?5'b01100:(r<6)?5'b01001:5'b00111;  // 0
                5'd1  : refg = (r==0)?5'b00100:(r==1)?5'b01100:(r<5)?5'b00100:
                          (r==5)?5'b00100:5'b01110;                 // 1
                5'd2  : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b00010:
                          (r==3)?5'b00100:(r==4)?5'b01000:(r==5)?5'b10000:5'b01111; // 2
                5'd3  : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b00001:
                          (r==3)?5'b00010:(r==4)?5'b00001:(r==5)?5'b10001:5'b01110; // 3
                5'd4  : refg = (r==0)?5'b00010:(r==1)?5'b00110:(r==2)?5'b01010:
                          (r==3)?5'b10010:(r==4)?5'b01111:(r==5)?5'b00010:5'b00010; // 4
                5'd5  : refg = (r==0)?5'b11111:(r==1)?5'b10000:(r==2)?5'b11110:
                          (r==3)?5'b00000:(r==4)?5'b00001:(r==5)?5'b10001:5'b01110; // 5
                5'd6  : refg = (r==0)?5'b00110:(r==1)?5'b01000:(r==2)?5'b10000:
                          (r==3)?5'b11100:(r==4)?5'b10001:(r==5)?5'b10001:5'b01110; // 6
                5'd7  : refg = (r==0)?5'b11111:(r==1)?5'b00001:(r==2)?5'b00010:
                          (r==3)?5'b00100:(r==4)?5'b01000:(r==5)?5'b01000:5'b01000; // 7
                5'd8  : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b10001:
                          (r==3)?5'b01110:(r==4)?5'b10001:(r==5)?5'b10001:5'b01110; // 8
                5'd9  : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b10001:
                          (r==3)?5'b01111:(r==4)?5'b00001:(r==5)?5'b00010:5'b01100; // 9
                5'd11 : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b10001:
                          (r==3)?5'b01110:(r==4)?5'b10001:(r==5)?5'b10001:5'b10001; // A
                5'd12 : refg = (r==0)?5'b11100:(r==1)?5'b10010:(r==2)?5'b10010:
                          (r==3)?5'b11100:(r==4)?5'b10010:(r==5)?5'b10010:5'b11100; // B
                5'd13 : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b10000:
                          (r==3)?5'b10000:(r==4)?5'b10000:(r==5)?5'b10001:5'b01110; // C
                5'd14 : refg = (r==0)?5'b11100:(r==1)?5'b10010:(r==2)?5'b10001:
                          (r==3)?5'b10001:(r==4)?5'b10001:(r==5)?5'b10010:5'b11100; // D
                5'd15 : refg = (r==0)?5'b11111:(r==1)?5'b10000:(r==2)?5'b11100:
                          (r==3)?5'b10000:(r==4)?5'b10000:(r==5)?5'b10000:5'b11111; // E
                5'd16 : refg = (r==0)?5'b11111:(r==1)?5'b10000:(r==2)?5'b11100:
                          (r==3)?5'b10000:(r==4)?5'b10000:(r==5)?5'b10000:5'b10000; // F
                5'd17 : refg = (r==0)?5'b01110:(r==1)?5'b10001:(r==2)?5'b10001:
                          (r==3)?5'b10001:(r==4)?5'b10001:(r==5)?5'b10001:5'b01110; // O
                5'd18 : refg = (r==0)?5'b10001:(r==1)?5'b10010:(r==2)?5'b10100:
                          (r==3)?5'b11000:(r==4)?5'b10100:(r==5)?5'b10010:5'b10001; // K
                5'd19 : refg = (r==0)?5'b11100:(r==1)?5'b10001:(r==2)?5'b10001:
                          (r==3)?5'b11100:(r==4)?5'b10010:(r==5)?5'b10010:5'b11110; // R
                5'd20 : refg = (r==0)?5'b01110:(r<6)?5'b00100:5'b01110;             // I
                5'd21 : refg = (r<6)?5'b10000:5'b11111;                              // L
                5'd22 : refg = (r<5)?5'b10001:(r==5)?5'b01010:5'b00100;             // V
                5'd23 : refg = (r==0)?5'b11111:(r<6)?5'b00100:5'b00100;             // T
                5'd24 : refg = (r==0)?5'b01111:(r==1)?5'b10000:(r==2)?5'b10000:
                          (r==3)?5'b01110:(r==4)?5'b00001:(r==5)?5'b00001:5'b11110; // S
                5'd25 : refg = (r==2)?5'b01110:(r==4)?5'b01110:5'b00000;            // =
                5'd26 : refg = 5'b00000;                                            // ' '
                5'd27 : refg = (r==0)?5'b01000:(r==1)?5'b10100:(r==2)?5'b10010:
                          (r==3)?5'b10001:(r==4)?5'b10000:(r==5)?5'b10000:5'b10000; // N
                5'd28 : refg = (r==0)?5'b00100:(r==1)?5'b01100:(r==2)?5'b10010:
                          (r==3)?5'b10001:(r==4)?5'b10001:(r==5)?5'b10001:5'b10001; // M
                5'd29 : refg = (r==0)?5'b10001:(r==1)?5'b10001:(r==2)?5'b10001:
                          (r==3)?5'b10001:(r==4)?5'b10101:(r==5)?5'b10101:5'b01010; // W
                default: refg = 5'b00000;
            endcase
        end
    endfunction

    // ---- expected line content (set per test) ----
    // Arrays are 28 deep: the fingerprint lines (T7) are 24 chars long;
    // shorter lines leave the tail as SP (glyph 26, blank).
    reg [4:0] exm [0:27];   // marker glyphs M 0 <stage> <status> (rest = SP)
    reg [4:0] ex1 [0:27];   // line 1 (15 chars)
    reg [4:0] ex2 [0:27];   // line 2 (10 chars)
    reg [4:0] ex3 [0:27];   // line 3 (21 chars)
    reg [4:0] exf [0:27];   // fingerprint line (24 chars)
    integer i;
    task set_marks;
        begin
            for (i = 0; i < 28; i = i + 1) exm[i] = 5'd26;
            exm[0] = 5'd28;  // M
            exm[1] = 5'd0;   // 0
            exm[2] = stage_m;
            exm[3] = !res_valid_m ? 5'd26 :
                     (res_code_m == 2'd0) ? 5'd17 :
                     (res_code_m == 2'd1) ? 5'd16 : 5'd27;
        end
    endtask
    task set_ex1_ok(input [31:0] crc);
        begin
            for (i = 0; i < 28; i = i + 1) ex1[i] = 5'd26;
            ex1[0]=5'd17; ex1[1]=5'd18; ex1[2]=5'd26; ex1[3]=5'd13;
            ex1[4]=5'd19; ex1[5]=5'd13; ex1[6]=5'd25;
            for (i=0;i<8;i=i+1)
                ex1[7+i] = (crc[31-4*i-:4] < 4'd10) ?
                           {1'b0, crc[31-4*i-:4]} :
                           ({1'b0, crc[31-4*i-:4]} + 5'd1);
        end
    endtask
    task set_ex1_no;
        begin
            for (i = 0; i < 28; i = i + 1) ex1[i] = 5'd26;
            ex1[0]=5'd27; ex1[1]=5'd17; ex1[2]=5'd26; ex1[3]=5'd16;
            ex1[4]=5'd20; ex1[5]=5'd21; ex1[6]=5'd15;
            for (i=7;i<15;i=i+1) ex1[i]=5'd26;
        end
    endtask
    task set_ex2(input [31:0] nbytes);
        begin
            for (i = 0; i < 28; i = i + 1) ex2[i] = 5'd26;
            ex2[0]=5'd27; ex2[1]=5'd25;
            for (i=0;i<8;i=i+1)
                ex2[2+i] = (nbytes[31-4*i-:4] < 4'd10) ?
                           {1'b0, nbytes[31-4*i-:4]} :
                           ({1'b0, nbytes[31-4*i-:4]} + 5'd1);
        end
    endtask
    task set_ex3(input [47:0] rc, input [2:0] fl);
        begin
            ex3[0]=5'd19; ex3[1]=5'd25;
            for (i=0;i<6;i=i+1)
                ex3[2+i] = (rc[47-4*i-:4] < 4'd10) ?
                           {1'b0, rc[47-4*i-:4]} :
                           ({1'b0, rc[47-4*i-:4]} + 5'd1);
            ex3[8]=5'd26; ex3[9]=5'd13; ex3[10]=5'd25;
            for (i=0;i<6;i=i+1)
                ex3[11+i] = (rc[23-4*i-:4] < 4'd10) ?
                            {1'b0, rc[23-4*i-:4]} :
                            ({1'b0, rc[23-4*i-:4]} + 5'd1);
            ex3[17]=5'd26;
            ex3[18]= fl[0] ? 5'd17 : 5'd26;   // O
            ex3[19]= fl[1] ? 5'd23 : 5'd26;   // T
            ex3[20]= fl[2] ? 5'd24 : 5'd26;   // S
            for (i = 21; i < 28; i = i + 1) ex3[i] = 5'd26;
        end
    endtask

    // ---- pixel sampling: capture the full active run of one line ----
    // The mirror's m_col is 0 through the blank and becomes 1 at the
    // first active posedge (NBA), so active pixel p is visible at the
    // following negedges with m_col == p+1. Consume the line: at each
    // negedge on line V's active run, store px[m_col-1].
    reg [23:0] px [0:559];
    // px index == DUT col. The col counters (DUT and mirror, identical
    // reset/increment logic) reach 1..558 during a row's visible active
    // run (ccyc 337..895) and 559 on the first cycle of the next row's
    // blank (still !hbl, row not yet incremented). m_col==0 occurs only
    // inside the blank, so a full line = 559 captured columns (1..559);
    // px[0] is never a visible pixel and is left stale on purpose.
    task sample_line(input [7:0] V);
        integer c;
        integer wait_cyc;
        begin
            c = 0;
            wait_cyc = 0;
            while (c < 559) begin
                if (m_row == V && !hbl && m_col != 10'd0) begin
                    px[m_col] = (rgb_out == 24'hFFFFFF) ? 24'hFFFFFF : 24'd0;
                    c = c + 1;
                    wait_cyc = 0;
                end else begin
                    wait_cyc = wait_cyc + 1;
                    if (wait_cyc > 150000) begin
                        $display("SL-HANG V=%0d m_row=%0d vbl=%b hbl=%b m_col=%0d c=%0d",
                                 V, m_row, vbl, hbl, m_col, c);
                        fails = fails + 1;
                        $fatal(1, "sample_line timeout V=%0d c=%0d", V, c);
                    end
                end
                @(negedge clk);
            end
        end
    endtask



    // pixel sampling of the T8 DUT (same raster, same mirror counters)
    reg [23:0] pxoff [0:559];
    task sample_line_off(input [7:0] V);
        integer c;
        integer wait_cyc;
        begin
            c = 0;
            wait_cyc = 0;
            while (c < 559) begin
                if (m_row == V && !hbl && m_col != 10'd0) begin
                    pxoff[m_col] = (rgb_off == 24'hFFFFFF) ? 24'hFFFFFF : 24'd0;
                    c = c + 1;
                    wait_cyc = 0;
                end else begin
                    wait_cyc = wait_cyc + 1;
                    if (wait_cyc > 150000) begin
                        $display("SLO-HANG V=%0d m_row=%0d vbl=%b hbl=%b c=%0d",
                                 V, m_row, vbl, hbl, c);
                        fails = fails + 1;
                        $fatal(1, "sample_line_off timeout V=%0d c=%0d", V, c);
                    end
                end
                @(negedge clk);
            end
        end
    endtask

    // debug: dump pixel regions to a file for offline decode
    integer pf;
    task dump_regions(input [63:0] tag);
        integer r, c;
        begin
            pf = $fopen("verilog/obj_dir_ovl/ovl_px.txt");
            $fdisplay(pf, "TAG %0h", tag);
            for (r = 0; r < 7; r = r + 1) begin
                sample_line(8'd0 + r);
                $fdisplay(pf, "M%0d", r);
                for (c = 0; c < 40; c = c + 1) $fwrite(pf, "%0d", (px[c] == 24'hFFFFFF) ? 1 : 0);
                $fdisplay(pf, "");
            end
            for (r = 0; r < 7; r = r + 1) begin
                sample_line(8'd8 + r);
                $fdisplay(pf, "L1%0d", r);
                for (c = 455; c < 560; c = c + 1) $fwrite(pf, "%0d", (px[c] == 24'hFFFFFF) ? 1 : 0);
                $fdisplay(pf, "");
            end
            for (r = 0; r < 7; r = r + 1) begin
                sample_line(8'd17 + r);
                $fdisplay(pf, "L2%0d", r);
                for (c = 455; c < 560; c = c + 1) $fwrite(pf, "%0d", (px[c] == 24'hFFFFFF) ? 1 : 0);
                $fdisplay(pf, "");
            end
            for (r = 0; r < 7; r = r + 1) begin
                sample_line(8'd25 + r);
                $fdisplay(pf, "L3%0d", r);
                for (c = 420; c < 560; c = c + 1) $fwrite(pf, "%0d", (px[c] == 24'hFFFFFF) ? 1 : 0);
                $fdisplay(pf, "");
            end
            $fclose(pf);
        end
    endtask

    task dump_art_unused(input [63:0] tag);
        integer r, c;
        begin
            $display("ART %0h (DUT rows / EXP rows):", tag);
            for (r = 0; r < 7; r = r + 1) begin
                sample_line(8'd0 + r);
                $display(" D r%0d:", r);
                for (c = 0; c < 32; c = c + 1)
                    $display("%s", (px[c] == 24'hFFFFFF) ? "X" : ".");
                $display(" E:");
                for (c = 0; c < 32; c = c + 1)
                    $display("%s", (refg(exu[c/6], r[2:0])[4-c%6] && (c%6) < 5 && c/6 < 6) ? "X" : ".");
            end
        end
    endtask

    // debug: hexdump one captured line (columns 0..127)
    task dump_line(input [63:0] tag);
        integer c, n;
        reg [3:0] nib;
        begin
            $display("DUMP %0h:", tag);
            for (c = 0; c < 128; c = c + 8) begin
                for (n = 0; n < 8; n = n + 1) begin
                    nib = (px[c+n] == 24'hFFFFFF) ? 4'h1 : 4'h0;
                    $display("  %04d %b", c, nib);
                end
            end
        end
    endtask

    // ---- exact checks ----
    integer fails;
    integer fbase;
    integer mr;
    // unified expected array (all line arrays are copied in before a
    // check; Verilog-2001 task array args need matching sizes)
    reg [4:0] exu [0:27];
    // exact per-row pixel check: exu[] holds GLYPH CODES; refg() renders
    // the row-r bitmap of each glyph (bit 4 = leftmost pixel)
    task check_row(input [9:0] x0, input [9:0] len, input [2:0] r);
        integer ci, c;
        reg got;
        begin
            for (ci = 0; ci < len; ci = ci + 1) begin
                for (c = 0; c < 5; c = c + 1) begin
                    got = refg(exu[ci], r)[4-c];
                    if (px[x0 + ci*6 + c] == 24'hFFFFFF) begin
                        if (!got) begin fails = fails + 1;
                            $display("F+ row%0d col%0d ch%0d c%0d: unexpected ON",
                                     m_row, x0+ci*6+c, ci, c); end
                    end else begin
                        if (got) begin fails = fails + 1;
                            $display("F- row%0d col%0d ch%0d c%0d: expected ON",
                                     m_row, x0+ci*6+c, ci, c); end
                    end
                end
                // gap column must be off
                if (px[x0 + ci*6 + 5] == 24'hFFFFFF) begin
                    fails = fails + 1;
                    $display("F- gap col%0d ch%0d ON", x0+ci*6+5, ci);
                end
            end
            // outside the box: off (within the captured 560 px)
            for (c = 0; c < 560; c = c + 1) begin
                if (c < x0 || c >= x0 + len*6) begin
                    if (px[c] == 24'hFFFFFF) begin
                        fails = fails + 1;
                        $display("F- outside row%0d col%0d ON", m_row, c);
                        if (fails > 40) return;
                    end
                end
            end
        end
    endtask

    // ---- scenario drivers ----
    // unified copy of an expected array into exu
    task copy_ex(reg [4:0] src [0:27]);
        begin
            for (i = 0; i < 28; i = i + 1) exu[i] = src[i];
        end
    endtask
    task set_result(input rv, input [1:0] code, input [1:0] fl_code,
                    input [31:0] crc, input [31:0] nb,
                    input [47:0] rc, input [2:0] fl, input [2:0] stg);
        begin
            // Model a fresh storage generation: the DUT latches text on the
            // RISING edge of res_valid_m, so drop it first (a new 008F
            // generation starts with valid=0), settle, then present the
            // payload and raise valid. Changing fields while valid stays
            // high would correctly NOT re-latch - tests must model the edge.
            res_valid_m <= 1'b0;
            repeat (8) @(negedge clk);
            res_valid_m <= rv;
            res_code_m  <= code;
            res_fail_m  <= fl_code;
            res_crc_m   <= crc;
            res_nbytes_m <= nb;
            dbg_rc_m    <= rc;
            dbg_fl_m    <= fl;
            stage_m     <= stg;
            @(negedge clk);
        end
    endtask

    // sample 7 consecutive rows of a box and check each
    task check_line_block(input [7:0] row0, input [9:0] x0, input [9:0] len,
                          reg [4:0] src [0:27]);
        integer r;
        begin
            for (i = 0; i < 28; i = i + 1) exu[i] = src[i];
            for (r = 0; r < 7; r = r + 1) begin
                sample_line(row0 + r);
                check_row(x0, len, r[2:0]);
            end
        end
    endtask

    initial begin
        fails = 0;

        // ================= T0: quiet - marker only, exact bitmap =====
        reset = 1'b1;
        res_valid_m = 1'b0; res_code_m = 2'd0; res_fail_m = 2'd0;
        res_crc_m = 32'd0; res_nbytes_m = 32'd0;
        dbg_rc_m = 48'd0; dbg_fl_m = 3'd0; stage_m = 3'd0;
        repeat (80) @(negedge clk);
        reset = 1'b0;
        // Wait for the first visible line (vbl deasserts after the 40 VBL
        // lines). Before that, m_row==0 is the stale reset value, not the
        // true row 0 - sampling it would read a VBL line.
        while (vbl) @(negedge clk);
        repeat (2000) @(negedge clk);   // several lines of raster

        // marker "M0 0" on visible line 1, rows 1..4 (row 1 of the 7)
        res_valid_m <= 1'b0; res_code_m <= 2'd0; res_fail_m <= 2'd0;
        res_crc_m <= 32'd0; res_nbytes_m <= 32'd0; stage_m <= 3'd3;
        repeat(4) @(negedge clk);   // let stage settle (set_marks reads it)
        set_marks;              // 'M 0 3 ' - stage 3, no result
        repeat(6) @(negedge clk);
        copy_ex(exm);
        // all 7 glyph rows of the marker, pixel-exact
        for (mr = 0; mr < 7; mr = mr + 1) begin
            sample_line(mr[7:0]);
            check_row(10'd4, 4, mr[2:0]);
        end
        // no other pixels anywhere on line 10 (no result -> no L1/L2/L3)
        sample_line(8'd10);
        for (i = 0; i < 560; i = i + 1)
            if (px[i] == 24'hFFFFFF) begin
                fails = fails + 1;
                $display("F T0: stray pixel line10 col%0d", i);
            end
        if (fails == 0) $display("T0 PASS: quiet marker exact, no other text");
        else $display("T0 FAIL (%0d)", fails);

        // ============ T1: OK result, exact text, 128-word counter =====
        set_result(1'b1, 2'd0, 2'd0, 32'h12345678, 32'h00030000,
                   {16'd0, 24'd128, 24'd128}, 3'd0, 3'd6);
        repeat (40) @(negedge clk);      // let show_start latch
        set_ex1_ok(32'h12345678);
        set_ex2(32'h00030000);
        set_ex3({16'd0, 24'd128, 24'd128}, 3'd0);
        set_marks;
        fbase = fails;
        check_line_block(8'd8, 10'd460, 15, ex1);   // L1 rows 8..14
        if (fails == fbase) $display("T1a PASS: L1 'OK CRC=12345678' exact");
        else $display("T1a FAIL (%0d new)", fails - fbase);
        fbase = fails;
        check_line_block(8'd17, 10'd460, 10, ex2);  // L2 rows 17..23
        if (fails == fbase) $display("T1b PASS: L2 'N=00030000' exact");
        else $display("T1b FAIL (%0d new)", fails - fbase);
        fbase = fails;
        check_line_block(8'd25, 10'd424, 21, ex3);  // L3 rows 25..31
        if (fails == fbase) $display("T1c PASS: L3 'R=000080 C=000080' (low nibble kept)");
        else $display("T1c FAIL (%0d new)", fails - fbase);
        // marker "M0 6O"
        copy_ex(exm);
        sample_line(8'd1);
        check_row(10'd4, 4, 3'd1);
        if (fails == fbase) $display("T1d PASS: marker 'M0 6O' exact");
        else $display("T1d FAIL (%0d new)", fails - fbase);

        // ================= T2: all 16 hex digits in one result =====
        set_result(1'b1, 2'd0, 2'd0, 32'hFEDCBA09, 32'h87654321,
                   48'd0, 3'd0, 3'd6);
        repeat (40) @(negedge clk);
        set_ex1_ok(32'hFEDCBA09);   // digits F E D C B A 0 9
        set_ex2(32'h87654321);     // digits 8 7 6 5 4 3 2 1
        fbase = fails;
        check_line_block(8'd8, 10'd460, 15, ex1);
        if (fails == fbase) $display("T2a PASS: all-16-digit L1 (FEDCBA09) exact");
        else $display("T2a FAIL (%0d new)", fails - fbase);
        fbase = fails;
        check_line_block(8'd17, 10'd460, 10, ex2);
        if (fails == fbase) $display("T2b PASS: L2 (87654321) exact");
        else $display("T2b FAIL (%0d new)", fails - fbase);

        // ================= T3: NO FILE + each fault flag separately
        set_result(1'b1, 2'd2, 2'd0, 32'd0, 32'd0, 48'd0, 3'd001, 3'd6);
        repeat (40) @(negedge clk);
        fbase = fails;
        set_ex1_no;
        set_ex3(48'd0, 3'd001);
        set_marks;
        check_line_block(8'd8, 10'd460, 15, ex1);
        check_line_block(8'd25, 10'd424, 21, ex3);
        if (fails == fbase) $display("T3a PASS: NO FILE + overflow flag 'O' exact");
        else $display("T3a FAIL (%0d new)", fails - fbase);
        set_result(1'b1, 2'd2, 2'd0, 32'd0, 32'd0, 48'd0, 3'd010, 3'd6);
        repeat (40) @(negedge clk);
        set_ex3(48'd0, 3'd010);
        fbase = fails;
        check_line_block(8'd25, 10'd424, 21, ex3);
        if (fails == fbase) $display("T3b PASS: timeout flag 'T' exact (O/S off)");
        else $display("T3b FAIL (%0d new)", fails - fbase);
        set_result(1'b1, 2'd2, 2'd0, 32'd0, 32'd0, 48'd0, 3'd100, 3'd6);
        repeat (40) @(negedge clk);
        set_ex3(48'd0, 3'd100);
        fbase = fails;
        check_line_block(8'd25, 10'd424, 21, ex3);
        if (fails == fbase) $display("T3c PASS: stuck flag 'S' exact (O/T off)");
        else $display("T3c FAIL (%0d new)", fails - fbase);

        // ================= T4: stage digit in the marker = 3 =====
        set_result(1'b0, 2'd0, 2'd0, 32'd0, 32'd0, 48'd0, 3'd0, 3'd3);
        repeat (40) @(negedge clk);
        set_marks;   // status = space (no result), stage = 3
        fbase = fails;
        copy_ex(exm);
        sample_line(8'd1);
        check_row(10'd4, 4, 3'd1);
        if (fails == fbase) $display("T4 PASS: marker 'M0 3' (stage 3, no result) exact");
        else $display("T4 FAIL (%0d new)", fails - fbase);

        // ================= T5: window expiry - text gone, marker left
        // (SHOW_CYCLES=4_000_000 ~ 280 ms; verify text ON, run past it)
        set_result(1'b1, 2'd0, 2'd0, 32'h12345678, 32'h00030000,
                   {16'd0, 24'd128, 24'd128}, 3'd0, 3'd6);
        set_marks;
        repeat (40) @(negedge clk);
        // pre-check: window text is ON right after the latch (L1 row 0 'O')
        sample_line(8'd8);
        fbase = fails;
        if (!((px[461] == 24'hFFFFFF) && (px[462] == 24'hFFFFFF) &&
              (px[463] == 24'hFFFFFF))) begin
            fails = fails + 1;
            $display("F T5: window text NOT on before expiry");
        end
        repeat (4_200_000) @(negedge clk);   // > SHOW_CYCLES + margin
        sample_line(8'd10);
        for (i = 0; i < 560; i = i + 1)
            if (px[i] == 24'hFFFFFF) begin
                fails = fails + 1;
                $display("F T5: window text still on col%0d", i);
            end
        if (fails == fbase) $display("T5a PASS: window text on, then expired");
        else $display("T5a FAIL (%0d new)", fails - fbase);
        // marker still there (result latched)
        copy_ex(exm);
        sample_line(8'd1);
        check_row(10'd4, 4, 3'd1);
        if (fails == fbase) $display("T5b PASS: marker persists after expiry");
        else $display("T5b FAIL (%0d new)", fails - fbase);

        // ================= T6: reset re-arms the window ==============
        reset = 1'b1;
        repeat (30) @(negedge clk);
        reset = 1'b0;
        repeat (3000) @(negedge clk);
        // window re-opened -> L1 text present again: row 0 of 'O'
        // (glyph O row0 = 01110) -> pixels at cols 461,462,463
        sample_line(8'd8);
        if ((px[461] == 24'hFFFFFF) && (px[462] == 24'hFFFFFF) &&
            (px[463] == 24'hFFFFFF))
            $display("T6 PASS: reset re-armed the window (L1 row0 'O' visible)");
        else begin
            fails = fails + 1;
            $display("T6 FAIL: window did not re-arm (px461=%b px462=%b px463=%b)",
                     px[461], px[462], px[463]);
        end

        // ================= T7: fingerprint lines (always-on) ===========
        // rows 65..71: "W0=0644D9BB W1=3BB1796C"  (24 chars, X0=406)
        // rows 73..79: "W2=431FCE9A W3=E79D5F99"
        // rows 81..87: "F=574F5A32FF0A0D0A"        (18 chars, X0=442)
        // rows 89..95: "L=...4C4D4E4F"
        // Values mirror tools/woz_fingerprint.py output for a known image.
        fp_w_r     <= {32'h0644D9BB, 32'h3BB1796C, 32'h431FCE9A, 32'hE79D5F99};
        fp_first_r <= 128'h574F5A32_FF0A0D0A_6680666C_00000000;
        fp_last_r  <= 128'h00000000_00000000_00000000_4C4D4E4F;
        repeat (40) @(negedge clk);
        fbase = fails;
        for (i = 0; i < 28; i = i + 1) exf[i] = 5'd26;
        exf[0]=5'd29; exf[1]=5'd0;  exf[2]=5'd25;              // W0=
        exf[3]=5'd0; exf[4]=5'd6;  exf[5]=5'd4;  exf[6]=5'd4;
        exf[7]=5'd14; exf[8]=5'd9; exf[9]=5'd12; exf[10]=5'd12;   // D9BB
        exf[11]=5'd26;
        exf[12]=5'd29; exf[13]=5'd1; exf[14]=5'd25;            // W1=
        exf[15]=5'd3; exf[16]=5'd12; exf[17]=5'd12; exf[18]=5'd1;
        exf[19]=5'd7; exf[20]=5'd9; exf[21]=5'd6;  exf[22]=5'd13;
        exf[23]=5'd26;
        check_line_block(8'd65, 10'd406, 24, exf);
        for (i = 0; i < 28; i = i + 1) exf[i] = 5'd26;
        exf[0]=5'd29; exf[1]=5'd2;  exf[2]=5'd25;              // W2=
        exf[3]=5'd4; exf[4]=5'd3;  exf[5]=5'd1;  exf[6]=5'd16;
        exf[7]=5'd13; exf[8]=5'd15; exf[9]=5'd9;  exf[10]=5'd11;
        exf[11]=5'd26;
        exf[12]=5'd29; exf[13]=5'd3; exf[14]=5'd25;            // W3=
        exf[15]=5'd15; exf[16]=5'd7; exf[17]=5'd9; exf[18]=5'd14;
        exf[19]=5'd5; exf[20]=5'd16; exf[21]=5'd9; exf[22]=5'd9;
        exf[23]=5'd26;
        check_line_block(8'd73, 10'd406, 24, exf);
        for (i = 0; i < 28; i = i + 1) exf[i] = 5'd26;
        exf[0]=5'd16; exf[1]=5'd25;                             // F=
        exf[2]=5'd5;  exf[3]=5'd7;  exf[4]=5'd4;  exf[5]=5'd16;
        exf[6]=5'd5;  exf[7]=5'd11; exf[8]=5'd3;  exf[9]=5'd2;
        exf[10]=5'd16; exf[11]=5'd16; exf[12]=5'd0; exf[13]=5'd11;
        exf[14]=5'd0; exf[15]=5'd14; exf[16]=5'd0; exf[17]=5'd11;
        check_line_block(8'd81, 10'd442, 18, exf);
        // L= line: LOW 64 bits of fp_last = the file's last 8 bytes.
        // fp_last_r = 128'h00000000_00000000_00000000_4C4D4E4F
        // -> "L=000000004C4D4E4F"
        for (i = 0; i < 28; i = i + 1) exf[i] = 5'd26;
        exf[0]=5'd21; exf[1]=5'd25;                             // L=
        for (i = 2; i < 10; i = i + 1) exf[i] = 5'd0;           // 00000000
        exf[10]=5'd4;  exf[11]=5'd13; exf[12]=5'd4;  exf[13]=5'd14;
        exf[14]=5'd4;  exf[15]=5'd15; exf[16]=5'd4;  exf[17]=5'd16; // 4C4D4E4F
        check_line_block(8'd89, 10'd442, 18, exf);
        if (fails == fbase) $display("T7 PASS: fingerprint lines W0/W1/W2/W3/F/L exact");
        else $display("T7 FAIL (%0d new)", fails - fbase);

        // ================= T8: SHOW_FP=0 (default) - shipping build =====
        // dut_off runs the same inputs with default parameters: fp rows
        // must be completely blank; a non-fp line (L1) must be
        // pixel-identical to the SHOW_FP=1 DUT.
        set_result(1'b1, 2'd0, 2'd0, 32'h12345678, 32'h00030000,
                   {16'd0, 24'd128, 24'd128}, 3'd0, 3'd6);
        repeat (40) @(negedge clk);   // both DUTs latch the fresh result
        fbase = fails;
        sample_line(8'd8);            // main DUT L1 (row 8)
        sample_line_off(8'd8);        // off DUT L1 (row 8, next frame)
        for (i = 0; i < 560; i = i + 1)
            if (px[i] != pxoff[i]) begin
                fails = fails + 1;
                $display("F T8: L1 diff col%0d dut=%b off=%b", i, px[i], pxoff[i]);
            end
        // fp row blocks on the off DUT must be blank (one row per block;
        // all four blocks share the same SHOW_FP gate)
        sample_line_off(8'd65);
        for (i = 0; i < 560; i = i + 1)
            if (pxoff[i] == 24'hFFFFFF) begin
                fails = fails + 1;
                $display("F T8: W0 row not blank col%0d", i);
            end
        sample_line_off(8'd81);
        for (i = 0; i < 560; i = i + 1)
            if (pxoff[i] == 24'hFFFFFF) begin
                fails = fails + 1;
                $display("F T8: F row not blank col%0d", i);
            end
        sample_line_off(8'd89);
        for (i = 0; i < 560; i = i + 1)
            if (pxoff[i] == 24'hFFFFFF) begin
                fails = fails + 1;
                $display("F T8: L row not blank col%0d", i);
            end
        if (fails == fbase) $display("T8 PASS: SHOW_FP=0 -> fp rows blank, other lines identical");
        else $display("T8 FAIL (%0d new)", fails - fbase);

        // ---- DUMP phase: OK result, stage 6 - file dump for offline decode ----
        set_result(1'b1, 2'd0, 2'd0, 32'hC9260F5E, 32'd512, 48'h000080_000080, 3'd0, 3'd6);
        repeat(8) @(negedge clk);
        dump_regions(64'hAA);
        res_valid_m <= 1'b0; res_code_m <= 2'd0; res_fail_m <= 2'd0;
        res_crc_m <= 32'd0; res_nbytes_m <= 32'd0; stage_m <= 3'd0;
        repeat(8) @(negedge clk);

        if (fails == 0) $display("OVL STATUS PASS: real raster, exact glyphs, all hex digits, per-flag, marker, expiry, re-arm, SHOW_FP gate");
        else $fatal(1, "OVL STATUS FAIL: %0d pixel mismatches", fails);
        $finish;
    end

    initial begin
        #5_000_000_000;   // 5 s of simulation
        $fatal(1, "OVL STATUS FAIL: watchdog");
    end

endmodule
