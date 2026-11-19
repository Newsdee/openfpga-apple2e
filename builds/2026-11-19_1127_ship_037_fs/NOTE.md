# Build 2026-11-19 11:27 — 0.3.7 RC candidate: floppy sound + MB x24/32/48 ladder

Shipping-flag build (diagnostics off; map confirms no `u_devkey_uart`).
First build containing the floppy-sound landing (commit `85a3e11`) and
the louder MB volume ladder (×24/×32/×48 + saturating mix). Supersedes
`2026-11-19_1051_ship_037`.

## Source

- Worktree commit: `85a3e11` (main) — "Land floppy drive sound (0.3.7):
  donor + CDC + saturating mix + Floppy Sound option"
- A&S note: first A&S attempt of this tree failed with Error 10170
  (syntax) in `floppy_sound.sv` — the QSF registered the donor as plain
  `VERILOG_FILE`; the donor uses SystemVerilog assignment patterns
  (`'{0, 0}`). Fixed to `SYSTEMVERILOG_FILE`; this 11:27 run is the
  first full compile of the corrected tree.

## Quartus 17.0.2 Lite — results

- Analysis & Synthesis: Successful (11:17). Registers 16,172.
- Fitter: Successful (11:26). Logic **16,052 / 18,480 ALM (87%)**
  (+372 vs the 10:51 build = donor 457 ALM net of packing + 2nd
  valid/ack handshake), registers 17,212, M10K 49%, DSP 29 (the donor's
  dividers map to DSP blocks — 44%, fine).
- STA (Slow 1100mV 85C, final models):
  - mp2 machine-domain setup slack: **0.540 ns** (10:51 build: 0.726;
    21:25 failed-HW build: 0.547 — slack is NOT the WOZ gate per the
    regression brief; hardware floppy test decides)
  - clk_74a setup slack: 3.239 ns
  - bridge_spiclk setup slack: 8.567 ns
  - all TNS = 0.000, holds green
- Map: `u_floppy_sound` elaborated (457 ALM / 193 regs),
  `u_devkey_uart` absent (shipping hygiene), `u_mockingboard` +
  `u_speaker_i2s` present.

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `1ec368eb1ba6b51eb6d7ba89b070f85aac5b35a28ed2fe8d01ac7970f06f9c37`
- `bitstream.rbf_r` (bit-reversed via `C:/Temp/bitrbf.pl`) SHA-256:
  `22996a7adcc2015ab30194db7372b3a61d5596b02425e78ff609ea0af199a54a`

## Hardware checklist (release gate)

1. MB slider: 0 off (silence, card inert), 1x / 2x / 3x ladder audible
   and monotonically louder; 3x = ~1.5x speaker level on a full
   single channel, no harsh clipping on loud demo material.
2. Floppy Sound option (default ON): motor hum on spin-up, head-step
   clunks on seek, activity texture during read/write; option OFF →
   drive sounds gone (rest of audio unchanged).
3. Floppy (.woz) load still works — the WOZ regression is closed only
   while it keeps passing; this build has the same placement-sensitive
   machine domain as before, so re-verify per build.
4. Savestate save/load spot-check (unchanged code path, but the audio
   domain grew — confirm the save/load menu still behaves).

## Sim gates that preceded this build (all green)

- `run_tb_floppy_sound_chain.sh`: 9/9 (zero-idle bit-identity on/off,
  step burst L-only peak 480, motor hum, saturating mix reaching both
  ±16-bit rails without wrap).
- `run_tb_mb_audio.sh`: all checks (T7 ladder ratios 1.32 / 1.98, no
  clip).
- `tb/run_tb_speaker_i2s.sh`: PASS, `-Werror`-clean.
- `run_tb_floppy_sound.sh` (donor level): 15/15.
