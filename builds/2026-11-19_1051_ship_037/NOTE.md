# 2026-11-19 10:51 - 0.3.7 ship candidate (Mockingboard + volume slider, no console)

Tree: post-commit `582861d`+`fe3ae5c` (MB port, audio x16/x24/x32 slider,
DEVKEY_DIAG=0 top AND sub-module, OVL_SS_* = 0). Floppy-sound prep files
(vendored donor + TB) are untracked/unregistered - NOT in this build.

## Verification
- Map: `u_devkey_uart` ABSENT (only file-parse infos for the registered
  devkey_uart.v; console generate block elided).
- Fit: 15,680 / 18,480 ALM (85%), 16,896 registers, seed 1 (default).
- STA (final models, TNS 0): mp2 divclk setup 0.726 ns, clk_74a 2.188,
  bridge_spiclk 10.989.

## History context (WOZ regression evidence table)
| build        | mp2 setup | floppy HW |
|--------------|----------:|-----------|
| 12:10 MB     | 0.858     | WORKS |
| 21:25 audio  | 0.547     | fails |
| 00:51 probe  | 0.685     | fails |
| 09:13 SSY    | 0.253     | WORKS (placement lottery) |
| this build   | 0.726     | **TEST PENDING** |

The 0.253-works data point refuted the slack gate: the hardware floppy
test is the shipping gate (EXPERT_BRIEF_WOZ_FLOPPY_HW_REGRESSION section
11). If floppy fails, revert nothing - re-roll the compile (fitter
preservation usually inherits the placement; a fresh draw may land the
feed differently).

## Raw rbf
sha256: 6fce2dfc3ae48c7df3bdf9fd2f47b60882d1f3f00d8669a77a84fcdae3988550
