// speaker_i2s.v - Apple II 555 speaker -> APF I2S audio (2026-10-26)
//
// Ported from the MiSTer core's audio chain (Apple-II_MiSTer rtl/apple2_top.v):
//   1. box-average the 1-bit speaker at 14.318 MHz into ~48 kHz duty samples
//      (298 clocks = 20.8 us) so fast toggles average out instead of aliasing
//      from point sampling. Duty maps to 0..512 (10-bit).
//   2. A local 1st-order tracker (time constant ~16 samples ~ 0.33 ms)
//      centers the duty stream: steady silence (duty 0) and steady full-on
//      (duty 512) both settle to 0; a toggling tone passes its fluctuation.
//   3. The centered sample is shifted out as 16-bit I2S (MSB first), mono to
//      both channels, on the existing 3.072 MHz sclk / 48 kHz lrck framing.
//
// GAIN: the centered duty is multiplied by 32 (half-scale 16-bit output,
// matching the MiSTer core's convention). Hardwired, per the core's
// "sane fixed audio level, no OSD knob" decision.
//
// 2026-11-18 (PLAN_MOCKINGBOARD_PORT / PLAN_MB_AUDIO_DEBUG): the Mockingboard
// adds a stereo 10-bit PSG sum (MB O_AUDIO_L/R). It is point-sampled (no box
// averaging - a tone's period is far longer than a 20.8 us window, so a box
// average destroys it) via a 2-entry valid/ack handshake into the mclk
// domain, DC-tracked slowly per channel (tau ~128 samples, passes 50-100 Hz),
// scaled by a user volume slider (x24/x32/x48 = 1x/2x/3x, saturating mix;
// the fixed x16 was judged too quiet on hardware 2026-11-19) and mixed
// into L/R; the option gate keeps the MB term at 0 when off (0 = MB off),
// bit-identical to the mono speaker path. See PLAN_MB_AUDIO_DEBUG_2026-11-18.md.

