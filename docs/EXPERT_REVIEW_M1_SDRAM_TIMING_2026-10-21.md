# Expert brief — Apple IIe Pocket core: SDRAM-controller timing violation (mp2 divclk, 133.12 MHz)

**Context.** A Cyclone V (5CEBA4F23C8, Quartus 17.0.2 Lite) Apple IIe core for the Analogue
Pocket (openFPGA/APF). The WOZ floppy image lives in the Pocket's 32 M×16 SDRAM, accessed by a
pinned `basicassets`-style `io_sdram` controller. Everything is in one Quartus project
(`apf_stream_video`, top `apf_top_stream`); run Quartus from `src/fpga/`. The SDRAM path is the
**only** multi-clock subsystem and it is currently the sole timing failure in the design.

## The violation (what needs judging)

Full (non-incremental) compile, fitter + assembler **Successful**, but the STA reports a
**setup violation** on the SDRAM **controller** clock:

| Clock (generated, from mp2 PLL) | F | period | setup slack (corners) |
|---|---:|---:|---|
| `ic\|mp2\|altera_pll_i\|general[0].gpll~PLL_OUTPUT_COUNTER\|divclk` (controller clk) | 133.12 MHz | 7.512 ns | **worst setup -0.355** (Slow-1100 mV **85 °C**) · **worst setup -0.889, TNS -5.154** (Slow-1100 mV **0 °C**) |
| `mp1` divclks, `clk_74a`, `bridge_spiclk` | various | — | all met (+5.3 … +33) |

Hold/recovery/removal/minimum-pulse are all met. So the **only** red item is the setup on the
133.12 MHz SDRAM-controller domain. The default `sta.rpt` gives per-clock slack only (no
From/To path detail); the full path report is available via
`quartus_sta apf_stream_video` → Timing Paths, or the fitter's detailed timing report — I can
produce it on request, but the endpoint logic is almost certainly inside the pinned
`io_sdram_pocket` controller (a register-to-register path in the controller clock domain).

## The SDRAM clocking (PLL + SDC)

**`src/fpga/core/apple2e/apple2e_sdram_pll.v`** — one fractional PLL, 74.25 MHz reference
(→ `clk_74a`), three 133.12 MHz outputs:
- `outclk_0` (0 ps) → **controller clock** (`dram_cont_clk`)
- `outclk_1` (3756 ps = 180°) → **SDRAM chip clock** (`dram_chip_clk`)
- `outclk_2` (5634 ps) → DDR capture clock (`clk_90`)

The 133.12 MHz / phase values are copied (grid-legal) from the open-fpga
`core-example-basicassets` reference; the SDRAM part is a 32 M×16, CAS3, **166 MHz max** part,
so 133.12 MHz is below the SDRAM's own limit — the miss is in the **controller logic**, not the
chip.

**`src/fpga/core/apple2e/apple2e_core_constraints.sdc`** (the whole SDRAM constraint block):
```tcl
set_clock_groups -asynchronous \
  -group { bridge_spiclk } -group { clk_74a } -group { clk_74b } \
  -group { ic|mp1|…general[0].gpll~PLL_OUTPUT_COUNTER|divclk } … (all mp1 divclks) \
  -group { ic|mp2|…general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
  -group { ic|mp2|…general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

set dram_chip_clk  "ic|mp2|…general[1].gpll~PLL_OUTPUT_COUNTER|divclk"
set dram_cont_clk  "ic|mp2|…general[0].gpll~PLL_OUTPUT_COUNTER|divclk"
set_input_delay  -clock $dram_chip_clk -reference_pin [get_ports {dram_clk}] -max 5.9 [get_ports dram_dq[*]]
set_input_delay  -clock $dram_chip_clk -reference_pin [get_ports {dram_clk}] -min 0.9 [get_ports dram_dq[*]]
set_output_delay -clock $dram_chip_clk -reference_pin [get_ports {dram_clk}] -max 2.0 [get_ports {dram_cke dram_a* dram_ba* dram_cas_n dram_ras_n dram_we_n}]
set_output_delay -clock $dram_chip_clk -reference_pin [get_ports {dram_clk}] -min -1.0 [get_ports {dram_cke dram_a* dram_ba* dram_cas_n dram_ras_n dram_we_n}]
set_multicycle_path -from $dram_chip_clk -to $dram_cont_clk -setup -end 2
```
So the chip↔controller relationship is a **2-cycle multicycle** (the controller samples one
chip-clock beat behind). The failing path is a **controller→controller (RR) path** inside
`io_sdram_pocket`, which the multicycle does **not** cover.

## What changed vs. the last known-good baseline

- The M0 (storage) and M1 (fetcher) builds that **passed on hardware** (the Pocket read back a
  loaded WOZ with `OK CRC`) had an overall **min slack ≈ +0.320 ns** — i.e. the SDRAM-controller
  domain was green then.
- The current build added the **WOZ engine** (`core/woz/*`, machine-domain @ 14.3 MHz) and a few
  overlay diagnostics. Device load grew: **registers 4,422 → 6,253**, **RAM blocks 154 → 190/308
  (62 %)** (ALM headroom still ample).
- A **full** (smart-compile disabled) re-fit was attempted and the mp2 divclk is **still -0.889
  worst-case** — so this is not an incremental-packing artifact.

