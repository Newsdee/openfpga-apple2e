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
  Hardware-verified (`Cores/Newsdee.Apple2eStreamVideo`).

## Cores on the SD card

| Folder | Core | Video path |
|---|---|---|
| `Cores/Newsdee.Apple2e` | stable machine core | frame-buffer: 1-bit machine video -> APF 400x512 @ 12.288 MHz |
| `Cores/Newsdee.Apple2eStreamVideo` | Phase 2 streaming | native 560x192 @ 14.318 MHz RGB -> APF DDR pad, full-color OSK, aspect presets below |
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

## Layout

```
src/fpga/            Quartus projects
  apple2e_core.qsf   stable machine core (Cores/Newsdee.Apple2e)
  apf_stream_video.qsf   Phase 2 streaming core (Cores/Newsdee.Apple2eStreamVideo)
  apf_stream_proto.qsf   Phase 1 prototype (Cores/Newsdee.Apple2eStreamProto)
  apf/               APF shell (template, unmodified)
  core/apple2e/      core tops: apple2e_core_top.v (frame-buffer),
                     apf_stream_video_top.v + apf_stream_video.v (streaming),
                     apf_video.v, apple2e_osk.v, apple2e_pll.v (+ SDC)
  rtl/roms/          ROM hexes (apple2e.hex, video2.hex) for Quartus CWD
machine/             byte-identical machine RTL (Apple-II_MiSTer/rtl)
verilog/             Verilator harnesses (tb/, stubs/, build+run bats)
sd_root/             SD-card staging (Cores/..., Platforms)
output/              generated bitstream.rbf_r (gitignored)
tools/rbf2rbf_r.py   .rbf -> .rbf_r (bit-reversal) converter
apple2e_build.bat    machine-core build: compile apple2e_core -> reverse -> stage
p0_build.bat         template regression build (NOT the Apple IIe core)
```

## Build (Windows, Quartus 17.0.2 on PATH)

```bat
:: stable machine core: compile apple2e_core + reverse + stage
::    into sd_root\Cores\Newsdee.Apple2e (the authoritative package).
apple2e_build.bat

:: or compile in the Quartus UI:
src\fpga\apple2e_core.qsf        rem stable machine core
src\fpga\apf_stream_video.qsf    rem Phase 2 streaming core
src\fpga\apf_stream_proto.qsf    rem Phase 1 prototype
:: p0_build.bat is the unmodified core-TEMPLATE regression path only -
:: it builds ap_core and stages Cores\Developer.Core Template, NOT the core.
```

Streaming-core packaging: reverse the fresh
`src/fpga/output_files_apple2e/apf_stream_video.rbf` with
`tools/rbf2rbf_r.py` and copy it to
`sd_root/Cores/Newsdee.Apple2eStreamVideo/bitstream.rbf_r`.

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

## Provenance / licensing

- APF shell: `open-fpga/core-template` (Analogue openFPGA program).
- Machine RTL: `Apple-II_MiSTer` project (Newsdee).
