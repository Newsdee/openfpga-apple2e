# Video edge-probe results — PLAN_VIDEO_40COL_ENCODER_EDGE_2026-11-25

**FINAL VERDICT (2026-11-26, hardware round 3): ALL MODES ALIGNED — owner
confirmed "perfect! it's all aligned as I expected".** Shipped candidate =
commit `cb9455c` (branch `video-40col-diag`), bitstream sha256
`8df43c03…0ee089`, deployed to K: and verified. Fix = Pocket-glue
`HBL_ALIGN=6` delay pipe on `ntsc_hbl`, bypassed when `m_early_video`
(COL80 | HIRES&DHIRES) — the donor's own early-grid flag, previously dead
on Pocket.

**Baseline:** worktree `apple2e-pocket-video` @ `53451f9` (0.4.5, released).
No RTL modified. Design as shipped: `video_pipeline_q17` NTSC_EN=1, real
`video2.hex` ROM, shipping `apf_stream_video` adapter (DEC2X=0).

**Tooling:** `fixture_gen.py` (6502 fixture programs), `tb_video_edge.sv`
(self-driving TB on the real `stream_video_core_top` + tb_dram_model + host
bridge; fixture injected by RAM deposit + ROM reset-vector patch + host
re-reset — CPU draws the scene through real soft-switch accesses; no video
state forced), `run_edge.bat` (AV-chained build+run).

**Reproduce:**
```
cd verilog/edge_probe
run_edge.bat gr   0 67     & rem GR mixed, graphics row 8 (scanline 3)
run_edge.bat t40  0 83     & rem TEXT40, row 10 scanline 3
run_edge.bat t80  0 83     & rem TEXT80, row 10 scanline 3
run_edge.bat hgr  0 67     & rem HGR marker line (see coordinate note)
run_edge.bat t40  1|2|3 83 & rem preset sweep
```
Outputs: `edge_<mode>_p<preset>.csv` (per-tick, four boundaries),
`edge_<mode>_p<preset>.ppm` (native 560-wide frame), `run_*.out` transcripts.
Edge convention: tick 0 = first 14.318 MHz sample after the machine HBL fall
of the captured line; values sampled ~1 ns after the rising edge.
DE sample s = tick − 17 on every captured line (DE start is constant).

## Results rows (preset 0 = default NTSC unless noted)

| mode | preset | line_cnt | DE run | col0/left marker first_lit (expected 0) | interior first_lit (expected 266/280) | right marker first_lit (expected 546) | verdict |
|---|---|---|---|---|---|---|---|
| GR mixed | 0 | 67 | 560 @ tick17 | **6** | 271 / 280 | **551** | +6 uniform shift |
| TEXT40 | 0 | 83 | 560 @ tick17 | **6** | 272 (col19) | **552** | +6 uniform shift |
| TEXT80 | 0 | 83 | 560 @ tick17 | **6** (of 0..6 window: only last sample lit) | 272 | **552** | +6 uniform shift, COL80=1 verified |
| HGR | 0 | 67 | 560 @ tick17 | **6** (window 0..27) | 370 (exp 364) | 538 (exp 532) | +6 uniform shift |
| TEXT40 | 1 | 83 | 560 | 6 | 272 | 552 | identical |
| TEXT40 | 2 | 83 | 560 | 6 | 272 | 552 | identical |
| TEXT40 | 3 | 83 | 560 | 6 | 272 | 552 | identical |

All runs: one contiguous 560-sample DE run, 192 visible lines (fb_h=191
last-index convention), black RGB outside DE, no early `track_data_valid`-
style anomalies, mode state logged (TEXT/HGR/COL80/GR2) — never inferred.

## First divergence (plan §3) — decoder hshift alignment constant

**Encoder admission passes every marker** (decision-table row 2 rejected):
on the GR line, `m_video`=1 and `video_sample`=1 for ticks 10–23 (col-0
cell), `comp`=36 (V_WHITE) on exactly those ticks — zero valid marker dots
replaced by blank/sync/burst. Boundary 1 also clean: DLB dump shows the
fixture bytes loaded at the correct cell slots (LDPS falls every 14 ticks;
HGR line shows dl=$7F at byte indices 0,1,26,27,38,39).