My working assumption (unproven): the added machine-domain logic changed the **global
packing/routing** enough to tip the already-tight 133.12 MHz `io_sdram` controller path over —
but the controller netlist itself is byte-identical to the M0 build, so I'd value an outside
read on whether this is (a) a packing effect a better fit can recover, (b) a genuinely
over-constrained 133.12 MHz controller that needs the clock or the SDC changed, or (c) a
pessimistic STA corner that the real Pocket (which demonstrably ran this domain in M0) tolerates.

## The operational stakes (why I want it resolved, not just annotated)

This is the **floppy I/O clock domain**. We are mid-diagnosis of a "machine stalls at the Apple
logo after a disk load" bug; I have a candidate root cause (a WOZ mount-repulse race) that is
sim-verified and now in the bitstream. If the SDRAM-controller domain is marginally failing, a
disk-read timing glitch could produce *the same* symptom and **confound the hardware test**. The
M0 acceptance is evidence the domain *can* run on the Pocket, but it was a single cold-boot
sample, not a robustness proof. I'd rather not send a disk-boot test on a domain that STA calls
failing.

## Questions for the expert

1. **Is the mp2 `general[0].divclk` setup miss a real functional risk for this design, or is it
   a pessimistic corner the Pocket (which ran this exact domain in M0) tolerates?** What's the
   decision criterion you'd apply (which PVT corner is "sign-off" for a handheld running warm)?
2. **How would you close it**, in order of preference/risk? Consider:
   - fitter **High-Effort** / different seed or a specific fitter strategy (cheapest; is -0.889
     realistically recoverable by packing alone, or is it netlist-limited?).
   - **Retiming/pipelining** the offending `io_sdram` controller path — and whether that is safe
     given the controller is a pinned, behavior-verified `basicassets` block (I would avoid
     editing it if possible).
   - **Lowering the SDRAM controller frequency** (e.g. 133.12 → 120–125 MHz): what breaks in the
     chip↔controller phase relationship + the `clk_90` DDR capture, and is there a grid-legal
     slower clock that keeps the read-capture window legal?
   - Any **SDC** correction (is the 2-cycle multicycle or an input/output delay on `dram_dq`
     mis-modeled in a way that over-penalizes the controller path?).
3. **What single, decisive check** would let me confirm the domain is fine on hardware without a
   redesign — e.g. a SignalTap on the controller's `burst_done`/`word_rd` turnaround at the
   actual Pocket temperature, or a margin test (run the SDRAM at a deliberately tightened corner)?
4. If you conclude it's **acceptable as-is** for the Pocket, say so explicitly and name the
   corner you're relying on, so I can document it and move the diagnosis forward.

## Constraints / non-goals
- Prefer **not** to modify the pinned `io_sdram` (behavior-verified against `tb_disk_store` /
  `tb_dram_model`). A PLL or SDC change is more acceptable than a controller netlist change.
- Save-states are a later milestone; the design must stay RAM-only/capturable (a SDRAM-content
  change is fine, a BRAM re-architecture is not wanted now).
- Owner launches the Quartus compiles; keep any recommended fix **compile-light** (a re-fit, not
  a full re-elaboration if avoidable).

## Post-review correction (expert, 2026-10-21)
- **-5.154 ns is Total Negative Slack (TNS), not a second path's slack.** The two failing
  corners are Slow-1100 mV **85 °C** (worst -0.355 / TNS -1.286) and Slow-1100 mV **0 °C**
  (worst -0.889 / TNS -5.154). The *colder* slow corner is the worse one, so "the Pocket runs
  warm" is **not** a valid waiver.
- The per-clock table reports the **destination** clock only — the offending module/path is not
  established until a `report_timing -detail full_path` run (staged in `src/fpga/sta_sdrampaths.tcl`).
- The "chip clock setup met ≥ 2.1 ns" line referred to **minimum-pulse-width** slack, not SDRAM data setup.
- The SDC's `set_clock_groups -asynchronous` puts the controller + chip clocks in **separate** groups.
  **Note:** this exactly matches the hardware-proven `basicassets` reference SDC
  (`refs/basicassets/src/fpga/core/core_constraints.sdc`), so it is the reference's intended model,
  not a Pocket typo — but the expert correctly notes the async cut weakens the chip↔controller
  relationship the multicycle is meant to protect. We inspect the actual paths before touching it.
- Separate flag: an **unconstrained clock derived from the OSK reset** + an inferred-latch report in
  the WOZ drive `bit_timer` path (unconstrained, not the -0.889 path); needs a focused netlist review.

## Files (for reference)
- `src/fpga/core/apple2e/apple2e_sdram_pll.v` — the 74.25→133.12 MHz PLL (phases above).
- `src/fpga/core/apple2e/io_sdram_pocket.v` — pinned `basicassets` `io_sdram` (controller + chip +
  `clk_90` clock inputs; `burst_rd`/`word_rd`/`word_wr` interface).
- `src/fpga/core/apple2e/apple2e_core_constraints.sdc` — the SDRAM SDC block (above).
- `src/fpga/core/apple2e/sdram_storage.v`, `sdram_sector_fetch.v`, `slot_fifo.v`,
  `sdram_word_owner.v`, `sdram_woz_transport.v` — the storage/fetch path around the controller.
- Reports: `src/fpga/output_files_apple2e/apf_stream_video.sta.{summary,rpt}`,
  `apf_stream_video.fit.summary`.
