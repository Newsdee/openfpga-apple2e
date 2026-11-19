# sound/ - donor import from the MiSTer Apple II core

Byte-identical import of the MiSTer Apple II core's Disk II floppy drive
sound generator (synthesized motor hum / step clunks / track-0 knock /
IO activity - no ROM or sample files). No modifications: the Pocket-side
integration (event taps from the WOZ engine, mixer extension in
`speaker_i2s.v`, option plumbing) lives in `apple2e` top-level files, so
the donor file stays diff-able against the upstream tree.

```
source: E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/floppy_sound.sv
donor head at import (2026-11-19): Apple-II_MiSTer working tree (newsdee),
commit 170dd2d "Floppy drive sound restored for WOZ implementation"
provenance: "Based on the work of Copyright (c) 2016 Sorgelig" per its
header (GPL-family MiSTer core); Newsdee extension for WOZ taps
(motor/step/trk0/io events, per-drive pan)
```

## SHA-256 pin (verified 2026-11-19)

| File             | SHA-256 | Status |
|------------------|---------|--------|
| `floppy_sound.sv` | `84a2ea89746fe5758873a8ec1f24a9a4985fc4c91df5a521137c785f82bd6956` | byte-identical |

Re-verify:

```bash
sha256sum src/fpga/core/sound/floppy_sound.sv
```

## Integration notes (landing checklist - NOT registered yet)

The file is vendored as PREP only: `apf_apple2.qsf` registration, the
`apf_stream_video_top.v` instantiation, and the `speaker_i2s.v` mixer
extension land TOGETHER as one atomic change once the WOZ floppy
regression brief is closed (see `docs/PLAN_FLOPPY_SOUND_PORT_2026-11-19.md`
section 2 - hard sequencing constraint).

Key interface facts (verified against the donor and the MiSTer
instantiation in `Apple-II_MiSTer/Apple-II.sv`):

- Clock: 14.318 MHz machine domain (MiSTer: `clk_sys`; Pocket:
  `clk_core_14318`). No CDC inside the donor.
- `reset`: ACTIVE-HIGH synchronous (MiSTer: `RESET | status[0] | ...`);
  Pocket equivalent is the top-level `machine_reset` (active-high) - do
  NOT copy the MB card's active-LOW `I_RESET_L` line.
- `pan`: MiSTer hardwires `2'd3` ("Drives": d1 -> L, d2 -> R).
- `gain`: MiSTer exposes 2-bit OSD gain (0=off/1=2x/2=4x); Pocket
  convention is hardwired constants (no audio knobs) - the option is an
  on/off `enable` only.
- Events (all single-cycle pulses, machine domain): `drive1_motor` =
  `D1_MOTOR_ON` (immediate command - NOT the spin-down-holding
  D1_ACTIVE), `drive1_io` = `D1_IO_ACTIVE`-equivalent (`d1_io`: read-flux
  pulse while selected+spinning, or write-cell strobe), `drive1_step` =
  `D1_STEP`, `drive1_track_zero_step` = `D1_TRACK0`. The WOZ engine
  already exports all of these (`disk_ii_woz.sv` "Sound taps" block);
  only `D1_MOTOR_ON` currently reaches the Pocket top (as `drv_motor`) -
  `D1_STEP`/`D1_TRACK0`/`D1_IO` are unconnected at the top and get wired
  at landing. Drive-2 inputs stay tied low (single-drive core).
- Output: `sample`/`sample_r` are 10-bit UNSIGNED AMPLITUDES (0 = idle,
  1023 = saturated). Zero-idle is inherent (no events => 0). Mixer
  side: added directly (no DC tracker - tiny mean, MiSTer parity),
  scaled x8, and the final 16-bit sum SATURATES (MiSTer saturates its
  11-bit sum too) because MB x3 + speaker + fs worst case exceeds 32767.
