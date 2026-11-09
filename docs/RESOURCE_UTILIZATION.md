# Resource utilization per component

Reference breakdown of the shipping core, `apf_stream_video`, on the
**Cyclone V 5CEBA4F23C8**. Numbers come from the Quartus Prime 17.0.2 Lite fitter
report, section **19 "Fitter Resource Utilization by Entity"**:

`src/fpga/output_files_apple2e/apf_stream_video.fit.rpt`

This is a **snapshot** of the fitter run **2026-11-08 17:15** (the `hdv_bridge`
sector-RAM → M10K refactor). It is a tracked (not dated) reference document: refresh
it after any build whose resource footprint changes (a new feature, a port, a
synthesis change). It exists to answer "how much headroom is there, and where is it
going?" before planning work.

> **REVERTED (2026-11-09):** the `hdv_bridge` M10K refactor **shipped a silicon
> regression** (inconsistent left-shift on HDV writes) that could not be resolved by
> a read-latency fix, so `hdv_bridge` was **reverted to the proven flip-flop array +
> `RD_PRIME_STAGE`** (the byte-exact 0.3.5 behavior). The numbers below are therefore
> the **superseded M10K snapshot**; the shipping state is back at the 0.3.5 footprint
> (~13,862 ALMs / 75 % — `hdv_bridge` ~5,067 ALMs / 4,435 regs / 0 M10K). Refresh this
> table after the post-revert recompile. See `HDV_WRITE_FIX.md` §"The M10K
> regression" and `PLAN_HDV_BRIDGE_RAM_M10K_2026-11-08.md`.

## Device totals

| Resource | Used | Device total | Utilization |
|---|---:|---:|---:|
| ALMs | 8,947 | 18,480 | 48 % |
| Registers | 10,253 | — | — |
| Combinational ALUTs | 15,212 | — | — |
| Block memory bits | 1,561,600 | 3,153,920 | 50 % |
| M10K blocks | 195 | 308 | 63 % |
| DSP blocks | 29 | 66 | 44 % |
| PLLs | 2 | 4 | 50 % |
| **Pins** | **224** | **224** | **100 %** |

> **Legacy "LE" estimate:** the 5CEBA4F23C8 is **ALM-based** — Quartus reports ALMs,
> not legacy LEs. Where a legacy-LE figure is wanted, the tables below carry an
> **"LE (est.)" column = 2 × ALMs** (a 2× ALM holds two logic elements). It is a rough,
> descriptive estimate (an ALM can be wired several ways) and covers **logic only** —
> it excludes registers, block RAM (M10Ks), and DSPs. The utilization % is identical
> to the ALM % (it is just ×2 across the board).

Headroom in plain terms:
- **~9,500 ALMs** free (18,480 − 8,947) — the `hdv_bridge` M10K refactor freed
  ~4,900 of these (it was the single largest ALM consumer at 5,067; now 151).
- **~1.6 Mbits** of block memory free (1,561,600 of 3,153,920 used) — comfortable.
- **~113 M10Ks** free — comfortable.
- **29 of 66 DSPs** used, 25 of them in the video pipeline — comfortable.
- **Pins are at 100 %.** The APF host / video / audio interface fully populates the
  device's I/O. There is **no spare pin** for new top-level I/O without repacking
  the pin plan. If a future feature needs a new physical pin (a second controller,
  an extra audio line, serial), that is the first thing to check against.

## Per-component (major instances)

ALMs and registers as the fitter reports them (values rounded to whole units).
Block memory bits and M10Ks are shown where the instance owns block RAM. DSP is
shown where used. The "Instance" is the hierarchy name from the report.

| Component | Instance | ALMs | LE (est.) | Registers | Block mem bits | M10Ks | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| **Whole core** | `apf_top_stream` | 8,947 | ~17,894 | 10,219 | 1,561,600 | 195 | 29 |
| APF host bridge | `io_bridge_peripheral:ibs` | 81 | ~162 | 229 | — | 0 | 0 |
| I/O pad controller | `io_pad_controller:ipm` | 101 | ~202 | 323 | — | 0 | 0 |
| Core container | `stream_video_core_top:ic` | 8,743 | ~17,486 | 9,652 | 1,561,600 | 195 | 29 |

The core container holds everything below it. The meaningful per-block breakdown:

