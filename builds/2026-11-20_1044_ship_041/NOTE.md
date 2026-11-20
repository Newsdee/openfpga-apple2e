# Build 2026-11-20 10:44 — 0.4.1 ship candidate (console out, ladder in)

Commit `b5a3881` (DEVKEY_DIAG=0 revert of the 10:21 diagnostic tree).
Placement roll #10: the ladder netlist with the devkey console REMOVED.
If this passes floppy + HDV + savestate save/load, 0.4.1 is cut from
it. If it fails while 09:24/10:21 (console IN) passed, that is a
strikingly clean placement signal and the structural fix moves to the
front.

## Results

- A&S Successful 10:34, Fitter Successful 10:44, **Standard Fit**.
- ALM **16,106 / 18,480 (87%)** (10:21 was 16,989... 17,063 with the
  console: -957 ALM), registers 17,250.
- STA: mp2 setup slack **1.504 ns**, clk_74a 3.665, bridge 10.437,
  TNS 0 across clocks.
- Map: `u_devkey_uart` ABSENT (console gated out via g_no_devkey),
  `u_floppy_sound` present, OVL switches 0 (shipping tree).

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `425df8c9fdf25052c85aacb038f02e2f6ee1a7d3a5d9e004a89c0850625d9daf`
- `bitstream.rbf_r` (staged) SHA-256:
  `1304d6f3f6e9d3c82a1022d8a0c0c42b6b21ae5cbe478173d8ec414a04f55024`

## HW test

1. Floppy load
2. HDV load
3. Savestate SAVE + LOAD (both directions)
(COM4 is silent by design - no console in this build.)

## HW result (2026-11-20): PASS - 0.4.1 cut from this build

User: "all good" - floppy load, HDV load, savestate save+load all pass.
Roll #10 = pass: series is now 8W/4F, and the ladder netlist family
passed three times in a row (09:24 console-in, 10:21 console-in,
10:44 console-out). **0.4.1 released from this bitstream**
(`Apple2e_Pocket_0.4.1.zip`).
