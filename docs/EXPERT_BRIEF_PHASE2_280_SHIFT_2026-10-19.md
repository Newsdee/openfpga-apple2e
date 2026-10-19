# Expert brief — Apple IIe Pocket core: 280-px stream renders shifted-left on hardware

Date: 2026-10-19
Project: `Newsdee/openfpga-apple2e` (Analogue Pocket / openFPGA APF, Cyclone V 5CEBA4F23C8)
Status: sim-clean, hardware artifact; one empirical fix staged; seeking APF-scaler knowledge.

## 1. What the core does

A native Apple IIe hardware core (6502 + BIOS + 64K + native video + full-color on-screen
keyboard, all in one 14.318 MHz-class machine clock domain) streams its raster directly to
the APF DDR video pad — no full-frame buffer (thin-adapter pattern per the pinned
`agg23/openfpga-NES` reference). Machine native raster: 560 active px × 192 lines,
~910–1041 machine clocks/line (measured ~1041 in this port), ~262 lines/frame, ~52–60 Hz.

## 2. Proven-good streams on this exact hardware

| # | Stream | DE geometry (machine clocks) | Manifest | Hardware result |
|---|--------|------------------------------|----------|-----------------|
| 1 | Phase 1 pattern gen | HS@H=0, DE@H=2..561 (560 px) | 560×192 @ 70:24 | **Clean**, full width, correct aspect |
| 2 | Phase 2 machine 560 (no decimation) | HS@H=5, DE@H=350..909 (560 px) | 560×192 @ 70:24 | **Clean** (OSK full color verified) |

Both use the same APF wrapper (`apf_top`, `mf_ddio_bidir` DDR pads from `video_rgb_clock`
+ 90° copy) and the same machine clock as `video_rgb_clock`.

## 3. The 280-px decimation effort (2:1 horizontal, even samples)

Goal: stream the Apple II's logical 280×192 raster (better aspect on the portrait Pocket
screen; APF accepts active widths down to 16 px).

**Attempt 1 — strobed DE (no buffer):** DE emitted on even machine samples only
(non-contiguous: on-off-on-off…). Sim contract clean. **Hardware: solid pink screen**
(APF rejects; a few black lines flickered when toggling the OSK). → Conclusion: the APF
needs contiguous DE, like a normal video raster.

