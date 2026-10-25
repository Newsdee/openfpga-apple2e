//
// tb_joystick_input.sv - J1 donor probe (2026-10-25)
//
// Verifies the byte-pinned import of the MiSTer donor joystick_input.sv
// in isolation, before it is wired into the Pocket top:
//   T1 relative accumulation (d-pad +3 per update step)
//   T2 saturation clamp at +254 / -256 (joy_an 127 / 0x80)
//   T3 relative Y axis (digital[2] = up)
//   T4 relative_mode entry resets the accumulator
//   T5 absolute mode: d-pad snap (7F/81) and analog mapping
//   T6 analog deadzone + signed X shaping
//   T7 swap_axes
//   T8 x_center offset
//   T9 paddle path (positive value; Pocket ties paddle=0)
//   T10 joy digital passthrough + axis-masked bits
//
// RELATIVE_UPDATE_CYCLES is overridden to 32 so a full step takes 32
// clocks instead of the production 71,591; the donor's step cadence is
// parameter-scaled, so behaviour at any CYC is the same logic.
//
// NOTE (donor semantics, verified against the source): the relative
// accumulator starts at 0 after reset (joy_an 0 = PDL hard left, NOT
// centre) and the output saturates at 127 (-128); centre (128) is only
// reachable in absolute mode or via the top's face-X centre override.
//
`timescale 1ns/10ps
module tb_joystick_input;

    localparam integer CYC = 32;

    reg         clk      = 1'b0;
    reg         reset    = 1'b1;
    reg  [15:0] jdig     = 16'h0000;
    reg  [15:0] janalog  = 16'h0000;
    reg  [7:0]  paddle   = 8'h00;
    reg         swap     = 1'b0;
    reg         pasx     = 1'b0;
    reg         pasy     = 1'b0;
    reg  [2:0]  xcenter  = 3'd0;
    reg         rel_mode = 1'b0;
    wire [15:0] joy_an;
    wire [7:0]  joy;

    integer fails = 0;

    joystick_input #(.RELATIVE_UPDATE_CYCLES(CYC)) dut (
        .clk(clk),
        .reset(reset),
        .joystick_digital(jdig),
        .joystick_analog(janalog),
        .paddle(paddle),
        .swap_axes(swap),
        .paddle_as_x(pasx),
        .paddle_as_y(pasy),
        .x_center(xcenter),
        .relative_mode(rel_mode),
        .joy_an(joy_an),
        .joy(joy)
    );

    always #5 clk = ~clk;   // 100 MHz sim clock

    // ---- step monitor: counts applied update steps -------------------
    integer steps = 0;
    reg  [8:0] prev_counter = 0;
    always @(posedge clk) begin
        if (dut.relative_update_counter === 0 && prev_counter == CYC - 1)
            steps <= steps + 1;
        prev_counter <= dut.relative_update_counter;
    end

    // ---- helpers -----------------------------------------------------

    task automatic check8(input [7:0] got, input [7:0] exp, input [255:0] msg);
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("F %0s: got %3d (0x%02X) want %3d (0x%02X)",
                         msg, got, got, exp, exp);
            end
        end
    endtask

    // Land exactly k steps later (k > 0), regardless of where in the
    // window we are now.
    task automatic wait_steps(input integer k);
        integer base;
        begin
            base = steps;
            wait (steps >= base + k);
        end
    endtask

    // ---- stimulus / checks -------------------------------------------

    initial begin : main
        #1;
        rel_mode = 1'b1;
        reset    = 1'b1;
        repeat (2) @(posedge clk);
        reset    = 1'b0;
        @(posedge clk);

        // T1: hold digital[0] (right) -> +3 per step
        jdig = 16'h0001;
        wait_steps(10);
        check8(joy_an[15:8], 8'd15, "T1 relative X +10 steps (30>>>1)");
        check8(joy_an[7:0],  8'd0,  "T1 relative Y at rest = 0 (donor)");

        // T2: saturate high
        wait_steps(100);
        check8(joy_an[15:8], 8'd127, "T2 X clamp +254 -> 127");

        // T2: saturate low
        jdig = 16'h0002;    // left -> -3 per step
        wait_steps(200);
        check8(joy_an[15:8], 8'h80, "T2 X clamp -256 -> 0x80");

        // T3: digital[2] (up) -> Y +3 per step
        jdig = 16'h0004;
        wait_steps(10);
        check8(joy_an[7:0], 8'd15, "T3 relative Y +10 steps");

        // T4: entering relative mode resets the accumulator
        rel_mode = 1'b0;
        repeat (3) @(posedge clk);
        rel_mode = 1'b1;
        @(posedge clk);
        check8(joy_an[15:8], 8'd0, "T4 mode-entry reset X");
        check8(joy_an[7:0],  8'd0, "T4 mode-entry reset Y");
        jdig = 16'h0004;
        wait_steps(1);
        check8(joy_an[15:8], 8'd0, "T4 X no delta (Y-only press)");
        check8(joy_an[7:0],  8'd1, "T4 Y one step (3>>>1)");

        // ---- absolute mode -------------------------------------------
        rel_mode = 1'b0;
        jdig     = 16'h0000;
        janalog  = 16'h0000;
        repeat (2) @(posedge clk);

        // T5: d-pad snap
        jdig = 16'h0001;  // right only
        #1;
        check8(joy_an[15:8], 8'h7F, "T5 abs X d-pad right");
        jdig = 16'h0002;  // left only
        #1;
        check8(joy_an[15:8], 8'h81, "T5 abs X d-pad left");
        jdig = 16'h0003;  // both -> analog path (0)
        #1;
        check8(joy_an[15:8], 8'h00, "T5 abs X both held -> 0");
        jdig = 16'h0004;  // up only
        #1;
        check8(joy_an[7:0], 8'h7F, "T5 abs Y d-pad up");
        jdig = 16'h0008;  // down only
        #1;
        check8(joy_an[7:0], 8'h81, "T5 abs Y d-pad down");
        jdig = 16'h0000;

        // T5/T6: analog shaping. Input convention: [7:0]=X, [15:8]=Y.
        // X=127: dz 123, gain 22/16 -> 168 -> clamped 127; Y=100 -> -100 = 0x9C
        janalog = 16'h647F;
        #1;
        check8(joy_an[15:8], 8'h7F, "T6 analog X 127 shaped->127");
        check8(joy_an[7:0],  8'h81, "T6 analog Y 100 shaped->127 -> -127");
        // X=0, Y=127 -> machine Y -127 = 0x81
        janalog = 16'h7F00;
        #1;
        check8(joy_an[15:8], 8'h00, "T6 analog X 0");
        check8(joy_an[7:0],  8'h81, "T6 analog Y 127 -> -127");
        // X=-28: dz -24, gain 22/16 -> -33; Y=0 -> machine 0
        janalog = 16'h00E4;
        #1;
        check8(joy_an[15:8], 8'hDF, "T6 analog X -28 shaped->-33");
        check8(joy_an[7:0],  8'h00, "T6 analog Y 0 -> 0");
        janalog = 16'h0000;

        // T7: swap_axes (X from input byte [15:8], Y from [7:0])
        swap    = 1'b1;
        janalog = 16'h6400;   // swap: X=100 (shaped 132 -> 127), Y=0
        #1;
        check8(joy_an[15:8], 8'h7F, "T7 swap X=100 -> 127");
        check8(joy_an[7:0],  8'h00, "T7 swap Y=0 -> 0");
        swap    = 1'b0;
        #1;
        check8(joy_an[15:8], 8'h00, "T7 unswap X=0");
        janalog = 16'h0000;

        // T8: x_center offset (3'd1 = -16): X raw 16 shapes to 16, -16 -> 0
        xcenter = 3'd1;
        janalog = 16'h0010;
        #1;
        check8(joy_an[15:8], 8'h00, "T8 x_center -16 cancels X=16");
        xcenter = 3'd0;
        #1;
        check8(joy_an[15:8], 8'h10, "T8 x_center 0 leaves X=16");
        janalog = 16'h0000;

        // T9: paddle path. Donor host encoding: input = value + 0x80
        // (biased two's complement; the module sign-flips bit 7).
        pasx    = 1'b1;
        paddle  = 8'h85;   // biased +5
        #1;
        check8(joy_an[15:8], 8'd5, "T9 paddle +5 passthrough");
        paddle  = 8'h7B;   // biased -5
        #1;
        check8(joy_an[15:8], 8'hFB, "T9 paddle -5");
        pasx    = 1'b0;
        paddle  = 8'h00;

        // T10: joy digital passthrough + axis-masked bits
        jdig    = 16'h0055;
        janalog = 16'h0000;
        #1;
        check8(joy, 8'h55, "T10 joy = digital (axes zero)");
        janalog = 16'h007F;   // X=127 non-zero masks joy[1:0]
        #1;
        check8(joy, 8'h54, "T10 joy[1:0] masked by active X axis");

        // ---- verdict ---------------------------------------------------
        if (fails == 0)
            $display("JOYSTICK INPUT PASS: relative, clamp, mode-entry, absolute, swap, center, paddle, joy");
        else
            $fatal(1, "JOYSTICK INPUT FAIL: %0d errors", fails);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "JOYSTICK INPUT FAIL: watchdog");
    end

endmodule
