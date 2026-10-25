# Build 2026-10-25 — HS/VS ordering fix for the 1st-line colour artifact (candidate 0.2.5)

Status: RTL fixed + sim-verified. **Awaiting owner Quartus compile + hardware test.**
Do NOT ship as 0.2.5 until the hardware test passes.

## Symptom (owner report, 0.2.4 hardware, 2026-10-25 22:2x)

Colour mode works, but the **1st visible line** of the screen is corrupted on every
colour title (Jungle Hunt, Carnival, Oregon Trail). Four Pocket screenshots on
`I:/Memories/Screenshots/20261025_2222xx.png`.

Pixel analysis of the four screenshots (PIL):
- **row 0 is a fixed rainbow subcarrier strip** — full width (559/560 bright px),
  identical pixels in all four screenshots:
  `left10 = [(90,69,165),(198,12,255),(189,85,247),(206,93,247),(0,36,24),(66,174,57)]`
  (a smooth hue ramp = pure colour subcarrier, no luma).
- rows 1.. are the correct screen content.
- Content-independent + identical across screens = NOT decoded video content:
  the framework is displaying something our stream emits only in blanking
  (the composite colour burst region).
- 0.2.3 (mono) had no such artifact (mono blanking carries no subcarrier).

## What was ruled out in simulation (all clean)

1. **Pipeline (shipping q17 tree)** — `verilog/tb/tb_ntsc_line0.sv` +
   `verilog/verilate_ntsc_line0.sh` (new, machine-true geometry: 122..511 V
   counter, two 64-line VBL regions, HGR block 256..447): first line after VBL
   decodes identical to later identical lines (white==white, black==black),
   left edge of black lines carries no colour, exactly 1 HBL_O fall per line
   (no glitches). Note: a first TB iteration with *simplified* 54-line-VBL
   geometry showed a line-0 anomaly — that was a stimulus artifact; the
   machine-true geometry is clean. (Lesson: don't assume line-0 bugs transfer
   across VBL geometry.)
2. **Full machine + pipeline + adapter** (`tb_pocket_boot` smoke, NTSC_EN=1):
   streamed frame = **192 DE windows**, first DE on line 0, lines 0..3 all
   carry DE, left edge clean (boot screen), frame rate 59.94 Hz (262 machine
   lines per VS). The sim frame NEVER shows the rainbow — the artifact is
   hardware-only.
3. **Blanking RGB contract**: the adapter already zeroes `video_rgb` outside DE
   (`apf_stream_video.v` default `video_rgb <= 24'h0`), so the framework sees
   0x000000 in blanking (sideband words = all-zero = no rescan/interlace,
   function 0 / slot 0). No violation here (the 0x191919 black level is internal
   to `ntsc_rgb` only).

## Root cause candidate (provable contract violation)

APF video contract (Analogue docs + KB-014): **"HS: one-cycle pulse per line,
not until 3 cycles after VS"** and "a VS in the middle of HS timing can wedge
the scaler".

Measured in the full harness (temporary SYNC/EDGE probes in
`tb_pocket_boot.sv`, logs `run_vs4.log` / `run_hs.log`):
- Frame line: **HS fires at hpos 5, VS fires at hpos ~42-47** (VS = VBL_O
  falling edge delayed by VBL_ALIGN=32 + latency). → **HS 37-42 cycles BEFORE
  VS — contract violation on every frame.**
- vs period = exactly 262 machine lines (pipeline VBL_O free-running cadence);
  HS = one per machine line (262 per frame span).

Mechanism (unproven but consistent): with HS-before-VS on the frame line the
framework's line/frame bookkeeping can latch the frame start one line early —
i.e. display the line BEFORE our first DE line (a machine VBL line, whose
composite is pure subcarrier → the fixed rainbow strip) as its row 0.

## Fix (this change)

`src/fpga/core/apple2e/apf_stream_video.v` (our code, NOT byte-pinned):
- HS moved from 5 to **60 clocks after the HBL rising edge** (`hs_dly` 3-bit→7-bit).
  Frame line: HS hpos ~60+latency(79 measured) vs VS hpos ~45 → **HS 34 cycles
  AFTER VS (≥3 required)**. Other lines: HS stays inside the ~350-clock HBL,
  ≥270-clock gap to DE, ≥~50-clock gap from DE-fall to next HS.
- DEC2X=1 read window `RD_START` 20→10 so the 280-clock window (H=70..350) still
  ends inside HBL with the new HS position. DEC2X=1 is NOT the shipping mode
  (DEC2X=0 ships); noted in-file that it needs re-verification if ever enabled.

Post-fix sim (`run_fix4.log`): HS hpos 79 vs VS hpos 45 (34 after ✓),
de_windows=192, first_de_ln=0, line_states=1111, frames streaming normally.

## Known uncertainty (read before testing)

The sim cannot reproduce the rainbow, so this fix is the best-available
candidate, NOT a proven cure. Two outcomes:
- **Rainbow gone** → contract violation was the trigger; ship 0.2.5.
- **Rainbow persists** → the mechanism is deeper (framework-side handling of
  the 262-line VS cadence, or a Quartus-synthesis difference in the pipeline).
  Next step: SignalTap on the Pocket build (see below).

## Suggested hardware test (owner)

1. Compile (Quartus), stage as 0.2.5 (bump `sd_root/.../core.json` at packaging).
2. Card I: copy core dir + `interact_persist.json` DELETE (unchanged from 0.2.4 procedure).
3. Boot a colour title (Carnival or Jungle Hunt via the WOZ disk).
4. **Check row 0 specifically** — is the rainbow strip gone? Is the top text
   line now correct content?
5. Rest of the 0.2.4 checklist (disk boot, joystick, audio) as regression.

### SignalTap plan if the rainbow persists

Capture on `clk_core_14318`, trigger on `video_vs`, depth ~2048 samples, probes:
- `video_de`, `video_hs`, `video_vs` (adapter outputs)
- `video_rgb[23:0]`
- `ntsc_rgb[23:0]`, `ntsc_hbl`, `ntsc_vbl` (pipeline outputs, pre-OSK)
- `sel_vbl` (the VBL_ALIGN output)
Confirm: (a) does `video_rgb` ever carry a subcarrier ramp on any line? (b)
where do HS/VS land relative to the first DE? (c) does `ntsc_rgb` differ from
sim on line 0?

## Files changed (this candidate)

- `src/fpga/core/apple2e/apf_stream_video.v` — the fix (HS timing, RD_START).
- `verilog/tb/tb_ntsc_line0.sv`, `verilog/verilate_ntsc_line0.sh` — new
  pipeline line-0/left-edge TB + runner (regenerates q17, donor byte-pin check).
- `verilog/pocket_boot/tb_pocket_boot.sv` — TEMPORARY SYNC/EDGE/DE-MAP probes
  (additive; clearly marked; removable before a clean commit).
- `sd_root/Cores/Newsdee.Apple2eStreamVideo/core.json` — bumped to 0.2.5
  (staging; ship only with the new bitstream).
