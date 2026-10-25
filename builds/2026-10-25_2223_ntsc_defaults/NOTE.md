# Build 2026-10-25 22:23 - NTSC colour, hardwired defaults (core 0.2.4)

First build carrying NTSC colour. Staged for hardware acceptance (plan N4)
BEFORE the OSD option surface is added, so that a failure on silicon can be
attributed to the video pipeline itself rather than to bridge-decode changes.

## Identity
- Branch `feature/ntsc-color` at merge `d2320c3`: NTSC colour + joystick/paddle
  + 555 speaker audio + file-based RAM zero-init, all four together.
- `NTSC_EN = 1'b1` (shipping path). Knobs HARDWIRED, no OSD options yet:
  `SCREEN_MODE = 2'b00` (Colour), `comp_preset = 2'd0` (Calibrated),
  `use_composite = 1`, `NTSC_VERTICAL_COMB = 1`, `LO_RES_TEXT = 1`,
  `comp_hue_adj = 0`, bright/sat/contrast offsets 0.
- `interact.json` holds only "Reboot on load" - deliberately unchanged. The
  proven `01F0xxxx` read-back wildcard is byte-identical to the 09:26 form,
  which matters because the option-word delta is what broke disk loading on
  silicon during the J7/J9 bisection.
- Core version bumped 0.2.3 -> **0.2.4** so this image is distinguishable from
  main's hardware-verified sound build (both were 0.2.3; the sound NOTE already
  records card-version confusion as a past annoyance).

## Compile (Quartus 17.0.2 Lite, 5CEBA4F23C8)
- Coherent full run 22:14 -> 22:23 (9:04), 0 errors, 0 critical warnings.
- A&S 2:17, Fitter 4:31, Assembler 0:08, TimeQuest 0:23.
- Fast because of file-based RAM init (`7e1e064`); the nested 256x256
  procedural zero-fill loops this replaces cost ~19 min of single-threaded A&S.

## Resources
| | main 21:16 sound | this build | delta |
|---|---|---|---|
| ALMs | 8,141 | 8,926 (48%) | +785 (NTSC pipeline) |
| registers | 6,755 | 7,975 | +1,220 |
| block memory bits | 1,527,836 | 1,544,220 (49%) | **+16,384** |
| DSP | 4 | 26 (39%) | +22 |
| PLLs | 2 | 2 | 0 |

The +16,384 bits is exactly the decoder's `linebuf_mem` (1024 x 16) inferring as
**two M10K** - `altsyncram:linebuf_mem_rtl_0 ... M10K block ; Simple Dual Port`.
Any other delta would mean RAM inferred that should not have been; this is the
gate that separates the port from the earlier Q17 register blow-up
(Error 276003/276007 -> ~500K logic registers -> Fitter 170011).

## Timing (Slow 1100mV 85C setup)
- mp2 **+1.274 ns**, clk_74a +5.274, bridge_spiclk +10.553, mp1 +30.920
- End Point TNS 0.000 on all four; worst-case hold +0.085 ns
- Unconstrained Clocks: 3, the known pre-existing set
  (`aud_mclk_divider[1]`, `audgen_mclk`, OSK `command_reset`). No NTSC signal
  appears as a clock anywhere in sta.rpt, so the port adds no gated clock and no
  new timing blind spot - unlike `joy_clk`.
- Note mp2 moved 0.859 -> 1.274 ns between the NTSC-only build and this one,
  purely from placement after the speaker merge. The 0.859 figure was placement
  luck, not a structural cost of NTSC.

## Fold-away verification (map/fit reports)
- `vga_controller` fully removed: 969 registers "Lost fanout", 213/74/71/23
  "Stuck at GND/VCC", and **0 hits in fit.rpt** (no placed logic survives).
  Caution when re-checking: those rows live in the "Register name ; Reason for
  Removal" table, and the reason is in a SEPARATE COLUMN, so a keyword filter on
  the name column shows ~819 false "survivors". Check the fitter hierarchy.
