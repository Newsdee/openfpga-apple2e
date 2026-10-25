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

module speaker_i2s (
    input  wire        clk_14m,   // 14.318 MHz machine domain (averager)
    input  wire        spk_bit,   // 1-bit speaker (machine domain, m_spk)
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
    always @(posedge mclk) begin
        duty_s1 <= spk_avg;
        duty_s2 <= duty_s1;
    end

    wire [ 9:0] d_in  = duty_s2;                       // 0..512 (raw unsigned)
    reg  [ 9:0] d_lp  = 10'd256;                        // tracker (starts centered)
    wire [ 9:0] d_abs = d_in >= d_lp ? (d_in - d_lp) : (d_lp - d_in);   // 0..511
    wire [ 9:0] d_step = (d_abs + 10'd15) >> 4;        // rounded /16: 0 for diff=0, >=1 for diff>=1 -> exact convergence, no deadband
    wire [10:0] d_sdiff = d_in - d_lp;                  // 11-bit raw two's complement, -512..511
    wire [15:0] d_sdiff16 = {d_sdiff[10], d_sdiff[10], d_sdiff[10], d_sdiff[10], d_sdiff[10], d_sdiff[10:0]};
    wire [15:0] spk_word  = d_sdiff16 << 5;                       // x32: -8192..+8160

    // ------------------------------------------------------------------
    // 3. I2S shift-out: 16 active + 16 dummy bits per channel
    // ------------------------------------------------------------------
    reg [4:0]  lrck_cnt = 5'd0;
    reg        lrck_r   = 1'b0;
    reg        dac_r    = 1'b0;
    reg [15:0] i2s_shift = 16'd0;

    always @(negedge sclk) begin
        if (lrck_cnt == 5'd31) begin
            // channel switch: load the centered sample, advance the tracker
            i2s_shift <= spk_word;
            d_lp      <= d_in >= d_lp ? (d_lp + d_step) : (d_lp - d_step);
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
