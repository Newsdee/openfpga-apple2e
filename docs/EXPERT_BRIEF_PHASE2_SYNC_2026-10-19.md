# EXPERT BRIEF — Phase 2 streaming video: sync fix verified in sim, hardware re-test pending
**Date:** 2026-10-19 · **Repo:** `apple2e-pocket` · **Branch:** `main` (Phase 2 files not yet committed)
**Companion doc:** `docs/PHASE2_STATUS_HANDOFF_2026-10-19.md` (full state)

## 1. Background in 3 lines

Phase 2 streams the Apple IIe's native raster (560×192 active, 14.318 MHz)
directly to the APF DDR video pad — no frame buffer (M10K/PSRAM-free path,
following the pinned NES Pocket reference). First hardware attempt showed a
bad image (black top band, uniform pink middle band, blue garbled text at
bottom; buttons had no visible effect). An expert review found a definite
video-protocol violation in the new adapter; that fix is now implemented and
**verified in Verilator**. Hardware re-test is the next gate.

## 2. What was wrong (accepted expert finding #1)

`apf_stream_video.v` originally generated HS on the HBL *falling* edge — the
very cycle DE first asserts. Result: **HS and DE high together on every
visible line** (steady-state violation of the APF HS/DE spacing rule; Phase 1's
proven pattern generator kept them apart). A "wait N frames" gate would not
have fixed it — correct.

### Fix applied (machine-anchored, per expert recommendation)

Machine per-line structure (measured/derived from `timing_generator.v`):
HBL high for the first ~350 clocks of each 910-clock line (line start),
DE active for the next 560 clocks; VBL band = first 70 lines of each frame;
VBL falls exactly on a line boundary.

```verilog
wire hbl_rise = ~hbl_r & hbl;                    // line start, inside HBL
reg  [2:0] hs_dly;                                // 1..6 after hbl_rise
wire hs_pulse = (hs_dly == 3'd5);                 // 1 cycle, 5 clocks after rise
wire vs_pulse = (vbl_r & ~vbl) & hbl;             // frame start, gated to blanking
```
- HS fires 5 clocks after the line-start HBL rising edge → always inside
  blanking, 328 clocks before DE. No free-running raster, no dropped pixels.
- VS fires at the VBL falling edge, gated to HBL-high (can only fire in
  blanking; the frame-start boundary is HBL-high by construction).
- DE unchanged: `!hbl && !vbl` (all 560 pixels, none discarded).

## 3. Testbench fixes (accepted expert findings #2 and #3)

`verilog/tb/tb_phase2_shots.sv` (machine + OSK + `apf_stream_video`, the exact
Phase 2 DUT wiring):
- Bounded completion: `$finish` at 2.33 s (previously ran forever; `final`
  never ran; the PPMs from the run before these fixes are **not** evidence).
- One-shot capture flags (`cap_a`/`cap_b`) — frame-counter wraps can no
  longer overwrite the documented boot/OSK frames.
- The actually-failing rule is now checked: **HS/DE overlap** (and HS→DE
  separation ≥ 1 blank clock).
- Line width 560 and exactly-192-lines-per-frame are **hard failures**, not
  print-only.
- Watchdog: first VS within 10 M clocks (the TB holds reset for ~4.2 M
  clocks, so nothing can sync before that — an earlier 400 k threshold was
  wrong for this harness).

## 4. Sim results (after DUT fix) — PASS

```
PHASE2 frames seen: 122 (33,285,714 cycles total)
PHASE2 rgb-nonde violations:   0 (expect 0)
PHASE2 pulse-width violations: 0 (expect 0)
PHASE2 HS/DE overlap viol.:    0 (expect 0)
PHASE2 min HS->DE separation:  328 (expect >= 1)
PHASE2 min VS->HS gap:         4   (expect >= 3)
PHASE2 bad line widths:        0 (expect 0)   <- 560 px/line
PHASE2 bad frame line counts:  0 (expect 0)   <- 192 lines/frame
PHASE2 APF contract PASS
```
Captured frames (`verilog/shots/phase2_frameA.png` / `phase2_frameB.png`):
- **frameA** (~0.6 s, OSK closed): machine booted, "Ready." prompt + cursor.
- **frameB** (~1.7 s, OSK open after Q+Enter stimulus): full-color OSK panel
  renders correctly — beige panel `0xD0C4B1`, gray keys, white key labels,
  Apple logo, CMO badge. **No pink anywhere in the composited content.**

## 5. Interpretation

- The composite *content* is clean in sim. The hardware pink band is most
  plausibly the APF's reaction to the (now-fixed) HS/DE overlap — the Phase 1
  prototype proved the APF accepts this geometry when the contract is clean.
- Two pre-existing, out-of-scope observations (flagged, not chased):
  1. **Machine polarity:** this port renders the machine TEXT screen as
     white-on-black (inverted vs. a real Apple IIe). Identical in the old
     P2b sim capture (`shots/machine.png`, `shots/frame.png` — known-good,
     hardware-verified P2b build) and the new harness. If the owner considers
     it wrong, it is a separate machine/OSK video-polarity issue.
  2. **Frame rate ≈ 52.4 Hz** (measured frame period 272,834 machine clocks;
     i.e. the core's native frame, longer than the 910×262 = 238,420 assumption
     used in Phase 1). Inside the APF 47–~61 Hz window, but note the core's
     native line period is ~1041 clocks, not 910 — Phase 1's pattern generator
     ran at a slightly different cadence than the machine.

## 6. What I want the expert to confirm (the only open questions)

1. Given the §2 fix + §4 sim PASS, is there **anything else in the APF video
   contract** that could still reject/mis-render this stream on hardware?
   Specifically: 52.4 Hz frame rate, ~1041-clock line period, VS position
   (line boundary inside the 70-line VBL band), and the `video.json` manifest
   (560×192, aspect 70:24).
2. Is a **recompile + Pocket re-test** the correct next gate, or do you
   recommend one more sim-level check first (e.g. capturing the raw DUT
   HS/VS/DE waveforms around frame start for visual inspection)?

## 7. Next step (owner)

Recompile the Phase 2 revision with the fixed adapter (no source changes
elsewhere), restage `Newsdee.Apple2eStreamVideo`, re-test on the Pocket:
```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket
apf_stream_video_build.bat
```
Expected if the sync fix is sufficient: black machine background (the
white-on-black polarity above), "Ready." text at the top, beige full-color OSK
panel at the bottom, button interaction visible (START toggles the panel).