**The divergence is between decoder output and the DE window.** Decoded
`g_comp` crosses the black/white midpoint 6 samples after DE start at the
left edge — and every interior/right marker is equally shifted +6. This is
a **uniform translation, not first-edge attenuation** (plan's distinction).

Mechanism, fully identified in `machine/video/video_pipeline_q17.sv:284`:

```verilog
wire [4:0] hshift_idx = HSHIFT_COMP[4:0]                      // 14
                      + ((p_smear != 4'd0) ? HSHIFT_SMOOTH : 0)  // +7 smoothing
                      - (HGR80_MODE ? 5'd1 : 5'd8);              // <-- -8 all normal modes
wire hb_c_s = hb_c_pipe[hshift_idx];   // -> ntsc_hbl -> adapter DE window
```

The adapter (`apf_stream_video.v`) builds `video_de = !hbl && !vbl` from
`hb_c_s` — the decoder-reconstructed HBL **advanced 6 taps** (14−8) for all
modes except HGR80 (advanced 1). Decoded RGB carries the full decoder
latency, the window does not, so content sits +6 samples right inside the
window: left 6 DE samples show pre-line black (the reported strip), right
edge loses 6 samples. Preset-independent because smear adds +7 to both
sides. The −8 is **donor (MiSTer) calibration for vga_controller**; the
Pocket adapter derives DE differently. The separate HGR80 −1 ("aligns its
CTV content to x0") confirms these taps are per-consumer calibration.

## Hardware A/B round 3 (2026-11-26, owner, K: card) — FINAL

Candidate = EARLY_VIDEO-keyed bypass (sha256 `8df43c03…0ee089`, compile
9:10, TNS 0.000, slack 1.745, RAM gate PASS):
- DHGR-16: aligned (was slightly left in round 2).
- DHGR quirk, TEXT80, 40-col TEXT, GR, HGR: all confirmed aligned.
- Owner verdict: "perfect! it's all aligned as I expected."

## Hardware A/B round 1 (2026-11-26, owner, K: card)

Candidate = uniform HBL_ALIGN 6 (sha256 `562588…93ab3`):
- **40-col TEXT + GR mixed: FIXED** (owner-confirmed on panel).
- **DHGR regression**: shifted ~1-2 px left, >=3 black pixels on the RIGHT
  edge (`K:\Memories\Screenshots\20261126_102930.png`) = the uniform +6
  over-shifting the HGR80 quirk window (donor tap already -1 vs -8, i.e. 7
  later than normal modes; content window documented as samples 7..566 in
  machine/apple2.v:458).

## Fix round 2: mode-aware HBL_ALIGN (applied, sim-verified)

`ntsc_hbl_aligned = m_hgr80_mode ? ntsc_hbl : hbl_align_pipe[5]` — zero glue
delay in the DHGR quirk state (restores its exact pre-fix window), 6 clocks
everywhere else. Sim: dhgr fixture shows HGR80=1 and DE start tick 24
(= donor tap-13 window, identical to pre-fix); t40 still tick 23 with
first_lit=0/266/280/546 ALL PASS; eol_guard clean (Quartus's CRLF smudge on
build_id.mif repaired to LF).

Hardware round 2 verdict (owner): "that's better" — DHGR quirk improved,
HGR fine, 40-col still fixed; but 16-colour DHGR (COL80 on) still slightly
left → round 3 re-keyed the bypass on EARLY_VIDEO (see above; FINAL).

## Candidate fix APPLIED + verified in sim (2026-11-25, owner approved)

`apf_stream_video_top.v`: new `HBL_ALIGN = 6` delay pipe on `ntsc_hbl`
(mirrors the `VBL_ALIGN` precedent); `sel_hbl` now feeds the aligned HBL to
OSK + adapter. Donor/q17 files untouched.

Post-fix scoreboard (same harness, same fixtures):

| mode | preset | DE start tick | first_lit (expected 0 / interior / right) | verdict |
|---|---|---|---|---|
| TEXT40 | 0 | 23 | **0 / 266 / 280 / 546** | ALL PASS, exact |
| TEXT40 | 1 | 30 | 0 / 266 / 280 (+7 smear shift moves window & content together) | ALL PASS |
| TEXT40 | 2 | 23 | 0 / 266 / 280 | ALL PASS |
| TEXT40 | 3 | 30 | 0 / 266 / 280 | ALL PASS |
| GR mixed | 0 | 23 | 0 / 266 / 280 / 546 (col19=$F0 dark on scanline 3 by design) | ALL PASS |
| TEXT80 | 0 | 23 | 0 / 266 / 546 + window[3] dark (see right-edge finding) | see below |
| HGR | 0 | 23 | **0 / 364 / 532** | ALL PASS |

PNG check: `edge_t40_p0_x3.png` row 83 white run now starts at x=1 (single
ramp sample at x=0); left strip gone. DE still exactly 560 contiguous
samples/line, one run, HS/VS structure unchanged (6 ticks later).

## Secondary finding: 80-column LAST cell is dropped (pre-existing, unmasked)

Post-fix, TEXT80 window[3] (display col 79, DE samples 553..559) is dark.
This is NOT caused by the fix - pre-fix the col-78 content shifted into that
window masked it, and col 79 was always off-window. Mechanism, measured:

- Machine closes its video window early: `m_hbl` rises at tick ~557,
  `WNDW_N` at ~558, but the 80-col serializer runs to tick ~568 (cells are
  7 ticks; 40-col cells are 14). The last ~12 ticks of content are emitted
  outside `WNDW_N`.
- Encoder recovers that tail via its right-edge exception (`hb && in_fporch`
  keeps emitting video, `in_fporch` = encoder hcnt 713..841) - measured:
  encoder `comp` = V_WHITE (1497380, 24-bit Q voltage) through tick ~561.
- Decoder clamps it: reconstructed blanking `hb_i = hpos<HB_END(220) ||
  hcnt>=front_at(line_len-FRONT_PORCH 132)` blanks the line tail. White
  decoder output ends at DE sample 552; samples 553..559 = blanking black.

Net: the last 80-col cell (~7 samples) dies in the encoder-porch vs
decoder-front_at tug-of-war. 40-col modes end cleanly at 559 (their last
cell fits inside the machine window). Any change here touches donor decoder
constants (`FRONT_PORCH`/`HB_END` in `composite_decoder_q17.sv:120-121`,
whose comments record a prior purple-seam incident at FRONT_PORCH=124) ->
owner decision required; hardware A/B should check whether real panels show
a dark last 80-col column today.

## Candidate fix (original proposal, superseded by the applied version above)

Pocket-glue only, mirroring the existing `VBL_ALIGN` precedent (the top
already delays donor VBL_O by 32 to fix a donor contract mismatch without
touching pinned files): delay `sel_hbl` 6 clocks before the OSK/adapter so
the DE window starts where decoded content starts. Donor and generated q17
files stay byte-pinned; parity harness untouched.

Expected post-fix, verifiable with this harness: first_lit = 0/266/280/546
(40-col) and 0/364/532 (HGR) at every preset; DE still one contiguous
560-sample run; HS/VS **structure** unchanged but shifted 6 ticks (0.42 µs)
— note this technically violates the plan's literal "baseline-identical
HS/VS/DE every clock" gate wording; the gate should be read as "structure
identical, deliberate 6-tick translation, nothing else changed". Hardware
A/B decides.

## Coordinate caveat (diagnostic only) — STILL OPEN

`line_cnt` (HBL falls after VBL fall) does NOT match textbook display-line
numbering, and HGR addressing does not follow the standard
`$80*(L&7)+$400*((L>>3)&7$28*(L>>6)` formula as indexed by line_cnt: the
$2828 marker (textbook HGR line 80) serializes at line_cnt 67 (and a masked
re-fetch at 130); a probe fixture at computed addresses for lines 66/70
loaded $7F at line_cnt 13/205/237 instead. Text/lo-res rows behave sanely
(row 10 -> line_cnt 83 = row*8+3, marker spans verified at 82/83). Affects
probe aiming for HGR lines only; the shift measurement is unaffected (DLB
byte-index dumps prove content identity on the captured line). Map the
V-counter/timing-generator addressing if HGR line-specific probes are ever
needed.

## Not yet done

- Owner decision on the 80-col last-cell right-edge finding (pre-existing,
  donor decoder constants).
- sim dhgr16 fixture does not reproduce the 7-tick interleaved DHGR fetch
  (serializer ran plain-HGR pitch) - fix if DHGR sim measurement ever needed.
- Mixed-mode boundary lines (GR row 19/20 transition) - harness ready.
- HGR line_cnt coordinate map (probe aiming only).
- Deferred: SDL video preview .bat with preset hotkeys (TASKS.md item 8).
