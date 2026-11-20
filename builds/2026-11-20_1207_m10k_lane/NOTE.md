# Build 2026-11-20 12:07 — HDV RAM→M10K lane conversion (first HW roll)

Commit `70cf8ef` (HDV sector RAM → four 128×8 lane altsyncrams;
`RD_PRIME_STAGE=0` shipping stage, OOR reads present the lane gather;
walk_in option-(d) delay). Placement roll #11 of the M10K netlist —
the first of the plan's 3 shipping-clean Standard Fit passes
(PLAN_HDV_M10K_2026-11-20 §5). DEVKEY_DIAG=0 (console out, verified
absent in map).

## Results

- A&S Successful 12:01, Fitter Successful 12:07, **Standard Fit**.
- ALM **11,222 / 18,480 (61%)** (0.4.1 was 16,106 / 87%), registers
  **12,881** (−4,369 vs 17,250).
- `hdv_bridge`: **138.7 ALM / 250 registers / 4 M10K** (was ~5,084 ALM
  / ~7,464 registers with the inferred 512×8 array + async read decode).
- STA: mp2 setup slack **1.523 ns**, clk_74a 5.715, bridge 10.372,
  TNS 0 across all clocks.
- Map: **0 errors**; no new uninferred-RAM warnings (only the two
  pre-existing `woz_bram.sv` async-read RAMs); `u_devkey_uart` ABSENT,
  `u_floppy_sound` present.
- Lane RAMs implemented as designed: 4× `128×8 True Dual Port,
  Dual Clocks, 1024 bits` at **M10K_X38_Y27–Y30** (the fitter used four
  blocks, adjacent row — packing was left to it per plan), port address
  registered / outputs UNREGISTERED, RDW "New data"
  (NEW_DATA_NO_NBE_READ). Total RAM blocks 202/308 (66%).

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `b6b8caf6f10339acf0c8587df028b425c697207670416c5871e4bd04d45a4313`
- `bitstream.rbf_r` (staged) SHA-256:
  `c14ecb8158ee2ab8703d244bbcd75ac197aa739f880494ea51a8c6ea356223b6`

## HW test (this roll)

1. Floppy load
2. HDV load
3. Savestate SAVE + LOAD
4. **HDV WRITE**: mount a writable HDV, write a file, reboot, verify
   the contents (the M10K gate — this is the path that killed the
   first attempt e20bd80)

COM4 is silent by design (no console). If this roll fails: spin the
DEVKEY_DIAG=1 post-mortem variant and capture before counting; a
failed roll does not count toward the 3-pass bar.