**Attempt 2 — 1-line buffer, contiguous window** (280×24-bit buffer ≈ 1 M10K; even samples
written during the machine active window, read back as one contiguous 280-clock DE window
in the following line's blanking; exactly 192 windows/frame; HS still fires on every
machine line; HS/VS placement identical to stream #2):
- sim: all APF contract checks PASS (RGB=0 outside DE, 1-cycle HS/VS pulses, HS/DE gap,
  280 px/line, 192 lines/frame, bounded $finish)
- variant 2a: window at **H=25..304** (20 clocks after HS): **hardware renders the image
  shifted LEFT — content left-aligned with a black band on the right** ("left side of the
  image hidden"). Everything else (color, OSK, text) is correct.
- variant 2b: window at **H=350..629** (345 clocks after HS — the *exact* DE start position
  of proven stream #2): sim PASS (min HS→DE separation = 345). **Not yet tested on hardware
  (compile in progress).**

## 4. Questions for the expert (APF scaler/frame-builder internals)

1. What determines the scaler's **horizontal placement** of an accepted stream? Is the
   left-shift of variant 2a expected behavior (e.g., the frame builder anchors the line
   start relative to the first DE, or to HS + a fixed back-porch), or does it indicate the
   stream was still outside the APF's comfort zone?
2. Is the **DE window position within the machine line** significant at all (20 vs 345
   clocks after HS), or only the DE count / pulse widths / HS-VS cadence?
3. Is there a canonical raster shape the APF frame builder prefers for narrow rasters
   (e.g., DE start offset, minimum back porch, max line period, line-tail blanking)?
4. `video.json` declares up to 8 `scaler_modes` ("slots"). The Pocket UI does **not** appear
   to expose mode selection to the user (only the default slot 0 is used). Confirm: is slot
   selection core-driven only, via the **end-of-line bits** (RGB word right after DE falls:
   `[2:0]=000` → "set scaler slot to [23:13]", default all-zero = slot 0)?
5. If yes: any gotchas for a core button that cycles slots at runtime (e.g., must the word
   be on the *first* cycle after DE falls, every frame, or once? "Last request wins,
   effective next frame" — does a one-shot word latch the slot permanently?).

## 5. Planned "stretch to fill" core option

The owner wants a user-selectable "fill the screen" mode (true-aspect is letterboxed on the
portrait screen). Options:
- (a) reorder `video.json` so the stretch mode is slot 0 (default) — what we have staged now
  (1:1 first, then 35:24, then 4:3);
- (b) a real core option: an unused Pocket button (trig-R2) cycles slots 0→1→2 by emitting
  end-of-line words.

Expert input on (4)/(5) decides whether (b) is reliable.

## 6. What to do next (independent of the review)

User is recompiling `apf_stream_video.qpf` (variant 2b: window at H=350..629). If the
shift disappears → timing-position was the cause; the "stretch" question remains for the
expert. If the shift persists → it is width/manifest-related and the expert's input on (1)
becomes the priority.

## 7. Files

- Adapter: `src/fpga/core/apple2e/apf_stream_video.v` (parameter `DEC2X=1` line buffer)
- TB (decisive, bounded): `verilog/tb/tb_phase2_shots.sv`
- Pixel-content TB: `verilog/tb/tb_decim_coord.sv` (deterministic coordinate pattern)
- Manifest: `sd_root/Cores/Newsdee.Apple2eStreamVideo/video.json` (3 modes)
- Captures: `verilog/shots/phase2_frameA.png` / `phase2_frameB.png` (sim, clean)
- Hardware capture of the shift: `WIN_20261019_21_07_54_Pro.jpg` (owner's gallery)
- Prior brief (HS/DE sync fix, same adapter): `docs/EXPERT_BRIEF_PHASE2_SYNC_2026-10-19.md`

## 8. Expert review received — findings accepted and applied

**All three data-path bugs were real (and mine). The left-shift was not an APF
scaler-placement issue.** Corrections applied to `apf_stream_video.v`:

- **A (counter/address truncation):** `wcnt` is now 10-bit (counts to 559);
  `waddr = wcnt[9:1]` (full 0..279). Previously: 9-bit `wcnt` wrapped at 512 and
  `wcnt[8:1]` is 8 bits, so addresses 256..279 were never written (stale right
  strip) and samples 512..559 overwrote addresses 0..23 (corrupted left edge).
- **B (write off-by-one):** the staged `wr_data` register was removed; the RAM now
  receives `rgb_in` directly on `wr_en` (the staged version delivered the
  previous even sample).
- **C (window overlap):** the read window moved BACK to H=25..304 (RD_START=20):
  fully inside HBL, disjoint from the write phase (H=350+). The H=350..629
  position is documented in the DUT as rejected (overlaps writes; broke the
  line-ownership guarantee; confounded the hardware experiment).
- Writes are now gated `&& DEC2X` so the shipping DEC2X=0 build drops the RAM.

**Pixel-content verification (new TB `tb_decim_coord.sv`)** — synthetic raster,
`rgb_in = {line_id, sample_index}` during active, verifies all 280×192 = 53,760
output pixels of every frame equal `{line_id, 2k}` (emphasis on k = 0,23,24,255,
256,279 and first/last lines), plus the APF contract basics. Bounded `$finish`,
`$fatal` on any mismatch:

- **Fixed DUT: PASS** — `COORD frame 1/2: 53,760/53,760 pixels correct`, all
  contract checks 0. Machine-based `tb_phase2_shots` also PASS (real BIOS + OSK
  frames captured clean).
- **Negative control: the reconstructed buggy DUT (9-bit counter + staged
  write) FAILS the same test with 53,760 mismatches** — the test provably
  detects the original defects.

**Shipping decision (per expert recommendation):** the Pocket core now ships the
**proven 560-px stream** (`apf_stream_video_top.v` instantiates
`#(.DEC2X(0))`). Aspect/stretch options are pure `video.json` presets on the
560×192 raster: 70:24 (true, default), **10:9** (Pocket LCD is 1600×1440 —
full-panel fill), 4:3. 560 samples are preserved for 80-column text / HGR /
native-width OSK. (Note: fitter report allocates **two** M10Ks to the line
buffer — corrected in this brief's record.)

**280-px experiment status:** fixed and pixel-verified in sim (above). NOT yet
re-tested on hardware — and per the expert, the next hardware iteration of
280-px output should use the documented **`video_skip`** mechanism (contiguous
DE over the source active interval, SKIP asserted on unwanted samples) rather
than the line buffer; the coordinate TB's expectation then becomes "280
ACCEPTED pixels", and the blanking-RGB check must allow the valid end-of-line
metadata word (all-zero = slot-0 request — a one-shot slot-N request is
overridden by subsequent zero words, so a slot register + persistent emit is
required for runtime switching).
