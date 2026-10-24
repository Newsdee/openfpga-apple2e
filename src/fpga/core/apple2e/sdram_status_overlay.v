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
//     plus (M1 no-boot diagnostics, always-on, NOT gated by the 5 s window):
//       line 4: MT=x RD=NNNNN   (x=image mounted ?; NNNNN=cumulative sd reads)
//       line 5: AC=x MO=x        (x=D1_ACTIVE / D1_MOTOR_ON)
//     Interpretation of the logo stall: MT=0 -> mount never happened;
//     MT=1 + RD=0 -> mounted but engine never reads; MT=1 + RD>0 -> engine reads.
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
    input  wire [2:0]  stage_m,    // furthest storage stage: 0..6 (see header)
    // ---- drive activity (M1 no-boot diagnostics, always-on) ----
    input  wire         drv_mounted,  // mount controller: image mounted ?
    input  wire         drv_active,   // engine D1_ACTIVE (selected-drive motor)
    input  wire         drv_motor,    // engine D1_MOTOR_ON (controller command)
    input  wire [23:0]  drv_reads,    // cumulative sd_buff_wr bytes (saturating)
    input  wire [2:0]   drv_mstate,   // mount-controller state 0=unm 1=mnted 2-4=eject
    input  wire         drv_ack,      // transport sd_ack level (engine read service)
    input  wire         drv_tfault,    // transport fault latch (triggers unmount)
    input  wire         drv_rdreq,    // engine SD read request (woz_sd_rd) level

    // ---- image fingerprint (M1 hardware-load diagnostics; drawn only
    //      when SHOW_FP=1 - see below; last latched verification pass;
    //      zero before the first pass) ----
    // fp_first = file bytes [0:15] (MSB = byte 0); fp_last = bytes [n-16:n-1]
    //   (word-aligned tail frame; see disk_verifier.v header);
    // fp_w = {w0,w1,w2,w3} independent zlib-style CRC32s of byte windows
    // [0:64K) [64K:128K) [128K:192K) [192K:n) (empty window = 0).
    // On-screen (8 bytes fit per line): F= = bytes [0:8], L= = bytes [n-8:n].
    // Compare on-screen values against tools/woz_fingerprint.py on the card
    // file: any W mismatch localizes a hardware-load corruption to a 64 KB
    // region; F=/L= give exact head/tail bytes.
    input  wire [127:0] fp_first,
    input  wire [127:0] fp_last,
    input  wire [127:0] fp_w
    );

    // Show-window length in machine clocks (default = 5 s @ 14.318 MHz;
    // a testbench may shorten it).
    parameter SHOW_CYCLES = 27'd71_590_900;
    // One-shot hardware diagnostic: when compiled 1, draw a persistent
    // white rectangle (rows 10..12, cols 100..149) independent of storage
    // state, results, and font logic - proves the overlay is in the video
    // path regardless of everything else. Shipping builds keep 0.
    parameter DBG_RECT = 1'b0;
    // Image-fingerprint lines (rows 65..95): 0 = shipping build (lines
    // blank, glyph/fp logic trimmed); 1 = build with the M1 hardware-load
    // diagnostic. The top-level FP_DIAG parameter fans this out together
    // with the disk_verifier FP_EN accumulator; tools/woz_fingerprint.py
    // stays the PC oracle for any build that enables it.
    parameter SHOW_FP = 1'b0;
    // Master switch for all overlay drawing: 0 = shipping build (rgb_out is
    // a pure pass-through of rgb_in - no debug lines, marker, fingerprint,
    // or debug rectangle); 1 = hardware-debug build (top-level OVL_DEBUG).
    // Needed because lines 4..6 (MO/ACK/ST-A-F) draw outside the 5 s show
    // window and are not covered by SHOW_FP.
    parameter OVL_DBG = 1'b0;

    // ---- glyph codes ----
    // 0-9 -> 0-9, A=11 B=12 C=13 D=14 E=15 F=16, O=17 K=18 R=19 I=20
    // L=21 V=22 T=23 S=24 '='=25 ' '=26 N=27, M=28
    localparam GL_O = 5'd17, GL_K = 5'd18, GL_R = 5'd19, GL_I = 5'd20;
    localparam GL_L = 5'd21, GL_V = 5'd22, GL_T = 5'd23, GL_S = 5'd24;
    localparam GL_N = 5'd27, GL_M = 5'd28, GL_W = 5'd29;
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
                5'd29 : gf = 35'b10001_10001_10001_10001_10101_10101_01010; // W
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

    // ---- drive-activity readout (always-on, NOT gated by the show window) ----
    // line 4: 13 chars at X0=460, rows 33..39: "MT=x RD=NNNNN" (mounted + reads)
    // line 5: 9 chars  at X0=460, rows 41..47: "AC=x MO=x"  (active + motor)
    wire [4:0] d4 [0:12];
    assign d4[0]  = GL_M;
    assign d4[1]  = GL_T;
    assign d4[2]  = GL_EQ;
    assign d4[3]  = drv_mounted ? 5'd1 : 5'd0;
    assign d4[4]  = GL_SP;
    assign d4[5]  = GL_R;   // 'RD='
    assign d4[6]  = 5'd14;  // 'D'
    assign d4[7]  = GL_EQ;
    assign d4[8]  = hexg(drv_reads[19:16]);
    assign d4[9]  = hexg(drv_reads[15:12]);
    assign d4[10] = hexg(drv_reads[11:8]);
    assign d4[11] = hexg(drv_reads[7:4]);
    assign d4[12] = hexg(drv_reads[3:0]);
    wire        in_x4, in_l4;
    wire [9:0]  cpx4, cidx4_w, cin4_w;
    wire [7:0]  r4_w;
    wire [4:0]  g4;
    wire [34:0] g4_bits;
    wire [4:0]  r4bits;
    wire        px4;
    assign in_x4   = (col >= 10'd460) && (col < 10'd540);
    assign cpx4    = in_x4 ? (col - 10'd460) : 10'd0;
    assign cidx4_w = cpx4 / 10'd6;
    assign cin4_w  = cpx4 % 10'd6;
    assign in_l4   = (row >= 8'd33) && (row < 8'd40);
    assign r4_w    = in_l4 ? (row - 8'd33) : 8'd0;
    assign g4      = (in_l4 && cidx4_w < 10'd13) ? d4[cidx4_w[3:0]] : 5'd0;
    assign g4_bits = gf(g4);
    assign r4bits  = g4_bits[34 - {2'b00, r4_w[2:0]} * 5'd5 -: 5];
    assign px4 = !hbl && !vbl && in_x4 && in_l4 && cidx4_w < 10'd13 &&
                cin4_w < 10'd5 && r4bits[3'd4 - cin4_w[2:0]];
    wire [4:0] d5 [0:8];
    assign d5[0] = 5'd11;  // 'A'
    assign d5[1] = 5'd13;  // 'C'
    assign d5[2] = GL_EQ;
    assign d5[3] = drv_active ? 5'd1 : 5'd0;
    assign d5[4] = GL_SP;
    assign d5[5] = GL_M;   // 'MO='
    assign d5[6] = GL_O;
    assign d5[7] = GL_EQ;
    assign d5[8] = drv_motor ? 5'd1 : 5'd0;
    wire        in_x5, in_l5;
    wire [9:0]  cpx5, cidx5_w, cin5_w;
    wire [7:0]  r5_w;
    wire [4:0]  g5;
    wire [34:0] g5_bits;
    wire [4:0]  r5bits;
    wire        px5;
    assign in_x5   = (col >= 10'd460) && (col < 10'd520);
    assign cpx5    = in_x5 ? (col - 10'd460) : 10'd0;
    assign cidx5_w = cpx5 / 10'd6;
    assign cin5_w  = cpx5 % 10'd6;
    assign in_l5   = (row >= 8'd41) && (row < 8'd48);
    assign r5_w    = in_l5 ? (row - 8'd41) : 8'd0;
    assign g5      = (in_l5 && cidx5_w < 10'd9) ? d5[cidx5_w[3:0]] : 5'd0;
    assign g5_bits = gf(g5);
    assign r5bits  = g5_bits[34 - {2'b00, r5_w[2:0]} * 5'd5 -: 5];
    assign px5 = !hbl && !vbl && in_x5 && in_l5 && cidx5_w < 10'd9 &&
                cin5_w < 10'd5 && r5bits[3'd4 - cin5_w[2:0]];
    // line 6: 11 chars at X0=460, rows 49..55: "ST=x A=x F=x"
    //   ST = mount-controller state (0 unm,1 mnted,2-4 eject); A = sd_ack level;
    //   F  = transport fault. ST!=1 with MT=1 -> controller not really mounted;
    //   A=0 persistently with MT=1 -> transport not servicing the engine's reads.
    wire [4:0] d6 [0:10];
    assign d6[0]  = 5'd19;  // 'S'
    assign d6[1]  = 5'd23;  // 'T'
    assign d6[2]  = GL_EQ;
    assign d6[3]  = hexg({1'b0, drv_mstate[2:0]});
    assign d6[4]  = GL_SP;
    assign d6[5]  = 5'd11;  // 'A'
    assign d6[6]  = GL_EQ;
    assign d6[7]  = drv_ack ? 5'd1 : 5'd0;
    assign d6[8]  = GL_SP;
    assign d6[9]  = 5'd15;  // 'F'
    assign d6[10] = drv_tfault ? 5'd1 : 5'd0;
    wire        in_x6, in_l6;
    wire [9:0]  cpx6, cidx6_w, cin6_w;
    wire [7:0]  r6_w;
    wire [4:0]  g6;
    wire [34:0] g6_bits;
    wire [4:0]  r6bits;
    wire        px6;
    assign in_x6   = (col >= 10'd460) && (col < 10'd526);
    assign cpx6    = in_x6 ? (col - 10'd460) : 10'd0;
    assign cidx6_w = cpx6 / 10'd6;
    assign cin6_w  = cpx6 % 10'd6;
    assign in_l6   = (row >= 8'd49) && (row < 8'd56);
    assign r6_w    = in_l6 ? (row - 8'd49) : 8'd0;
    assign g6      = (in_l6 && cidx6_w < 10'd11) ? d6[cidx6_w[3:0]] : 5'd0;
    assign g6_bits = gf(g6);
    assign r6bits  = g6_bits[34 - {2'b00, r6_w[2:0]} * 5'd5 -: 5];
    assign px6 = !hbl && !vbl && in_x6 && in_l6 && cidx6_w < 10'd11 &&
                cin6_w < 10'd5 && r6bits[3'd4 - cin6_w[2:0]];

    // ---- sticky 'engine read request seen' (M1 no-boot diagnostic) ----
    // Latches on the first woz_sd_req. RQ=0 -> the engine never requested a
    // byte (mount/reset/parser-start path); RQ=1 -> it requested (transport/
    // fetch/SDRAM-completion path). Cleared only by power-on reset, not by
    // machine reset, so a late request is retained for the capture.
    reg rd_req_seen = 1'b0;
    always @(posedge clk or posedge reset) begin
        if (reset)
            rd_req_seen <= 1'b0;
        else if (drv_rdreq)
            rd_req_seen <= 1'b1;
    end

    // line 7: 4 chars at X0=460, rows 57..63: "RQ=x"
    wire [4:0] d7 [0:3];
    assign d7[0] = 5'd17;  // 'R'
    assign d7[1] = 5'd18;  // 'Q'
    assign d7[2] = GL_EQ;
    assign d7[3] = rd_req_seen ? 5'd1 : 5'd0;
    wire        in_x7, in_l7;
    wire [9:0]  cpx7, cidx7_w, cin7_w;
    wire [7:0]  r7_w;
    wire [4:0]  g7;
    wire [34:0] g7_bits;
    wire [4:0]  r7bits;
    wire        px7;
    assign in_x7   = (col >= 10'd460) && (col < 10'd484);
    assign cpx7    = in_x7 ? (col - 10'd460) : 10'd0;
    assign cidx7_w = cpx7 / 10'd6;
    assign cin7_w  = cpx7 % 10'd6;
    assign in_l7   = (row >= 8'd57) && (row < 8'd64);
    assign r7_w    = in_l7 ? (row - 8'd57) : 8'd0;
    assign g7      = (in_l7 && cidx7_w < 10'd4) ? d7[cidx7_w[3:0]] : 5'd0;
    assign g7_bits = gf(g7);
    assign r7bits  = g7_bits[34 - {2'b00, r7_w[2:0]} * 5'd5 -: 5];
    assign px7 = !hbl && !vbl && in_x7 && in_l7 && cidx7_w < 10'd4 &&
                cin7_w < 10'd5 && r7bits[3'd4 - cin7_w[2:0]];

    // ---- image fingerprint readout (SHOW_FP-gated, M1 hardware-load diagnostic) ----
    // line 8:  24 chars at X0=406, rows 65..71: "W0=XXXXXXXX W1=XXXXXXXX"
    // line 9:  24 chars at X0=406, rows 73..79: "W2=XXXXXXXX W3=XXXXXXXX"
    // line 10: 18 chars at X0=442, rows 81..87: "F=XXXXXXXXXXXXXXXX" (bytes 0..15)
    // line 11: 18 chars at X0=442, rows 89..95: "L=XXXXXXXXXXXXXXXX" (last 16)
    // fp_w = {w0, w1, w2, w3}; fp_first/fp_last MSB = the older byte.
    wire [4:0] f8 [0:23];
    assign f8[0]  = GL_W;  assign f8[1]  = 5'd0;  assign f8[2]  = GL_EQ;
    assign f8[3]  = hexg(fp_w[127:124]); assign f8[4]  = hexg(fp_w[123:120]);
    assign f8[5]  = hexg(fp_w[119:116]); assign f8[6]  = hexg(fp_w[115:112]);
    assign f8[7]  = hexg(fp_w[111:108]); assign f8[8]  = hexg(fp_w[107:104]);
    assign f8[9]  = hexg(fp_w[103:100]); assign f8[10] = hexg(fp_w[99:96]);
    assign f8[11] = GL_SP;
    assign f8[12] = GL_W;  assign f8[13] = 5'd1;  assign f8[14] = GL_EQ;
    assign f8[15] = hexg(fp_w[95:92]);  assign f8[16] = hexg(fp_w[91:88]);
    assign f8[17] = hexg(fp_w[87:84]);  assign f8[18] = hexg(fp_w[83:80]);
    assign f8[19] = hexg(fp_w[79:76]);  assign f8[20] = hexg(fp_w[75:72]);
    assign f8[21] = hexg(fp_w[71:68]);  assign f8[22] = hexg(fp_w[67:64]);
    assign f8[23] = 5'd26;   // blank (line is 24 slots: 11 + SP + 12)
    wire        in_x8, in_l8;
    wire [9:0]  cpx8, cidx8_w, cin8_w;
    wire [7:0]  r8_w;
    wire [4:0]  g8;
    wire [34:0] g8_bits;
    wire [4:0]  r8bits;
    wire        px8;
    assign in_x8   = (col >= 10'd406) && (col < 10'd550);
    assign cpx8    = in_x8 ? (col - 10'd406) : 10'd0;
    assign cidx8_w = cpx8 / 10'd6;
    assign cin8_w  = cpx8 % 10'd6;
    assign in_l8   = (row >= 8'd65) && (row < 8'd72);
    assign r8_w    = in_l8 ? (row - 8'd65) : 8'd0;
    assign g8      = (in_l8 && cidx8_w < 10'd24) ? f8[cidx8_w[4:0]] : 5'd0;
    assign g8_bits = gf(g8);
    assign r8bits  = g8_bits[34 - {2'b00, r8_w[2:0]} * 5'd5 -: 5];
    assign px8 = SHOW_FP && !hbl && !vbl && in_x8 && in_l8 && cidx8_w < 10'd24 &&
                cin8_w < 10'd5 && r8bits[3'd4 - cin8_w[2:0]];
    wire [4:0] f9 [0:23];
    assign f9[0]  = GL_W;  assign f9[1]  = 5'd2;  assign f9[2]  = GL_EQ;
    // fp_w = {w0[127:96], w1[95:64], w2[63:32], w3[31:0]}
    assign f9[3]  = hexg(fp_w[63:60]); assign f9[4]  = hexg(fp_w[59:56]);
    assign f9[5]  = hexg(fp_w[55:52]); assign f9[6]  = hexg(fp_w[51:48]);
    assign f9[7]  = hexg(fp_w[47:44]); assign f9[8]  = hexg(fp_w[43:40]);
    assign f9[9]  = hexg(fp_w[39:36]); assign f9[10] = hexg(fp_w[35:32]);
    assign f9[11] = GL_SP;
    assign f9[12] = GL_W;  assign f9[13] = 5'd3;  assign f9[14] = GL_EQ;
    assign f9[15] = hexg(fp_w[31:28]); assign f9[16] = hexg(fp_w[27:24]);
    assign f9[17] = hexg(fp_w[23:20]); assign f9[18] = hexg(fp_w[19:16]);
    assign f9[19] = hexg(fp_w[15:12]); assign f9[20] = hexg(fp_w[11:8]);
    assign f9[21] = hexg(fp_w[7:4]);   assign f9[22] = hexg(fp_w[3:0]);
    assign f9[23] = 5'd26;   // blank (line is 24 slots: 11 + SP + 12)
    wire        in_x9, in_l9;
    wire [9:0]  cpx9, cidx9_w, cin9_w;
    wire [7:0]  r9_w;
    wire [4:0]  g9;
    wire [34:0] g9_bits;
    wire [4:0]  r9bits;
    wire        px9;
    assign in_x9   = (col >= 10'd406) && (col < 10'd550);
    assign cpx9    = in_x9 ? (col - 10'd406) : 10'd0;
    assign cidx9_w = cpx9 / 10'd6;
    assign cin9_w  = cpx9 % 10'd6;
    assign in_l9   = (row >= 8'd73) && (row < 8'd80);
    assign r9_w    = in_l9 ? (row - 8'd73) : 8'd0;
    assign g9      = (in_l9 && cidx9_w < 10'd24) ? f9[cidx9_w[4:0]] : 5'd0;
    assign g9_bits = gf(g9);
    assign r9bits  = g9_bits[34 - {2'b00, r9_w[2:0]} * 5'd5 -: 5];
    assign px9 = SHOW_FP && !hbl && !vbl && in_x9 && in_l9 && cidx9_w < 10'd24 &&
                cin9_w < 10'd5 && r9bits[3'd4 - cin9_w[2:0]];
    wire [4:0] f10 [0:17];
    assign f10[0]  = 5'd16;   // 'F' = first-16-bytes marker
    assign f10[1]  = GL_EQ;
    // byte i of fp_first sits at bits [127 - i*8 -: 8]; MSB nibble first
    assign f10[2]  = hexg(fp_first[127:124]); assign f10[3]  = hexg(fp_first[123:120]);
    assign f10[4]  = hexg(fp_first[119:116]); assign f10[5]  = hexg(fp_first[115:112]);
    assign f10[6]  = hexg(fp_first[111:108]); assign f10[7]  = hexg(fp_first[107:104]);
    assign f10[8]  = hexg(fp_first[103:100]); assign f10[9]  = hexg(fp_first[99:96]);
    assign f10[10] = hexg(fp_first[95:92]);   assign f10[11] = hexg(fp_first[91:88]);
    assign f10[12] = hexg(fp_first[87:84]);   assign f10[13] = hexg(fp_first[83:80]);
    assign f10[14] = hexg(fp_first[79:76]);   assign f10[15] = hexg(fp_first[75:72]);
    assign f10[16] = hexg(fp_first[71:68]);   assign f10[17] = hexg(fp_first[67:64]);
    wire        in_x10, in_l10;
    wire [9:0]  cpx10, cidx10_w, cin10_w;
    wire [7:0]  r10_w;
    wire [4:0]  g10;
    wire [34:0] g10_bits;
    wire [4:0]  r10bits;
    wire        px10;
    assign in_x10   = (col >= 10'd442) && (col < 10'd550);
    assign cpx10    = in_x10 ? (col - 10'd442) : 10'd0;
    assign cidx10_w = cpx10 / 10'd6;
    assign cin10_w  = cpx10 % 10'd6;
    assign in_l10   = (row >= 8'd81) && (row < 8'd88);
    assign r10_w    = in_l10 ? (row - 8'd81) : 8'd0;
    assign g10      = (in_l10 && cidx10_w < 10'd18) ? f10[cidx10_w[4:0]] : 5'd0;
    assign g10_bits = gf(g10);
    assign r10bits  = g10_bits[34 - {2'b00, r10_w[2:0]} * 5'd5 -: 5];
    assign px10 = SHOW_FP && !hbl && !vbl && in_x10 && in_l10 && cidx10_w < 10'd18 &&
                cin10_w < 10'd5 && r10bits[3'd4 - cin10_w[2:0]];
    // line 11: 18 chars at X0=442, rows 89..95: "L=XXXXXXXXXXXXXXXX"
    // 16 hex chars = 8 bytes: the LOW 64 bits of fp_last = the file's
    // last 8 bytes (bytes n-8..n-1). F= likewise shows the FIRST 8 bytes.
    // (A 32-hex-char 16-byte line would need 34 columns = 204 px, which
    // does not fit in the 560-sample active run.)
    wire [4:0] f11 [0:17];
    assign f11[0]  = GL_L;    // 'L' = last-8-bytes marker
    assign f11[1]  = GL_EQ;
    assign f11[2]  = hexg(fp_last[63:60]);  assign f11[3]  = hexg(fp_last[59:56]);
    assign f11[4]  = hexg(fp_last[55:52]);  assign f11[5]  = hexg(fp_last[51:48]);
    assign f11[6]  = hexg(fp_last[47:44]);  assign f11[7]  = hexg(fp_last[43:40]);
    assign f11[8]  = hexg(fp_last[39:36]);  assign f11[9]  = hexg(fp_last[35:32]);
    assign f11[10] = hexg(fp_last[31:28]);  assign f11[11] = hexg(fp_last[27:24]);
    assign f11[12] = hexg(fp_last[23:20]);  assign f11[13] = hexg(fp_last[19:16]);
    assign f11[14] = hexg(fp_last[15:12]);  assign f11[15] = hexg(fp_last[11:8]);
    assign f11[16] = hexg(fp_last[7:4]);    assign f11[17] = hexg(fp_last[3:0]);
    wire        in_x11, in_l11;
    wire [9:0]  cpx11, cidx11_w, cin11_w;
    wire [7:0]  r11_w;
    wire [4:0]  g11;
    wire [34:0] g11_bits;
    wire [4:0]  r11bits;
    wire        px11;
    assign in_x11   = (col >= 10'd442) && (col < 10'd550);
    assign cpx11    = in_x11 ? (col - 10'd442) : 10'd0;
    assign cidx11_w = cpx11 / 10'd6;
    assign cin11_w  = cpx11 % 10'd6;
    assign in_l11   = (row >= 8'd89) && (row < 8'd96);
    assign r11_w    = in_l11 ? (row - 8'd89) : 8'd0;
    assign g11      = (in_l11 && cidx11_w < 10'd18) ? f11[cidx11_w[4:0]] : 5'd0;
    assign g11_bits = gf(g11);
    assign r11bits  = g11_bits[34 - {2'b00, r11_w[2:0]} * 5'd5 -: 5];
    assign px11 = SHOW_FP && !hbl && !vbl && in_x11 && in_l11 && cidx11_w < 10'd18 &&
                cin11_w < 10'd5 && r11bits[3'd4 - cin11_w[2:0]];

    wire ovl_px = mpx || px1 || px2 || px3 || px4 || px5 || px6 || px7 ||
                  px8 || px9 || px10 || px11 || dbg_px;
    assign rgb_out = (OVL_DBG && ovl_px) ? 24'hFFFFFF : rgb_in;


endmodule
