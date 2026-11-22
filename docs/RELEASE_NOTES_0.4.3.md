# Release 0.4.3 — 2026-11-22

**joy2key `.a2k` profile fix (big-endian capture); WOZ load-window flux
fix.**

0.4.3 is 0.4.2 plus two bug fixes, each found and verified on hardware.
Everything else is unchanged: same machine behavior, same options, same
resources within a few LUTs.

## What's new over 0.4.2

### joy2key: `.a2k` profile files now load with the correct mapping

Symptom: a profile that works correctly on the MiSTer core produced a
cross-wired mapping on the Pocket — e.g. with the ThunderbirdsGX profile
the D-pad up typed Space (instead of 'A'), D-pad down typed the left
cursor (instead of Space), and the face/shoulder buttons hit each
other's keys.

Root cause: the `.a2k` capture in `apf_stream_video_top.v` unpacked each
host DMA word little-endian, but the host delivers file words
**big-endian** (first file byte in `[31:24]`) — the same convention the
working WOZ/HDD paths use. Every 4-byte group of the 16-byte profile
table was therefore stored byte-reversed on the real device. The
simulation masked it for five weeks because the testbench's emulated
host wrote little-endian words that happened to match the wrong unpack
— the identical trap behind the HDV `0x0180` fix in the 0.4.2 lineage.

The bug was pinned by a 16-byte label-test profile (each slot types its
own letter); the measured keys transcribed the exact per-word reversal
permutation, leaving no ambiguity. Fix: big-endian unpack in the
capture (4 lines), plus the TB host model corrected to write BE words so
the sim now models the real host. Result: any `.a2k` profile that maps
correctly on MiSTer now maps identically on the Pocket (D-pad
directions, face buttons, shoulders, and the Select-hold layer).

### WOZ: no more load-window "I/O ERROR" flake

Between disk mount and `woz_valid` (the metadata scan), the controller
reported `bit_count = 0` — total flux silence. A single read attempt by
the RWTS in that window timed out and surfaced as a spurious "I/O
ERROR" on disk load (mechanism B′, placement-independent; details in
`docs/ADDENDUM_WOZ_LOAD_IOERR_SCAN_WINDOW_2026-11-22.md`). During the
scan window the controller now presents a nominal 40,000-bit track with
a deterministic transition-rich pattern instead of possibly-zeroed BRAM.
Behavior with no media present or a valid WOZ mounted is unchanged.

## Build

- 2026-11-22 22:01, Standard Fit (Quartus Prime 17.0.2 Lite),
  `DEVKEY_DIAG=0`; build stamp `20261122/00:21:53` (pre-flow)
- 11,207 / 18,480 ALM (61 %), 12,839 registers, RAM blocks 202/308
  (66 %), pins 224/224, DSP 29, PLL 2
- STA: TNS 0.000 all corners (min setup slack 1.162 ns)
- `bitstream.rbf_r` SHA-256
  `e4ae03a2c3ca8e6c0c1741cdeb47d7cafde0bb4690a6c63712de136c8f5a0ef5`
- **Hardware-validated 2026-11-22:** label-test `.a2k` profile shows the
  correct per-slot mapping (every press hits its own slot, including the
  Select layer); MiSTer-equivalent profile (ThunderbirdsGX) now matches
  the MiSTer core; WOZ disk load in the I/O-ERROR flake scenario is
  clean.

## Known issues

Carried from 0.4.2 (no changes):

- **M10K hardware gate:** the validation plan calls for three consecutive
  shipping-clean rolls; 0.4.2 was the first clean pass. If a future
  compile of this tree fails the hardware gate, the fallback is 0.4.1
  (FF array, HW-validated).
- **Transport region is still shared:** ship builds remain HW-gated
  (floppy + HDV load/write + savestate).
- **Mockingboard state is not in the savestate blob** (carried from
  0.4.0): the card resets on sleep/wake; machine state round-trips.

## Packaging

`sd_root_release/Apple2e_Pocket_0.4.3.zip` (cores + assets + platforms;
`cartridge_adapter: -1`, platform year 1983).
