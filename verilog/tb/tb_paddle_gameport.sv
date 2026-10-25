//
// tb_paddle_gameport.sv - J2: Apple II paddle $C07x contract (2026-10-25)
//
// Verifies pdl_timer (the donor P1 block from rtl/apple2_top.v) against
// the Apple II one-shot contract. Donor formula (VERIFIED in sim, 2026-10-25):
//
//     cx = 2800 + 22 * $signed(joy_an[15:8])   (same for cy)
//
// i.e. the axis byte is SIGNED: 0x00 = centre (2800 ticks), 0x80 = -128
// (hard left, clamped to 0 = immediate low), 0x7F = +127 (5650 max).
// NOTE: the plan doc's "value 0 -> immediate, 255 -> 5650" phrasing was a
// mis-statement; the donor's $signed() makes 0 the centre and 0x80 the
// hard stop. The joystick_input outputs are signed patterns (0x00 rest,
// 0x7F right, 0x80/0x81 left), so the formula is the intended one.
//
//   T1 strobe at centre (0x00/0x00) -> PDL high for ~2800 ticks
//   T2 value 0x80 (-128) -> clamped to 0 -> PDL low immediately
//   T3 value 0x7F (+127) -> 5594 -> clamped 5650 -> PDL high ~5650 ticks
//   T4 a strobe that misses the tick edges does NOT re-arm a running
//      counter (the donor model re-arms on tick edge + strobe only)
//   T5 Y axis independent (centre X, 0x80 Y / 0x7F Y)
//
// The tick is a clean 4-phase derived clock (1 clk high, 3 clk low) so
// the tick-edge alignment of the strobe is fully deterministic.
//
`timescale 1ns/10ps
module tb_paddle_gameport;

    reg         clk  = 1'b0;
    reg         tick;
    reg         pdl_strobe = 1'b0;
    reg  [15:0] joy_an = 16'h8080;
    wire        joyx, joyy;

    integer fails = 0;

    // tick generator: 4-clk period, rising edge at tickcnt 0->1
    reg [1:0] tickcnt = 2'd0;
    always @(posedge clk) tickcnt <= tickcnt + 2'd1;
    assign tick = (tickcnt == 2'd1);

    pdl_timer dut (
        .clk(clk),
        .tick(tick),
        .pdl_strobe(pdl_strobe),
        .joy_an(joy_an),
        .joyx(joyx),
        .joyy(joyy)
    );

    always #5 clk = ~clk;   // 100 MHz sim

    task automatic check_range(input integer got, input integer lo,
                               input integer hi, input [255:0] msg);
        begin
            if (got < lo || got > hi) begin
                fails = fails + 1;
                $display("F %0s: got %0d want %0d..%0d", msg, got, lo, hi);
            end
        end
    endtask

    // Strobe guaranteed to overlap a tick rising edge (re-arm).
    // The DUT's edge detector fires one cycle after the tick rise
    // (tickcnt 1->2 edge), so the strobe stays high through that edge.
    task automatic strobe_aligned;
        begin
            wait (tickcnt == 2'd3);
            @(posedge clk);      // 3->0
            pdl_strobe = 1'b1;
            repeat (3) @(posedge clk);   // 0->1, 1->2 (reload), 2->3
            pdl_strobe = 1'b0;
        end
    endtask

    // One-machine-cycle strobe in the middle of the tick low period -
    // never sampled by a tick edge (donor: read not on the tick phase).
    task automatic strobe_misaligned;
        begin
            wait (tickcnt == 2'd2);
            @(posedge clk);      // 2->3
            pdl_strobe = 1'b1;
            @(posedge clk);      // 3->0
            pdl_strobe = 1'b0;
        end
    endtask

    // Count tick rising edges while joyx (which==1) / joyy (which==2) is
    // high (includes the edge where it falls). Module-scope wire refs:
    // a task INPUT port would snapshot the value at call time (LRM) and
    // never see the transition.
    task automatic count_ticks(input integer which, output integer cnt);
        integer c;
        begin
            if (which == 1) begin
                wait (joyx == 1'b1);
                c = 0;
                while (joyx == 1'b1) begin
                    @(posedge tick);
                    c = c + 1;
                end
            end else begin
                wait (joyy == 1'b1);
                c = 0;
                while (joyy == 1'b1) begin
                    @(posedge tick);
                    c = c + 1;
                end
            end
            cnt = c;
        end
    endtask

    integer cx_count, cy_count;

    initial begin : main
        // let the regs settle (cx/cy start at 0)
        repeat (8) @(posedge clk);

        // ---- T1: centre (signed 0) -> 2800 + 22*0 = 2800 ticks -------
        joy_an = 16'h0000;
        strobe_aligned;
        count_ticks(1, cx_count);
        check_range(cx_count, 2797, 2803, "T1 centre X duration");
        $display("T1 centre X: %0d ticks (want ~2800)", cx_count);

        // ---- T2: value 0x80 = -128 -> 2800-2816 = -16 -> clamp 0 ------
        joy_an = 16'h8080;
        strobe_aligned;
        repeat (8) @(posedge tick);   // 8 ticks: any high window is <= 2
        if (joyx !== 1'b0) begin
            fails = fails + 1;
            $display("F T2: joyx still high %0d ticks after strobe", 8);
        end
        $display("T2 hard-left X (0x80): joyx low after strobe");

        // ---- T3: value 0x7F = +127 -> 5594 -> clamp 5650 --------------
        joy_an = 16'h7F7F;
        strobe_aligned;
        count_ticks(1, cx_count);
        check_range(cx_count, 5647, 5653, "T3 max X duration");
        $display("T3 max X: %0d ticks (want ~5650)", cx_count);

        // ---- T4: mid-count strobe that misses tick edges -------------
        joy_an = 16'h0000;
        strobe_aligned;                       // arm: 2800 ticks
        repeat (200) @(posedge tick);         // ~200 of the 2800 elapsed
        if (joyx !== 1'b1) begin
            fails = fails + 1;
            $display("F T4: joyx not high mid-count");
        end
        strobe_misaligned;                    // a $C07x read off-tick
        repeat (20) @(posedge tick);
        if (joyx !== 1'b1) begin
            fails = fails + 1;
            $display("F T4: joyx fell after off-tick strobe");
        end
        // must still run out at the ORIGINAL total, not a fresh 2800
        count_ticks(1, cx_count);
        check_range(cx_count, 2575, 2585, "T4 remaining after off-tick read");
        $display("T4 remaining: %0d ticks (want ~2580 = 2800 - 220, i.e. no re-arm)", cx_count);

        // ---- T5: Y axis independence ----------------------------------
        joy_an = 16'h0080;                    // X centre, Y hard-left
        strobe_aligned;
        repeat (8) @(posedge tick);
        if (joyy !== 1'b0) begin
            fails = fails + 1;
            $display("F T5a: joyy high for Y=0x80");
        end
        count_ticks(1, cx_count);          // X: 2800 minus the 8 ticks elapsed
        check_range(cx_count, 2789, 2799, "T5a X unaffected by Y=0x80");

        joy_an = 16'h007F;                    // Y max -> 5650
        strobe_aligned;
        count_ticks(2, cy_count);
        check_range(cy_count, 5647, 5653, "T5b max Y duration");
        $display("T5b max Y: %0d ticks (want ~5650)", cy_count);

        // ---- verdict ---------------------------------------------------
        if (fails == 0)
            $display("PADDLE GAMEPORT PASS: one-shot centre/zero/max, off-tick read no-rearm, Y independence");
        else
            $fatal(1, "PADDLE GAMEPORT FAIL: %0d errors", fails);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "PADDLE GAMEPORT FAIL: watchdog");
    end

endmodule
