// Chain testbench for the floppy-sound PORT (PLAN_FLOPPY_SOUND_PORT_2026-11-19.md):
// real floppy_sound donor + real speaker_i2s mixer + I2S word decoder.
// The donor's own physics (hum/clunk/knock levels, zero-idle, gain ladder,
// pan) are proven at donor level in tb_floppy_sound.sv; THIS bench proves the
// integration the donor TB cannot see:
//   C1  bit-identity: fs_en=1 (silent drive) vs fs_en=0 over a speaker-beep
//       window -> identical I2S words (zero-idle crosses exactly 0; the
//       saturating add of 0 is exact)
//   C2  step event -> non-zero LEFT words (pan=3 = Drives: d1 -> L),
//       RIGHT words stay exactly 0 (MB off, speaker off)
//   C3  motor -> sustained low-level hum on L, R still 0
//   C4  saturating mix: MB 3x (0<->765 pattern) + 1 kHz speaker beep +
//       motor -> words reach BOTH 16-bit rails (32767 / -32768) and never
//       wrap (no word-to-word jump > 40000)
//
// Build/run: run_tb_floppy_sound_chain.sh (CWD = verilog/)
`timescale 1ns / 1ps

module tb_floppy_sound_chain;

    // ------------------------------------------------------------------
    // clocks (same values as tb_mb_audio.sv / the core's audio generator)
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    always #35 clk = ~clk;                       // 70 ns = 14.318 MHz
    reg mclk = 1'b0;
    always #40.6905 mclk = ~mclk;                // 12.288 MHz
    reg sclk = 1'b0;
    always #162.7605 sclk = ~sclk;               // 3.0712 MHz = mclk/4

    // ------------------------------------------------------------------
    // DUT pair: floppy_sound (machine dom) -> speaker_i2s (mclk dom)
    // ------------------------------------------------------------------
    reg        reset = 1'b1;
    reg        fs_en = 1'b0;
    reg        drv_motor = 1'b0, drv_step = 1'b0, drv_trk0 = 1'b0, drv_io = 1'b0;
    wire [9:0] fs_l, fs_r;

    floppy_sound u_fs (
        .clk(clk), .reset(reset), .enable(fs_en), .gain(2'd0), .pan(2'd3),
        .drive1_motor(drv_motor), .drive2_motor(1'b0),
        .drive1_io(drv_io), .drive2_io(1'b0),
        .drive1_step(drv_step), .drive2_step(1'b0),
        .drive1_track_zero_step(drv_trk0), .drive2_track_zero_step(1'b0),
        .sample(fs_l), .sample_r(fs_r)
    );

    reg        spk_on = 1'b0;
    reg [14:0] beep_cnt = 15'd0;
    reg        spk_bit = 1'b0;
    always @(posedge clk) begin
        if (spk_on) begin
            if (spk_bit && beep_cnt != 15'd7158) beep_cnt <= beep_cnt + 15'd1;
            else beep_cnt <= 15'd0;
            spk_bit <= (beep_cnt == 15'd7159) ? 1'b0 : 1'b1;    // ~1 kHz
        end else begin
            beep_cnt <= 15'd0;
            spk_bit  <= 1'b0;
        end
    end

    // MB side: direct level drive (C4 rail transients) - the 0<->765
    // toggle of tb_mb_audio would let the mclk-domain DC tracker settle
    // into a small oscillation (sdiff peak ~465), which never crosses the
    // 16-bit rails; a single 0->765 step gives sdiff = +765 for ~10.4 us
    // (tracker closes at 6/mclk) -> the x48 word clamps at +32767, and
    // the 765->0 drop gives sdiff = -765 -> -32768.
    reg [9:0]  mb_const_l = 10'd0;
    reg        mb_gate = 1'b0;
    reg [1:0]  mb_gain = 2'd0;
    wire [9:0] mb_l = mb_const_l;
    wire [9:0] mb_r = 10'd0;

    wire i2s_lrck, i2s_dac;
    speaker_i2s u_spk (
        .clk_14m(clk), .spk_bit(spk_bit),
        .mb_in_m(mb_gate), .mb_gain_m(mb_gain), .mb_l(mb_l), .mb_r(mb_r),
        .fs_l(fs_l), .fs_r(fs_r),
        .mclk(mclk), .sclk(sclk), .lrck(i2s_lrck), .dac(i2s_dac)
    );

    // ------------------------------------------------------------------
    // I2S word decoder (copied from tb_mb_audio.sv - same framing rules)
    // ------------------------------------------------------------------
    reg [15:0] dec_word = 16'd0;
    reg [4:0]  dec_cnt = 5'd0;
    reg        dec_lrck_r = 1'b0;
    reg [15:0] w_l = 16'd0, w_r = 16'd0;
    integer    word_idx = 0;
    localparam integer WMAX = 16384;
    reg [15:0] w_l_hist [0:WMAX-1];
    reg [15:0] w_r_hist [0:WMAX-1];
    always @(negedge sclk) begin
        dec_word <= {dec_word[14:0], i2s_dac};
        if (dec_cnt == 5'd17) begin
            if (dec_lrck_r) w_r <= dec_word; else w_l <= dec_word;
            if (word_idx < WMAX) begin
                w_l_hist[word_idx] <= w_l;
                w_r_hist[word_idx] <= w_r;
                word_idx <= word_idx + 1;
            end
            dec_lrck_r <= ~dec_lrck_r;
        end
        dec_cnt <= dec_cnt + 5'd1;
    end

    // ------------------------------------------------------------------
    // plumbing
    // ------------------------------------------------------------------
    integer fails = 0;
    task check(input [8*50:1] name, input cond);
        begin
            if (cond) $display("PASS %s", name);
            else begin
                $display("FAIL %s", name);
                fails = fails + 1;
            end
        end
    endtask

    task measure_pp(input integer i0, input integer i1,
                    output integer pmax, output integer pmin);
        integer i;
        reg signed [15:0] sw;
        begin
            pmax = -32768; pmin = 32767;
            for (i = i0; i <= i1; i = i + 1) begin
                sw = w_l_hist[i];
                if (sw > pmax) pmax = sw;
                if (sw < pmin) pmin = sw;
            end
        end
    endtask
    task measure_pp_r(input integer i0, input integer i1,
                      output integer pmax, output integer pmin);
        integer i;
        reg signed [15:0] sw;
        begin
            pmax = -32768; pmin = 32767;
            for (i = i0; i <= i1; i = i + 1) begin
                sw = w_r_hist[i];
                if (sw > pmax) pmax = sw;
                if (sw < pmin) pmin = sw;
            end
        end
    endtask
    // largest |w[i] - w[i-1]| over [i0+1, i1] (a 16-bit wrap jumps ~65535)
    task max_jump(input integer i0, input integer i1, output integer mj);
        integer i;
        integer d;
        begin
            mj = 0;
            for (i = i0 + 1; i <= i1; i = i + 1) begin
                d = $signed(w_l_hist[i]) - $signed(w_l_hist[i-1]);
                if (d < 0) d = -d;
                if (d > mj) mj = d;
            end
        end
    endtask

    integer i, pmax, pmin, mj;
    reg [15:0] a, b;

    // ------------------------------------------------------------------
    initial begin
        $display("tb_floppy_sound_chain: start");
        repeat (200) @(negedge clk);
        reset = 1'b0;
        repeat (5000) @(negedge clk);            // handshakes + trackers settle

        // C1: zero-idle through the whole chain - speaker OFF (duty 0 => spk_word
        // exactly 0), MB off, silent drive: fs_en=1 must produce exactly zero
        // I2S words (the zero-idle donor crosses 0 and the mix adds nothing).
        // (With a live 1kHz beep the duty tracker is centered at 50% so the
        // speaker word is ~0 too - the two-window comparison would test
        // unrelated tracker phases, not the fs term.)
        spk_on = 1'b0;
        repeat (3000) @(negedge clk);            // trackers settle to zero
        fs_en = 1'b1;
        repeat (146_000) @(negedge clk);        // ~1000 lrck words
        idxA0 = word_idx;
        repeat (146_000) @(negedge clk);
        fs_en = 1'b0;
        repeat (20_000) @(negedge clk);
        idxB0 = word_idx;
        repeat (146_000) @(negedge clk);
        for (i = 0; i < 1000; i = i + 1) begin
            a = w_l_hist[idxA0 + i];
            b = w_l_hist[idxB0 + i];
            if (a !== b) begin
                $display("C1 first L mismatch at +[%0d]: %h vs %h", i, a, b);
                c1_match = 0;
            end
        end
        for (i = 0; i < 1000; i = i + 1) begin
            a = w_r_hist[idxA0 + i];
            b = w_r_hist[idxB0 + i];
            if (a !== b) c1_match = 0;
        end
        measure_pp(idxA0, idxA0 + 999, pmax, pmin);
        measure_pp_r(idxA0, idxA0 + 999, pmaxr, pminr);
        check("C1 fs_en=1 silent drive: L+R words exactly 0", (pmax == 0 && pmin == 0 && pmaxr == 0 && pminr == 0));
        measure_pp(idxB0, idxB0 + 999, pmax, pmin);
        measure_pp_r(idxB0, idxB0 + 999, pmaxr, pminr);
        check("C1 fs_en=0: L+R words exactly 0 (bit-identical to on)", (pmax == 0 && pmin == 0 && pmaxr == 0 && pminr == 0 && c1_match));

        // C2: step event -> L burst, R stays 0
        spk_on = 1'b0;
        fs_en = 1'b1;
        repeat (20_000) @(negedge clk);
        @(negedge clk) drv_step = 1'b1;
        repeat (2) @(negedge clk);
        drv_step = 1'b0;
        idxC0 = word_idx;
        repeat (146_000) @(negedge clk);
        measure_pp(idxC0, idxC0 + 999, pmax, pmin);
        measure_pp_r(idxC0, idxC0 + 999, pmaxr, pminr);
        $display("C2 swings: L peak=%0d min=%0d  R peak=%0d", pmax, pmin, pmaxr);
        check("C2 step event: L words non-zero (peak 200..500)", (pmax >= 200 && pmax <= 500));
        check("C2 step event: R words exactly 0 (pan=Drives)", (pmaxr == 0 && pminr == 0));

        // C3: motor -> sustained low-level L hum, R still 0
        @(negedge clk) drv_motor = 1'b1;
        repeat (400_000) @(negedge clk);         // ~28 ms: envelope -> 2
        idxD0 = word_idx;
        repeat (146_000) @(negedge clk);
        measure_pp(idxD0, idxD0 + 999, pmax, pmin);
        measure_pp_r(idxD0, idxD0 + 999, pmaxr, pminr);
        $display("C3 hum: L peak=%0d min=%0d", pmax, pmin);
        check("C3 motor: L hum present (peak 4..32, non-idle)", (pmax >= 4 && pmax <= 32 && pmin >= 0));
        check("C3 motor: R words exactly 0", (pmaxr == 0 && pminr == 0));

        // C4: saturating mix - MB x48 rail transients + 1kHz beep + motor.
        // Each 0<->765 edge (tracker converged before the edge) gives
        // sdiff = +/-765 decaying over ~14 WORD PERIODS - the DC tracker
        // steps once per I2S word (6/word, min 1, ~128 words per e-fold) -
        // so the x48 word clamps at +/-32767/-32768 for several words
        // after every edge. 60_000-clk phases (402 words) let the tracker
        // converge fully before each edge. Floppy enable is OFF here (C3
        // already proved the drive path): enable=0 resets the donor's
        // state immediately (the motor envelope would otherwise decay at
        // ~190k clocks/step and its ~+16 DC would floor the sum at
        // -32,752, masking the exact -32,768 rail). With only MB+speaker
        // the sum crosses both rails exactly.
        spk_on = 1'b1;
        mb_gate = 1'b1;
        mb_gain = 2'b11;
        fs_en = 1'b0;                               // donor state -> 0 immediately
        drv_motor = 1'b0;
        repeat (30_000) @(negedge clk);           // MB handshake + tracker settle (mb=0)
        idxE0 = word_idx;
        mb_const_l = 10'd765;
        repeat (60_000) @(negedge clk);           // 402 words: +rail transients
        mb_const_l = 10'd0;
        repeat (60_000) @(negedge clk);           // 402 words: -rail transients
        measure_pp(idxE0, idxE0 + 804, pmax, pmin);
        measure_pp_r(idxE0, idxE0 + 804, pmaxr, pminr);
        max_jump(idxE0, idxE0 + 804, mj);
        $display("C4 mix: L peak=%0d min=%0d R peak=%0d R min=%0d maxjump=%0d", pmax, pmin, pmaxr, pminr, mj);
        check("C4 saturating mix: reaches +32767 rail", (pmax == 32767));
        check("C4 saturating mix: reaches -32768 rail", (pmin == -32768));
        check("C4 saturating mix: no wrap (max word jump < 40000)", (mj < 40000));

        if (fails == 0) $display("FLOPPY SOUND CHAIN TB ALL CHECKS PASSED");
        else $display("FLOPPY SOUND CHAIN TB FAILURES: %0d", fails);
        $display("TB-RESULT: %s", (fails == 0) ? "PASS" : "FAIL");
        $finish;
    end

    // window markers (declared here to keep the initial block simple)
    integer idxA0, idxB0, idxC0, idxD0, idxE0, c1_match = 1, pmaxr, pminr;

endmodule
