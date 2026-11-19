# Build 2026-11-19 23:31 — raised audio ladders (0.3.7, pre-cut)

Commit `2ea480b` ("Audio ladders: floppy off/2x/4x/8x, beeper 2x/4x/6x/8x;
drop redundant checkbox"). Same Standard-Fit standing config.

## Changes since the 22:32 build

- Floppy Volume ladder raised: 0=off, 1=2x (default), 2=4x, 3=8x (new
  x2 boost stage for the 8x stop; the donor's gain port tops out at x4).
- Beeper Volume ladder raised x2: 0=2x (default), 1=4x, 2=6x, 3=8x
  (hardware: the x1..x4 steps were imperceptible against the mix).
- The "Floppy Sound" on/off checkbox is GONE (interact.json id 12
  removed) - the slider's 0 stop is the off state.
- RTL fix: MB term 16->18-bit sign extension used one sign-bit copy where
  two are needed (17-bit concat zero-extended into the 18-bit net,
  flipping the MB negative rail to +32,768). Latent in the 22:32 build.

## Results

- A&S Successful 23:20; Fitter Successful 23:30, **Standard Fit**
  (maximum effort, seed 1).
- ALM **16,079 / 18,480 (87%)** (22:32: 16,049 - the boost stage + a CDC
  bit).
- STA (Slow 1100mV 85C final): mp2 setup slack **1.259 ns**, clk_74a
  3.855, bridge 10.528, TNS 0 across all clocks.
- Map: `u_floppy_sound` present (466 ALM); `u_devkey_uart` absent.

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `84359bb7db7e7df03f3744f78fc7e089e2e3859af1c7ead8d29a6efd7592d0d8`
- `bitstream.rbf_r` (bit-reversed, staged) SHA-256:
  `7c0424ba079d6229433f310cfc593f09e6eedbe64481fd7cba98720e7baf943c`

## Gate

Sim: chain TB 15/15 (floppy 160/320/640 exact ratios, beeper x4/x8 at
both rails, MB both rails exact), mono harness -Werror-clean, MB audio
TB all checks. Hardware: three-way test + A/B walk of the three sliders
(Mockingboard 24/32/48, Floppy Volume off/2x/4x/8x, Beeper Volume
2x/4x/6x/8x).
