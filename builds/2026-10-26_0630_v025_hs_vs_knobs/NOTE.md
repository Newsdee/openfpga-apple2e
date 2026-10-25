# Build 2026-10-26 06:30 — v0.2.5: NTSC colour + OSD knobs + HS/VS sync fix

Main-worktree compile of `8beaf2a` (knobs) + uncommitted HS/VS fix in
`src/fpga/core/apple2e/apf_stream_video.v` (HS 5→60 clocks after HBL rise;
DEC2X=1 RD_START 20→10). The two NTSC-branch-only commits (f8f6b4d opt_test TB,
6ec7c38 interact self-consistency) are NOT in this build — f8f6b4d is TB-only
(no RTL impact), and 6ec7c38's 1-variable interact revert is intentionally not
applied (this build HAS the knob latches at 0x01F00004/0x01F00008, so the
3-variable interact.json in sd_root is the correct pairing).

## Identity

- rbf     sha256 `930783860eca6c5300ec242bfff990a7e0a3afdad9ec3c55467893c8976083ad` (1,658,208 B)
- rbf_r   sha256 `a62f73a3cced679941d7773b1739e35e147f80523c5f33acb42b086ce3014bab` (1,658,208 B)
- Quartus 17.0.2 Build 602 Lite, rev `apf_stream_video`, top `apf_top_stream`,
  device 5CEBA4F23C8. Fitter Successful 06:30:32.
- core.json: version 0.2.5, shortname **Apple2e** (renamed from Apple2eStreamVideo
  2026-10-26; folder `sd_root/Cores/Newsdee.Apple2e/`).
- interact.json: 3 variables (Reboot + Display Mode + Colour Preset, both knobs
  writeonly — read-back wildcard 01F0xxxx preserved).

## Resources (fit.summary)

- ALMs 8,981 (49%), registers 8,143, pins 224/224, mem bits 1,544,220 (49%),
  RAM 192/308, DSP 29/66, PLL 2.
- vs 0.2.3 sound build (8,141 ALM / 6,755 regs / 4 DSP / 190 RAM):
  +840 ALM, +1,388 regs, +25 DSP, +2 RAM, +16,384 mem bits — the NTSC
  composite-decode chain (matches the earlier options-build delta record:
  +108 ALM / +3 DSP on top of the hardwired NTSC base).

## Timing (sta.summary)

- **TNS 0.000 on every corner** (Slow/Fast × 0C/85C, setup/hold/recovery/
  removal/pulse-width). Worst setup +0.930 ns (Fast 1100mV 0C, mp2 PLL
  counter); worst hold +0.157 ns (Fast 85C, bridge_spiclk).

## What this build contains (feature set)

1. NTSC colour pipeline (composite decode, comb filter, palettes) — 0.2.4
2. OSD Display Mode (Colour/Mono/Green/Amber) + Colour Preset knobs — 8beaf2a
3. 555 speaker audio — 0.2.3
4. HS/VS APF sync-contract fix — this build (HS now ≥34 cycles AFTER the
   frame-line VS; previously HS fired ~40 cycles BEFORE VS) — target of the
   0.2.4 hardware "1st-line rainbow" artifact
5. File-based RAM zero-init, J10/J11/J12 (absolute joystick, boot window,
   drive LEDs)

## Sim evidence (pre-compile)

- `tb_ntsc_line0.sv` (machine-true geometry): pipeline line-0/left-edge clean.
- Full harness post-fix: HS hpos 79 vs VS hpos 45 (34 after ✓),
  de_windows=192, first_de_ln=0, line_states=1111, frames streaming.
- Sim does NOT reproduce the hardware rainbow — the fix is the best-available
  candidate; hardware is the acceptance gate.

## Hardware results

2026-10-26 owner report on the Pocket (card I:, installed under the new
`Newsdee.Apple2e` shortname): **"works great"** - the 1st-line rainbow
artifact is gone and the full feature set (NTSC colour, disk boot, joystick,
555 audio, both OSD knobs incl. the renamed presets) verified on hardware.
0.2.5 accepted as the release build; packaged as
`sd_root_release/Apple2e_Pocket_0.2.5.zip` (zip sha256
`81f44a17eff1f7609643b091923bb003e77294b6951ab20218b0858832d1edb5`).
