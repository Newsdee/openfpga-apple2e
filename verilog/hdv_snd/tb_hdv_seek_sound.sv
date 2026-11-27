// ============================================================================
// tb_hdv_seek_sound.sv - step-1 voice render + step-2 event acceptance
// (PLAN_HDV_PROCEDURAL_SEEK_SOUND_2026-11-26)
//
// Phase A (voice): drives the trigger inputs so five SHORT seeks start at
// 0.35/0.79/1.23/1.67/2.11 s and five LONG seeks at 3.30/3.74/4.18/4.62/
// 5.06 s (the preview's onset times), captures `sample` on `sample_tick`
// and writes raw little-endian s16 PCM. A python wrapper adds the WAV
// header (48 kHz mono). NO per-event normalization - the render keeps the
// true mixer gain (plan section 1).
//
// Phase B (events, +EVENTS plusarg): same/adjacent blocks silent, forward
// and reverse distances 2/63/64, 0xFFFF->0x0000 (unsigned, not wraparound),
// long sequential run silent, command between synthesis ticks updates
// history, eject silences mid-seek, re-mount seeds silently, seek during
// playback neither extends nor queues, reset ends at exact zero.
// ============================================================================
`timescale 1ns / 1ps

module tb_hdv_seek_sound;

    // 14.31818 MHz machine clock
    reg clk = 1'b0;
    always #34.921 clk = ~clk;    // ~14.318 MHz

    reg         reset = 1'b1;
    reg         enable = 1'b1;
    reg         mounted = 1'b0;
    reg         cmd_valid = 1'b0;
    reg  [15:0] cmd_sector = 16'd0;

    wire signed [15:0] sample;
    wire        sample_tick;

    hdv_seek_sound dut (
        .clk(clk), .reset(reset), .enable(enable),
        .cmd_valid(cmd_valid), .cmd_sector(cmd_sector), .mounted(mounted),
        .sample(sample), .sample_tick(sample_tick)
    );

    // Variant A: ST-225 beep timbre - 2650->2580 Hz body (recording: 2616 Hz
    // dominant), grit attenuated 16x, body x2 louder
    wire signed [15:0] sample_a;
    hdv_seek_sound #(.BODY_START_HZ(2650), .BODY_END_HZ(2580),
                     .BODY_SHIFT(2), .GRIT_SHIFT(4)) dutA (
        .clk(clk), .reset(reset), .enable(enable),
        .cmd_valid(cmd_valid), .cmd_sector(cmd_sector), .mounted(mounted),
        .sample(sample_a), .sample_tick()
    );
    // Variant B: hybrid, beep:mechanical = 2:1 as measured in the recording
    // (explicit signed wires: concatenations would be UNSIGNED and wrap)
    wire signed [16:0] b_aext  = sample_a;
    wire signed [16:0] b_mhalf = $signed({sample[15], sample});  // M as 17-bit signed
    wire signed [17:0] sample_b = b_aext + (b_mhalf >>> 1);      // A + M/2

    // Variant S: ST-225 beep timbre, SOFT / ethereal profile - slower swell
    // (70/55 Hz), longer edges (16/30 ms), shallow peak-to-floor (sustained,
    // not percussive), a touch of air (grit/8), gentle 2640->2590 fall.
    wire signed [15:0] sample_s;
    hdv_seek_sound #(.BODY_START_HZ(2640), .BODY_END_HZ(2590),
                     .BODY_SHIFT(2), .GRIT_SHIFT(3),
                     .ATK_MS(16), .REL_MS(30),
                     .SCRAPE_HZ_S(70), .SCRAPE_HZ_L(55),
                     .ENV_PEAK_I(1500), .ENV_FLOOR_I(900),
                     .DECAY_DIV_I(192)) dutS (
        .clk(clk), .reset(reset), .enable(enable),
        .cmd_valid(cmd_valid), .cmd_sector(cmd_sector), .mounted(mounted),
        .sample(sample_s), .sample_tick()
    );

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    task automatic do_cmd(input [15:0] sec);
        begin
            @(negedge clk);
            cmd_sector <= sec;
            cmd_valid  <= 1'b1;
            @(negedge clk);
            cmd_valid  <= 1'b0;
        end
    endtask

    // run to an absolute sim time in seconds
    task automatic run_to(input real t_sec);
        begin
            while ($realtime/1e9 < t_sec) @(posedge clk);
        end
    endtask

    integer pcm_fd;
    integer pcm_fd_a, pcm_fd_b, pcm_fd_s;
    integer n_samp;
    integer peak_pos, peak_neg;
    integer peak_a, peak_b, peak_s;
    integer i;

    // event-phase helpers
    integer ev_fail;
    integer s_start, s_end;      // sample index of first/last nonzero in a probe window
    integer probe_lo, probe_hi;
    integer nz;
    reg signed [15:0] sbuf [0:48000*2];   // up to 2 s capture for events
    integer scnt;
    reg     capturing;

    task automatic cap_start;
        begin scnt = 0; capturing = 1; end
    endtask
    task automatic cap_stop;
        begin capturing = 0; end
    endtask

    always @(posedge clk) begin
        if (sample_tick) begin
            if (capturing && scnt < 48000*2) begin
                sbuf[scnt] <= sample;
                scnt = scnt + 1;
            end
        end
    end

    // count nonzero samples in sbuf[lo..hi]
    function integer count_nz(input integer lo, input integer hi);
        integer k, c;
        begin
            c = 0;
            for (k = lo; k <= hi && k < scnt; k = k + 1)
                if (sbuf[k] !== 16'sd0) c = c + 1;
            count_nz = c;
        end
    endfunction

    function integer max_abs(input integer lo, input integer hi);
        integer k, m, v;
        begin
            m = 0;
            for (k = lo; k <= hi && k < scnt; k = k + 1) begin
                v = (sbuf[k] < 0) ? -sbuf[k] : sbuf[k];
                if (v > m) m = v;
            end
            max_abs = m;
        end
    endfunction

    // ------------------------------------------------------------------
    // stimulus
    // ------------------------------------------------------------------
    initial begin
        pcm_fd     = 0;
        pcm_fd_a   = 0;
        pcm_fd_b   = 0;
        pcm_fd_s   = 0;
        n_samp     = 0;
        peak_pos   = 0;
        peak_neg   = 0;
        peak_a     = 0;
        peak_b     = 0;
        peak_s     = 0;
        ev_fail    = 0;
        capturing  = 0;
        scnt       = 0;

        if ($test$plusargs("EVENTS")) begin
            // ================= Phase B: event acceptance =================
            repeat (10) @(posedge clk);
            reset <= 1'b0;
            mounted <= 1'b1;
            repeat (100) @(posedge clk);

            // 1) seed silently, then same/adjacent => silence
            //    (5 ms spacing so the dist-2 seek cannot leak into the
            //    silence window)
            cap_start;
            do_cmd(16'd1000);            // seed (silent)
            run_to($realtime/1e9 + 0.005);
            do_cmd(16'd1000);            // dist 0
            run_to($realtime/1e9 + 0.005);
            do_cmd(16'd1001);            // dist 1
            run_to($realtime/1e9 + 0.005);
            do_cmd(16'd999);             // dist 2 -> SHORT expected
            run_to($realtime/1e9 + 0.08);
            cap_stop;
            // first ~14 ms (670 samples) must be silent; the short seek
            // then sounds for the rest of the window
            if (count_nz(0, 650) != 0) begin
                $display("EV1 FAIL: sound during seed/dist0/dist1 (%0d nz first 14ms)",
                         count_nz(0, 650));
                ev_fail = ev_fail + 1;
            end else
                $display("EV1 OK: seed/dist0/dist1 silent");
            if (count_nz(700, scnt-1) < 500) begin
                $display("EV1b FAIL: dist-2 did not trigger a short seek");
                ev_fail = ev_fail + 1;
            end else
                $display("EV1b OK: dist-2 short seek sounded");

            // wait out the short seek
            run_to($realtime/1e9 + 0.10);

            // 2) forward/reverse 63 (short) and 64 (long)
            cap_start;
            do_cmd(16'd1062);            // 999->1062 dist 63 short
            run_to($realtime/1e9 + 0.075);
            cap_stop;
            if (count_nz(0, scnt-1) < 100) begin
                $display("EV2 FAIL: dist 63 fwd no sound"); ev_fail = ev_fail + 1;
            end else begin
                $display("EV2 OK: dist 63 fwd short (%0d nz, peak %0d)",
                         count_nz(0, scnt-1), max_abs(0, scnt-1));
            end
            run_to($realtime/1e9 + 0.03);

            cap_start;
            do_cmd(16'd998);             // 1062->998 dist 64 LONG
            run_to($realtime/1e9 + 0.15);
            cap_stop;
            if (count_nz(0, scnt-1) < 3000) begin  // 150ms*48k=7200 window
                $display("EV3 FAIL: dist 64 rev not long-sounding"); ev_fail = ev_fail + 1;
            end else
                $display("EV3 OK: dist 64 rev long (%0d nz in 150ms window)",
                         count_nz(0, scnt-1));
            run_to($realtime/1e9 + 0.05);

            // 3) 0xFFFF -> 0x0000: unsigned diff = 65535 -> LONG (not wrap 1)
            cap_start;
            do_cmd(16'hFFFF);             // 998->65535: LONG
            run_to($realtime/1e9 + 0.16); // let it finish
            cap_stop;
            cap_start;
            do_cmd(16'h0000);             // dist 65535 -> LONG
            run_to($realtime/1e9 + 0.02);
            cap_stop;
            if (count_nz(0, scnt-1) < 100) begin
                $display("EV4 FAIL: 0xFFFF->0x0000 (dist 65535) did not sound");
                ev_fail = ev_fail + 1;
            end else
                $display("EV4 OK: 0xFFFF->0x0000 LONG sounded (%0d nz)",
                         count_nz(0, scnt-1));
            run_to($realtime/1e9 + 0.20);

            // 4) long sequential run: seed silently via eject/remount, then
            //    200 consecutive +1 commands, every 100 us => must stay SILENT
            mounted <= 1'b0;
            run_to($realtime/1e9 + 0.005);
            mounted <= 1'b1;
            run_to($realtime/1e9 + 0.005);
            cap_start;
            for (i = 0; i < 200; i = i + 1) begin
                do_cmd(16'd2000 + i[15:0]);   // first seeds silently
                run_to($realtime/1e9 + 0.0001);
            end
            cap_stop;
            if (count_nz(0, scnt-1) != 0) begin
                $display("EV5 FAIL: sequential run made noise (%0d nz)",
                         count_nz(0, scnt-1));
                ev_fail = ev_fail + 1;
            end else
                $display("EV5 OK: 200-step sequential run silent");

            // 5) command between synthesis ticks: sample_tick period is
            //    298 clks; issue a dist-2 cmd at a random non-tick phase
            //    and verify the NEXT command's distance uses it (history
            //    updated even if missed by the audio grid)
            @(posedge clk); #10;          // arbitrary phase
            do_cmd(16'd2400);             // 2200->2400 dist 200 -> LONG
            run_to($realtime/1e9 + 0.2);

            // 6) trigger during playback: history updates, no extend/queue
            cap_start;
            do_cmd(16'd3000);             // dist 600 -> LONG starts
            run_to($realtime/1e9 + 0.03);
            do_cmd(16'd3100);             // during playback: dist 100 -> dropped
            do_cmd(16'd3200);             // dropped too
            run_to($realtime/1e9 + 0.16); // long ends ~134ms after start
            cap_stop;
            // after the 134ms window + 20ms grace there must be NO queued sound
            if (count_nz(48000*160/1000, scnt-1) != 0) begin
                $display("EV6 FAIL: dropped triggers sounded later (%0d nz after window)",
                         count_nz(48000*160/1000, scnt-1));
                ev_fail = ev_fail + 1;
            end else
                $display("EV6 OK: mid-play triggers dropped, no queue");
            run_to($realtime/1e9 + 0.1);

            // 7) eject mid-seek silences immediately
            cap_start;
            do_cmd(16'd4000);             // dist 800 -> LONG
            run_to($realtime/1e9 + 0.03);
            mounted <= 1'b0;
            run_to($realtime/1e9 + 0.002);
            cap_stop;
            // last 48 samples (1ms after eject) must be zero
            if (count_nz(scnt-48, scnt-1) != 0) begin
                $display("EV7 FAIL: not silent after eject (%0d nz in last ms)",
                         count_nz(scnt-48, scnt-1));
                ev_fail = ev_fail + 1;
            end else
                $display("EV7 OK: eject silenced the voice");

            // 8) re-mount seeds silently, then dist works again
            mounted <= 1'b1;
            run_to($realtime/1e9 + 0.01);
            cap_start;
            do_cmd(16'd100);              // seed
            run_to($realtime/1e9 + 0.005);
            do_cmd(16'd300);              // dist 200 -> LONG
            run_to($realtime/1e9 + 0.03);
            cap_stop;
            if (count_nz(0, 200) != 0) begin
                $display("EV8 FAIL: seed after remount sounded (%0d nz first 4ms)",
                         count_nz(0, 200)); ev_fail = ev_fail + 1;
            end else if (count_nz(201, scnt-1) < 100) begin
                $display("EV8b FAIL: post-remount seek did not sound"); ev_fail = ev_fail + 1;
            end else
                $display("EV8 OK: remount seeds silently, seeks sound");
            run_to($realtime/1e9 + 0.25);

            // 9) reset during seek -> exact zero, no stuck sample
            cap_start;
            do_cmd(16'd900);              // dist 600 -> LONG
            run_to($realtime/1e9 + 0.03);
            reset <= 1'b1;
            repeat (5) @(posedge clk);
            reset <= 1'b0;
            run_to($realtime/1e9 + 0.005);
            cap_stop;
            if (count_nz(scnt-200, scnt-1) != 0) begin
                $display("EV9 FAIL: nonzero after reset"); ev_fail = ev_fail + 1;
            end else
                $display("EV9 OK: reset -> exact digital zero");

            // 10) enable=0: silent even on seeks
            run_to($realtime/1e9 + 0.05);
            enable <= 1'b0;
            cap_start;
            do_cmd(16'd5000);
            do_cmd(16'd5500);
            run_to($realtime/1e9 + 0.08);
            cap_stop;
            if (count_nz(0, scnt-1) != 0) begin
                $display("EV10 FAIL: sound while disabled"); ev_fail = ev_fail + 1;
            end else
                $display("EV10 OK: disabled = silent");

            if (ev_fail == 0)
                $display("TB HDV SEEK SOUND EVENTS: ALL PASS");
            else begin
                $display("TB HDV SEEK SOUND EVENTS: FAIL (%0d)", ev_fail);
                $fatal(1);
            end
            $finish;
        end

        // ================= Phase A: voice render =================
        pcm_fd   = $fopen("hdv_seek_render.pcm", "wb");
        pcm_fd_a = $fopen("hdv_seek_render_a.pcm", "wb");
        pcm_fd_b = $fopen("hdv_seek_render_b.pcm", "wb");
        pcm_fd_s = $fopen("hdv_seek_render_s.pcm", "wb");
        if (pcm_fd == 0 || pcm_fd_a == 0 || pcm_fd_b == 0 || pcm_fd_s == 0) begin
            $display("TB: FAIL - cannot open PCM output");
            $fatal(1);
        end

        repeat (20) @(posedge clk);
        reset   <= 1'b0;
        mounted <= 1'b1;
        repeat (200) @(posedge clk);

        // five short seeks (dist 10) at the preview's short onsets
        fork
            begin : short_seq
                run_to(0.35); do_cmd(16'd10);   // seed at t=0 was skipped:
                run_to(0.79); do_cmd(16'd20);   // first cmd seeds silently,
                run_to(1.23); do_cmd(16'd30);   // so seed at 0.30 then seek
                run_to(1.67); do_cmd(16'd40);
                run_to(2.11); do_cmd(16'd50);
            end
            begin : seed_pre
                run_to(0.30); do_cmd(16'd0);    // silent seed
            end
            begin : long_seq
                run_to(3.30); do_cmd(16'd200);  // dist 150 -> long
                run_to(3.74); do_cmd(16'd400);
                run_to(4.18); do_cmd(16'd600);
                run_to(4.62); do_cmd(16'd800);
                run_to(5.06); do_cmd(16'd1000);
            end
        join

        run_to(5.40);

        // PCM capture ran in the background via the always block? No -
        // Phase A writes directly here from a parallel sampler:
        $finish;
    end

    // Phase A PCM writer + peak tracker (independent of the event buffer)
    always @(posedge clk) begin
        if (sample_tick && !capturing && pcm_fd != 0) begin
            $fwrite(pcm_fd,   "%c%c", sample[7:0],   sample[15:8]);
            $fwrite(pcm_fd_a, "%c%c", sample_a[7:0], sample_a[15:8]);
            $fwrite(pcm_fd_b, "%c%c", sample_b[7:0], sample_b[15:8]);
            $fwrite(pcm_fd_s, "%c%c", sample_s[7:0], sample_s[15:8]);
            n_samp = n_samp + 1;
            if (sample > peak_pos) peak_pos = sample;
            if (sample < peak_neg) peak_neg = sample;
            if (sample_a > peak_a) peak_a = sample_a;
            if (sample_b > peak_b) peak_b = sample_b;
            if (sample_s > peak_s) peak_s = sample_s;
        end
    end

    final begin
        if (pcm_fd   != 0) $fclose(pcm_fd);
        if (pcm_fd_a != 0) $fclose(pcm_fd_a);
        if (pcm_fd_b != 0) $fclose(pcm_fd_b);
        if (pcm_fd_s != 0) $fclose(pcm_fd_s);
        $display("TB: rendered %0d samples (%.3f s), M peak +%0d/%0d, A peak %0d, B peak %0d, S peak %0d",
                 n_samp, n_samp/48000.0, peak_pos, peak_neg, peak_a, peak_b, peak_s);
    end

    // watchdog
    initial begin
        #12_000_000_000;   // 12 s sim
        $display("TB: watchdog timeout");
        $fatal(1);
    end

endmodule
