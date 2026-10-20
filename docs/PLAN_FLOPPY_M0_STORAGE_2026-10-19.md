# PLAN — Floppy M0: external image storage (SDRAM)

**Date:** 2026-10-19 · **Status:** plan, ready to implement
**Supersedes:** the storage assumptions in
`EXPERT_DESIGN_FLOPPY_WOZ_2026-10-19.md` §2/§4 (corrected by
`FLOPPY_WOZ_RECOMMENDATION_2026-10-19.md`, accepted 2026-10-19).

## Owner decisions (2026-10-19)

1. SDRAM controller source: **basicassets `io_sdram.v` first** (open-fpga
   `core-example-basicassets` @ `e5f9c0a`, pinned in `refs/basicassets/`).
2. Disk data slot: **`required: true`** (optional/diskless BASIC later).
3. Second drive: **unmounted** — keep both drive engines (byte-identical
   wrapper), drive 2: `IMG_MOUNTED1=0`, `SD_ACK1=0`, WP high.

## Scope (M0 only)

Prove **external image storage**: the WOZ data slot loads into SDRAM via
bridge writes and reads back bit-exact. **Go gate (per the recommendation):**
"prove external image storage and one exact 512-byte transaction before
integrating disk boot." M0 delivers the storage half; the exact 512-byte
transaction is the M0→M1 boundary and closes this milestone.

NOT in M0: sector transport shim, WOZ path, machine slot-6 wiring, interact
options. The streaming core's video path is untouched.

## Reference facts (verified in source)

- `io_sdram.v` (572 lines, Analogue 2019–2022, basicassets @ `e5f9c0a`):
  self-contained SDRAM controller for the APF 64 MB mobile SDRAM
  (32M×16, CAS3 timing set for 166 MHz). Ports: `controller_clk`,
  `chip_clk`, `clk_90`; PHY `phy_*` (dram_* pad signals); `burst_rd`
  (controller-domain), `burstwr` (16-bit strobed write, ready/done
  handshake), and a **32-bit word port that synchronizes cross-domain
  requests internally** (`word_rd` "can be from other clock domain").
  Handles init/program-mode registers and auto-refresh. Staged byte-
  identical at `src/fpga/core/apple2e/io_sdram.v` (sha256
  `0c53ad4d…`, matches `refs/basicassets/`).
- basicassets integration (`refs/basicassets/src/fpga/core/core_top.v`):
  PLL `mf_pllbase` (refclk `clk_74a`) → outclk_2/3/4 = **133.12 MHz**
  controller / chip / 90°; 64 MB mapped at **bridge address 0**
  (`bridge_addr[31:24]==0`): word writes `word_addr = bridge_addr[25:2]`,
  `word_data = bridge_wr_data`; SDC declares the PLL outputs
  asynchronous to `clk_74a/74b`.
- Our `apf_top.v` already exposes all `dram_*` pads (a/ba/dq/dqm/clk/cke/
  ras/cas/we).
- Our `apple2e_pll` has 4 outputs in use (14.318 / 12.288 / 12.288-90 /
  3.072) — no room for the 3 SDRAM outputs; the 5CEBA4F23C8 has **three**
  PLLs, one is in use.

## Files

| File | Action |
|---|---|
| `src/fpga/core/apple2e/io_sdram.v` | **staged** (byte-identical basicassets) |
| `src/fpga/core/apple2e/apple2e_sdram_pll.v` | **new**: second `altera_pll`, refclk `clk_74a`, 3 outputs 133.12 MHz (controller / chip / 90°) — proven basicassets frequencies; Quartus 17 A&S must confirm the grid |
| `src/fpga/core/apple2e/apf_stream_video_top.v` | wire `dram_*` pads → `io_sdram`; bridge decode: disk-slot region → `word_wr` (74.25 domain); PLL instance; SDRAM init gated behind bridge-ready (do not ack host readiness before storage can accept the transfer) |
| `apple2e_core_constraints.sdc` | SDRAM clock definitions + asynchronous clock groups (per basicassets SDC pattern) |
| `sd_root/Cores/Newsdee.Apple2eStreamVideo/data.json` | slot `disk`: `id`, `required: true`, `extensions: ["woz"]`, `address` = SDRAM base, `size_maximum` = storage allocation, parameters bit0 (reloadable) |
| `src/fpga/apf/apf_stream_video.qip/qsf` | register new files (QSF source list) |

**Open items to settle during implementation:**
- SDRAM bridge base address: basicassets uses bridge 0. Our core's existing
  bridge decoder (command block, datatable, OSK/interact registers) must not
  collide; pick the largest clean 64 MB-aligned region (verify against the
  current top's `bridge_addr` mux).
- `size_maximum` value: 4 MB covers 140K-disk WOZ files with wide margin;
  must match the storage allocation actually decoded.

## Validation ladder (M0)

1. **Lint/A&S:** Quartus Analysis & Synthesis of the streaming core with
   `io_sdram` + second PLL (owner-run; confirm PLL grid, pad binding, no
   new warnings beyond known).
2. **Sim — storage:** Verilator TB: behavioral DRAM (or the real controller
   + fake DRAM), drive `word_wr` bursts like the host loader, read back via
   `word_rd` from a *second clock domain* (CDC exercise); verify first/last
   bytes, unaligned end, full checksum. No fake host ok responses.
3. **Sim — 512-byte transaction (go gate):** one exact 512-byte sector
   fetch: LBA → `image_base + LBA*512`, all 512 bytes back in order
   (bytes 0/255/256/511 emphasized), phase randomized. This is the exact
   contract the M1 block shim will serve.
4. **Hardware (owner):** compile; load a real .woz via the data slot;
   checksum proof (debug readback — TBD: bridge probe vs on-screen hex
   dump); then M1.

## Budget (expected, to be measured)

`io_sdram` FSM: low ALM count (tens), no M10K. Second PLL: 1 of 3 device
PLLs. No RAM. The M0 delta should be nearly zero against the current fit
(3,330 ALMs / 152 M10K) — any significant move means something is wrong.
