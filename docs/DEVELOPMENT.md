# Developer notes

Build, project layout, simulation, and JSON-manifest rules for the Pocket Apple IIe
core. The user-facing side is [`README.md`](../README.md); this is for people building
or modifying the core. The contributor/agent operating guide is [`AGENTS.md`](../AGENTS.md);
release and milestone history is in [`CHANGELOG.md`](CHANGELOG.md).

The APF shell is `open-fpga/core-template` v1.3.0 (commit `da3a021`). The machine RTL
is a byte-identical copy of the `Apple-II_MiSTer` project — `machine/` is kept in sync
by `check_machine_sync.sh` (don't edit it here without re-syncing). The machine + APF
bridge + video adapter all live in this repo so the Quartus project is self-contained.

## Core packages on the SD card

`sd_root/` is the card layout — copy its `Cores/`, `Platforms/` and `Assets/` trees to
the SD card root. There is exactly **one** live core package:

| Folder | Core | Video path |
|---|---|---|
| `Cores/Newsdee.Apple2e` | **the live core** (build `apf_apple2`) | Phase 2 streaming: native 560×192 @ 14.318 MHz RGB → APF DDR pad, full-colour OSK, colour presets |

Historical packages (do not build or ship): the earlier frame-buffer core (1-bit machine
video → APF 400×512 @ 12.288 MHz) and the Phase-1 colour-bar prototype
(`Cores/Newsdee.Apple2eStreamProto`) were retired to `archive/` on 2026-10-20.

**Video modes (streaming).** `video.json` declares three scaler "slots" of the same
560×192 stream: **10:9** (fills the Pocket panel; the default), **4:3**, and **70:24**
(true aspect — the Apple II raster is a 2.9:1 strip, so the full-panel modes stretch
characters vertically). The Pocket boots to slot 0 (the first entry) and has **no UI
selector**; slot selection is core-driven via an end-of-line word (the RGB word right
after DE falls: `[2:0]=0`, slot in `[23:13]`; all-zero = slot 0). The Pocket LCD is
1600×1440 (10:9), not square. The APF rejects non-contiguous (strobed) DE — any decimation
must keep DE contiguous.

## Project layout

```
src/fpga/            ONE active Quartus project:
  apf_apple2.qsf   the Apple IIe core (top apf_top_apple2), OSK, M0 SDRAM
                         storage, status overlay - the only build (2026-10-20)
  apf/                 APF shell (template, unmodified)
  core/apple2e/        streaming top (apf_stream_video_top.v + apf_stream_video.v),
                       apf_video.v, apple2e_osk.v, apple2e_pll.v, M0 storage RTL
                       (slot_fifo/disk_store/disk_verifier/sdram_storage/
                       sdram_status_overlay/io_sdram_pocket), legacy tops kept
                       for the Verilator harnesses (+ SDC)
  rtl/roms/            ROM hexes (apple2e.hex, video2.hex) for Quartus CWD
machine/             byte-identical machine RTL (Apple-II_MiSTer/rtl)
verilog/             Verilator harnesses (tb/, stubs/, build+run bats)
sd_root/             SD-card staging: Cores/Newsdee.Apple2e (live),
                     Cores/Developer.Core Template (development), Platforms
output/              generated bitstream.rbf_r (gitignored)
tools/rbf2rbf_r.py   .rbf -> .rbf_r (bit-reversal) converter
apf_apple2_build.bat   THE build: compile apf_apple2 -> reverse ->
                            stage into sd_root/Cores/Newsdee.Apple2e
```

## Build (Windows, Quartus 17.0.2 on PATH)

```bat
:: The single active build: compile apf_apple2 + reverse + stage
:: into sd_root\Cores\Newsdee.Apple2e (the only core package).
apf_apple2_build.bat

:: or compile in the Quartus UI:
src\fpga\apf_apple2.qsf
```

There is exactly one Quartus project (`apf_apple2`). The earlier projects (basicassets
skeleton, P2a frame-buffer core, Phase-1 prototype) were retired 2026-10-20 into
`archive/quartus-legacy/` — they shared the `output_files_apple2e` output directory and
their stale RBFs/reports were a bitstream-provenance hazard. Build variants are parameters
of `apf_apple2` (e.g. `DEC2X`), not new projects. See `archive/quartus-legacy/README.md`.

Streaming-core packaging: reverse the fresh
`src/fpga/output_files_apple2e/apf_apple2.rbf` with `tools/rbf2rbf_r.py` and copy it
to `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r`. The build does both steps.

## Sim (MSYS2 UCRT64)

```sh
cd verilog
bash verilate_p2a.sh          # machine + apf_video harness (tb_apf_video.sv)
cmd //c run_p2a_verilator.bat # run (CWD = Apple-II_MiSTer root for ROMs)
bash verilate_apple2e.sh && cmd //c run_apple2e_verilator.bat  # P1 smoke
```

See `verilog/README.md` for the full harness list (P0/P1/P2a/P2b, geometry probe,
Phase-2 streaming frame captures, the decimator pixel-coordinate check, keyboard-protocol
regression, RAM-inference minimal repro in `ramtest/`).

### Differential equivalence against a VHDL golden (example: `hdd_equivalence/`)

Some modules were ported from the MiSTer core's VHDL, and their proof of correctness is
a **differential harness**: the VHDL donor runs under GHDL as the golden, the Verilog
candidate runs under Verilator, and both are driven through the same stimulus and compared
field-by-field.

`verilog/hdd_equivalence/` is the working example — `golden/hdd.vhd` is the donor (with the
two same-clock processes that co-wrote `sector_buf` merged into one writer, which is
behaviour-identical per VHDL semantics but required for Verilog's single-driver rule),
`hdd_vhdl_tb.vhd` and `hdd_verilog_tb.sv` are the two testbenches, and `run_equivalence.ps1`
drives both and compares. It sweeps STATUS / READ / WRITE / FORMAT and toggles `hdd_protect`,
with explicit coverage gates so skipped VHDL metavalues (Verilator is two-state) cannot
produce an empty pass.

```powershell
Set-Location verilog/hdd_equivalence
.\run_equivalence.ps1              # or -CompareOnly to recheck existing traces
```

Known good: `HDD EQUIVALENCE PASS rows=7600 fields=128397 ignored_metavalues=803
hdd_read=5 hdd_write=5`.

The sibling repo `Apple-II-Verilog_MiSTer/module_tests/` holds the same kind of harness for
the donor modules this core ports byte-identically (Disk II, keyboard, font ROM, dpram, and
others). `machine/` is pinned to the donor and `check_machine_sync.sh` enforces that it
cannot drift, so those results apply to this core too. See `AGENTS.md` for the GHDL 6 /
Verilator 5.050 gotchas before building a new one — notably that GHDL 6 silently loses
array-element writes when two processes write the same array signal.

## Core JSON files — single source of truth

**All openFPGA manifest JSONs live ONLY in `sd_root/Cores/Newsdee.Apple2e/`**
(`core.json`, `data.json`, `interact.json`, `video.json`, `audio.json`, `input.json`,
`variants.json`), plus `sd_root/Platforms/apple2e.json`. That directory IS the card
layout — copy it to the Pocket SD card root. When a release adds or changes an interact
option (e.g. 0.3.5's combined **Boot Media**), the **bitstream and `interact.json` must
be copied to the card as a pair** — a mismatched pair is inert (old core ignores the new
address; new core without the JSON keeps its safe RTL default), so there is no corruption
risk either way.

There are deliberately **no copies at the repository root**. They used to exist as
leftovers from the `open-fpga/core-template` origin and had silently drifted: root
`data.json` had an empty `data_slots` (no disk slot at all), root `interact.json` had
no "Reboot on load" option, and root `video.json` still declared a 320×240 scaler mode
that contradicts the shipping native 560×192 streaming path. Nothing ever read them —
`apf_apple2_build.bat` only checks that the `sd_root` copies exist, and
`repackage.bat` only touches the bitstream — so they were removed on 2026-10-24 rather
than synced, because two copies is how they drifted in the first place.

**Do not add JSONs back at the repo root.** Edit the `sd_root` copy. If you are reading
a root-level `data.json`/`video.json` in this repo, you are looking at a stale artifact
from before that cleanup.

(`refs/basicassets/` is third-party reference material and `archive/sd-legacy/` is frozen
history; both keep their own JSONs and are not part of the package.)

## Documentation policy

This repository keeps only **durable, contributor-facing** documentation. Interim working
documents — expert reviews, external-review briefs, coder kickoff briefs, milestone plans,
and handovers — live in a private repository and are `.gitignore`d. The convention is
mechanical: **a date in the filename marks a document as interim** (`docs/*_20YY-MM-DD.md`),
so dated files are ignored automatically and undated files are tracked normally. When
adding permanent documentation, give it an undated name.

The interim files still exist on disk in a working copy — only their tracking is
suppressed — so cross-references between documents keep resolving locally. Documents
published before 2026-10-25 remain in this repository's git history; the split applies
from that date forward and history was not rewritten.

Tracked, undated docs:

| File | Content |
|---|---|
| `README.md` | user-facing: what it does, install, media, controls, Core Settings, licensing |
| `AGENTS.md` | operating guide for agents and engineers working in this tree |
| `docs/DEVELOPMENT.md` | this file — build, layout, sim, JSON-manifest rules, doc policy |
| `docs/CHANGELOG.md` | release and milestone history |
| `docs/HDV_WRITE_FIX.md` | technical root cause + fix for the 0.3.5 HDV write fix |
| `docs/RESOURCE_UTILIZATION.md` | per-component ALM/M10K/DSP/pin breakdown (snapshot; refresh after a footprint change) |
| `docs/HARDWARE_CAPTURE_CHECKLIST.md` | how to capture hardware evidence |
| `docs/OSK_KEYBOARD_FLOOD.md` | on-screen keyboard behaviour and its limits |
| `docs/POCKET_BOOT_HARNESS.md` | the `verilog/pocket_boot/` simulation harness |
| `docs/RELEASE_NOTES_0.3.*.md` | per-release notes |
| `src/fpga/core/woz/NOTICE.md` | pinned-donor provenance for the WOZ engine |
