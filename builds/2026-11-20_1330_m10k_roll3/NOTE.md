# Build 2026-11-20 13:30 — HDV M10K roll #3 (post RD_PRIME_STAGE flip, commit 2a5bc2c)

Fresh full (non-incremental) Standard Fit of the corrected tree:
`RD_PRIME_STAGE=1` restored (plain ALM prime FF host-facing again; M10K lane
read is the upstream stage) after HW rolls 1-2 refuted the M10K output
host-facing (prime=0) config — HDV writes corrupted on both placements,
roll 2 forensics showed a deterministic 2-word-early kept stream
(SmartportHD_test.HDV sector 2, 502/512 bytes file[x]=C[x+8]).
`DEVKEY_DIAG=0` (shipping-clean; no console in the validation series).
Plan record: `docs/PLAN_HDV_M10K_2026-11-20.md` §11.

## Results

- A&S Successful 13:23, Fitter Successful 13:29, **Standard Fit**
  (fit.rpt: "Fitter is performing a Standard Fit compilation using
  maximum Fitter effort"); full flow (A&S 2:24, Fitter 5:55, ASM 0:10,
  STA 0:27); build_id stamp 20261121/00:32 (pre-flow script local time).
- ALM **11,168 / 18,480 (60%)**, registers **12,912** (+31 vs rolls 1/2:
  the prime FF is now live — under prime=0 it was synthesized away).
- STA: all TNS 0.000; tightest setup slacks 1.234 / 0.351 / 0.395 ns.
- Map: 0 errors; only the two pre-existing `woz_bram` async-read
  uninferred RAMs; `u_devkey_uart` absent (0 hits); `u_floppy_sound`
  present; 4 "synthesized away" warnings (same family as before).
- Lane RAMs: 4× `128×8` moved OUT of the roll 1/2 region
  (M10K_X38_Y27–Y30) to **M10K_X46_Y29, X46_Y30, X51_Y28, X51_Y29** —
  the prime=1 netlist reflow relocated the HDV RAM cluster, exactly the
  structural intent of the M10K landing (shrink/move the suspect
  transport region for the WOZ placement marginality).
- Fitter packed the gather FF (`hdv_ram_word_ww_q`) into the lane RAMs'
  M10K PORTADATAOUT output registers (cycle-exact packing: the RAM output
  register holds mem[latched_addr] at the same 74a edge the standalone
  gather latched). The host-facing stage remains a plain ALM register —
  the 0.3.5-0.4.1 silicon-proven form.

## Bitstreams

- `apf_apple2.rbf` (source) SHA-256:
  `8002a9ee31de51e1aaaed4a623a1c10f0a266dcb750daec12547e79920960bee`
- `bitstream.rbf_r` (staged) SHA-256:
  `77b3c8bdab8b0d7cfbb8be5a5f792830d3002fc8fe38f4612118640d124a23d7`
  (sd_root + K: hash-verified)

## HW test (roll #3) — result pending

Order: **HDV WRITE first** (the roll 1/2 killer: clean folder creation,
no hang, reboot, folder present, contents intact, no 8-byte/2-word
shift), then floppy load, HDV load (Total Replay), savestate save+load.

Decision rule:
1. All four pass → M10K pass 1 of 3 on the corrected tree (two more
   shipping-clean Standard Fit rolls to go).
2. HDV write still corrupts → the flip did not fix it; add a
   devkey-gated readback checksum on the write path to capture which
   bytes are wrong (new deviation from the 0.3.5-0.4.1 proven form).
3. HDV write passes but floppy/MB fail → placement marginality of the
   surrounding region persists; targeted constraints or floorplan
   reconsideration.