module speaker_i2s (
    input  wire        clk_14m,   // 14.318 MHz machine domain (averager)
    input  wire        spk_bit,   // 1-bit speaker (machine domain, m_spk)
    input  wire        mb_in_m,   // Mockingboard inslot option (machine domain)
    input  wire [1:0]  mb_gain_m, // MB volume slider 00 off / 01 1x / 10 2x / 11 3x (machine domain)
    input  wire [1:0]  spk_gain_m, // beeper volume slider 00 x2 / 01 x4 / 10 x6 / 11 x8 (machine domain)
    input  wire        fs_boost_m, // floppy volume top stop (x8 = donor x4 * 2, machine domain)
    input  wire [9:0]  mb_l,      // MB O_AUDIO_L 10-bit sample sum (machine domain)
    input  wire [9:0]  mb_r,      // MB O_AUDIO_R 10-bit sample sum (machine domain)
    input  wire [9:0]  fs_l,      // floppy sound LEFT amplitude 0..1023 (machine dom, 0 = idle)
    input  wire [9:0]  fs_r,      // floppy sound RIGHT amplitude (machine dom, 0 = idle)
    input  wire        mclk,      // 12.288 MHz audio master (CDC clock)
    input  wire        sclk,      // 3.072 MHz = mclk/4 (I2S shift clock)
    output wire        lrck,      // 48 kHz word select
    output wire        dac        // I2S data, 16 active bits per channel
);

    // ------------------------------------------------------------------
    // 1. Box averager (machine domain) - MiSTer-exact
    // ------------------------------------------------------------------
    reg  [8:0]  spk_cnt = 9'd0;
    reg  [8:0]  spk_sum = 9'd0;
    reg  [9:0]  spk_avg = 10'd0;
    wire [8:0]  spk_sum_now = spk_sum + {8'b0, spk_bit};
    wire [17:0] spk_prod = {spk_sum_now, 9'b0};      // *512, max 152576 < 2^18
    wire [17:0] spk_div  = spk_prod / 18'd298;        // max 512

    always @(posedge clk_14m) begin
        if (spk_cnt == 9'd297) begin
            spk_cnt <= 9'd0;
            spk_sum <= 9'd0;
            spk_avg <= spk_div[9:0];
        end else begin
            spk_cnt <= spk_cnt + 9'd1;
            if (spk_bit) spk_sum <= spk_sum + 9'd1;
        end
    end

    // ------------------------------------------------------------------
    // 1b. Mockingboard point-sample capture (machine domain)
    // 2026-11-18 rev (PLAN_MB_AUDIO_DEBUG): the original box averager
    // (298-clock window) destroyed the music - a tone's period is much
    // longer than the 20.8 us window, so its window average was
    // near-constant and the DC blocker removed it, leaving only the
    // tracker's tracking ripple (a 48 kHz square wave: the "noisy"
    // symptom) plus a thin quantized remnant ("off-pitch"). The MiSTer
    // golden path point-samples the PSG output instead (apple2_top.v:
    // sat10(psg4+psg5+spk_avg) - no PSG box averaging). So: capture
    // mb_l/mb_r into a 2-entry valid/ack handshake, one sample pair per
    // handshake. The card's outputs only change every 14 machine clocks
    // (980 ns), far slower than the mclk handshake (~300 ns): no
    // overflow, and the data is stable while it is being crossed - which
    // also fixes the multi-bit CDC skew of the old plain 2-FF crossing
    // (plan suspect S1).
    // ------------------------------------------------------------------
    reg [9:0] mb_x_l = 10'd0, mb_x_r = 10'd0;   // sample data registers
    reg       mb_vld = 1'b0;                    // valid toggle (machine dom)
    reg       mb_ack = 1'b0;                    // ack toggle (mclk dom)
    reg       mb_ack_s1 = 1'b0, mb_ack_s2 = 1'b0;
    always @(posedge clk_14m) begin
        mb_ack_s1 <= mb_ack;
        mb_ack_s2 <= mb_ack_s1;
        if (mb_ack_s2 == mb_vld) begin          // consumer caught up: send next
            mb_x_l <= mb_l;
            mb_x_r <= mb_r;
            mb_vld <= ~mb_vld;
        end
    end

    // Floppy-sound CDC: same valid/ack pattern as MB (independent
    // handshake - separate source). The donor is zero-idle (no drive
    // events / option off -> 0), so a silent drive crosses exactly 0 and
    // the mix term below adds nothing: bit-identical to the speaker+MB
    // build. No DC tracker: the samples are amplitudes (unsigned,
    // idle 0), summed directly - MiSTer parity (floppy_sound.sv NOTICE).
    reg [9:0] fs_x_l = 10'd0, fs_x_r = 10'd0;
    reg       fs_vld = 1'b0;
    reg       fs_ack = 1'b0;
    reg       fs_ack_s1 = 1'b0, fs_ack_s2 = 1'b0;
    always @(posedge clk_14m) begin
        fs_ack_s1 <= fs_ack;
        fs_ack_s2 <= fs_ack_s1;
        if (fs_ack_s2 == fs_vld) begin
            fs_x_l <= fs_l;
            fs_x_r <= fs_r;
            fs_vld <= ~fs_vld;
        end
    end

    // ------------------------------------------------------------------
    // 2. CDC to the audio domain + DC blocker
    // ------------------------------------------------------------------
    // Quasi-static 10-bit duty (0..512) crossed to the audio domain (2-FF),
    // then centered by a FIRST-ORDER TRACKER on the raw unsigned duty:
    //   d_lp follows d_in with step = |d_in - d_lp|/16 (0..15, rounded) -
    //   pure unsigned 10-bit arithmetic: no negation, no signed ops, no
    //   signed shifts anywhere in this block. (Verilator 5.050 miscompiles
    //   signed `>>` as logical - proven in tb_signshift.sv - and folds
    //   explicit two's-complement idioms into wrong bit widths; Quartus
    //   follows IEEE. This form is identical in hardware and immune to
    //   both problems.)
    // The I2S word is the centered difference (duty - mean) x 32, i.e.
    // -8192..+8160 => half-scale 16-bit, the MiSTer core's convention.
    reg [ 9:0] duty_s1 = 10'd0, duty_s2 = 10'd0;
    // MB handshake receive (mclk domain): latch a new sample pair when the
    // synchronized valid toggle differs from the ack. The option bit
    // crosses as a plain 2-FF so the mix gate below is a plain mclk-domain
    // signal.
    reg [ 9:0] mb_l_c = 10'd0, mb_r_c = 10'd0;   // latched samples (mclk dom)
    reg [ 9:0] fs_l_c = 10'd0, fs_r_c = 10'd0;   // floppy latched samples (mclk dom)
    reg        fs_vld_s1 = 1'b0, fs_vld_s2 = 1'b0;
    reg        mb_vld_s1 = 1'b0, mb_vld_s2 = 1'b0;
    reg        mb_in_s1, mb_in_s2;
    reg [1:0]  mb_gain_s1, mb_gain_s2;
    reg [1:0]  spk_gain_s1, spk_gain_s2;
    reg        fs_boost_s1, fs_boost_s2;
    always @(posedge mclk) begin
        duty_s1 <= spk_avg;
        duty_s2 <= duty_s1;
        mb_vld_s1 <= mb_vld;
        mb_vld_s2 <= mb_vld_s1;
        if (mb_vld_s2 !== mb_ack) begin
            mb_l_c <= mb_x_l;
            mb_r_c <= mb_x_r;
            mb_ack <= ~mb_ack;
        end
        fs_vld_s1 <= fs_vld;
        fs_vld_s2 <= fs_vld_s1;
        if (fs_vld_s2 !== fs_ack) begin
            fs_l_c <= fs_x_l;
            fs_r_c <= fs_x_r;
            fs_ack <= ~fs_ack;
        end
        mb_in_s1 <= mb_in_m;  mb_in_s2 <= mb_in_s1;
        mb_gain_s1 <= mb_gain_m;  mb_gain_s2 <= mb_gain_s1;
        spk_gain_s1 <= spk_gain_m;  spk_gain_s2 <= spk_gain_s1;
        fs_boost_s1 <= fs_boost_m;  fs_boost_s2 <= fs_boost_s1;
    end

    wire [ 9:0] d_in  = duty_s2;                       // 0..512 (raw unsigned)
    reg  [ 9:0] d_lp  = 10'd256;                        // tracker (starts centered)
    wire [ 9:0] d_abs = d_in >= d_lp ? (d_in - d_lp) : (d_lp - d_in);   // 0..511
    wire [ 9:0] d_step = (d_abs + 10'd15) >> 4;        // rounded /16: 0 for diff=0, >=1 for diff>=1 -> exact convergence, no deadband
    wire [10:0] d_sdiff = d_in - d_lp;                  // 11-bit raw two's complement, -512..511
    wire [15:0] d_sdiff16 = {d_sdiff[10], d_sdiff[10], d_sdiff[10], d_sdiff[10], d_sdiff[10], d_sdiff[10:0]};
    wire [15:0] spk_word  = d_sdiff16 << 5;                       // x32: -8192..+8160

    // ------------------------------------------------------------------
    // 2b. MB DC removal + gain + mix (mclk domain, 2026-11-18 rev)
    // ------------------------------------------------------------------
    // The point-sampled AY sum (0..765) carries a DC offset = the tone's
    // mean level (V/2 per active channel). A SLOW first-order tracker
    // removes it: step = |diff|/128 (min 1 while off-target), tau ~128
    // samples ~ 2.7 ms: passes 100 Hz at 0.3 dB and 50 Hz at 0.06 dB (the
    // old tau=16 sample tracker was a ~500 Hz high-pass that ate the MB
    // bass - plan suspect S3) while still tracking volume/DC changes
    // between notes within a few ms.
    // Gain x16: the first hardware A/B (2026-11-18, build 21:25, x4) was
    // judged too quiet. x16 = geometric midpoint of the too-loud x64 and the
    // too-quiet x4: a single-channel full-volume tone (sdiff +/-127) x16 =
    // +/-2032 = 1/4 of the speaker's +/-8192 full swing; a 3-channel
    // transient peak (sdiff +/-765) tops out at +/-12240 - the 16-bit add
    // (spk +/-8192 + mb +/-12240 = +/-20432 max) still cannot clip.
    // (x4 was MiSTer-parity ~1/15 - the golden is quiet; the Pocket's I2S
    // chain needs more to sit right in the headphones.)
    // mb_in_s2=0: the MB term is 0 (silent card => sdiff converges to 0),
    // so L/R = spk_word exactly - bit-identical to the pre-port mono path.
    wire [10:0] mb_sdiff_l = mb_l_c - mb_lp_l;   // -1024..+1023 (11-bit two's comp)
    wire [10:0] mb_sdiff_r = mb_r_c - mb_lp_r;
    reg [9:0]   mb_lp_l = 10'd0, mb_lp_r = 10'd0;   // DC trackers (mclk dom)
    wire [9:0]  mb_dabs_l = mb_l_c >= mb_lp_l ? (mb_l_c - mb_lp_l) : (mb_lp_l - mb_l_c);
    wire [9:0]  mb_dabs_r = mb_r_c >= mb_lp_r ? (mb_r_c - mb_lp_r) : (mb_lp_r - mb_r_c);
    // step = |diff|/128 rounded, min 1 while off-target (exact convergence)
    wire [9:0]  mb_step_l = (mb_dabs_l == 10'd0) ? 10'd0 : (((mb_dabs_l + 10'd63) >> 7) | 10'd1);
    wire [9:0]  mb_step_r = (mb_dabs_r == 10'd0) ? 10'd0 : (((mb_dabs_r + 10'd63) >> 7) | 10'd1);
    // Volume slider (mb_gain_s2): 01 = x24 (1x), 10 = x32 (2x),
    // 11 = x48 (3x). 00 only occurs with the card off (mb_in_s2 gates the
    // term out). Levels vs the speaker (single-channel 255 -> speaker
    // full-scale is +/-8192):
    //   1x x24 -> +/-6120  (0.75x speaker)
    //   2x x32 -> +/-8160  (~1.0x speaker)
    //   3x x48 -> +/-12240 (1.5x speaker)
    // (2026-11-19 hardware: x16 was too quiet; ladder shifted x1.5 and
    // the top level raised to x48 - see PLAN_MB_AUDIO_DEBUG section 9.)
    // All base forms are EXACT 16-bit two's complement of sdiff scaled
    // (the -Werror build flags WIDTHTRUNC on wider concatenations):
    //   x8  = {3 sign, sd[9:0], 3 zeros}
    //   x16 = {2 sign, sd[9:0], 4 zeros}      x32 = {1 sign, sd[9:0], 5 zeros}
    wire [15:0] mb_word_l_x16 = {mb_sdiff_l[10], mb_sdiff_l[10],
                                 mb_sdiff_l[9:0], 4'b0000};
    wire [15:0] mb_word_l_x8  = {mb_sdiff_l[10], mb_sdiff_l[10], mb_sdiff_l[10],
                                 mb_sdiff_l[9:0], 3'b000};
    wire [15:0] mb_word_l_x24 = mb_word_l_x16 + mb_word_l_x8;
    wire [15:0] mb_word_l_x32 = {mb_sdiff_l[10], mb_sdiff_l[9:0], 5'b00000};
    // x48: signed 17-bit product, clamped to 16 bits. At the card's true
    // max (sdiff 765 = three full channels) x48 = 36,720 exceeds 16 bits -
    // the extreme corner clamps (clean limiting), it never wraps.
    wire signed [10:0] mb_sd_l = mb_sdiff_l;   // same bits, signed view
    wire signed [16:0] mb_word_l_x48_raw = mb_sd_l * 17'sd48;
    wire [15:0] mb_word_l_x48 = (mb_word_l_x48_raw > 17'sd32767) ? 16'sd32767 :
                                (mb_word_l_x48_raw < -17'sd32768) ? 16'h8000 :
                                mb_word_l_x48_raw[15:0];
    wire [15:0] mb_word_l = mb_gain_s2[1] ? (mb_gain_s2[0] ? mb_word_l_x48 : mb_word_l_x32)
                                          : mb_word_l_x24;
    wire [15:0] mb_word_r_x16 = {mb_sdiff_r[10], mb_sdiff_r[10],
                                 mb_sdiff_r[9:0], 4'b0000};
    wire [15:0] mb_word_r_x8  = {mb_sdiff_r[10], mb_sdiff_r[10], mb_sdiff_r[10],
                                 mb_sdiff_r[9:0], 3'b000};
    wire [15:0] mb_word_r_x24 = mb_word_r_x16 + mb_word_r_x8;
    wire [15:0] mb_word_r_x32 = {mb_sdiff_r[10], mb_sdiff_r[9:0], 5'b00000};
    wire signed [10:0] mb_sd_r = mb_sdiff_r;
    wire signed [16:0] mb_word_r_x48_raw = mb_sd_r * 17'sd48;
    wire [15:0] mb_word_r_x48 = (mb_word_r_x48_raw > 17'sd32767) ? 16'sd32767 :
                                (mb_word_r_x48_raw < -17'sd32768) ? 16'h8000 :
                                mb_word_r_x48_raw[15:0];
    wire [15:0] mb_word_r = mb_gain_s2[1] ? (mb_gain_s2[0] ? mb_word_r_x48 : mb_word_r_x32)
                                          : mb_word_r_x24;
    // Final sum: 16-bit SATURATING add of speaker + MB + floppy (x48 +
    // speaker full + floppy x8 can exceed the range; clamping is clean
    // limiting, wrapping is a harsh digital glitch). 17 bits hold the
    // pre-clamp range: 8192 + 32767 + 8184 = 49,143 < 65,535.
    // The MB inslot option gates ONLY the MB term (independent feature:
    // floppy sound works with the MB card off). Silent sources add
    // exactly 0 (tracker-converged MB sdiff; zero-idle donor), so MB-off
    // + silent card + silent drive reproduces spk_word bit-exactly.
    wire [15:0] mb_term_l = mb_in_s2 ? mb_word_l : 16'd0;
    wire [15:0] mb_term_r = mb_in_s2 ? mb_word_r : 16'd0;
    // Beeper volume slider (spk_gain_s2): 00 = OFF, 01 = x1/4, 10 = x1/2,
    // 11 = x1 (2026-11-20 v2 remap: the user wants the beeper SOFTER than
    // the 0.3.6 baseline, not louder - the MB top stop is rail-clamped so
    // the beeper must sit below it. Stop 3 = the 0.3.6 pre-feature word
    // bit-exactly; 1/2 are arithmetic right-shifts of the signed word
    // (truncation toward zero; the DC tracker absorbs the sub-LSB bias).
    // Max |spk_word| is 16384 (d_sdiff16 << 5), so x1 fits in 17 bits and
    // no stop can reach the 16-bit rails; the 19-bit final sum is kept
    // for headroom (max 16,384 + 32,767 + 16,368 = 65,519 = 17 bits).
    // 16->19 sign extension: the sign bit appears THREE times (one per
    // added width bit) - fewer copies zero-extend and flip negatives
    // positive (the constant-0-prefix bug found 2026-11-19).
    wire signed [15:0] spk_ws_l   = spk_word;                 // sign reinterpret
    wire signed [15:0] spk_x12_l  = spk_ws_l >>> 1;           // x1/2
    wire signed [15:0] spk_x14_l  = spk_ws_l >>> 2;           // x1/4
    wire signed [18:0] spk_g19_l  = (spk_gain_s2 == 2'd0) ? 19'sd0
                  : (spk_gain_s2 == 2'd1) ? {spk_x14_l[15], spk_x14_l[15], spk_x14_l[15], spk_x14_l}
                  : (spk_gain_s2 == 2'd2) ? {spk_x12_l[15], spk_x12_l[15], spk_x12_l[15], spk_x12_l}
                  : {spk_word[15], spk_word[15], spk_word[15], spk_word};   // x1 = 0.3.6 word
    wire signed [18:0] spk_g19_r  = spk_g19_l;
    // 16->18 sign extension: the sign bit appears TWICE (one per each of
    // the two added width bits) and the concat must be exactly 18 bits -
    // a 17-bit concat zero-extends into [17:0] and flips negatives
    // positive (found 2026-11-19: the MB negative rail became +32768).
    wire signed [17:0] mbt18_l = {mb_term_l[15], mb_term_l[15], mb_term_l};
    wire signed [17:0] mbt18_r = {mb_term_r[15], mb_term_r[15], mb_term_r};
    wire signed [18:0] mbt_s19_l = {mbt18_l[17], mbt18_l};
    wire signed [18:0] mbt_s19_r = {mbt18_r[17], mbt18_r};
    // Floppy term: unsigned amplitude x8 (0..8184, idle 0), optionally
    // x2 boosted (slider top stop = donor x4 * 2 = x8 total).
    wire [15:0]  fs_word_l = {3'b000, fs_l_c, 3'b000};      // x8
    wire [15:0]  fs_word_r = {3'b000, fs_r_c, 3'b000};      // x8
    wire [17:0]  fs_x16_l  = {4'b0000, fs_l_c, 4'b0000};    // x16 (boost case), max 16368
    wire [17:0]  fs_x16_r  = {4'b0000, fs_r_c, 4'b0000};
    wire signed [18:0] fs_s19_l = fs_boost_s2 ? {1'b0, fs_x16_l} : {3'b000, fs_word_l};
    wire signed [18:0] fs_s19_r = fs_boost_s2 ? {1'b0, fs_x16_r} : {3'b000, fs_word_r};
    // 19-bit sum: signed addends sign-extend with THEIR SIGN BIT (a
    // constant-0 prefix flips negative addends positive - found
    // 2026-11-19). fs is unsigned (floppy amplitude, top bit always 0)
    // so its 0-prefix is exact.
    wire signed [18:0] sum_l = spk_g19_l + mbt_s19_l + fs_s19_l;
    wire signed [18:0] sum_r = spk_g19_r + mbt_s19_r + fs_s19_r;
    // 19-bit to 16-bit SATURATE, sign-magnitude form (unsigned compares
    // only - Verilator 5.050 evaluates signed-looking comparisons on
    // this sum UNSIGNED, and -32768 has the same top bit in 17 and 18
    // bits, which is what let that bug hide for a day). Reachable
    // |sum| <= 180,207 keeps the bit18 sign test valid (only the 19-bit
    // minimum, -262,144, would flip it).
    //   sum > +32767  <=> bit18==0 and mag[17:0] > 18'd32767
    //   sum < -32768  <=> bit18==1 and |sum| > 32768, where
    //   |sum| = 2^18 - bits[17:0] = ~bits[17:0] + 1  (bit18 discarded)
    wire [17:0] sum_mag_l = ~sum_l[17:0] + 18'd1;
    wire [15:0] out_l16 = (sum_l[18] ? (sum_mag_l > 18'd32768 ? 16'h8000 : sum_l[15:0])
                                     : (sum_l[17:0] > 18'd32767 ? 16'sd32767 : sum_l[15:0]));
    wire [17:0] sum_mag_r = ~sum_r[17:0] + 18'd1;
    wire [15:0] out_r16 = (sum_r[18] ? (sum_mag_r > 18'd32768 ? 16'h8000 : sum_r[15:0])
                                     : (sum_r[17:0] > 18'd32767 ? 16'sd32767 : sum_r[15:0]));

    // ------------------------------------------------------------------
    // 3. I2S shift-out: 16 active + 16 dummy bits per channel
    // ------------------------------------------------------------------
    reg [4:0]  lrck_cnt = 5'd0;
    reg        lrck_r   = 1'b0;
    reg        dac_r    = 1'b0;
    reg [15:0] i2s_shift = 16'd0;

    always @(negedge sclk) begin
        if (lrck_cnt == 5'd31) begin
            // channel switch: load the centered sample, advance the trackers
            // MB stereo (2026-11-18): the word streams over the NEXT period
            // with lrck = ~lrck_r (I2S: lrck high = right channel), so pick
            // by the CURRENT lrck_r: 0 -> right period follows -> R, 1 -> left.
            // Mono (mb_in_s2=0): out_l16 == out_r16 == spk_word - no-op select.
            i2s_shift <= lrck_r ? out_l16 : out_r16;
            d_lp      <= d_in >= d_lp ? (d_lp + d_step) : (d_lp - d_step);
            mb_lp_l   <= mb_l_c >= mb_lp_l ? (mb_lp_l + mb_step_l) : (mb_lp_l - mb_step_l);
            mb_lp_r   <= mb_r_c >= mb_lp_r ? (mb_lp_r + mb_step_r) : (mb_lp_r - mb_step_r);
            lrck_r    <= ~lrck_r;
        end else begin
            // MSB-first stream: read bit 15 while shifting LEFT.
            // (W<<k)[15] = W[15-k]; a right-shift would emit W[15] once,
            // then zeros forever - proven wrong by tb_speaker_i2s.
            i2s_shift <= i2s_shift << 1;
        end
        dac_r       <= i2s_shift[15];
        lrck_cnt    <= lrck_cnt + 5'd1;
    end

    assign lrck = lrck_r;
    assign dac  = dac_r;
endmodule
