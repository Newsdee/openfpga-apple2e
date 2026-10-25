# Build 2026-10-25 21:16 - 555 speaker audio (speaker_i2s)

## Identity
- First build with `src/fpga/core/apple2e/speaker_i2s.v` (new module):
  box-averaged 1-bit speaker duty (298-clk MiSTer-exact window) -> 2-FF CDC ->
  unsigned first-order tracker (DC centering, exact convergence) -> x32
  half-scale -> 16-bit I2S MSB-first on the existing mclk/sclk framing.
- Replaces the I2S silence generator; mclk/sclk generation unchanged.
- Gain hardwired x32 (no OSD knob - core convention).

## Compile (owner, Quartus 17.0.2 Lite, 5CEBA4F23C8)
- Coherent run: A&S 21:10 -> fit 21:15 -> .done 21:16
- A&S successful; fitter successful; RBF generated 21:15

## Resources (vs Phase B known-good 19:37 build)
| | 19:37 fileinit | 21:16 sound | delta |
|---|---|---|---|
| ALMs | 8,060 | 8,141 | +81 (speaker_i2s) |
| registers | 6,696 | 6,755 | +59 |
| block memory bits | 1,527,836 | 1,527,836 | 0 |
| RAM blocks | 190 | 190 | 0 |
| DSP | 4 | 4 | 0 |
| PLLs | 2 | 2 | 0 |

## Timing
- All constrained domains positive: mp2 +1.618 ns, clk_74a +4.036 ns,
  bridge_spiclk +9.252 ns, mp1 +29.227 ns (Slow 1100mV 85C setup)
- End Point TNS 0.000 on all four
- Audio mclk/sclk domain remains unconstrained (as in all prior builds)

## Bitstream
- apf_stream_video.rbf sha256: 31d1ea797dca6ee2eb9d8608f72dda6bcbeed405b6b76892c90d92be23b6742f
- staged bitstream.rbf_r sha256: 75bac347c15376bf722ba399fa164ed2709252f82c593c7158255b8326827e96

## Pre-hardware validation (Verilator)
- Unit TB `verilog/tb/run_tb_speaker_i2s.sh`: PASS (silence / full-on DC /
  anti-alias / AC tone + framing). The TB caught two real DUT bugs:
  1. I2S shifter direction: right-shift + read bit 15 emits W[15] once then
     zeros forever; fixed to left-shift ((W<<k)[15] = W[15-k]).
  2. DC-blocker deadband: truncated /32 step stalled at |diff|<32; fixed with
     rounded /16 step (exact convergence, no limit cycle).
- Full-machine pocket_boot: builds clean; headless smoke smokePass=1 EXIT=0.

## Hardware results (2026-10-25, owner)
- PASS: "it works" - boot/disk normal, 555 speaker tone audible on the Pocket
  (half-scale gain, no DC offset/pop at tone edges). Core version bumped
  to 0.2.3 in sd_root (the card copy shows 0.2.2 until the next sync -
  cosmetic only; the running bitstream is this build).
