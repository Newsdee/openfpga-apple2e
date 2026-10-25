// tb_speaker_i2s.sv - unit test for speaker_i2s.v (555 speaker -> I2S)
//
// Checks (self-driving, no C++ main; build with --binary --timing):
//   1. silence   : spk_bit = 0 constant  -> I2S word == 0 after DC warmup
//   2. full-on    : spk_bit = 1 constant  -> I2S word == 0 (DC is blocked,
//                  the key centering property - constant on = inaudible DC)
//   3. alias      : fast 50% tone (toggle every 32 clk) -> each 298-clk
//                  duty window averages to ~256 -> output ~ 0 (box
//                  averaging instead of aliasing from point sampling)
//   4. tone       : slow tone (toggle at every 298-clk window boundary)
//                  -> duty alternates 0/512 -> centered AC: words on BOTH
//                  signs with |word| > 2500
//   5. framing    : per lrck posedge the captured 16-bit word is MSB-first
//                  and the surrounding dummy bits are zero
//
// Clocks (ratios matter, not absolute rates): clk_14m 10 MHz (period 100),
// mclk 10 MHz, sclk 2.5 MHz (period 400 = mclk/4). The DUT's 298-clk duty
// window (29800 units) is close to one lrck period (32 sclk = 12800);
// lrck posedges are 25600 units apart (lrck toggles every 32 sclk, so
// successive same-polarity edges are two periods).
//
// Timing facts verified in this TB (2026-10-26): a word loaded at an lrck
// posedge appears on dac 2 sclk later (bit15 first); the shifter emits 16
// active bits then zeros, so samples 2..17 after a posedge are the word.

