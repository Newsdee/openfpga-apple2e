//
// sdram_status_overlay.v - temporary M0 on-screen diagnostic
// (M0 rework, Unit 4 + Unit 8 raster/encoding fixes - see
//  docs/PLAN_FLOPPY_M0_STORAGE_REWORK and
//  docs/EXPERT_REVIEW_M0_HARDWARE_NOVIS_2026-10-20.md)
//
// Shows the SDRAM storage verification result for SHOW_CYCLES
// (~5 s at 14.318 MHz) after the verifier finishes (pass or fail):
//   line 1:  OK CRC=XXXXXXXX      (or  FAIL OV / FAIL TO / FAIL ST)
//   line 2:  N=XXXXXXXX           (file length in bytes, hex)
//   line 3:  R=NNNNNN C=NNNNNN OTS (words received / committed + flags:
//              O=FIFO overflow, T=store timeout, S=verifier stuck)
// plus an UNCONDITIONAL build marker in the top-left corner, always on
// (independent of storage state):  M 0 <stage> <status>
//   stage  = furthest storage stage this generation: 0=none, 1=request
//            seen, 2=data seen, 3=all-complete seen, 4=drain complete,
//            5=verifier started, 6=result latched
//   status = (none) | O (OK) | F (FAIL) | N (NO FILE)
// While a result is latched the stage/status read 6 and O/F/N, so the
// marker persists as a corner badge after the window closes; it re-arms
// on every machine reset (reset clears the window, res_valid_m stays
// high). Same data is always available in the 0xF9xxxxxx bridge debug
// reads; this overlay exists because the M0 hardware proof wants the
// screen. Removed (or kept silent) once M3 boot-time verification
// exists.
//
// DOMAIN: machine (14.318 MHz). Sits AFTER the OSK compositor in the
// video chain (it wins over everything, including the OSK).
//
// RASTER (the machine's real geometry, verified against
// machine/timing_generator.v + apf_video.v):
//   - m_hbl is a WIDE blanking interval (~336 machine clocks/line),
//     NOT a one-clock pulse. Row counting must therefore be EDGE-based
//     (once per HBL rising edge), exactly like the hardware-verified
//     OSK overlay (machine/osk/virtual_keyboard_overlay.sv) and the
//     apf_video line buffer (vline counts HBL rises while !vbl, reset
//     at VBL falling).
//   - Visible stream = 192 lines x up to 560 active samples/line
//     (apf_video VISIBLE_LINES / MAX_CAP), matching video.json.
//   - The Apple II raster interlaces: VBL has multiple runs per V
//     cycle; both this counter and apf_video reset at each VBL
//     falling edge and freeze across VBL, so row == apf_video vline
//     (0 = first captured line of the stream frame).
//
// Geometry: 6 px pitch (5 px glyph + 1 px gap).
//   marker: 4 glyphs at X0=4,   rows 0..4   (unconditional)
//   line 1: 15 chars at X0=460, rows 8..14
//   line 2: 10 chars at X0=460, rows 17..23
//   line 3: 21 chars at X0=424, rows 25..31
//
`timescale 1ns/10ps
module sdram_status_overlay (
    input  wire        clk,          // machine, 14.318 MHz
    input  wire        reset,

    input  wire [23:0] rgb_in,
    input  wire        hbl,
    input  wire        vbl,
    output wire [23:0] rgb_out,

    // ---- result (machine domain, from the load/verify coordinator) ----
    input  wire        res_valid_m,    // result latched (show trigger)
    input  wire [1:0]  res_code_m,     // 0=OK, 1=FAIL, 2=NOFILE
    input  wire [1:0]  res_fail_m,     // subcode: 0=ST, 1=OV, 2=TO, 3=IN
    input  wire [31:0] res_crc_m,
    input  wire [31:0] res_nbytes_m,

    // ---- debug (machine domain, for line 3 + the marker) ----
    input  wire [47:0] dbg_rc_m,   // {words_received[23:0], words_committed[23:0]}
    input  wire [2:0]  dbg_fl_m,   // bit0=FIFO overflow, bit1=store timeout, bit2=verifier stuck
    input  wire [2:0]  stage_m     // furthest storage stage: 0..6 (see header)
);

    // Show-window length in machine clocks (default = 5 s @ 14.318 MHz;
    // a testbench may shorten it).
    parameter SHOW_CYCLES = 27'd71_590_900;
    // One-shot hardware diagnostic: when compiled 1, draw a persistent
    // white rectangle (rows 10..12, cols 100..149) independent of storage
    // state, results, and font logic - proves the overlay is in the video
    // path regardless of everything else. Shipping builds keep 0.
    parameter DBG_RECT = 1'b0;

    // ---- glyph codes ----
    // 0-9 -> 0-9, A=11 B=12 C=13 D=14 E=15 F=16, O=17 K=18 R=19 I=20
    // L=21 V=22 T=23 S=24 '='=25 ' '=26 N=27, M=28
    localparam GL_O = 5'd17, GL_K = 5'd18, GL_R = 5'd19, GL_I = 5'd20;
    localparam GL_L = 5'd21, GL_V = 5'd22, GL_T = 5'd23, GL_S = 5'd24;
    localparam GL_N = 5'd27, GL_M = 5'd28;
    localparam GL_C5 = 5'd13;         // 'C' (glyph code 13)
    localparam GL_EQ = 5'd25, GL_SP = 5'd26;

    // ---- 5x7 font: gf = {row0, row1, ..., row6}; row0 = MSB;
    //      within a row bit 4 = leftmost pixel ----
    // Combinational lookup (not an inferred RAM): keeps this temporary
    // diagnostic free of inferred-IP undriven-port warnings.
    function [34:0] gf;
        input [4:0] g;
        begin
            case (g)
                5'd0  : gf = 35'b00111_01001_01010_01100_01001_01001_00111; // 0
                5'd1  : gf = 35'b00100_01100_00100_00100_00100_00100_01110; // 1
                5'd2  : gf = 35'b01110_10001_00010_00100_01000_10000_01111; // 2
                5'd3  : gf = 35'b01110_10001_00001_00010_00001_10001_01110; // 3
                5'd4  : gf = 35'b00010_00110_01010_10010_01111_00010_00010; // 4
                5'd5  : gf = 35'b11111_10000_11110_00000_00001_10001_01110; // 5
                5'd6  : gf = 35'b00110_01000_10000_11100_10001_10001_01110; // 6
                5'd7  : gf = 35'b11111_00001_00010_00100_01000_01000_01000; // 7
                5'd8  : gf = 35'b01110_10001_10001_01110_10001_10001_01110; // 8
                5'd9  : gf = 35'b01110_10001_10001_01111_00001_00010_01100; // 9
                5'd11 : gf = 35'b01110_10001_10001_01110_10001_10001_10001; // A
                5'd12 : gf = 35'b11100_10010_10010_11100_10010_10010_11100; // B
                5'd13 : gf = 35'b01110_10001_10000_10000_10000_10001_01110; // C
                5'd14 : gf = 35'b11100_10010_10001_10001_10001_10010_11100; // D
                5'd15 : gf = 35'b11111_10000_11100_10000_10000_10000_11111; // E
                5'd16 : gf = 35'b11111_10000_11100_10000_10000_10000_10000; // F
                5'd17 : gf = 35'b01110_10001_10001_10001_10001_10001_01110; // O
                5'd18 : gf = 35'b10001_10010_10100_11000_10100_10010_10001; // K
                5'd19 : gf = 35'b11100_10001_10001_11100_10010_10010_11110; // R
                5'd20 : gf = 35'b01110_00100_00100_00100_00100_00100_01110; // I
                5'd21 : gf = 35'b10000_10000_10000_10000_10000_10000_11111; // L
                5'd22 : gf = 35'b10001_10001_10001_10001_10001_01010_00100; // V
                5'd23 : gf = 35'b11111_00100_00100_00100_00100_00100_00100; // T
                5'd24 : gf = 35'b01111_10000_10000_01110_00001_00001_11110; // S
                5'd25 : gf = 35'b00000_00000_01110_00000_01110_00000_00000; // =
                5'd26 : gf = 35'b00000_00000_00000_00000_00000_00000_00000; // ' '
                5'd27 : gf = 35'b01000_10100_10010_10001_10000_10000_10000; // N
                5'd28 : gf = 35'b00100_01100_10010_10001_10001_10001_10001; // M
                default: gf = 35'd0;
            endcase
        end
    endfunction

    // ---- raster counters: EDGE-based (see header) ----
    // row == apf_video vline: 0 = first visible line after a VBL
    // falling edge; counts HBL rising edges while !vbl; frozen at 191.
    // col = active-sample index within the line (0..559).
    reg         hbl_d;
    reg         vbl_r;
    reg  [9:0]  col;
    reg  [7:0]  row;
    wire        hbl_rise = ~hbl_d & hbl;
    wire        vbl_fall = vbl_r & ~vbl;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hbl_d <= 1'b1;
            vbl_r <= 1'b1;
            col   <= 10'd0;
            row   <= 8'd0;
        end else begin
            hbl_d <= hbl;
            vbl_r <= vbl;
            if (vbl_fall) begin
                col <= 10'd0;
                row <= 8'd0;
            end else begin
                if (hbl) col <= 10'd0;
                else     col <= col + 10'd1;
                if (!vbl && hbl_rise && row != 8'd191)
                    row <= row + 8'd1;
            end
        end
    end

    // ---- show window (default 5 s @ 14.318 MHz = 71_590_900 cycles) ----
    reg [26:0] show_cnt;
    reg        event_s;
    wire       show_ev;
    wire       show_start;
    assign show_ev      = res_valid_m;
    assign show_start = show_ev && !event_s;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            show_cnt <= 27'd0;
            event_s  <= 1'b0;
        end else begin
            event_s <= show_ev;
            if (show_start)
                show_cnt <= 27'd1;
            else if (show_ev && show_cnt != SHOW_CYCLES)
                show_cnt <= show_cnt + 27'd1;
        end
    end
    wire show;
    // The counter runs to SHOW_CYCLES and holds; the detailed text is
    // visible only while the window is open (1 .. SHOW_CYCLES-1).
    assign show = show_ev && (show_cnt != 27'd0) && (show_cnt != SHOW_CYCLES);

    // ---- line text (latched on the show-start pulse) ----
    reg [4:0] ln1 [0:14];
    reg [4:0] ln2 [0:9];
    reg [4:0] ln3 [0:20];

    // Hex digit -> glyph. The 5-bit add keeps 'F' (n=15 -> 16) from
    // wrapping back to glyph 0 as the 4-bit version did.
    function [4:0] hexg;
        input [3:0] n;
        begin
            hexg = (n < 4'd10) ? {1'b0, n[3:0]} : ({1'b0, n[3:0]} + 5'd1);
        end
    endfunction

    integer di;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (di = 0; di < 15; di = di + 1) ln1[di] <= 5'd0;
            for (di = 0; di < 10; di = di + 1) ln2[di] <= 5'd0;
            for (di = 0; di < 21; di = di + 1) ln3[di] <= 5'd0;
        end else if (show_start) begin
            case (res_code_m)
            2'd0: begin
                // "OK CRC=XXXXXXXX"
                ln1[0] <= GL_O;  ln1[1] <= GL_K;  ln1[2] <= GL_SP;
                ln1[3] <= GL_C5; ln1[4] <= GL_R;  ln1[5] <= GL_C5;
                ln1[6] <= GL_EQ;
                for (di = 0; di < 8; di = di + 1)
                    ln1[7 + di] <= hexg(res_crc_m[31 - di*4 -: 4]);
            end
            2'd1: begin
                // "FAIL OV" / "FAIL TO" / "FAIL IN" / "FAIL ST"
                ln1[0] <= 5'd16; ln1[1] <= 5'd11; ln1[2] <= GL_I;
                ln1[3] <= GL_L;  ln1[4] <= GL_SP;
                case (res_fail_m)
                    2'd1: begin ln1[5] <= GL_O; ln1[6] <= GL_V; end
                    2'd2: begin ln1[5] <= GL_T; ln1[6] <= GL_O; end
                    2'd3: begin ln1[5] <= GL_I; ln1[6] <= GL_N; end
                    default: begin ln1[5] <= GL_S; ln1[6] <= GL_T; end
                endcase
                for (di = 7; di < 15; di = di + 1) ln1[di] <= GL_SP;
            end
            default: begin
                // "NO FILE"
                ln1[0] <= GL_N;  ln1[1] <= GL_O;  ln1[2] <= GL_SP;
                ln1[3] <= 5'd16; ln1[4] <= GL_I;  ln1[5] <= GL_L;
                ln1[6] <= 5'd15;
                for (di = 7; di < 15; di = di + 1) ln1[di] <= GL_SP;
            end
            endcase
            // "N=XXXXXXXX"
            ln2[0] <= GL_N;  ln2[1] <= GL_EQ;
            for (di = 0; di < 8; di = di + 1)
                ln2[2 + di] <= hexg(res_nbytes_m[31 - di*4 -: 4]);
            // "R=NNNNNN C=NNNNNN OTS" (21 chars; full 24-bit counters,
            // 6 hex digits each - the 5-nibble version dropped the low
            // digit and made 128 words read as 8)
            ln3[0]  <= GL_R;  ln3[1]  <= GL_EQ;
            for (di = 0; di < 6; di = di + 1)
                ln3[2 + di]  <= hexg(dbg_rc_m[47 - di*4 -: 4]);   // received
            ln3[8]  <= GL_SP;
            ln3[9]  <= GL_C5; ln3[10] <= GL_EQ;
            for (di = 0; di < 6; di = di + 1)
                ln3[11 + di] <= hexg(dbg_rc_m[23 - di*4 -: 4]);  // committed
            ln3[17] <= GL_SP;
            ln3[18] <= dbg_fl_m[0] ? GL_O : GL_SP;  // O = FIFO overflow
            ln3[19] <= dbg_fl_m[1] ? GL_T : GL_SP;  // T = store timeout
            ln3[20] <= dbg_fl_m[2] ? GL_S : GL_SP;  // S = verifier stuck
        end
    end

    // ---- line 1: 15 chars at X0=460, rows 8..14 ----
    wire        in_x1;
    wire [9:0]  cpx1;
    wire [9:0]  cidx1_w;   // cpx1 / 6 -> 0..14
    wire [9:0]  cin1_w;    // cpx1 % 6 -> 0..5
    wire        in_l1;
    wire [7:0]  r1_w;      // row within line -> 0..6
    wire [4:0]  g1;
    wire [34:0] g1_bits;
    wire [4:0]  r1bits;
    wire        px1;
    assign in_x1   = (col >= 10'd460) && (col < 10'd550);
    assign cpx1    = in_x1 ? (col - 10'd460) : 10'd0;
    assign cidx1_w = cpx1 / 10'd6;
    assign cin1_w  = cpx1 % 10'd6;
    assign in_l1   = (row >= 8'd8) && (row < 8'd15);
    assign r1_w    = in_l1 ? (row - 8'd8) : 8'd0;
    assign g1      = (in_l1 && cidx1_w < 10'd15) ? ln1[cidx1_w[3:0]] : 5'd0;
    assign g1_bits = gf(g1);
    // Row r occupies bits [34-5r : 30-5r] of gf (row0 = MSB). The base
    // is 34-5r for r = 0..6 (range [4:0] at r=6) - no -4 offset.
    assign r1bits  = g1_bits[34 - {2'b00, r1_w[2:0]} * 5'd5 -: 5];
    // Vertical gate per layer: each text line may only draw inside its own
    // row band. Without it the layer keeps rendering (glyph 0 = digit '0',
    // row 0) across every other row and ORs over the active line's text.
    assign px1 = show && !hbl && !vbl && in_x1 && in_l1 && cidx1_w < 10'd15 &&
                cin1_w < 10'd5 && r1bits[3'd4 - cin1_w[2:0]];

    // ---- line 2: 10 chars at X0=460, rows 17..23 ----
    wire        in_x2;
    wire [9:0]  cpx2;
    wire [9:0]  cidx2_w;   // 0..9
    wire [9:0]  cin2_w;    // 0..5
    wire        in_l2;
    wire [7:0]  r2_w;      // 0..6
    wire [4:0]  g2;
    wire [34:0] g2_bits;
    wire [4:0]  r2bits;
    wire        px2;
    assign in_x2   = (col >= 10'd460) && (col < 10'd520);
    assign cpx2    = in_x2 ? (col - 10'd460) : 10'd0;
    assign cidx2_w = cpx2 / 10'd6;
    assign cin2_w  = cpx2 % 10'd6;
    assign in_l2   = (row >= 8'd17) && (row < 8'd24);
    assign r2_w    = in_l2 ? (row - 8'd17) : 8'd0;
    assign g2      = (in_l2 && cidx2_w < 10'd10) ? ln2[cidx2_w[3:0]] : 5'd0;
    assign g2_bits = gf(g2);
    assign r2bits  = g2_bits[34 - {2'b00, r2_w[2:0]} * 5'd5 -: 5];
    assign px2 = show && !hbl && !vbl && in_x2 && in_l2 && cidx2_w < 10'd10 &&
                cin2_w < 10'd5 && r2bits[3'd4 - cin2_w[2:0]];

    // ---- line 3: 21 chars at X0=424, rows 25..31 ----
    wire        in_x3;
    wire [9:0]  cpx3;
    wire [9:0]  cidx3_w;   // 0..20
    wire [9:0]  cin3_w;    // 0..5
    wire        in_l3;
    wire [7:0]  r3_w;      // 0..6
    wire [4:0]  g3;
    wire [34:0] g3_bits;
    wire [4:0]  r3bits;
    wire        px3;
    assign in_x3   = (col >= 10'd424) && (col < 10'd550);
    assign cpx3    = in_x3 ? (col - 10'd424) : 10'd0;
    assign cidx3_w = cpx3 / 10'd6;
    assign cin3_w  = cpx3 % 10'd6;
    assign in_l3   = (row >= 8'd25) && (row < 8'd32);
    assign r3_w    = in_l3 ? (row - 8'd25) : 8'd0;
    assign g3      = (in_l3 && cidx3_w < 10'd21) ? ln3[cidx3_w[4:0]] : 5'd0;
    assign g3_bits = gf(g3);
    assign r3bits  = g3_bits[34 - {2'b00, r3_w[2:0]} * 5'd5 -: 5];
    assign px3 = show && !hbl && !vbl && in_x3 && in_l3 && cidx3_w < 10'd21 &&
                cin3_w < 10'd5 && r3bits[3'd4 - cin3_w[2:0]];

    // ---- unconditional build marker: M 0 <stage> <status>, X0=4 ----
    // Always drawn (independent of storage state) so the next hardware
    // run identifies this bitstream and shows how far the storage path
    // got: 0 none, 1 request, 2 data, 3 all-complete, 4 drain,
    // 5 verify, 6 result latched.
    wire [4:0] status_g;
    assign status_g = !res_valid_m ? GL_SP :
                      (res_code_m == 2'd0) ? GL_O :
                      (res_code_m == 2'd1) ? 5'd16 : 5'd27; // O / F / N
    wire        in_xm;
    wire [9:0]  cpxm;
    wire [9:0]  m_i_w;     // 0..3
    wire [9:0]  m_c_w;     // 0..5
    wire        in_lm;
    wire [4:0]  gm;
    wire [34:0] gm_bits;
    wire [4:0]  rmbits;
    wire        mpx;
    assign in_xm = (col >= 10'd4) && (col < 10'd28);
    assign cpxm  = in_xm ? (col - 10'd4) : 10'd0;
    assign m_i_w = cpxm / 10'd6;
    assign m_c_w = cpxm % 10'd6;
    assign in_lm = (row < 8'd7);   // 7-row glyphs; rows 0..6, L1 starts row 8
    assign gm    = (m_i_w == 10'd0) ? GL_M :
                   (m_i_w == 10'd1) ? 5'd0 :
                   (m_i_w == 10'd2) ? {2'b000, stage_m} : status_g;
    assign gm_bits = gf(gm);
    assign rmbits  = gm_bits[34 - {3'b000, row[2:0]} * 5'd5 -: 5];
    // glyph bit 4 = LEFTMOST pixel, so pixel column c reads bit 4-c
    // (rmbits[c] would mirror every glyph horizontally - 'K', 'R', 'C',
    //  'L', 'F', 'S', 'V' are not left-right symmetric).
    assign mpx = !hbl && !vbl && in_xm && in_lm &&
                m_c_w < 10'd5 && rmbits[3'd4 - m_c_w[2:0]];


    // ---- optional hardware diagnostic rectangle (default off) ----
    wire        in_dr;
    wire        dbg_px;
    assign in_dr  = (col >= 10'd100) && (col < 10'd150) &&
                    (row >= 8'd10) && (row < 8'd13);
    assign dbg_px = DBG_RECT && !hbl && !vbl && in_dr;

    assign rgb_out = (mpx || px1 || px2 || px3 || dbg_px) ? 24'hFFFFFF : rgb_in;


endmodule
