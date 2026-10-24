//
// tb_reboot_ctl.sv - unit test for the "Reboot on disk change" cold-reboot
// FSM (M1+, 2026-10-24). Short windows (CLR=32, HOLD=16) for speed.
//
// Covers: power-on mount suppression (first rise), second-mount trigger,
// exact CLR/HOLD window shapes, mid-reboot mount ignored (no restart or
// extension), option OFF = no reboot, base-reset abort (async) +
// ever-flag re-arm, repeated changes reboot again.
//
`timescale 1ns/10ps

module tb_reboot_ctl;

    localparam CLK_NS = 20;   // 50 MHz (fast; the DUT is clock-frequency agnostic)
    localparam CLR = 32;
    localparam HOLD = 16;
    localparam WIN = CLR + HOLD;   // 48

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg reboot_opt = 1'b0;
    reg mount_rise = 1'b0;
    wire cold_reset, ram_clear;

    reboot_ctl #(.CLR_CYCLES(CLR), .HOLD_CYCLES(HOLD)) dut (
        .clk(clk), .rst(rst),
        .reboot_opt(reboot_opt), .mount_rise(mount_rise),
        .cold_reset(cold_reset), .ram_clear(ram_clear)
    );

    always #(CLK_NS/2) clk = ~clk;

    integer fails;
    integer rem;

    // one machine cycle
    task cyc;
        begin
            @(negedge clk);
        end
    endtask

    // N machine cycles
    task ncy(input integer n);
        begin
            repeat (n) cyc;
        end
    endtask

    // 1-cycle mount_rise pulse: the DUT's trigger posedge is the one inside
    // this pulse; by the time this returns, cold_reset/ram_clear are
    // already high (NBA of that posedge settled at this negedge).
    task mount_pulse;
        begin
            mount_rise <= 1'b1;
            cyc;
            mount_rise <= 1'b0;
        end
    endtask

    // The window is WIN posedges long (cnt counts them). At the negedge
    // just after posedge k of the window, outputs reflect state k. Count
    // WIN cycles, then one more before asserting the window is over.
    task check_window(input [15:0] n, input [15:0] m, input [63:0] tag);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                if (i < m) begin
                    if (!ram_clear) begin
                        fails = fails + 1;
                        $display("F %0h: ram_clear low at cycle %0d (expected high for first %0d)", tag, i, m);
                    end
                end else begin
                    if (ram_clear) begin
                        fails = fails + 1;
                        $display("F %0h: ram_clear high at cycle %0d (expected low after %0d)", tag, i, m);
                    end
                end
                if (!cold_reset) begin
                    fails = fails + 1;
                    $display("F %0h: cold_reset low at cycle %0d (expected high for %0d)", tag, i, n);
                end
                cyc;
            end
            cyc;   // let the final posedge of the window settle
            if (cold_reset || ram_clear) begin
                fails = fails + 1;
                $display("F %0h: window not over after %0d cycles (cold=%b clr=%b)", tag, n, cold_reset, ram_clear);
            end
        end
    endtask

    // expect both outputs low for n cycles
    task check_quiet(input [15:0] n, input [63:0] tag);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                if (cold_reset || ram_clear) begin
                    fails = fails + 1;
                    $display("F %0h: not quiet at cycle %0d (cold=%b clr=%b)", tag, i, cold_reset, ram_clear);
                end
                cyc;
            end
        end
    endtask

    initial begin
        fails = 0;

        // ================= T1: power-on mount suppressed ================
        rst = 1'b1; reboot_opt = 1'b1; mount_rise = 1'b0;
        ncy(5);
        rst = 1'b0;
        ncy(5);
        mount_pulse;                     // mount #1 (power-on load)
        check_quiet(20, 64'h1);
        if (fails == 0) $display("T1 PASS: first (power-on) mount does not reboot");

        // ================= T2: second mount -> exact cold window ========
        mount_pulse;                     // mount #2 (a disk CHANGE)
        check_window(WIN, CLR, 64'h2);
        check_quiet(10, 64'h21);
        if (fails == 0) $display("T2 PASS: second mount reboots, CLR=%0d then HOLD=%0d, clean exit", CLR, HOLD);

        // ================= T3: mid-reboot mount ignored =================
        rem = 0;
        mount_pulse;                     // mount #3 -> window starts
        ncy(6);
        mount_pulse;                     // mount #4, ~7 cycles into the window
        // The window must NOT restart or extend: the remainder is bounded
        // above by WIN (no restart) and below by WIN/2 (no early exit).
        while (cold_reset) begin
            rem = rem + 1;
            if (rem > WIN + 4) begin
                fails = fails + 1;
                $display("F T3: runaway window (rem=%0d)", rem);
                break;
            end
            cyc;
        end
        if (rem > WIN) $display("F T3: window extended beyond %0d (rem=%0d)", WIN, rem);
        else if (rem < WIN/2) begin
            fails = fails + 1;
            $display("F T3: window truncated to %0d cycles", rem);
        end
        if (ram_clear) begin
            fails = fails + 1;
            $display("F T3: ram_clear still high after the window");
        end
        check_quiet(10, 64'h31);
        if (fails == 0) $display("T3 PASS: mount during reboot is ignored (rem=%0d <= WIN, not restarted)", rem);

        // ================= T4: option OFF -> no reboot ==================
        rst = 1'b1;
        ncy(3);
        rst = 1'b0;
        reboot_opt = 1'b0;
        ncy(3);
        mount_pulse;                     // mount #1 (suppressed anyway)
        mount_pulse;                     // mount #2 - option OFF
        check_quiet(20, 64'h4);
        if (fails == 0) $display("T4 PASS: option OFF -> mounts never reboot");

        // ================= T5: base reset aborts an active reboot =======
        reboot_opt = 1'b1;
        ncy(3);
        mount_pulse;                     // mount #1 (suppressed)
        mount_pulse;                     // mount #2 -> reboot starts
        ncy(10);
        rst = 1'b1;                      // async base reset during the window
        ncy(3);
        if (cold_reset || ram_clear) begin
            fails = fails + 1;
            $display("F T5: reboot survived the base reset (cold=%b clr=%b)", cold_reset, ram_clear);
        end
        rst = 1'b0;
        ncy(3);
        mount_pulse;                     // ever must have re-armed: suppressed
        check_quiet(15, 64'h5);
        if (fails == 0) $display("T5 PASS: base reset aborts reboot and re-arms power-on suppression");

        // ================= T6: reboot works again after the abort =======
        mount_pulse;                     // mount #2 again (opt ON)
        check_window(WIN, CLR, 64'h6);
        if (fails == 0) $display("T6 PASS: subsequent disk changes reboot again");

        if (fails == 0)
            $display("REBOOT CTL PASS: suppression, windows, mid-reboot, opt-off, reset-abort, repeat");
        else
            $fatal(1, "REBOOT CTL FAIL: %0d errors", fails);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "REBOOT CTL FAIL: watchdog");
    end

endmodule
