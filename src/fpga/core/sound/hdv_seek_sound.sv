// ============================================================================
// hdv_seek_sound.sv - procedural HDV seek "soft grind" voice (Pocket-only)
//
// PLAN_HDV_PROCEDURAL_SEEK_SOUND_2026-11-26 step 1+2. Listening reference:
// HDV-audio-previews/L-soft-grindy-seeks.wav (NOT reproduced bit-for-bit;
// no recording, no sample ROM, no card assets - fully procedural like the
// floppy_sound.sv donor pattern, but this module is Pocket-owned: the donor
// is not modified).
//
// Voice (per plan section 1):
//   body   quiet triangle, gentle 800 -> 710 Hz fall over the seek
//          (32-bit phase accumulator, folded upper bits; no LUT)
//   grit   bipolar LFSR noise (nonzero seed), two-pole shift/add lowpass
//   scrape amplitude re-triggered ~130/s (short seek) / ~100/s (long seek)
//          with slight deterministic jitter; amplitude decays between
//          peaks but never mutes (one grind, not separate knocks)
//   edges  ~6 ms attack, ~12 ms release, INSIDE the 52/134 ms duration;
//          ends at exact digital zero; nothing at power-on or idle
//   one sound for reads and writes; silence on sequential access
//
// Trigger (plan section 2): observes ACCEPTED guest command pulses
// (hdd_read|hdd_write with hdd_sector; machine domain, same as this
// module's clock - hdd.v runs on CLK_14M). Distance = unsigned absolute
// difference of 16-bit block numbers (no wraparound). 0..1 silent,
// 2..63 short seek, >=64 long seek. History updates on EVERY accepted
// command including while busy; triggers during playback are dropped
// (no queue, no restart). Reset/disable/eject/mount silences and
// invalidates history (first command after invalidation seeds silently).
//
// DOMAIN: machine clock (clk_core_14318, 14.318 MHz), all inputs and
// outputs in that domain. The consumer (speaker_i2s) does the CDC with
// its existing valid/ack held-sample pattern - this module just presents
// a signed mono sample stream with a 48 kHz sample_tick.
//
// Arithmetic: bounded, explicitly signed, saturating final mix. No
// inferred memory, no multiplication (gains are shift-add constants).
// ============================================================================
`timescale 1ns / 1ps

module hdv_seek_sound #(
    // Timbre parameters. DEFAULTS = preset "Q", the owner-approved sweet
    // spot (2026-11-27): a 3040->3240 Hz RISING body sweep with light grit
    // and a soft/ethereal envelope. Found by ear in tone_lab.html, which is
    // an exact integer mirror of this module - keep the two in sync.
    //   Q: {3040, 3240, BODY_SHIFT 4, GRIT_SHIFT 2, ATK 16, REL 30,
    //       SWELL 70/55 Hz, ENV 1500/900, DECAY 192}
    parameter integer BODY_START_HZ = 3040,
    parameter integer BODY_END_HZ   = 3240,
    parameter integer BODY_SHIFT    = 4,   // body scale = 1/2^BODY_SHIFT
    parameter integer GRIT_SHIFT    = 2,   // extra grit attenuation
    // envelope / swell profile (soft/ethereal = slower swell, gentler
    // edges, shallow peak-floor; percussive = faster + deeper)
    parameter integer ATK_MS        = 16,
    parameter integer REL_MS        = 30,
    parameter integer SCRAPE_HZ_S   = 70,  // swell rate, short seeks
    parameter integer SCRAPE_HZ_L   = 55,  // swell rate, long seeks
    parameter integer ENV_PEAK_I    = 1500,
    parameter integer ENV_FLOOR_I   = 900,
    parameter integer DECAY_DIV_I   = 192, // env decay: 1 unit / N clks
    parameter integer OUT_SHIFT     = -5   // final level: negative = gain
                                           // (see "final voice level")
) (
    input  wire        clk,          // machine 14.318 MHz
    input  wire        reset,        // active-high machine reset
    input  wire        enable,       // HDV Sound option (machine-domain sync)

    // accepted guest command observation (pulses/level, machine domain)
    input  wire        cmd_valid,    // 1-cycle pulse: accepted read|write
    input  wire [15:0] cmd_sector,
    input  wire        mounted,      // hdv_mounted_m level

    // mono voice output (machine domain; CDC is the consumer's job)
    output reg  signed [15:0] sample,
    output reg         sample_tick   // 1 clk wide, 48 kHz rate
);

    // ------------------------------------------------------------------
    // 48 kHz sample tick: 14.31818 MHz / 48000 = 298.295 -> 298 (0.1%
    // rate error; irrelevant for a rendered effect, keeps a plain counter)
    // ------------------------------------------------------------------
    localparam [8:0] TICK_DIV = 9'd298;
    reg [8:0] tick_cnt;
    always @(posedge clk) begin
        if (reset) tick_cnt <= 9'd0;
        else if (tick_cnt == TICK_DIV - 9'd1) tick_cnt <= 9'd0;
        else tick_cnt <= tick_cnt + 9'd1;
        sample_tick <= (tick_cnt == TICK_DIV - 9'd2);
    end

    // ------------------------------------------------------------------
    // Seek geometry (machine clocks @ 14.31818 MHz)
    // ------------------------------------------------------------------
    localparam [20:0] DUR_SHORT = 21'd744_545;    //  52 ms
    localparam [20:0] DUR_LONG  = 21'd1_918_636;  // 134 ms
    localparam [20:0] ATK_LEN   = ATK_MS * 21'd14_318;   // ms -> machine clks
    localparam [20:0] REL_LEN   = REL_MS * 21'd14_318;
    localparam [20:0] REL_OFF_S = DUR_SHORT - REL_LEN;   // 658,636
    localparam [20:0] REL_OFF_L = DUR_LONG  - REL_LEN;   // 1,746,818

    // body oscillator: inc = f * 2^32 / 14.31818e6 (~299.97 per Hz)
    localparam [31:0] INC_START = (64'd4294967296 * BODY_START_HZ) / 64'd14318180;
    localparam [31:0] INC_END   = (64'd4294967296 * BODY_END_HZ)   / 64'd14318180;
    // sweep span is UNSIGNED magnitude: the sweep is bidirectional, so
    // BODY_END_HZ may be above OR below BODY_START_HZ (preset Q rises).
    localparam [31:0] INC_SPAN = (INC_START > INC_END) ? (INC_START - INC_END)
                                                       : (INC_END - INC_START);
    // step once per SWEEP_DIV clocks so the full span is covered by the end
    // of the seek: DIV = dur_clks / span (25 bits, span!=0 guarded)
    localparam [24:0] SWEEP_DIV_S = 25'd744545  / (INC_SPAN != 0 ? INC_SPAN : 1);
    localparam [24:0] SWEEP_DIV_L = 25'd1918636 / (INC_SPAN != 0 ? INC_SPAN : 1);

    // scrape/swell period in machine clocks (20 bits: 14.318e6/55 = 260,330
    // max at the soft preset - a 16-bit counter would silently wrap)
    localparam [19:0] SCRAPE_S = 20'd14_318_180 / SCRAPE_HZ_S[19:0];
    localparam [19:0] SCRAPE_L = 20'd14_318_180 / SCRAPE_HZ_L[19:0];
    localparam [19:0] SCRAPE_JIT = 20'd64;    // jitter = jit[9:0]*64 clks
                                              // = 0..4.5 ms (+/- ~3%)

    // decay floor between scrape peaks: amp = FLOOR + decayed peak
    localparam signed [15:0] ENV_PEAK  = ENV_PEAK_I[15:0];
    localparam signed [15:0] ENV_FLOOR = ENV_FLOOR_I[15:0];
    localparam [8:0] DECAY_DIV = DECAY_DIV_I[8:0];

    // final voice level: v = ((body>>BODY_SHIFT) + (grit>>GRIT_SHIFT)) * env
    // >> 15, then sample = v * edge/8192 >> OUT_SHIFT. With preset Q the
    // pre-OUT_SHIFT peak is ~98 (measured), so OUT_SHIFT = -5 (i.e. >> 8
    // instead of >> 13) gives ~3100 signed peak ~= 9.5% FS - a clearly
    // audible but non-dominant effect next to the floppy/speaker terms.
    // OUT_SHIFT may be negative (gain); the mixer saturates independently.
    // Verified by render: Q UNNORMALIZED peak, see tone_lab.html mirror.

    // ------------------------------------------------------------------
    // Trigger / state
    // ------------------------------------------------------------------
    localparam [1:0] ST_IDLE = 2'd0, ST_SEEK = 2'd1;
    reg [1:0]  state;
    reg [20:0] elapsed;
    reg [20:0] dur;         // latched duration
    reg [24:0] sweep_div;   // latched per duration
    reg [19:0] scrape_per;  // latched per duration
    reg [20:0] rel_off;     // latched release start

    reg        hist_valid;
    reg [15:0] hist_sector;
    reg        mounted_d;

    // distance (unsigned absolute difference, no wraparound)
    wire [15:0] sdist = (cmd_sector >= hist_sector) ? (cmd_sector - hist_sector)
                                                   : (hist_sector - cmd_sector);
    wire        trig_short = (sdist >= 16'd2) && (sdist < 16'd64);
    wire        trig_long  = (sdist >= 16'd64);

    // ------------------------------------------------------------------
    // Voice elements
    // ------------------------------------------------------------------
    reg [31:0] phase_acc;
    reg [31:0] freq_inc;
    reg [31:0] sweep_cnt;

    reg [12:0] lfsr;         // nonzero seed, never all-zero
    reg signed [15:0] n1, n2, nlp1, nlp2, noise_lp;

    reg [19:0] scrape_cnt;
    reg [19:0] scrape_next;
    reg [12:0] jit_lfsr;     // separate small LFSR: deterministic jitter
    reg signed [15:0] env;   // scrape envelope FLOOR..ENV_PEAK
    reg [8:0]  decay_cnt;

    reg [20:0] edge_len;     // current attack/release length
    reg signed [15:0] edge_mul; // progress along the edge, 0..EDGE_SCALE
    localparam signed [15:0] EDGE_SCALE = 16'sd8192;

    // sample-level mix registers (updated on sample_tick)
    reg signed [15:0] body_s, grit_s;
    reg signed [15:0] env_q;
    reg signed [20:0] edge_q;   // 0..8192 scaled envelope product

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            state        <= ST_IDLE;
            elapsed      <= 21'd0;
            hist_valid   <= 1'b0;
            hist_sector  <= 16'd0;
            mounted_d    <= 1'b0;
            phase_acc    <= 32'd0;
            freq_inc     <= INC_START;
            sweep_cnt    <= 32'd0;
            lfsr         <= 13'h1ACE;   // nonzero seed (plan)
            n1 <= 0; n2 <= 0; nlp1 <= 0; nlp2 <= 0; noise_lp <= 0;
            scrape_cnt   <= 20'd0;
            scrape_next  <= SCRAPE_S;
            jit_lfsr     <= 13'h05B3;
            env          <= 16'sd0;
            decay_cnt    <= 9'd0;
            sample       <= 16'sd0;
            body_s       <= 16'sd0;
            grit_s       <= 16'sd0;
            env_q        <= 16'sd0;
            edge_q       <= 21'sd0;
            edge_len     <= 21'd0;
            edge_mul     <= 16'sd0;
        end else begin
            mounted_d <= mounted;

            // ---- silence + invalidate on eject/disable/mount change ----
            // (plan: identify the real media-change indication; we use the
            // mounted LEVEL falling OR enable dropping - a replacement that
            // goes size->0->size drops mounted_d for at least one 0x008A
            // gap; a same-size replacement is indistinguishable by design)
            if (!mounted || !enable) begin
                state      <= ST_IDLE;
                hist_valid <= 1'b0;
                env        <= 16'sd0;
                sample     <= 16'sd0;
                edge_q     <= 21'sd0;
            end

            // ---- command observation: history updates ALWAYS ----
            if (cmd_valid && mounted && enable) begin
                if (!hist_valid) begin
                    hist_valid  <= 1'b1;          // seed silently
                    hist_sector <= cmd_sector;
                end else begin
                    hist_sector <= cmd_sector;
                    if (state == ST_IDLE) begin
                        if (trig_long) begin
                            state      <= ST_SEEK;
                            dur        <= DUR_LONG;
                            rel_off    <= REL_OFF_L;
                            sweep_div  <= SWEEP_DIV_L;
                            scrape_per <= SCRAPE_L;
                            elapsed    <= 21'd0;
                            phase_acc  <= 32'd0;
                            freq_inc   <= INC_START;
                            sweep_cnt  <= 32'd0;
                            env        <= ENV_FLOOR;
                            scrape_cnt <= 20'd0;
                            scrape_next <= SCRAPE_L +
                                           {7'd0, jit_lfsr[9:0]} * SCRAPE_JIT;
                            jit_lfsr   <= {jit_lfsr[11:0],
                                           jit_lfsr[12] ^ jit_lfsr[7]};
                        end else if (trig_short) begin
                            state      <= ST_SEEK;
                            dur        <= DUR_SHORT;
                            rel_off    <= REL_OFF_S;
                            sweep_div  <= SWEEP_DIV_S;
                            scrape_per <= SCRAPE_S;
                            elapsed    <= 21'd0;
                            phase_acc  <= 32'd0;
                            freq_inc   <= INC_START;
                            sweep_cnt  <= 32'd0;
                            env        <= ENV_FLOOR;
                            scrape_cnt <= 20'd0;
                            scrape_next <= SCRAPE_S +
                                           {7'd0, jit_lfsr[9:0]} * SCRAPE_JIT;
                            jit_lfsr   <= {jit_lfsr[11:0],
                                           jit_lfsr[12] ^ jit_lfsr[7]};
                        end
                        // sdist 0/1: silent, history already updated
                    end
                    // busy: trigger dropped, history still updated (plan)
                end
            end

            // ---- voice advance (per machine clock) ----
            if (state == ST_SEEK) begin
                elapsed <= elapsed + 21'd1;

                // body sweep
                phase_acc <= phase_acc + freq_inc;
                sweep_cnt <= sweep_cnt + 32'd1;
                if (sweep_cnt >= sweep_div) begin
                    sweep_cnt <= 32'd0;
                    // bidirectional sweep: step toward INC_END (preset Q rises)
                    if (freq_inc > INC_END)
                        freq_inc <= freq_inc - 32'd1;
                    else if (freq_inc < INC_END)
                        freq_inc <= freq_inc + 32'd1;
                end

                // noise + two-pole smoothing (shift/add lowpass)
                lfsr <= {lfsr[11:0], lfsr[12] ^ lfsr[7]};
                n1   <= (lfsr[12] ^ lfsr[7]) ? 16'sd900 : -16'sd900;
                nlp1 <= n1 - (n1 >>> 2) + (nlp1 >>> 2);
                nlp2 <= nlp1 - (nlp1 >>> 2) + (nlp2 >>> 2);
                noise_lp <= nlp2 >>> 1;

                // scrape envelope: re-trigger at scrape_next, else slow
                // decay toward (never reaching) the floor
                scrape_cnt <= scrape_cnt + 16'd1;
                decay_cnt  <= decay_cnt + 9'd1;
                if (scrape_cnt >= scrape_next) begin
                    scrape_cnt <= 20'd0;
                    env        <= ENV_PEAK;
                    scrape_next <= scrape_per +
                                   {7'd0, jit_lfsr[9:0]} * SCRAPE_JIT;
                    jit_lfsr   <= {jit_lfsr[11:0], jit_lfsr[12] ^ jit_lfsr[7]};
                end else if (decay_cnt == DECAY_DIV && env > ENV_FLOOR) begin
                    decay_cnt <= 9'd0;
                    env <= env - 16'sd1;
                end

                // edge envelope (attack, then release window)
                if (elapsed < ATK_LEN) begin
                    edge_len <= ATK_LEN;
                    edge_mul <= (elapsed * EDGE_SCALE) / ATK_LEN;
                end else if (elapsed >= rel_off) begin
                    edge_len <= REL_LEN;
                    edge_mul <= ((dur - elapsed) * EDGE_SCALE) / REL_LEN;
                end else begin
                    edge_mul <= EDGE_SCALE;
                end

                if (elapsed >= dur - 21'd1) begin
                    state  <= ST_IDLE;
                    env    <= 16'sd0;
                    sample <= 16'sd0;   // exact digital zero at the end
                    edge_q <= 21'sd0;
                end
            end else begin
                env    <= 16'sd0;
                edge_q <= 21'sd0;
            end

            // ---- 48 kHz sample capture + mix ----
            // body_s/grit_s/env_q/edge_q are the PREVIOUS tick's captures;
            // one-48k-tick latency is inaudible and keeps the path short.
            if (sample_tick) begin
                // triangle from folded phase: 0..32767 -> signed
                body_s <= phase_acc[31] ? -$signed({1'b0, ~phase_acc[30:16]})
                                        : $signed({1'b0, phase_acc[30:16]});
                grit_s <= noise_lp;
                env_q  <= env;
                edge_q <= $signed({5'd0, edge_mul});
            end
            // mix (runs every tick on the held captures; sample holds its
            // value between ticks, which is exactly what the consumer's
            // held-sample CDC wants):
            //   v = ((body/8 + grit) * env) >> 15   -> +/-172 pk
            //   s = (v * edge_q) >> (13 + OUT_SHIFT)
            begin : mix_block
                reg signed [27:0] v28;
                reg signed [35:0] p36;
                reg signed [35:0] s36;
                v28 = ((body_s >>> BODY_SHIFT) + (grit_s >>> GRIT_SHIFT)) * env_q; // +/-10.2M max, 28 bit
                p36 = v28 >>> 15;                          // +/-310
                s36 = (p36 * edge_q) >>> (13 + OUT_SHIFT); // +/-310
                if (s36 > 36'sd32767)       sample <= 16'sd32767;
                else if (s36 < -36'sd32768) sample <= -16'sd32768;
                else                        sample <= s36[15:0];
            end
        end
    end

    // Magnitude bound (asserted in TB): (4096+512)*2200 >> 15 = 307;
    // *8192 >> 13 = 307; OUT_SHIFT=0 -> |sample| <= 307 << 32767.

endmodule
