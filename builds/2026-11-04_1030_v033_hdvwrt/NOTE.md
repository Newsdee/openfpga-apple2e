# Build archive: 2026-11-04 10:22-10:31 — v0.3.3 HDV write-through (protected-by-default)

Purpose: 0.3.3 un-gates the existing HDV write path (PLAN_HDV_WRITE_2026-11-04)
behind a new write-protect option. Default remains PROTECTED (behaviorally
identical to 0.3.2); "Writable" arms the 0x0184 host-write leg.

## What changed in this build (vs 0.3.2)
- `src/fpga/core/apple2e/apf_stream_video_top.v`: `cfg_wp_word` latch at
  `0x01F00018` (init 1 = protected), 3FF `synch_3 u_hdv_protect_sync` to the 14M
  domain; `.hdd_protect(hdv_protect_m)` (14M hdd) + `.hdv_protect(cfg_wp_word[0])`
  (74a hdv_bridge) replace the two hardwired 1s.
- `src/fpga/core/apple2e/sdram_status_overlay.v`: green HD lamp now lights on
  read OR write (`hd_rd_act || hd_wr_act`).
- `sd_root/Cores/Newsdee.Apple2e/interact.json`: new option
  "Hard Disk Write Protect" (Protected/Writable, writeonly, persist, default
  Protected) at `0x01F00018` (free address; 0x01F00014 is Joystick Mode).
- `core.json`: 0.3.2 -> 0.3.3.
- Bitstream + interact.json must ship as a PAIR (README + release notes).

## Compile (Quartus 17.0.2 Lite, owner-launched) — shipping-clean (OVL_DEBUG=0)
- Coherent single run: A&S done 10:22:10 -> fitter 10:30:17 -> asm rbf
  10:30:37 -> STA 10:31:11. No source mtime inside the window (only my two
  01:00 edits predate it; qsf rewritten by the flow at 10:19, content == HEAD).
- Fit: Successful. ALM 13,878 / 18,480 (75 %), registers 14,465, pins 224/224,
  RAM 193/308, DSP 29/66, PLL 2/4.
- **ALM delta vs the 0.3.2 shipping build (11,544): +2,334 — fitter packing
  variance, NOT added logic.** Netlist is 0.3.2 + this tiny diff: registers
  -54 (14,465 vs 14,519), block memory bits BIT-IDENTICAL (1,557,504), DSP/PLL/
  pins identical, `u_hdv_protect_sync` = 1 ALM / 3 regs in the map. Device
  still fits with 2,602 ALM headroom. (If a tighter match to the 0.3.2 fit is
  ever wanted, re-fit from a known seed; not required — all constraints met.)
- STA: TNS 0.000, all 80 constraints met. Tightest setup +0.719 ns (Slow
  1100mV 85C, mp2 divclk) vs +0.900 at 0.3.2 — consistent with the packing
  variance, comfortably positive. Hold +0.293/+0.364/+0.446.
- A&S: 0 errors. Warning classes all standard/benign: synthesized-away nodes
  (14320x99, 14284/14285), pin/node/register notices (13410/13010/13310/10030/
  15610/13033), 276027 dual-clock RAM x3 (known), 21074 input-pins-no-load x1,
  13040/13039 bidir pins (APF ports). NO multiple-driver, NO inferred-latch,
  NO 276003/276007 Q17 register blow-up.

## SHA-256
- source `.rbf`:        `351d1a7a9dc1349859be3b1d68dc6dbaf4b71c23b144743759256abd0262f456`
- `bitstream.rbf_r`:    `832e0b9a5264112939b2261420d00956dba88fba030073234507762bd6e221f9`
- `interact.json` (pair): `60ae88ea89d6ab8639120cf53918f3a4b8de619c1a9f31071fc7e6577ce6562c`
- staged 11-04 11:08 (rbf2rbf_r.py + copy; owner's compile was run raw, so the
  staging step was done separately). All 7 manifests validate as JSON, incl.
  the updated interact.json.

## Validation status
- Sim: HDV bridge harness 12/12 (incl. full 0x0184 round-trip T8a/T8b/T9,
  protect-toggle T10, write-leg timeout T11); hdd equivalence PASS; pocket_boot
  WOZ smoke + HDV baseline unchanged. `verilator --lint-only` clean on harness.
- Hardware (WP4 matrix on THROWAWAY media, pending): default-protect regression,
  Writable write + read-back, durability (Quit / sleep / power-off), Nox Archaist
  save, Total Replay preference writes, green lamp visible on write.