| Block | Instance | ALMs | LE (est.) | Registers | Block mem bits | M10Ks | DSP | What it is |
|---|---|---:|---:|---:|---:|---:|---:|---|
| **HDV bridge** | `hdv_bridge:h` | 151 | ~302 | 201 | 4,096 | 2 | 0 | Hard-disk transfer engine (CPU + host, dual clock domains); the 512-byte sector RAM now lives in 2 M10Ks (was ~4,096 flip-flops + a 4×512:1 read mux) |
| **On-screen keyboard** | `apple2e_osk` | 2,131 | ~4,262 | 1,372 | 15,360 | 2 | 0 | OSK: `virtual_keyboard_overlay` + `_controller` + `hid_to_ps2` + `keyboard` |
| **WOZ floppy** | `disk_ii_woz` | 1,779 | ~3,558 | 1,416 | 280,576 | 35 | 0 | WOZ Disk II: `flux_drive`, `woz_cell525`, `woz_floppy_controller` (+ 32 M10K sector BRAM) |
| **SDRAM transport** | `sdram_storage` | 1,211 | ~2,422 | 2,385 | 18,432 | 3 | 0 | WOZ/HDV SDRAM mapping: `disk_store`, `disk_verifier`, `io_sdram_pocket`, `sdram_sector_fetch`, `slot_fifo` |
| **Machine** | `apple2:d1` | 1,103 | ~2,206 | 272 | 163,840 | 20 | 0 | The Apple II core (RAM/ROM + timing + video generator + CPU) |
| ↳ **CPU** | `wdc65c02:cpu65c02` | 975 | ~1,950 | 174 | — | 0 | 0 | WDC 65C02 (Kitrinx) — the machine's biggest child |
| **Video pipeline** | `video_pipeline_q17` | 820 | ~1,640 | 1,358 | 16,384 | 2 | **25** | NTSC generation; `apple_composite_q17`/`composite_decoder_q17` do colour encoding (Kitrinx) — uses 25 of the 29 DSPs |
| APF bridge commands | `core_bridge_cmd` | 202 | ~404 | 430 | 8,192 | 2 | 0 | APF host-target bridge (commands 0x0180/0x0184/…) |
| Audio (I2S) | `speaker_i2s` | 134 | ~268 | 82 | — | 0 | 0 | I2S sample generator (includes an `lpm_divide`) |
| SDRAM storage window | `altsyncram:ram_aux/main_rtl_0` | 22 + 28 | ~100 | — | 2 × 524,288 | 2 × 64 | 0 | The 2 × 512 KiB SDRAM-mapped storage window (WOZ + HDV) |
| **HDD controller** | `hdd:h` | 74 | ~148 | 74 | 6,144 | 1 | 0 | Steven Wilson's ProDOS HDD interface (peripheral logic, not the transfer engine) |
| Video adapter | `apf_stream_video:apfv` | 80 | ~160 | 36 | — | 0 | 0 | APF video adapter / streaming glue |
| Joystick + paddle | `joystick_input` + `pdl_timer` | 86 + 107 | ~386 | 45 + 81 | — | 0 | 2 + 2 | Joystick, paddle timer, and `joy_to_key` (108 ALMs) |
| Status overlay | `sdram_status_overlay` | 91 | ~182 | 139 | — | 0 | 0 | On-screen status bar |

### Where the resources go (at a glance)
- **ALMs:** now led by `apple2e_osk` (2,131) and the WOZ floppy (1,779); the SDRAM
  transport (1,211) and machine (1,103) round out the top four. The 65C02 CPU alone
  is 975 ALMs. `hdv_bridge` is no longer significant (151 ALMs after the M10K
  refactor; it was 5,067 before).
- **Block memory:** the 2 × 512 KiB SDRAM storage window is 1,048,576 bits (two-
  thirds of the total); WOZ's 32 M10K sector BRAM (262,144) and the machine's
  20 M10K (RAM/ROM) make up most of the rest.
- **DSP:** almost all 29 DSPs that the video pipeline uses (25) sit in the NTSC
  composite colour-encoding path.

## How to read / use this
- **Planning a feature:** check the block it touches. E.g. floppy write-back
  (W0 WP2) adds to `disk_ii_woz`/`sdram_storage`; save states would add a new
  block; anything adding block RAM draws from the ~1.6 Mbit headroom.
- **The 0.3.5 HDV fix** (`RD_PRIME_STAGE`, see [`HDV_WRITE_FIX.md`](HDV_WRITE_FIX.md))
  moved `hdv_bridge` from ~5,006 to 5,067 ALMs (+61). The follow-on **M10K sector-RAM
  refactor** (this snapshot) then dropped `hdv_bridge` to **151 ALMs / 201 regs / 2
  M10Ks** (from 5,067 / 4,435 / 0) by moving its 512-byte FF array + 4×512:1 read mux
  into block RAM — the whole core fell from 13,862 to **8,947 ALMs** (75 % → 48 %).
  See `PLAN_HDV_BRIDGE_RAM_M10K_2026-11-08.md` §10.
- **M10K read-latency regression fix (2026-11-08):** the M10K Port A read turned out to
  be combinational (0-cycle), so the `RD_PRIME_STAGE` removal had silently dropped the
  host read to 0 cycles (the pre-0.3.5 k=1 shift, `SmartportHD_corrupted6.HDV`). Restored
  with a local `q_a_q` register stage on the host read (+~32 `hdv_bridge` regs, no ALM/
  M10K change — negligible; confirm in the next fitter run). See
  `HDV_WRITE_FIX.md` §“The M10K read-latency regression”.
- **Pins (100 %) is the binding constraint**, not ALMs or memory. New physical I/O
  needs a repacked pin plan.
- Parent rows **include their descendants** — do not add a parent row to its
  children.

## How to refresh
```
quartus_sh --flow compile apf_stream_video
```
Then re-extract section 19 from `src/fpga/output_files_apple2e/apf_stream_video.fit.rpt`
(update the fitter-run date and the tables above). Keep the block memory total
in view — it was 1,557,504 bits through 0.3.5 and became **1,561,600** after the
`hdv_bridge` M10K refactor (+4,096 = the 2 M10K sector RAM); a further jump means
something new is synthesizing block RAM.