- Dead-code chain also removed: `v_abs`, `d_mean`, `alpha_adapt`, `hs_i` 0 hits;
  `dacc` Lost fanout; `pix_out` "Explicitly unconnected"; `hs_out` "Connected to
  dangling logic". This validates the deadness analysis itself, not just the
  rewrite.

## Pre-hardware validation (Verilator, all PASS after the merge)
- `verilog/verilate_ntsc_parity.sh`: 0 mismatches / 3,823,104 cycles / 16 frames,
  golden donor vs generated q17, all 4 comp_preset x 4 SCREEN_MODE.
  SCREEN_MODE=0 produced 51,308 chromatic pixels, max channel spread 255.
- `verilog/verilate_osk_transparency.sh`: RGB_IN=1 passes a chromatic background
  through bit-exactly (0 / 188,760 failures); RGB_IN=0 reproduces the original
  1-bit expansion exactly (protects the 5 pre-existing OSK callers).
- `verilog/verilate_ntsc_reset_recovery.sh`: after a 16-cycle reset injected
  mid-active-video (2,075 bad pixels) and during vertical blanking (1,608), exact
  recovery within ~4 lines; raster legal throughout; q17 rewrite reset-equivalent.
- `verilog/run_joy_suites.sh`: tb_joystick_input, tb_paddle_gameport,
  tb_joy_gate (incl. freeze-on-OSK) all OK.
- `verilog/verilate_wrapper.sh`: tb_wrapper_kbd PASS.
- `verilog/tb/run_tb_speaker_i2s.sh`: PASS.
- `pocket_boot --smoke`: BOOT OK frames=10, crc=74EA1324 (M1 golden), fb=560x191.

## Known gaps - what simulation could NOT prove
- **No integrated colour screenshot exists.** DOS 3.3 boots to 40-column TEXT,
  which is monochrome on a real Apple II, so the boot harness measures max channel
  spread 0 whether or not the decoder works. Colour is proven at the pipeline
  (51,308 chromatic px) and at the OSK glue (0/188,760 failures) separately, and
  the J11 green drive-status LED proves the integrated transport carries non-gray
  pixels (8 chromatic px, first 00FF00) - but the full chain has never been seen
  producing NTSC artefact colour. **This is the primary thing hardware must show.**
- Open-OSK blend over a chromatic background is untested (OSK-closed only).
- Colour re-acquisition after a real disk swap is untested (sim models a 16-cycle
  pulse, not the full cold_reset_m + RAM-sweep sequence).

## Bitstream
- apf_stream_video.rbf sha256: a1167efd3e60ca3bbb2b851a56dd35cbe2179e90fcb63043a434cb371c028017
- staged bitstream.rbf_r sha256: 239eb6666cb838f13000e3f39689c47b986f94ec1b5edd923e0b981f253d614d

## Hardware test checklist (owner)
1. Card copy shows core version **0.2.4** - if it shows 0.2.3 or 0.2.2 the
   package did not sync.
2. Delete `/Settings/Newsdee.Apple2eStreamVideo/Interact/interact_persist.json`
   on the card before first run: it may hold a stale clobbered value from the
   J7/J9 joystick bisection builds.
3. Boot DOS 3.3 and Jungle Hunt from WOZ - disks must load (this is the
   regression that the J7/J9 bisection chased).
4. **Colour check**: run a LORES or HIRES program (e.g. a Total Replay title or
   any HGR demo). Text screens will be monochrome and prove nothing.
5. Check colour re-acquires after a disk swap (cold reboot path).
6. Joystick: Absolute mode, fire on PB0/PB1, paddle centre button; OSK open must
   freeze the paddles.
7. Audio: 555 speaker tone, no DC pop (regression check on the sound merge).
8. Report the observed picture; do not assume the sim results transfer.

## Hardware results
- pending
