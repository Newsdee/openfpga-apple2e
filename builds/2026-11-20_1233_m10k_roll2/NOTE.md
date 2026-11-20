# Build 2026-11-20 12:33 — HDV M10K placement roll #2 (re-roll after roll #1 failure)

Same tree/commit as roll #1 (`70cf8ef` + archive commit), `DEVKEY_DIAG=0`,
**Standard Fit** (confirmed in fit.rpt: "Fitter is performing a Standard
Fit compilation"), smart/incremental compile OFF (user-verified in GUI).
This roll exists to discriminate H1 (code bug in the M10K read/write path)
from H2 (placement marginality from the big reflow) after roll #1 failed:
MB silent, floppy errors, HDV load OK, **HDV write corrupted**.

## Results

- Fitter Successful 12:33, **Standard Fit**.
- ALM **11,222 / 18,480 (61%)**, registers 12,881 (identical netlist).
- STA: mp2 setup **1.523 ns**, clk_74a 5.715, bridge 10.372, TNS 0.
- Map: 0 errors; only the two pre-existing `woz_bram` async-read uninferred
  RAMs; no console (DEVKEY_DIAG=0).
- Lane RAMs: 4× `128×8 True Dual Port, Dual Clocks, 1024 bits`, again in
  **M10K_X38_Y27–Y30** (same four blocks as roll #1, lane→block assignment
  shuffled: lane0→Y28, lane1→Y30, lane2→Y27, lane3→Y29). RAM-block
  placement is deterministic; the rolled variable is the surrounding
  ALM/FF logic (walk_out CDC, MB audio CDC, WOZ paths).

## Bitstreams

- `apf_apple2.rbf` (local archive) — see directory
- `bitstream.rbf_r` (staged) SHA-256:
  `4ae28a9897c99aeef2a6a095d5a4a0a37215345fcebf8517aab036ba3513ce2a`
  (sd_root + K: hash-verified)

## HW test (roll #2) — result pending

Order: **HDV WRITE first** (decisive: every-write vs some-writes), then
floppy load, HDV load (Total Replay), savestate save+load.

Decision rule:
1. All four pass → roll #1 was a bad ticket; this is M10K pass 1 of 3.
2. HDV write still corrupts (same failure, fresh placement) → H1 (code) or
   systematic placement; next step = devkey-gated readback checksum on the
   HDV write path to capture which bytes are wrong.
3. HDV write passes but MB/floppy still fail → M10K floorplan systematically
   harms those paths; targeted constraints or reconsider conversion.
