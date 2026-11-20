# Release 0.4.0 — 2026-11-19

**Savestates, Mockingboard, floppy drive sound, audio balance.**

First stable release of the feature wave developed across internal
0.3.7-RC builds. Supersedes 0.3.7 RC (Mockingboard + slider fix as a
release candidate; predates the audio work). Cut from the
HW-validated 2026-11-19 22:32 bitstream (`cc061da3…`, commit `2daf3a5`),
user audio-tested with floppy + HDV + savestate all working.

## What's new over 0.3.6

- **Savestates**: the Pocket's native save/load/sleep-wake flow. Three
  load/save defects found during bring-up (save command-path race,
  host-rate write overflow on load, one-word load-alignment error) are
  fixed and hardware-validated.
- **Mockingboard** (slot 4): 2× 6522 VIA + 2× AY-3-8910 PSG, six stereo
  channels, behind a volume slider (Off / 1x / 2x / 3x, gain ×0/×24/
  ×32/×48 with saturation). RTL vendored byte-identical from the MiSTer
  Apple II core (`src/fpga/core/mockingboard/NOTICE.md`); audio follows
  the MiSTer golden path (point-sampled PSG, valid/ack CDC, slow DC
  tracker preserving low-end).
- **Floppy drive sound**: synthesized drive motor/step activity mixed
  into the stereo I2S output, with its own option.
- **Audio balance sliders**: Floppy Volume and Beeper Volume (first
  form; the beeper ladder was reworked to attenuation in 0.4.1).

## Known issues (at release)

- Beeper Volume slider reported inert on two subsequent dev builds —
  resolved in 0.4.1 as a placement-sensitive marginality (not a beeper
  bug).
- Shared host→machine transport region placement-fragile (~3/7
  compiles fail the hardware test); ship builds are HW-gated.
- Mockingboard state not in the savestate blob (board resets on
  sleep/wake).

## Packaging

`sd_root_release/Apple2e_Pocket_0.4.0.zip` from the 22:32 bitstream
(`bitstream.rbf_r` `cc061da371f4a043a6724b8453c960efe30fb76551f71881cfbb0d81ec16ee91`),
`cartridge_adapter: -1`, platform year 1983.
