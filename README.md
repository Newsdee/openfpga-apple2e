# Apple IIe for Analogue Pocket (openFPGA)

Analogue Pocket (openFPGA/APF) core for the Apple IIe, built on
`open-fpga/core-template` v1.3.0 (commit `da3a021`). Machine RTL is a
byte-identical copy of the `Apple-II_MiSTer` project (see
`check_machine_sync.sh`); the machine + APF bridge + video adapter live in
this repo so the Quartus project is self-contained.

## Status (2026-10-19)

- **P0 toolchain** — template compiles on Quartus 17.0.2 Lite
  (Cyclone V `5CEBA4F23C8`), `.rbf` -> `.rbf_r` conversion, SD staging. Done.
- **P1 shell** — PLL tree (74.25 MHz x2, 12.288 MHz video, 14.312 MHz
  machine), I2S, bridge, KB-014-clean test-pattern video. Hardware-verified.
- **P2a machine** — real Apple IIe boots: 65C02 + BIOS + 64K RAM +
  `apf_video` adapter (native 1-bit video -> APF 400x512 @ 12.288 MHz).
  Boots to the Apple logo, then the `Ready.` prompt. Hardware-verified,
  including the fix for the intermittent duplicate-screen (ping-pong
  buffer-race) glitch.
- **P2b OSK** — full-color on-screen keyboard (24-bit composite with
  transparency, MiSTer-identical panel). Hardware-verified. Fixed along
  the way: dpad bit-reversal (APF vs OSK conventions), press-latch with
  release confirmation, and glyph fidelity — the wrapper must drive
  `pixel_clock_double=1` (MiSTer's own default); with 0, the 8-bit font
  OR-compresses two bits per column and letterforms collapse ("I"
  rendered as "C"). The "one press types many of the same key" report was
  a monitor artifact: the BIOS acks keys with a `$C01X` write, not the
  `$C000` read — all three sim levels and hardware are clean. Details in
  `docs/` and the parent workspace's `docs/porting/PLAN_POCKET_CORE.md`.
- **Phase 1 streaming** — native `560x192 @ 14.318 MHz` RGB streamed
  directly to the APF DDR video pad (no frame buffer). Hardware-verified
  pattern prototype core (`Cores/Newsdee.Apple2eStreamProto`).
- **Phase 2 streaming** — real machine video + full-color OSK via
  `apf_stream_video` (APF-clean HS/DE spacing, no M10K frame buffer).
  Hardware-verified (`Cores/Newsdee.Apple2e`).

## Cores on the SD card

| Folder | Core | Video path |
|---|---|---|
| `Cores/Newsdee.Apple2e` | stable machine core | frame-buffer: 1-bit machine video -> APF 400x512 @ 12.288 MHz |
| `Cores/Newsdee.Apple2e` | Phase 2 streaming | native 560x192 @ 14.318 MHz RGB -> APF DDR pad, full-color OSK, aspect presets below |
| `Cores/Newsdee.Apple2eStreamProto` | Phase 1 prototype | colour-bar / line-ID pattern on the same streaming path |

**Video modes (streaming cores).** `video.json` declares three scaler
"slots" of the same 560x192 stream: **10:9** (fills the Pocket panel,
default), **4:3**, **70:24** (true aspect — the Apple II raster is a 2.9:1
strip, so full-panel modes stretch characters vertically). The Pocket
boots to slot 0 (the first entry) and has **no UI selector** — slot
selection is core-driven via an end-of-line word (RGB word right after DE
falls, `[2:0]=0`, slot in `[23:13]`; all-zero = slot 0). A runtime
button-combination switcher is planned. Note the Pocket LCD is 1600x1440
(10:9), not square. The APF rejects non-contiguous (strobed) DE — any
decimation must keep DE contiguous (see `video_skip` note in the expert
briefs).

## OSK controls

Works on both cores; START opens/closes the panel.

| Button | Action |
|---|---|
| D-pad | move the cursor |
| face-A | fire (press the selected key) |
| face-X | Space |
| face-Y | Backspace (back arrow, hold-to-repeat) |
| trig-L1 | panel position (top/bottom) |
| trig-R1 | Enter |
| face-SELECT | cycle OSK transparency |
| face-START | OSK on/off |
| face-B | (unused) |

The panel's Caps/Ctrl/Shift keys latch like the real machine; the arrow
keys and Apple-logo key behave as on MiSTer.

## Joystick / paddle controls (streaming core)

The d-pad and face buttons double as an Apple II joystick/paddle port
(donor `joystick_input` + one-shot `pdl_timer`, 2026-10-25). While the OSK
is open the joystick is frozen (not re-centred) and the buttons belong to
the OSK; with the OSK closed:

| Button | Apple II |
|---|---|
| D-pad | paddle X/Y — accumulate (Relative) or snap to extremes (Absolute) |
| face-A | PB0 / `$C061` — fire 0 (OR'd with the OSK open-apple) |
| face-B | PB1 / `$C062` — fire 1 (OR'd with the OSK closed-apple) |
| face-X | centre both paddles (calibration-style games) |
| face-Y | PB2 / `$C063` — IIe shift line / third fire |

Core Settings → **Joystick** selects the mode: Absolute (snap) - the
default - or Relative (slow / normal / fast). Absolute is the default because
many titles are digital-only and snap instantly to the d-pad extremes;
Relative accumulates a virtual paddle position, with an update step of
2 / 1 / 0.5 ms for slow / normal / fast. Paddle values are the classic one-shot interval: a `$C07x`
read arms the counter (2800 ticks at centre, 0–5650 with position); PDL2/PDL3
read 0 (poll loops terminate).

Core Settings → **Controls** (input.json) lets the four face mappings above
be remapped to any of the face buttons/triggers/start/select; the d-pad is
not remappable (it is the OSK cursor).

## Layout

```
src/fpga/            ONE active Quartus project:
  apf_stream_video.qsf   streaming core (top apf_top_st), OSK, M0 SDRAM
                         storage, status overlay - the only build (2026-10-20)
  apf/                 APF shell (template, unmodified)
  core/apple2e/        streaming top (apf_stream_video_top.v + apf_stream_video.v),
                       apf_video.v, apple2e_osk.v, apple2e_pll.v, M0 storage RTL
                       (slot_fifo/disk_store/disk_verifier/sdram_storage/
                       sdram_status_overlay/io_sdram_pocket), legacy tops kept
                       for the Verilator harnesses (+ SDC)
  rtl/roms/            ROM hexes (apple2e.hex, video2.hex) for Quartus CWD
archive/               retired projects (quartus-legacy: ap_core, apple2e_core,
                       apf_stream_proto QSFs + old build bats; sd-legacy: stale
                       P2a / Phase-1 SD core packages) - see its README
machine/             byte-identical machine RTL (Apple-II_MiSTer/rtl)
verilog/             Verilator harnesses (tb/, stubs/, build+run bats)
sd_root/             SD-card staging: Cores/Newsdee.Apple2e (live),
                     Cores/Developer.Core Template (development), Platforms
output/              generated bitstream.rbf_r (gitignored)
tools/rbf2rbf_r.py   .rbf -> .rbf_r (bit-reversal) converter
apf_stream_video_build.bat   THE build: compile apf_stream_video -> reverse ->
                            stage into sd_root/Cores/Newsdee.Apple2e
```

## Build (Windows, Quartus 17.0.2 on PATH)

```bat
:: The single active build: compile apf_stream_video + reverse + stage
:: into sd_root\Cores\Newsdee.Apple2e (the only core package).
apf_stream_video_build.bat

:: or compile in the Quartus UI:
src\fpga\apf_stream_video.qsf
```

There is exactly one Quartus project (`apf_stream_video`). The earlier
projects (basicassets skeleton, P2a frame-buffer core, Phase-1 prototype)
were retired 2026-10-20 into `archive/quartus-legacy/` - they shared the
`output_files_apple2e` output directory and their stale RBFs/reports were a
bitstream-provenance hazard. Build variants are parameters of
`apf_stream_video` (e.g. `DEC2X`), not new projects. See
`archive/quartus-legacy/README.md`.

Streaming-core packaging: reverse the fresh
`src/fpga/output_files_apple2e/apf_stream_video.rbf` with
`tools/rbf2rbf_r.py` and copy it to
`sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r`.

## Sim (MSYS2 UCRT64)

```sh
cd verilog
bash verilate_p2a.sh          # machine + apf_video harness (tb_apf_video.sv)
cmd //c run_p2a_verilator.bat # run (CWD = Apple-II_MiSTer root for ROMs)
bash verilate_apple2e.sh && cmd //c run_apple2e_verilator.bat  # P1 smoke
```

See `verilog/README.md` for the full harness list (P0/P1/P2a/P2b, geometry
probe, Phase 2 streaming frame captures, the decimator pixel-coordinate
check, keyboard-protocol regression, RAM-inference minimal repro in
`ramtest/`).

## Core JSON files - single source of truth

**All openFPGA manifest JSONs live ONLY in
`sd_root/Cores/Newsdee.Apple2e/`** (`core.json`, `data.json`,
`interact.json`, `video.json`, `audio.json`, `input.json`, `variants.json`),
plus `sd_root/Platforms/apple2e.json`. That directory IS the card layout - copy
it to the Pocket SD card root.

There are deliberately **no copies at the repository root**. They used to exist
as leftovers from the `open-fpga/core-template` origin and had silently drifted:
root `data.json` had an empty `data_slots` (no disk slot at all), root
`interact.json` had no "Reboot on load" option, and root `video.json`
still declared a 320x240 scaler mode that contradicts the shipping native
560x192 streaming path. Nothing ever read them - `apf_stream_video_build.bat`
only checks that the `sd_root` copies exist, and `repackage.bat` only touches
the bitstream - so they were removed on 2026-10-24 rather than synced, because
two copies is how they drifted in the first place.

**Do not add JSONs back at the repo root.** Edit the `sd_root` copy. If you are
reading a root-level `data.json`/`video.json` in this repo, you are looking at a
stale artifact from before that cleanup.

(`refs/basicassets/` is third-party reference material and `archive/sd-legacy/`
is frozen history; both keep their own JSONs and are not part of the package.)

## Documentation policy

This repository keeps only **durable, contributor-facing** documentation:

| File | Content |
|---|---|
| `README.md` | this file - status, controls, layout, build, sim |
| `AGENTS.md` | operating guide for agents and engineers working in this tree |
| `docs/HARDWARE_CAPTURE_CHECKLIST.md` | how to capture hardware evidence |
| `docs/OSK_KEYBOARD_FLOOD.md` | on-screen keyboard behaviour and its limits |
| `docs/POCKET_BOOT_HARNESS.md` | the `verilog/pocket_boot/` simulation harness |
| `src/fpga/core/woz/NOTICE.md` | pinned-donor provenance for the WOZ engine |

**Interim working documents are deliberately not published here.** Expert reviews,
external-review briefs, coder kickoff briefs, milestone plans and handovers live in
a private repository and are `.gitignore`d. The convention is mechanical: **a date
in the filename marks a document as interim** (`docs/*_20YY-MM-DD.md`), so dated
files are ignored automatically and undated files are tracked normally. When adding
permanent documentation, give it an undated name.

The files still exist on disk in a working copy - only their tracking is suppressed -
so cross-references between documents keep resolving locally.

Note that documents published before 2026-10-25 remain in this repository's git
history; the split applies from that date forward and history was not rewritten.

## Provenance / licensing

- APF shell: `open-fpga/core-template` (Analogue openFPGA program).
- Machine RTL: `Apple-II_MiSTer` project (Newsdee).
