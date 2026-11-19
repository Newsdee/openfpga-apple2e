# Build 2026-11-18 21:25 — MB audio fix (point-sample chain)

Quartus full compile, 21:25–21:26, by user. Revision `apf_apple2`,
device 5CEBA4F23C8, top `apf_top_apple2`.

## What this build is

Shipping-tree Mockingboard port (slot-4 card, menu option, I2S mix) plus
the audio-chain fix from `docs/PLAN_MB_AUDIO_DEBUG_2026-11-18.md` §7:
the MB path was box-averaging the PSG (298-clk window), which destroyed
the tone (constant average → DC-blocked → only 48 kHz tracker ripple +
thin remnant = the "noisy / off-pitch / too loud" symptom). Replaced with
MiSTer-parity point sampling:

- 2-entry valid/ack handshake CDC (machine → mclk) for mb_l/mb_r
- slow per-channel DC tracker (tau ~128 samples ~ 2.7 ms; passes
  50/100 Hz)
- gain x4 (MiSTer-parity relative level; 16-bit add cannot clip)
- MB-off remains bit-identical to the mono speaker path

Only RTL changed vs the 12:10 MB test build: `speaker_i2s.v`.

## Validation (sim)

- `verilog/tb/tb_mb_audio.sv`: ALL 11 CHECKS PASSED (tone half-period
  112,000 machine clocks exact; no clip; bass survival; gate bit-identity;
  stereo image; CDC value-set; card I/O smoke).
- `tb/tb_speaker_i2s.sv` (mono harness): PASS.

## Fit / timing (this compile)

- ALMs: 15,753 / 18,480 (85%) — up from 14,823 on the 0.3.6 shipping
  build (the MB card + audio chain).
- Timing: met. Min setup slack 0.306 ns (final timing models).
- RAM 64%, DSP 44%, PLLs 2/4.

## Hashes

- `bitstream.rbf` (raw Quartus output, this dir):
  sha256 a5602a68466edab1ca4be27bfde9f0a8112e4337e124596bbfe5e2d196d514f5
- `bitstream.rbf_r` (staged to sd_root/Cores/Newsdee.Apple2e/, via
  validated `C:/Temp/bitrbf.pl` bit-reversal):
  sha256 a4c9c47517368f354f22f2008d626745dfc26e703ebf2a6e1dd67d4f9ba1aa0f

## Hardware sign-off (pending)

- [ ] MB menu option toggles the card
- [ ] tone audible, clear (no 48 kHz crackle), bass present on low notes
- [ ] volume: x4 build judged TOO QUIET on hardware (2026-11-18 22:5x) ->
      gain raised to x16 in the tree (sim-validated: 3-ch loud range
      +/-8.5k, no clip; all 11 TB checks green). Awaiting compile.
- [ ] no CPU wedge, no stereo crosstalk

## KNOWN REGRESSION in this build (do not ship this bitstream)

WOZ floppy load broken on hardware: machine reboots, disk spins (dark red
LED) but never reads. A/B confirmed: the archived 12:10 bitstream
(`builds/2026-11-18_1210_mb_test/bitstream.rbf_r`, fe885e9f...) loads
floppies fine on the same card/.woz; this 21:25 bitstream does not.

Root cause (working hypothesis, hardware-confirmed at bitstream level):
the speaker_i2s change forced a fitter re-placement; the machine-clock
domain (mp2 divclk - where disk_ii_woz/flux_drive live) setup slack
fell 0.858 -> 0.547 ns (still "met" per TimeQuest, TNS=0). HDV load
unaffected (74a domain, 3 ns margin). Floppy sim chain green 7/7
(m0m1 fast suite + bridge storage) - logic is not at fault.

Mitigation: FITTER_SEED pinned in apf_apple2.qsf (20261119) to force a
fresh placement on the next compile; next build must be accepted only
if the machine-domain setup slack is back near >= 0.8 ns (check
`apf_apple2.sta.summary`: the `...mp2...divclk` Setup line).
