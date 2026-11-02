//
// tb_reboot_ctl.sv - unit test for the "Reboot on disk change" cold-reboot
// FSM (M1+, 2026-10-24; updated for the clr_done sweep handshake).
//
// The CLR phase now ends when the RAM write-sweep reports clr_done (one
// pulse at the end of the sweep), bounded by CLR_TIMEOUT; the HOLD phase
// then keeps the machine in reset. The TB models the sweep with a counter
// that asserts clr_done one cycle after D cycles of ram_clear (D =
// tb_sweep_len), mirroring the top's 65,536-cycle sweep at a short D.
//
// Covers: power-on mount suppression (first rise), second-mount trigger
// with exact CLR(handshake)/HOLD window shape, mid-reboot mount ignored
// (no restart or extension), option OFF = no reboot, base-reset abort
// (async) + ever-flag re-arm, repeated changes reboot again, the
// CLR_TIMEOUT path when clr_done never comes, and (2026-10-30) the
// osk_cold_req path: an OSK Reset release forces a cold reboot with the
// option OFF (not gated by reboot_opt), glitch-free (cold_reset high on
// the request cycle itself via the combinational OR), and a request
// during an active reboot neither restarts nor extends the window.
//
`timescale 1ns/10ps

module tb_reboot_ctl;

    localparam CLK_NS = 20;   // 50 MHz (fast; the DUT is clock-frequency agnostic)
    localparam HOLD = 16;
    localparam CLR_TO = 64;   // safety bound (T7 uses it; D=32 normally beats it)
    localparam SWEEP = 32;    // tb sweep length D (stands in for 65,536)
    localparam CLR_CYC = SWEEP + 1;          // ram_clear cycles (handshake at D+1)
    localparam WIN = CLR_CYC + HOLD;         // 49 (trigger posedge shared with HOLD)

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg reboot_opt = 1'b0;
    reg mount_rise = 1'b0;
    reg osk_cold_req = 1'b0;
    reg tb_done_en = 1'b1;
    wire cold_reset, ram_clear, clr_done;

    // TB model of the RAM sweep's completion pulse: one cycle high after
    // D cycles of ram_clear (same shape as the top's ram_clear_done).
    reg [31:0] tb_clear_cnt = 0;
    always @(posedge clk) begin
        if (ram_clear)
            tb_clear_cnt <= tb_clear_cnt + 32'd1;
        else
            tb_clear_cnt <= 32'd0;
    end
    assign clr_done = tb_done_en && (tb_clear_cnt == SWEEP);

    reboot_ctl #(.CLR_TIMEOUT(CLR_TO), .HOLD_CYCLES(HOLD)) dut (
        .clk(clk), .rst(rst),
        .reboot_opt(reboot_opt), .mount_rise(mount_rise), .clr_done(clr_done),
        .osk_cold_req(osk_cold_req),
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

    // 1-cycle osk_cold_req pulse: models the synchronized falling-edge
    // pulse the top derives from the OSK Reset release. The DUT latches
    // it on the posedge inside the pulse. Glitch check inside: cold_reset
    // must be high on the request cycle itself (the DUT ORs the request
    // combinationally, so no out-of-reset gap before `active` registers).
    task osk_pulse;
        begin
            osk_cold_req <= 1'b1;
            #1;   // let the NBA settle within this timestep
            if (!cold_reset) begin
                fails = fails + 1;
                $display("F osk: cold_reset not high on the request cycle (glitch) - cold=%b req=%b", cold_reset, osk_cold_req);
            end
            cyc;
            osk_cold_req <= 1'b0;
        end
    endtask

    // Window check: ram_clear high for the first m cycles, cold_reset high
    // for all n cycles, both low after the window settles.
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
        rst = 1'b1; reboot_opt = 1'b1; mount_rise = 1'b0; tb_done_en = 1'b1;
        ncy(5);
        rst = 1'b0;
        ncy(5);
        mount_pulse;                     // mount #1 (power-on load)
        check_quiet(20, 64'h1);
        if (fails == 0) $display("T1 PASS: first (power-on) mount does not reboot");

        // ================= T2: second mount -> exact cold window ========
        // CLR ends on the sweep's done pulse (SWEEP+1 cycles), then HOLD.
        mount_pulse;                     // mount #2 (a disk CHANGE)
        check_window(WIN, CLR_CYC, 64'h2);
        check_quiet(10, 64'h21);
        if (fails == 0) $display("T2 PASS: second mount reboots, CLR=%0d (sweep done) then HOLD=%0d, clean exit", CLR_CYC, HOLD);

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
        check_window(WIN, CLR_CYC, 64'h6);
        if (fails == 0) $display("T6 PASS: subsequent disk changes reboot again");

        // ================= T7: clr_done never comes -> timeout ==========
        // The safety bound ends the CLR phase at CLR_TIMEOUT cycles; HOLD
        // still follows, so the machine always comes back (no stuck reset).
        tb_done_en = 1'b0;
        mount_pulse;                     // mount #3 (opt ON, done disabled)
        rem = 0;
        while (cold_reset) begin
            rem = rem + 1;
            if (rem > CLR_TO + HOLD + 8) begin
                fails = fails + 1;
                $display("F T7: runaway timeout window (rem=%0d)", rem);
                break;
            end
            cyc;
        end
        if (rem != CLR_TO + HOLD) begin
            fails = fails + 1;
            $display("F T7: timeout window %0d (want %0d = CLR_TIMEOUT %0d + HOLD %0d)",
                     rem, CLR_TO + HOLD, CLR_TO, HOLD);
        end
        check_quiet(10, 64'h71);
        tb_done_en = 1'b1;
        if (fails == 0) $display("T7 PASS: missing clr_done falls back to the CLR_TIMEOUT bound (window=%0d)", rem);

        // ============ T8: OSK Reset release -> cold boot, opt OFF =========
        // An explicit OSK Reset must NOT be gated by reboot_opt: it runs
        // the full CLR/HOLD window even with the option OFF.
        reboot_opt = 1'b0;
        ncy(3);
        osk_pulse;                     // 1-cycle request (glitch checked inside)
        check_window(WIN, CLR_CYC, 64'h8);
        check_quiet(10, 64'h81);
        if (fails == 0) $display("T8 PASS: OSK reset release cold-boots with the option OFF (window=%0d)", WIN);

        // ============ T9: OSK request mid-reboot: no restart/extend =====
        reboot_opt = 1'b1;
        ncy(3);
        osk_pulse;                     // request #1 -> window starts
        ncy(6);
        osk_pulse;                     // request #2, ~7 cycles into the window
        rem = 0;
        while (cold_reset) begin
            rem = rem + 1;
            if (rem > WIN + 4) begin
                fails = fails + 1;
                $display("F T9: runaway window (rem=%0d)", rem);
                break;
            end
            cyc;
        end
        if (rem > WIN) $display("F T9: window extended beyond %0d (rem=%0d)", WIN, rem);
        else if (rem < WIN/2) begin
            fails = fails + 1;
            $display("F T9: window truncated to %0d cycles", rem);
        end
        check_quiet(10, 64'h91);
        if (fails == 0) $display("T9 PASS: OSK request during reboot is ignored (rem=%0d <= WIN, not restarted)", rem);

        if (fails == 0)
            $display("REBOOT CTL PASS: suppression, handshake window, mid-reboot, opt-off, reset-abort, repeat, timeout, osk-cold");
        else
            $fatal(1, "REBOOT CTL FAIL: %0d errors", fails);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "REBOOT CTL FAIL: watchdog");
    end

endmodule
