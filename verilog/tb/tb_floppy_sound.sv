// tb_floppy_sound.sv - donor-level harness for src/fpga/core/sound/
// floppy_sound.sv (PLAN_FLOPPY_SOUND_PORT section 4.2, items a-c).
//
// PREP-stage TB: exercises the vendored donor standalone (no WOZ engine,
// no speaker_i2s). The full-chain checks (4.2d: through speaker_i2s,
// gate-off bit-identity) land with the mixer extension.
//
// Donor facts baked into the checks (from the source + NOTICE):
//  - outputs are 10-bit UNSIGNED amplitudes; 0 = idle (zero-idle rule)
//  - motor hum envelope ramps 15 steps x 190909 clk (~2.86 s at 14.318
//    MHz... no: 2,863,635 clk = ~200 ms) - tests use 3.1M-clk windows
//  - the noise LFSR advances ONLY while motor_audible (a motor input OR
//    a live envelope) - trk0-knock and io-texture noise gates need a
//    running LFSR; with motor-on + envelope 0 the motor SAMPLES are 0
//    (level product = 0), so io/stop peaks stay exact
//  - step clunk (step_sample) is ungated - works with the motor off
//  - gain ladder: 0=1x, 1=2x, 2=4x (exact while under the per-gain
//    saturation thresholds 511/255)
//  - pan: 0=Center (both), 1=Left, 2=Right, 3=Drives (d1->L, d2->R)
//
// Run: cd verilog && bash run_tb_floppy_sound.sh
`timescale 1ns/1ps

module tb_floppy_sound;
    reg        clk = 0;
    reg        reset = 0;
    reg        enable = 0;
    reg  [1:0] gain = 2'd0;
    reg  [1:0] pan  = 2'd3;
    reg        drive1_motor = 0, drive2_motor = 0;
    reg        drive1_io = 0, drive2_io = 0;
    reg        drive1_step = 0, drive2_step = 0;
    reg        drive1_track_zero_step = 0, drive2_track_zero_step = 0;
    wire [9:0] sample, sample_r;

    floppy_sound dut (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .gain(gain),
        .pan(pan),
        .drive1_motor(drive1_motor),
        .drive2_motor(drive2_motor),
        .drive1_io(drive1_io),
        .drive2_io(drive2_io),
        .drive1_step(drive1_step),
        .drive2_step(drive2_step),
        .drive1_track_zero_step(drive1_track_zero_step),
        .drive2_track_zero_step(drive2_track_zero_step),
        .sample(sample),
        .sample_r(sample_r)
    );

    initial forever #35 clk = ~clk;   // ~14.3 MHz

    integer failures = 0;
    task check(input [255:0] name, input cond);
        begin
            if (cond) $display("PASS %0s", name);
            else begin failures = failures + 1; $display("FAIL %0s", name); end
        end
    endtask

    // Full re-arm: enable=0 resets the donor (envelopes, LFSR seed
    // 13'h1FFF, all counters) - cheaper than the hardware reset and
    // keeps every test group at envelope 0 unless it ramps deliberately.
    task rearm();
        begin
            enable = 0;
            repeat (20) @(posedge clk);
            enable = 1;
            repeat (20) @(posedge clk);
        end
    endtask

    // Motor on long enough for the LFSR to be live (envelope still 0:
    // the first envelope step lands only after 190909 divider ticks).
    task motor_warm();
        begin
            drive1_motor = 1;
            repeat (10_000) @(posedge clk);
        end
    endtask

    // One-clock event pulse (two clocks wide for phase safety).
    task pulse(input integer which);
        begin
            case (which)
                1: drive1_io = 1;
                2: drive1_step = 1;
                3: drive1_track_zero_step = 1;
            endcase
            repeat (2) @(posedge clk);
            case (which)
                1: drive1_io = 0;
                2: drive1_step = 0;
                3: drive1_track_zero_step = 0;
            endcase
        end
    endtask

    // Sample n clocks; report per-channel peak, non-zero count, and
    // whether every sample was zero.
    task measure_window(input integer n,
                        output integer pk_l, output integer pk_r,
                        output integer nnz_l, output integer nnz_r,
                        output integer all_zero);
        integer i;
        integer s;
        begin
            pk_l = 0; pk_r = 0; nnz_l = 0; nnz_r = 0; all_zero = 1;
            for (i = 0; i < n; i = i + 1) begin
                s = sample;
                if (s > pk_l) pk_l = s;
                if (s !== 0) begin nnz_l = nnz_l + 1; all_zero = 0; end
                s = sample_r;
                if (s > pk_r) pk_r = s;
                if (s !== 0) begin nnz_r = nnz_r + 1; all_zero = 0; end
                @(posedge clk);
            end
        end
    endtask

    // ----------------------------- test state -------------------------
    integer pk_l, pk_r, nnz_l, nnz_r, all_zero, i;
    integer io_peak;   // 1x io-burst peak (14 if the first texture hit
                       // lands while envelope=7, else 12 after the first
                       // 4096-clk decay step - see F5 comment)

    initial begin
        // Cold: reset high, everything off.
        reset = 1; drive1_motor = 0; drive2_motor = 0;
        drive1_io = 0; drive2_io = 0; drive1_step = 0; drive2_step = 0;
        drive1_track_zero_step = 0; drive2_track_zero_step = 0;
        repeat (100) @(posedge clk);
        reset = 0;
        pan = 2'd3; gain = 2'd0;

        // F1: zero idle - no events, motor off => both channels exactly 0
        // (the AGENTS zero-idle rule: nothing to mix in).
        rearm();
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F1 zero idle: no events -> sample==0 && sample_r==0",
              all_zero && pk_l == 0 && pk_r == 0);

        // F2: motor hum - drive1 motor, pan Drives (d1->L). Ramp to
        // envelope 15 (15 x 190909 = 2,863,635 clk) + margin, then a
        // 100k window: L carries bounded activity, R stays 0.
        rearm();
        drive1_motor = 1;
        repeat (3_100_000) @(posedge clk);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        $display("F2 motor window: pk_l=%0d pk_r=%0d nnz_l=%0d (%0.1f%%)",
                 pk_l, pk_r, nnz_l, 100.0 * nnz_l / 100_000);
        check("F2 motor hum present on L (pk 3..20, >20%% activity)",
              pk_l >= 3 && pk_l <= 20 && nnz_l > 20_000);
        check("F2 R silent in Drives pan (d1 -> L only)", pk_r == 0);

        // F10: hum stops - motor off, envelope decays at the same rate;
        // must return to EXACTLY zero (no lingering hum - the AGENTS
        // domain-boundary trap: MOTOR_ON, not ACTIVE).
        drive1_motor = 0;
        repeat (3_100_000) @(posedge clk);
        measure_window(50_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F10 motor decay returns to exact zero", all_zero);

        // F3: step clunk - UNGATED burst, works with the motor off.
        // envelope 15 -> 60 on the first hit, decays 15 x 2048; the ring
        // tail (7 x 24576) needs the full ~200k before silence.
        rearm();
        pulse(2);
        measure_window(1_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F3 step burst present within 1k clocks (pk >= 50)", pk_l >= 50);
        repeat (299_000) @(posedge clk);
        measure_window(50_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F3 step/ring fully decayed to zero", all_zero);

        // F4: track-0 knock - noise-gated (needs a live LFSR => motor on;
        // envelope still 0 at 10k warm, so motor samples are 0 and the
        // peak is the exact stop_sample = 7<<3 = 56).
        rearm();
        motor_warm();
        pulse(3);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F4 track-0 knock on L, exact peak 56", pk_l == 56 && pk_r == 0);
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);
        measure_window(50_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F4 knock decayed to zero", all_zero);

        // F5+F6: IO activity burst + gain ladder. io_sample =
        // envelope<<1 (7<<1 = 14 while envelope=7, 12 after the first
        // 4096-clk decay step). The texture is noise-gated (needs live
        // LFSR => motor_warm, envelope 0 => motor samples stay 0). The
        // first texture-1 hit may land after one decay step, so the 1x
        // peak is 12 OR 14 (deterministic per rearm); the gain/pan
        // checks are EXACT ratios against the measured 1x peak - all
        // runs rearm identically, so they hit the same envelope level.
        pan = 2'd0;
        gain = 2'd0;
        rearm();
        motor_warm();
        pulse(1);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        io_peak = pk_l;
        $display("F5 io burst (1x): pk_l=%0d pk_r=%0d", pk_l, pk_r);
        check("F5 io burst on both channels (Center pan), peak 12 or 14",
              (pk_l == 14 || pk_l == 12) && pk_r == pk_l);
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);
        measure_window(50_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F5 io decayed to zero", all_zero);

        gain = 2'd1;   // 2x
        rearm();
        motor_warm();
        pulse(1);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F6 gain 2x: exact 2x the 1x peak", pk_l == 2 * io_peak && pk_r == 2 * io_peak);
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);

        gain = 2'd2;   // 4x
        rearm();
        motor_warm();
        pulse(1);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F6 gain 4x: exact 4x the 1x peak", pk_l == 4 * io_peak && pk_r == 4 * io_peak);
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);
        gain = 2'd0;

        // F7: pan - one io burst per pan position (motor warm for LFSR).
        pan = 2'd1;   // Left
        rearm();
        motor_warm();
        pulse(1);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F7 pan Left: L only (pk 12/14, R 0)",
              (pk_l == 14 || pk_l == 12) && pk_r == 0);
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);

        pan = 2'd2;   // Right
        rearm();
        motor_warm();
        pulse(1);
        measure_window(100_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F7 pan Right: R only (L 0, pk 12/14)",
              pk_l == 0 && (pk_r == 14 || pk_r == 12));
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);
        pan = 2'd3;

        // F8: enable off kills the output mid-burst (MiSTer wires the
        // OSD off bit to enable; Pocket option = the same role).
        rearm();
        motor_warm();
        pulse(1);
        repeat (20_000) @(posedge clk);   // io burst in flight
        enable = 0;
        measure_window(1_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F8 enable=0: output exactly zero mid-burst", all_zero);
        enable = 1;
        drive1_motor = 0;
        repeat (299_000) @(posedge clk);

        // F9: final idle sanity (post all tests).
        rearm();
        measure_window(10_000, pk_l, pk_r, nnz_l, nnz_r, all_zero);
        check("F9 idle after all tests", all_zero);

        $display("FLOPPY SOUND TB FAILURES: %0d", failures);
        if (failures == 0)
            $display("FLOPPY SOUND TB ALL CHECKS PASSED");
        else
            $display("FLOPPY SOUND TB FAILURES PRESENT");
        $finish;
    end

    // Global watchdog (sim safety, not a DUT expectation). Full run is
    // ~9.7M clocks (~680 ms sim time) dominated by the two 3.1M motor
    // envelope ramp/decay windows.
    initial begin
        #5_000_000_000;
        $display("FLOPPY SOUND TB GLOBAL WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
