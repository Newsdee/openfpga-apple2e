# Changelog

Release history and the project's build-up milestones. The shipped version and date
live in `sd_root/Cores/Newsdee.Apple2e/core.json` (`metadata.version` / `date_release`).
Each release has detailed notes in `RELEASE_NOTES_<version>.md`; this file is the
at-a-glance index.

## Releases

### 0.4.4 — 2026-11-22
**joy2key per-slot "Custom (.a2k profile)" options (working off-switch); joy2key profiles tracked + shipped in the release.**

0.4.3 plus the joy2key activation redesign: each of DPad Keys (value 5) and Fire Keys (value 3) can now select the loaded `.a2k` file as the source for its table bytes (DPad = slots 0-3, Fire = slots 4-15, mixable), and any Off/preset value ignores the file — closing the 0.4.3 gap where a loaded profile could not be switched off. One-time change: a present profile no longer auto-activates (pick Custom once after updating). The Joy2key profile set (layouts, `Game Specific\`, `Others\`, `off.a2k`, `tester.a2k`), `disk.a2k` and the Assets README become git-tracked (gitignore exception; `.woz`/`.hdv` fixtures stay out), and this is the first zip that ships the profiles. 11,226 ALM / 61 % (+19), TNS 0, pins 224/224. HW-verified 2026-11-22. See [`RELEASE_NOTES_0.4.4.md`](RELEASE_NOTES_0.4.4.md).

### 0.4.3 — 2026-11-22
**joy2key `.a2k` profile fix (big-endian capture); WOZ load-window flux fix.**

0.4.2 plus two hardware-verified bug fixes, machine behavior otherwise
unchanged (11,207 ALM / 61 %, TNS 0, pins 224/224). (1) joy2key `.a2k`
profiles loaded with every 4-byte group byte-reversed: the capture
unpacked host DMA words little-endian while the host delivers them
big-endian (first file byte in `[31:24]`, same as the working WOZ/HDD
paths) — profiles that map correctly on MiSTer came out cross-wired on
the Pocket (D-pad/face/shoulder hitting each other's slots, X/Y in the
Select layer). Found via a 16-byte label-test profile that transcribed
the exact per-word reversal; the sim masked it for five weeks because
the TB host model wrote LE words matching the wrong unpack (same trap
as the 0.4.2-lineage HDV `0x0180` fix). (2) WOZ load-window flake
(mechanism B′): between mount and `woz_valid` the controller reported
`bit_count=0` — total flux silence, so one RWTS read attempt timed out
into a spurious "I/O ERROR"; the scan window now presents a nominal
40,000-bit track with a deterministic transition-rich pattern. See
[`RELEASE_NOTES_0.4.3.md`](RELEASE_NOTES_0.4.3.md).

### 0.4.2 — 2026-11-21
**HDV sector storage on M10K block RAM (structural placement fix); final
beeper ladder; diagnostic console out.**

0.4.1 (beeper attenuation ladder Off/×1/4/×1/2/×1, console gated out)
plus the structural attempt at the transport placement sensitivity: the
~4,096-FF `hdv_ram` sector array — the largest non-video monolith in the
suspect host→machine region — is now four 128×8 lane M10Ks (16,106 →
11,142 ALM, 87 % → 60 %; pins unchanged 224/224; TNS 0). Read/write
semantics are cycle-identical to 0.4.1, proven by the new A/B
differential harness (`verilog/hdv_ab/`: real PMP + real hdd.v +
faithful host model — 128/128 words byte-exact vs the 0.4.1 FF tree) and
on hardware. Note: the first three M10K rolls failed the HDV-write gate;
the A/B harness localized a one-word over-shift (same-strobe double latch
in the read prime, sim-masked) and the fixed tree passed. Roll-4 HW:
floppy, Mockingboard, HDV load + write all pass; the written HDV is
byte-exact against the known-good reference (4-byte test-file naming
artifact only). Gate status: first of the three consecutive clean rolls
the plan requires; 0.4.1 remains the fallback. Known: transport region
still shared (ship builds HW-gated), Mockingboard state not in the
savestate blob. See
[`RELEASE_NOTES_0.4.2.md`](RELEASE_NOTES_0.4.2.md).

### 0.4.1 — 2026-11-20
**Beeper volume attenuation ladder; diagnostic console out.**

The beeper slider is final: Off / ×1/4 (default) / ×1/2 / ×1, where ×1
is the 0.3.6 beeper bit-exactly — attenuation, because the beeper must
sit *below* the rail-clamped Mockingboard top. The "dead beeper slider"
reported on two 0.4.0-dev builds was the placement-sensitive transport
marginality (same bad placements that broke floppy/HDV), not a beeper
bug. The devkey diagnostic console (transport taps, delta-printed) is
gated out (~957 ALMs freed, 92%→87%); the code stays in the tree for
the next diagnostic. HW-validated three-way (floppy, HDV, savestate
save+load). Known: transport placement sensitivity (8 pass / 4 fail
across the 10-build series; structural fix is the next-release target),
Mockingboard state not in the savestate blob. See
[`RELEASE_NOTES_0.4.1.md`](RELEASE_NOTES_0.4.1.md).

### 0.4.0 — 2026-11-19
**Savestates, Mockingboard, floppy drive sound, audio balance.**

First stable release of the feature wave that landed across internal
0.3.7-RC builds: savestate save/load/sleep-wake (hardware-validated
command-race, write-overflow and load-base fixes), the Mockingboard
sound card (slot 4, six stereo AY-3-8910 channels, volume slider),
synthesized floppy drive sound with volume slider, and Beeper Volume
slider (in its first, to-be-corrected amplifying form — see 0.4.1).
Cut from the HW-validated 2026-11-19 22:32 bitstream. Supersedes the
0.3.7 RC (which shipped the Mockingboard + slider fix as a release
candidate but predates the audio work). See
[`RELEASE_NOTES_0.4.0.md`](RELEASE_NOTES_0.4.0.md).

### 0.3.7 — 2026-11-19
**Mockingboard sound card (slot 4) with volume slider.**

The core now emulates a Mockingboard (Model A clone) — 2× 6522 VIA +
2× AY-3-8910 PSG, six stereo channels — in slot 4, behind a new
*Mockingboard* menu option (a volume slider: Off / 1x / 2x / 3x). Its
audio mixes into the stereo I2S output; at Off the audio path is
bit-identical to the plain speaker. The card RTL is vendored
byte-identical from the MiSTer Apple II core (provenance in
`src/fpga/core/mockingboard/NOTICE.md`). No other behavior changes
from 0.3.6 (savestates, floppy, HDV, video, keyboard). Platform year
corrected to 1983 (Apple IIe). See
[`RELEASE_NOTES_0.3.7.md`](RELEASE_NOTES_0.3.7.md).

### 0.3.6 — 2026-11-18
**Savestate save/load.**

The Pocket's native savestate flow now works: save the running machine
from the host menu and load it back later. Three load/save defects
found during bring-up (a save command-path race, a host-rate write
overflow on load, and a one-word load-alignment error) are fixed and
hardware-validated; the diagnostic infrastructure that found them is
compile-flagged out of this build. See
[`RELEASE_NOTES_0.3.6.md`](RELEASE_NOTES_0.3.6.md).

### 0.3.5 — 2026-11-08
**Writable HDV (working) + combined Boot Media option.**

The hard disk is now readable **and** writable — **default read-only** (opt in). The
writable-HDV work ran across internal builds (0.3.3 added opt-in writes; 0.3.4 chased
the write corruption); 0.3.5 is the fix — a local read stage in `hdv_bridge.sv`
(`RD_PRIME_STAGE`, ships at 1) that corrects the framework's 0x0184 prime + discard
convention, so HDV writes are now byte-exact. The separate "Boot Media" and "Hard Disk
Write Protect" options are combined into one 5-value **Boot Media** option; diagnostics
are reverted for shipping. See [`RELEASE_NOTES_0.3.5.md`](RELEASE_NOTES_0.3.5.md)
(user-facing) and [`HDV_WRITE_FIX.md`](HDV_WRITE_FIX.md) (technical root cause + fix).

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
