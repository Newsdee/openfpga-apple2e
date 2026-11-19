# Build 2026-11-19 12:07 — Standard-Fit re-roll of the floppy-sound build

First re-roll after the 11:27 build failed the hardware floppy test AND
savestate load (see `2026-11-19_1127_ship_037_fs/` and EXPERT_BRIEF_WOZ_
FLOPPY_HW_REGRESSION section 13). Same netlist (commit `85a3e11`),
different fitter search.

## The re-roll

- `FITTER_EFFORT "HIGH"` (my first attempt) was rejected by QP 17 (Error
  125036) — the value space is `"Auto Fit" / "Fast Fit" / "Standard Fit"`.
- Key finding: fit.rpt Info 171003/170199 show **Auto Fit degrades the
  fit** ("may decrease Fitter effort", "optimizations were skipped to
  reduce compilation time") — every build to date ran under-fitted.
- This build: `FITTER_EFFORT "Standard Fit"` — verified in fit.rpt
  ("Fitter Effort: Standard Fit"), seed still 1.

## Results (vs 11:27 Auto-Fit failing build)

- Fitter: Successful 12:06. ALM **16,023 / 18,480 (87%)** (11:27: 16,052),
  registers **17,127** (11:27: 17,212) — a genuinely different placement.
- STA (Slow 1100mV 85C final): mp2 setup slack **1.131 ns** (11:27: 0.540),
  clk_74a 4.063, bridge_spiclk 9.681, TNS 0.
- The slack improvement is encouraging but NOT the gate (0.253 ns once
  passed); the hardware floppy + savestate test decides.

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `d9eaeb5446cbdb178e13554568f55c8a00d17b15ace486e56a7f1b6f79140823`
- `bitstream.rbf_r` (bit-reversed via `C:/Temp/bitrbf.pl`) SHA-256:
  `3c2572551d33789ea1eb948a712524ec2d4ac08a9794cff8fa8692a7fbce1c33`

## Hardware gate (three-way)

1. Floppy (.woz) load.
2. Savestate load.
3. Savestate save (direction probe — machine→host; the 11:27 build
   failed only loads, saves untested).
Plus spot-checks: MB slider 1x/2x/3x, Floppy Sound option, drive sound.

If this roll passes all three, the 11:27 failure is a per-placement
congestion of host→machine transport and Standard Fit (which should also
be used for future builds once confirmed) is the structural mitigation.
If it still fails: next roll OPTIMIZATION_TECHNIQUE SPEED→BALANCED, then
PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF, then the machine-domain
constraint / sound-engine-to-mclk structural fix.
