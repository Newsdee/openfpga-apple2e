# Build 2026-11-19 22:32 — audio-balance sliders (0.3.7, pre-cut)

First build containing the Floppy Volume (0x01F00028) and Beeper Volume
(0x01F0002C) sliders — commit `2daf3a5` ("Audio balance: Floppy Volume +
Beeper Volume sliders (pre-0.3.7 cut)"). Same Standard-Fit standing config
as the hardware-passing 12:07 build.

## Results

- A&S: Successful 22:22. Fitter: Successful 22:32, **Standard Fit** (fit.rpt
  "Fitter Effort: Standard Fit", Info 171004 maximum effort), seed 1.
- ALM **16,049 / 18,480 (87%)**, registers **17,145**, DSP 29 (vs 12:07:
  16,023 / 17,127 — the gain-stage selects + two 2-bit CDCs).
- STA (Slow 1100mV 85C final): mp2 setup slack **1.177 ns**, clk_74a 4.081,
  bridge 10.359, TNS 0 across all clocks (12:07 passing build: 1.131).
- Map hierarchy: `u_floppy_sound` present (467 ALM); `u_devkey_uart`
  ABSENT (shipping tree, diagnostics off).

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `b10d184632e9c5552b5dce2d0841397998cc773038d2de1736722a86ac8b60ba`
- `bitstream.rbf_r` (bit-reversed, staged) SHA-256:
  `cc061da371f4a043a6724b8453c960efe30fb76551f71881cfbb0d81ec16ee91`

## Gate

Sim: chain TB 15/15, mono harness -Werror-clean, MB audio TB all checks
(see commit). Hardware: the three-way test (floppy load / savestate load /
savestate save) plus the first A/B walk of the three volume sliders
(Mockingboard / Floppy Volume / Beeper Volume) decides. Defaults are the
1x/x1 starting points; JSON-only default tweaks are allowed after the
listen, then the 0.3.7 cut.

**Superseded:** the ladders in this build were then raised (floppy
off/2x/4x/8x, beeper 2x/4x/6x/8x) plus an MB negative-rail sign-extension
fix - commit `0e0ee0b`. A new Standard-Fit build of that commit is the
one to test.