module tb_speaker_i2s;
    reg         clk_14m = 1'b0;
    reg         mclk    = 1'b0;
    reg         sclk    = 1'b0;
    reg         spk_bit = 1'b0;
    wire        lrck;
    wire        dac;

    always #50  clk_14m = ~clk_14m;   // 10 MHz
    always #50  mclk    = ~mclk;      // 10 MHz
    always #200 sclk    = ~sclk;      // 2.5 MHz

    speaker_i2s dut (
        .clk_14m(clk_14m),
        .spk_bit(spk_bit),
        .mclk   (mclk),
        .sclk   (sclk),
        .lrck   (lrck),
        .dac    (dac)
    );

    // ------------------------------------------------------------------
    // I2S word capture: lrck toggles on EVERY wrap (12800 units). Words
    // load at a lrck NEGedge and are transmitted over the following lrck=0
    // channel (16 active bits MSB-first, then zeros). On each lrck POSEDGE
    // the word loaded 12800 units ago has just finished transmitting, so
    // sample the PRECEDING 64 sclk: its samples 17..32 carry that word.
    // ------------------------------------------------------------------
    reg  [15:0] cap_word;
    reg  [15:0] cap_dummy;
    reg         cap_valid;
    reg  [63:0] bits;
    integer     bi;
    always @(posedge lrck) begin
        for (bi = 0; bi < 64; bi = bi + 1) begin
            @(posedge sclk) #1;
            bits[63 - bi] <= dac;
        end
        cap_word  <= bits[62:47];   // samples 2..17 = W[15:0] MSB-first
        cap_dummy <= {bits[63], bits[46:32]};   // sample 1 (tail) + samples 18..32
        cap_valid = 1'b1;   // set once, never cleared (word refreshes each period)
    end

    // ------------------------------------------------------------------
    // DC-blocker warmup: lrck posedges are 2 block-updates apart; 600
    // posedges = 1200 updates (coefficient 1/128 -> well converged)
    // ------------------------------------------------------------------
    task automatic warmup;
        integer w;
        begin
            for (w = 0; w < 600; w = w + 1) @(posedge lrck);
        end
    endtask

    integer err = 0;
    integer  i;
    integer  t;
    integer  posc, negc;
    reg [15:0] w16;
    reg [63:0] bnd;

    initial begin
        // ============ phase 1: silence ============
        spk_bit = 1'b0;
        while (!cap_valid) @(posedge lrck);   // first capture completes
        warmup;
        repeat (10) begin
            @(posedge lrck) #1;
            if (!cap_valid) begin
                $display("TB: framing FAIL (no capture)");
                err = err + 1;
            end else if (cap_word !== 16'd0) begin
                $display("TB: silence FAIL word=%h (want 0)", cap_word);
                err = err + 1;
            end else if (cap_dummy !== 16'd0) begin
                $display("TB: silence FAIL dummy=%h (want 0)", cap_dummy);
                err = err + 1;
            end
        end
        $display("TB: silence phase done (err so far=%0d)", err);

        // ============ phase 2: full-on constant (DC must be blocked) =====
        spk_bit = 1'b1;
        warmup;
        begin : fullon
            for (i = 0; i < 10; i = i + 1) begin
                @(posedge lrck) #1;
                w16 = cap_word;
                // converged DC -> 0; allow the convergence-ramp tail
                // (|signed(w16)| > 256  <=>  unsigned w16 in (256, 65279])
                if (w16 > 16'd256 && w16 < 16'd65280) begin
                    $display("TB: full-on FAIL word=%0d (want ~0 DC)", $signed(w16));
                    err = err + 1;
                end
            end
        end
        $display("TB: full-on phase done (err so far=%0d)", err);

        // ============ phase 3a: fast 50% tone must not alias =============
        // toggle every 32 clk -> duty ~256 per window -> output ~ 0
        spk_bit = 1'b0;
        for (i = 0; i < 40; i = i + 1) begin
            repeat (32) @(posedge clk_14m);
            spk_bit = ~spk_bit;
        end
        repeat (700) @(posedge lrck);   // tracker settles to the ~256-duty mean
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge lrck) #1;
            w16 = cap_word;
            if (w16 > 16'd200 && w16 < 16'd65336) begin   // |signed(w16)| > 200
                $display("TB: alias FAIL word=%0d (fast tone must avg to ~0)", $signed(w16));
                err = err + 1;
            end
        end
        $display("TB: alias phase done (err so far=%0d)", err);

        // ============ phase 3b: slow tone -> centered AC =================
        // tonegen toggles spk_bit exactly at each DUT duty-window boundary
        // (clk_14m posedge #298k, absolute time 29750 + 29800*k, clocks
        // start at t=50 with period 100) so each window is cleanly all-0
        // or all-1 and the duty alternates 0 <-> 512.
        spk_bit = 1'b0;
        fork
            begin : tonegen
                bnd = 64'd29750;
                for (t = 0; t < 900; t = t + 1) begin
                    while (bnd <= $time) bnd = bnd + 64'd29800;
                    #(bnd - $time - 5);      // 5 units before the boundary posedge
                    spk_bit = ~spk_bit;
                    bnd = bnd + 64'd29800;   // consume this boundary
                end
            end
            begin : tonecheck
                // let lp settle against the alternating mean
                repeat (900) @(posedge lrck);
                posc = 0; negc = 0;
                for (i = 0; i < 40; i = i + 1) begin
                    @(posedge lrck) #1;
                    w16 = cap_word;
                    // signed w >  2500  <=>  unsigned in [2501, 32767]
                    // signed w < -2500  <=>  unsigned in [32768, 63035]
                    if (w16 >= 16'd2501 && w16 <= 16'd32767) posc = posc + 1;
                    if (w16 >= 16'd32768 && w16 <= 16'd63035) negc = negc + 1;
                end
                if (posc == 0) begin
                    $display("TB: tone FAIL: no positive word > 2500 in 40 samples");
                    err = err + 1;
                end
                if (negc == 0) begin
                    $display("TB: tone FAIL: no negative word < -2500 in 40 samples");
                    err = err + 1;
                end
                $display("TB: tone counts pos=%0d neg=%0d (of 40)", posc, negc);
            end
        join
        $display("TB: tone phase done (err so far=%0d)", err);

        // ============ verdict ============
        if (err == 0) $display("TB: SPEAKER-I2S PASS");
        else          $display("TB: SPEAKER-I2S FAIL (%0d errors)", err);
        $finish;
    end

    initial begin
        #200_000_000;   // time units (ps in Verilator default scale)
        $display("TB: TIMEOUT");
        $finish;
    end
endmodule
