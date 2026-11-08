# Changelog

Release history and the project's build-up milestones. The shipped version and date
live in `sd_root/Cores/Newsdee.Apple2e/core.json` (`metadata.version` / `date_release`).
Each release has detailed notes in `RELEASE_NOTES_<version>.md`; this file is the
at-a-glance index.

## Releases

### 0.3.5 — 2026-11-08
**HDV writes fixed; Boot Media and Write Protect combined.**
- **Root cause of HDV write corruption** was the framework's 0x0184 convention (a
  129-strobe prime + discard). The core's single-stage HDV read port lagged by one
  position, shifting every read-back. Fixed with a local read stage in `hdv_bridge.sv`
  (`RD_PRIME_STAGE`, ships at 1) — local to the bridge, no global mux touched.
- **Combined the "Boot Media" and "Hard Disk Write Protect" options** into one 5-value
  **Boot Media** option (Both read-only / Both write / Floppy no HD / HDD read-only /
  HDD write); the separate Write Protect option is retired.
- Diagnostics reverted for shipping (`OVL_DEBUG=0`, `OOB_ENCODE` diagnostic-only).
- Testbench release gate moved to the 2-stage shipping port. See
  [`RELEASE_NOTES_0.3.5.md`](RELEASE_NOTES_0.3.5.md).

### 0.3.4 — 2026-11-07
**Diagnostics + the second root cause (not the shipped fix).**
- Added the OOB / out-of-range trace and K-counter diagnostics; fixed an arm race.
- Expert review identified **root cause #2** — the 0x0184 read-back alignment (the
  prime + discard). A fresh compile was required before any hardware test; the fix
  itself shipped in 0.3.5. See [`RELEASE_NOTES_0.3.4.md`](RELEASE_NOTES_0.3.4.md).

### 0.3.3 — 2026-11-04
**Writable HDV behind a Hard Disk Write Protect option (default protected).**
- Added the **Hard Disk Write Protect** option (default **Protected** = read-only)
  gating HDV writes. Drive lamps show HD read/write. See
  [`RELEASE_NOTES_0.3.3.md`](RELEASE_NOTES_0.3.3.md).

### 0.3.2
**Docked USB keyboard; HDV read-only; joystick relative mode.**
- Docked USB HID keyboard (Player-3 slot).
- Hard disk (HDV) read-only streaming (0.3.0 feature).
- Joystick relative mode (0.3.1 feature).
- Video & identity fixes (0.3.0). See [`RELEASE_NOTES_0.3.2.md`](RELEASE_NOTES_0.3.2.md).

## Milestone history (build-up)

The core was brought up in phases (as of 2026-10-19; the "Phase 2 streaming" core is
the one that ships):

- **P0 — toolchain.** The `open-fpga/core-template` compiles on Quartus 17.0.2 Lite
  (Cyclone V `5CEBA4F23C8`); `.rbf` → `.rbf_r` conversion and SD staging work.
- **P1 — shell.** PLL tree (74.25 MHz ×2, 12.288 MHz video, 14.312 MHz machine), I2S,
  the host bridge, and a KB-014-clean test-pattern video. Hardware-verified.
- **P2a — machine.** Real Apple IIe boots: 65C02 + BIOS + 64K RAM + the `apf_video`
  adapter (native 1-bit video → APF 400×512 @ 12.288 MHz). Boots to the Apple logo,
  then the `Ready.` prompt. Hardware-verified, including the fix for the intermittent
  duplicate-screen (ping-pong buffer-race) glitch.
- **P2b — OSK.** Full-colour on-screen keyboard (24-bit composite with transparency,
  MiSTer-identical panel). Hardware-verified. Fixed along the way: dpad bit-reversal
  (APF vs OSK conventions), press-latch with release confirmation, and glyph fidelity
  (the wrapper must drive `pixel_clock_double=1` — with 0, the 8-bit font OR-compresses
  two bits per column and letterforms collapse). The "one press types many of the same
  key" report was a monitor artifact: the BIOS acks keys with a `$C01X` write, not the
  `$C000` read — all three sim levels and hardware are clean.
- **Phase 1 — streaming.** Native 560×192 @ 14.318 MHz RGB streamed directly to the APF
  DDR video pad (no frame buffer). Hardware-verified pattern prototype core.
- **Phase 2 — streaming (ships).** Real machine video + full-colour OSK via
  `apf_stream_video` (APF-clean HS/DE spacing, no M10K frame buffer). Hardware-verified.
