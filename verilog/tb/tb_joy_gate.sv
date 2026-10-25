//
// tb_joy_gate.sv - J3: OSK/joystick gate (2026-10-25)
//
// Instantiates the real apple2e_osk + the donor joystick_input with the
// SAME gating wires the top uses (joy_enable = ~osk_visible, the gated
// step clock, the face-X centre override) and verifies:
//   T1 OSK off:  d-pad relative accumulation runs
//   T2 OSK on:   the accumulator FREEZES (not zeroed) while visible
//   T3 OSK on:  the fire-button contribution to GAMEPORT is gated
//   T4 OSK on:  the face-X centre override is gated (no override)
//   T5 OSK off: accumulation resumes from the frozen value; the
//               centre override works
//
// The OSK's button path is the real one (debounce ~20480 cycles,
// release ~430000 cycles at the TB clock).
//
// RUN WITH CWD = Apple-II_MiSTer/ repo root (the OSK's font ROM
// $readmemh "rtl/roms/video2.hex" is CWD-relative - same convention as
// the wrapper-level keyboard TBs).
//
`timescale 1ns/10ps
module tb_joy_gate;

    localparam integer CYC = 64;   // fast steps for the TB

    reg         clk    = 1'b0;
    reg         reset  = 1'b1;
    reg  [31:0] key    = 32'h0;
    // OSK
    wire        osk_video, osk_hblank_unused;
    wire [23:0] osk_rgb24;
    wire [7:0]  osk_K;
    wire        osk_akd, osk_open_apple, osk_closed_apple, osk_cmd_reset;
    wire        osk_visible;
    // joystick
    wire [15:0] joy_an;
    wire [7:0]  joy;

    integer fails = 0;

    apple2e_osk osk (
        .clk(clk),
        .reset(reset),
        .cont1_key(key),
        .video_in(1'b0),
        .hblank(1'b0),
        .vblank(1'b0),
        .video_out(osk_video),
        .video_rgb24(osk_rgb24),
        .K(osk_K),
        .reads(1'b0),
        .akd(osk_akd),
        .open_apple(osk_open_apple),
        .closed_apple(osk_closed_apple),
        .command_reset(osk_cmd_reset),
        .osk_visible(osk_visible)
    );

    // ---- top-identical gating ----------------------------------------
    wire        joy_enable = ~osk_visible;
    reg  [1:0]  joy_div = 2'd0;
    // "normal" speed = 50% of the machine clock
    wire        joy_gate  = joy_div[0];
    wire        joy_clk   = clk & joy_gate & joy_enable;
    always @(posedge clk) joy_div <= joy_div + 2'b01;

    wire [15:0] joy_dig = {8'b0,
                           key[7], key[6], key[5], key[4],
                           key[1], key[0], key[2], key[3]};
    // NOTE: key goes through the top's 3FF there; the TB drives it
    // stably, so direct connection is equivalent.
    joystick_input #(.RELATIVE_UPDATE_CYCLES(CYC)) dut (
        .clk(joy_clk),
        .reset(reset),
        .joystick_digital(joy_dig),
        .joystick_analog(16'h0),
        .paddle(8'h0),
        .swap_axes(1'b0),
        .paddle_as_x(1'b0),
        .paddle_as_y(1'b0),
        .x_center(3'd0),
        .relative_mode(1'b1),
        .joy_an(joy_an),
        .joy(joy)
    );
    wire [15:0] joy_an_eff = (joy[6] & joy_enable) ? 16'h0000 : joy_an;

    always #5 clk = ~clk;   // 100 MHz

    // ---- step monitor --------------------------------------------------
    integer steps = 0;
    reg [7:0] prev_counter = 0;
    always @(posedge clk) begin
        if (dut.relative_update_counter === 0 && prev_counter == CYC - 1)
            steps <= steps + 1;
        prev_counter <= dut.relative_update_counter;
    end

    task automatic wait_steps(input integer k);
        integer base;
        begin
            base = steps;
            wait (steps >= base + k);
        end
    endtask

    task automatic check(input integer cond, input [255:0] msg);
        begin
            if (!cond) begin
                fails = fails + 1;
                $display("F %0s", msg);
            end
        end
    endtask

    integer x0;
    integer tw;

    initial begin : main
        #1;
        reset = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // ---- T1: OSK off, d-pad right accumulates ---------------------
        key = 32'h0000_0008;   // dpad_right
        wait_steps(20);
        x0 = joy_an[15:8];
        check(x0 == 30, "T1 relative X after 20 steps (=30)");
        $display("T1: joy_anX=%0d (want 30), osk_visible=%b", x0, osk_visible);

        // ---- T2: OSK on -> frozen --------------------------------------
        key = 32'h0000_8000;   // start only (no d-pad: X holds at 30)
        wait (osk_visible == 1'b1);
        check(joy_enable == 1'b0, "T2 joy_enable closed while OSK visible");
        x0 = joy_an[15:8];
        check(x0 == 30, "T2 X still 30 while waiting for the OSK");
        key = 32'h0000_8008;   // start + dpad_right (gated: must not move)
        // Let 20 machine-update windows elapse (20 steps x CYC x 2 for
        // the 50% gate). The module clock is gated, so no steps apply.
        for (tw = 0; tw < 20 * CYC * 2; tw = tw + 1) @(posedge clk);
        // ...but the module clock is gated, so no steps are applied
        check(joy_an[15:8] == x0, "T2 accumulator frozen while OSK visible");
        check(osk_visible == 1'b1, "T2 OSK still visible");
        $display("T2: frozen at %0d", x0);

        // ---- T3: fire button gated while OSK visible --------------------
        key = 32'h0000_8010;   // start + face A
        repeat (10) @(posedge clk);
        check(joy[4] == 1'b1, "T3 joy[4] live from face A");
        check((joy[4] & joy_enable) == 1'b0, "T3 GAMEPORT fire contribution gated");

        // ---- T4: centre override gated while OSK visible ----------------
        key = 32'h0000_8040;   // start + face X
        repeat (10) @(posedge clk);
        check(joy[6] == 1'b1, "T4 joy[6] live from face X");
        check(joy_an_eff == joy_an, "T4 centre override inert while OSK visible");

        // ---- T5: OSK off -> resume + override works ---------------------
        // The OSK toggles on PRESS edges: release start, wait for the
        // release latch to clear, press again to toggle it off.
        key = 32'h0000_0008;   // start released (right still held)
        wait (osk.btn_latched[6] == 1'b0);
        key = 32'h0000_8008;   // press start again
        wait (osk_visible == 1'b0);
        check(joy_enable == 1'b1, "T5 joy_enable reopened");
        wait_steps(20);
        check(joy_an[15:8] == x0 + 30, "T5 resumed from frozen value");
        $display("T5: resumed to %0d", joy_an[15:8]);

        // centre override active with OSK off
        key = 32'h0000_0040;   // face X only
        repeat (10) @(posedge clk);
        check(joy_an_eff == 16'h0000, "T5 centre override -> signed 0");
        key = 32'h0000_0000;
        repeat (10) @(posedge clk);
        check(joy_an_eff == joy_an, "T5 override released");

        // ---- verdict -----------------------------------------------------
        if (fails == 0)
            $display("JOY GATE PASS: accumulate, freeze-on-OSK, gated fire/centre, resume");
        else
            $fatal(1, "JOY GATE FAIL: %0d errors", fails);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "JOY GATE FAIL: watchdog");
    end

endmodule
