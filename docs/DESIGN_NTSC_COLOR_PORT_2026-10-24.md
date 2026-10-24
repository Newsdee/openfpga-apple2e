# Design note — porting the MiSTer NTSC colour path to the Pocket core

Date: 2026-10-24
Status: **design note, no RTL written.** Successor to
[`COLOR_PIPELINE_DECISION_2026-10-19.md`](COLOR_PIPELINE_DECISION_2026-10-19.md)
(closed) and [`MISTER_POCKET_COLOR_HANDOVER_2026-10-19.md`](MISTER_POCKET_COLOR_HANDOVER_2026-10-19.md)
(§1 current, §2/§3 historical).
Baseline: `origin/main` = `b9fe195` (M1 complete, WOZ floppy boot hardware-verified).

Scope: add Apple IIe composite colour (NTSC encode → decode, i.e. the artefact
look) plus RGB-monitor colour, by reusing the MiSTer video pipeline. This is
**Phase 3** of the closed decision doc's sequence; Phases 0–2 shipped.

---

## 1. Why this is a small job now

When the 2026-10-19 docs were written, the colour decision was a **storage**
problem: the shipping path buffered a whole frame in M10K, and RGB888 did not
fit. That problem no longer exists. Option D (native RGB streaming, no
framebuffer) was implemented and is hardware-verified, and **the chain already
carries 24 bits end-to-end**:

```
machine VIDEO (1-bit) + mode flags
  → apple2e_osk            (video_rgb24: full MiSTer colour + transparency)
  → sdram_status_overlay   (ovl_rgb: badge, status, mount state, M1 fingerprint)
  → apf_stream_video #(.DEC2X(0))   native 560 px/line @ clk_core_14318
  → APF DDR video pad
```

Commits: `b6efcf2` (Phase 1 prototype), `e1cfd2a` (Phase 2 native streaming +
full-colour OSK), `d7be961` (button remap, aspect presets). All marked
hardware-verified.

So the remaining work is **inserting an RGB producer where a 1-bit signal
currently enters**, not re-architecting storage.

Note `apf_video.v` (the old M10K ping-pong adapter) is still in the tree but is
**not instantiated** by the shipping top. It should be moved to `archive/` or
deleted; both 2026-10-19 docs budget against it, and a new engineer reading
them will otherwise plan against a module that isn't in the build.

---

## 2. Corrected facts that change the plan

Two claims made during earlier reviews of this work were wrong. Both are
corrected here so they do not propagate.

### 2.1 `vga_controller.v` is NOT a line-doubler

Its own header comment said *"A VGA line-doubler for an Apple ]["*, and that
comment caused a review to plan for a doubled 560×384 raster at 28.636 MHz —
implying a second PLL output, a new APF raster and new `video.json` presets.

**Verified against the body: it does not double anything.**

- `hcount`/`vcount` free-run on `CLK_14M` at native machine geometry.
- `assign VGA_HBL = ~filtered_timing_active;` and `assign VGA_VBL = vbl_delayed;`
  — native blanking, no line repetition.
- `previous_line_rgb[0:559]` × 24 b is a **one-line history for the vertical
  comb / HGR artefacting**, not a doubling buffer.
- `video_pipeline.sv` agrees: it derives composite sync *"from machine blanking
  using native geometry"* (`HSYNC_FRONT_PORCH=130`, `HSYNC_WIDTH=68`,
  `VSYNC_FRONT_PORCH=33`, `VSYNC_LINES=3`), and its outputs are
  `HS = use_composite ? hs_c_s : hs_vga` etc.

**Consequence: `video_pipeline` is a native-rate, `CLK_14M`-domain, 560×192 RGB
producer.** That is precisely the clock and raster the Pocket already streams.
There is no option-A-vs-option-B decision to make; the drop-in path is the only
path. No new PLL, no raster change, no `video.json` change.

The misleading comment in `Apple-II_MiSTer/rtl/video/vga_controller.v` has been
annotated (comment-only change, no logic touched) so the next reader is not
misled the same way.

### 2.2 Memory cost was overstated by 8×

An earlier estimate put `previous_line_rgb` at 107 Kbit. It is
**560 × 24 = 13,440 bits**. Correct totals:

| Array | Size | M10K |
|---|---|---|
| `composite_decoder.linebuf_mem[0:1023]` × 16 b | 16,384 bits | ~2 |
| `vga_controller.previous_line_rgb[0:559]` × 24 b | 13,440 bits | ~2 |
| **Total new memory** | **~30 Kbit** | **~4 of 118 free blocks** |

(`composite_decoder.ybuf` is `[15:0][15:0]` — registers, not RAM. The
`seam_*_window[0:8]` arrays are registers too.)

Memory is a non-issue. **Logic utilisation is the only real budget risk** and
cannot be predicted from source; see §6.

---

## 3. What the port consists of

Source to bring over (MiSTer `rtl/video/`, 2,200 lines total):

| File | Lines | Role |
|---|---|---|
| `video_pipeline.sv` | 325 | top of the colour path; mode/preset muxing, sync derivation |
| `vga_controller.v` | 896 | native RGB renderer (palette, HGR/DHGR artefacting, text) |
| `apple_composite.sv` | 166 | composite **encoder** (mono → NTSC with burst) |
| `composite_decoder.sv` | 783 | composite **decoder** (NTSC → RGB, comb filter) |
| `video_mode_decode.v` | 30 | small mode helper |

`video_pipeline.sv`'s machine-side inputs are:

```
CLK_14M, VIDEO, HBL, VBL, COLOR_LINE, TEXT_MODE, LO_RES_TEXT,
SCREEN_MODE[1:0], COLOR_PALETTE[1:0], RUN_FILL_OK, NTSC_VERTICAL_COMB,
EARLY_VIDEO, HGR_MODE, HGR80_MODE, GR2, COL80, DHIRES_MODE,
ioctl_addr[24:0], ioctl_data[7:0], ioctl_index[7:0], ioctl_download, ioctl_wr,
ioctl_wait (out), reset, machine_ce,
use_composite, comp_preset[1:0], comp_hue_adj[4:0],
comp_bright_st[1:0], comp_sat_st[1:0], comp_contrast_st[1:0]
outputs: R[7:0], G[7:0], B[7:0], HS, VS, HBL_O, VBL_O
```

**The Pocket machine already exports every machine-derived one of these.**
`machine/apple2.v:101–112` has `VIDEO, COLOR_LINE, RUN_FILL_OK, TEXT_MODE,
EARLY_VIDEO, HGR_MODE, HGR80_MODE, GR2, COL80, DHIRES_MODE, HBL, VBL`, and the
shipping top already wires them out as `m_video, m_col_line, m_run_fill_ok,
m_text_mode, m_early_video, m_hgr_mode, m_hgr80_mode, m_gr2, m_col80,
m_dhires, m_hbl, m_vbl`. This is why the port is mostly wiring.

Everything else is **user options**, not machine signals — see §5.

---

## 4. Risk #1 — keep RGB and blanking from the same source

`video_pipeline` **delays video relative to blanking**. Its own comment records
a sync pipeline depth of `8 + ALIGN_DLY (11)`, plus `HSHIFT_COMP`.

`apf_stream_video` derives everything from the blanking it is given:
`de_active = !hbl && !vbl`, the HS pulse fires a fixed 5 clocks after the HBL
rising edge, and VS fires on the VBL falling edge gated to HBL-high.

**So if you take `R/G/B` from the pipeline but keep feeding the machine's raw
`m_hbl`/`m_vbl` into `apf_stream_video`, DE and RGB will be misaligned by the
pipeline latency** — the picture shifts, or the leading/trailing pixels of each
line are wrong, or DE opens on blanked data. This is the single most likely way
for the port to be subtly broken while still "working".

Requirement: **feed `apf_stream_video` the pipeline's `HBL_O`/`VBL_O`, not the
machine's.** Then re-verify the APF contract items that depend on that pairing:

- HS is a 1-cycle pulse **during blanking** and never overlaps DE.
- VS is a 1-cycle pulse per frame, during blanking.
- There is a blank gap between VS and the next DE (the current code relies on
  HS landing 5 clocks after the HBL rise).
- RGB is 0 outside DE.
- DE is a **contiguous** run — hardware already rejected a strobed DE (pink
  screen), recorded in `apf_stream_video.v`'s header.

Also confirm the pipeline's HS/VS are not *additionally* needed; the Pocket
adapter generates its own from HBL/VBL, so `video_pipeline`'s `HS`/`VS` outputs
should probably be left unused rather than mixed in.

---

## 5. Risk #2 — the two integration seams

### 5.1 `apple2e_osk` must composite over RGB, not over 1-bit video

Today it is instantiated with `.video_in(m_video)` — a **1-bit** background —
and expands that to RGB internally before blending the OSK. With the pipeline
in place the background is arbitrary 24-bit RGB.

The canonical overlay (`machine/osk/virtual_keyboard_overlay.sv`, byte-identical
to MiSTer) **already does RGB888 fg/bg blending** — that is exactly how MiSTer
gets a transparent OSK over composite colour. So this is a rewiring of the
Pocket wrapper `apple2e_osk.v`, not a change to a pinned file.

Note this contradicts the 2026-10-19 doc's "What we will NOT do" list, which
scoped the colour change to `apple2e_osk.v` + `apf_video.v`. Re-state the scope:
`apple2e_osk.v` + a new pipeline instantiation + `apf_stream_video_top.v`
wiring. `apf_video.v` is out of the picture.

### 5.2 Overlay ordering differs from MiSTer — decide deliberately

| | Order |
|---|---|
| MiSTer | `video_pipeline` → `drive_status_overlay` → `virtual_keyboard_overlay` → `video_mixer` |
| Pocket | `machine` → `apple2e_osk` → `sdram_status_overlay` → `apf_stream_video` |

The status overlay and the keyboard are in the **opposite relative order**.
That was harmless while the background was monochrome. Once the background is
arbitrary colour, decide explicitly whether the Pocket's status/fingerprint
overlay should sit before or after the OSK, and verify transparency over both
dark and bright backgrounds (the 2026-10-19 handover's acceptance criterion 5
still applies: blends over black **and** white, all transparency settings,
glyphs, highlights, badges, panel positions).

Also note `sdram_status_overlay.v` was touched by the M1 closeout (fingerprint
lines, rows 65–95). See §7 — that work should land first.

### 5.3 `ioctl_*` on the pipeline

`video_pipeline` passes `ioctl_addr/data/index/download/wr` through to
`vga_controller` and returns `ioctl_wait`. The Pocket top ties the machine's
`ioctl_*` to zero today. **Establish whether that port is required** (a
downloaded palette or character ROM) or only serves the optional user-ROM case:

- if optional → tie off deliberately, document it, and confirm
  `ioctl_wait` never asserts;
- if required → it needs a `data.json` slot, which is a packaging change
  (and a new load path) and must be scoped before the RTL work.

This is an open question, not a detail; it can change the size of the task.

---

## 6. Resource budget (measured baseline, 2026-10-24 fit)

From `src/fpga/output_files_apple2e/apf_stream_video.fit.summary`:

| Resource | Used | Free | This port |
|---|---|---|---|
| ALMs | 8,978 / 18,480 (49%) | **9,502** | ~2,200 lines of palette + filter logic — **unknown, this is the risk** |
| Memory bits | 1,527,836 / 3,153,920 (48%) | 1.63 Mbit | ~30 Kbit |
| RAM blocks | 190 / 308 (62%) | **118** | ~4 |
| DSP blocks | 0 / 66 (0%) | **66** | possibly some; baseline is zero, so any DSP use in a future report is new |
| PLLs | 2 / 4 | 2 | **0** (native rate — see §2.1) |
| Pins | 224 / 224 (100%) | **0** | 0 (no new I/O) |

The MiSTer core as a whole uses 29,682 ALMs on a 41,910-ALM device — **it does
not fit here**, and only the video subtree is being ported. Memory, blocks, DSPs
and PLLs are all comfortable. **ALMs are the go/no-go.**

**Gate: run `quartus_map` with the pipeline instantiated and its outputs stubbed
before writing any integration code.** If the ALM delta does not fit in ~9,500
with margin, stop and re-scope (e.g. RGB-monitor mode only, defer the composite
encode/decode pair, or drop the adaptive comb). This is the cheapest possible
kill switch and it must come first. The owner runs compiles.

Timing should be a non-issue: the whole path runs at 14.318 MHz, and the
critical path in this design is the 133.12 MHz `mp2` SDRAM domain (+1.080 ns at
85C, +0.967 ns at 0C after M1). The pipeline was designed for the same 14.318
MHz Apple II master clock on MiSTer, so there is no retiming work — but confirm
the `mp2` path is unchanged after the map, since that is what M1 just closed.

---

## 7. Sequencing against the open M1 follow-ups

`docs/HANDOVER_M1_POST_FINGERPRINT_2026-10-24.md` has two open tasks, and
**both collide with this work**:

- **Task 1 — gate the fingerprint overlay behind `FP_DIAG` (default OFF).**
  Touches `sdram_status_overlay.v`, `disk_verifier.v`, `sdram_storage.v`,
  `apf_stream_video_top.v` — the same RGB chain and the same top-level file.
- **Task 2 — cold reset on disk insert, optional per game.** Touches
  `machine_reset`, the `ram_main`/`ram_aux` arrays, and **`apple2e_osk.v`**
  (new command key) — the same wrapper §5.1 needs to change.

Recommended order:

1. **Task 1 first.** Small, self-contained, gets four always-on diagnostic text
   lines off the screen, and means the colour work is validated against a clean,
   stable overlay instead of one that is simultaneously changing.
2. **Then the colour port.**
3. **Then Task 2**, or run it in parallel only if a different person owns
   `apple2e_osk.v` — otherwise there are two owners of one file.

Do not start the colour port while M1's post-fingerprint tasks are mid-flight in
the same files.

---

## 8. Pinning policy — decide before the first line is copied

The WOZ engine is byte-pinned from MiSTer with a `NOTICE.md` recording the one
allowed exception. That discipline paid off: during the M1 investigation the
question "has anyone modified the engine?" was settled with a single `diff`
(verified byte-identical; `disk_ii_woz.sv` has exactly the one documented hunk).

The four video files will become a **third** copy of actively-developed MiSTer
video logic (MiSTer + Pocket + the deprecated `_newsdee` archive). The MiSTer
video path is still moving — `video_pipeline.sv` had preset changes as recently
as 2026-09-28 (Sharpness/Smoothing removed, NTSC Vert. Comb Filter reverted to
1-bit).

**Recommendation: byte-pin `video_pipeline.sv`, `vga_controller.v`,
`apple_composite.sv`, `composite_decoder.sv` and `video_mode_decode.v` under a
`src/fpga/core/video/NOTICE.md`**, with the same rules as `src/fpga/core/woz/`:
no local edits; any required divergence is a documented exception with a
justification. All Pocket-specific adaptation goes in a thin wrapper
(`apple2e_video.v` or similar) plus `apf_stream_video_top.v` wiring.

If instead the intent is to fork and diverge deliberately, say so explicitly and
record the divergence list — silent drift is the outcome to avoid either way.

Note the existing mirrored-file rule already in force for
`machine/osk/virtual_keyboard_{controller,overlay}.sv` (byte-identical to
MiSTer, edits applied to both copies in the same change). The video files should
get the same treatment or an explicit pin; do not leave them unclassified.

---

## 9. Verification plan

1. **`quartus_map` resource gate** (§6) — before any integration code.
2. **Differential module TB.** Bring up the pipeline standalone, drive
   `VIDEO/HBL/VBL` + mode flags, and compare RGB against a golden capture from
   the MiSTer build. This is the same differential-harness pattern already used
   in this workspace for `disk_ii`, `apple2_font_rom` and `keyboard`, and the
   tooling exists (`verilog/rerun_m1_regress.sh`, `verilog/run_ovl_suites.sh`).
   Reuse it rather than inventing a new approach.
3. **Blanking/DE contract test.** With the pipeline's `HBL_O/VBL_O` feeding
   `apf_stream_video`, assert every APF contract item in §4 in simulation
   (`tb_phase2_shots.sv` already checks this class of property).
4. **OSK blend test.** Transparency over both dark and bright backgrounds, all
   transparency settings, glyphs, highlights, badges, panel positions
   (2026-10-19 handover criterion 5).
5. **Full-machine sim + PPM dumps.** The `verilog/pocket_boot` harness renders
   frames to PPM; use a known HGR and a known DHGR title.
6. **Hardware eyeball pass.** Per `AGENTS.md`, colour/geometry correctness
   cannot be judged by assertion. Pocket screenshots are lossless RGB565
   (skill KB-103), so captures are comparable.
7. **STA re-check both corners** — confirm the `mp2` path M1 just closed is
   unchanged.

Known pre-existing issue to decide on **before** the hardware pass: the
HGR/DHGR left-shift documented in
`Apple-II_MiSTer/docs/video/VIDEO_RENDERING_ISSUES.md`. It is pre-existing on
MiSTer (not a regression), caused by the HGR active window being adjusted
against Total Replay's screen. Porting the pipeline makes it visible on Pocket
too. Decide in advance whether fixing it is in scope or explicitly deferred, so
it is not rediscovered as a "new" Pocket bug.

---

## 10. Open questions (answer before coding)

1. **`ioctl_*`** — required or optional? (§5.3) Determines whether a `data.json`
   slot is needed.
2. **Which modes ship first?** RGB-monitor colour (native renderer only) is a
   much smaller step than the full composite encode→decode pair. Consider
   landing RGB-monitor colour first, then composite, so each is separately
   verifiable on hardware.
3. **Overlay ordering** — status/fingerprint overlay before or after the OSK?
   (§5.2)
4. **`interact.json` allocation.** The pipeline needs roughly 8 user entries
   (`SCREEN_MODE`, `COLOR_PALETTE`, `NTSC_VERTICAL_COMB`, `use_composite`,
   `comp_preset`, `comp_hue_adj`, `comp_bright_st`, `comp_sat_st`,
   `comp_contrast_st`). `interact.json` is currently empty, so there is room —
   but **skill KB-079: interact silently caps at 16 shown UI entries**, and
   Task 2 may also want one. Allocate deliberately now; the cap fails silently.
5. **Pinning vs forking** (§8) — needs an owner decision.
6. **Is `DEC2X=1` (280-px decimation) still wanted?** It is a non-shipping
   experiment with an unresolved shift issue
   (`docs/EXPERT_BRIEF_PHASE2_280_SHIFT_2026-10-19.md`). Colour work should not
   be validated in that mode; state explicitly that `DEC2X=0` is the target.

---

## 11. Summary

The 2026-10-19 docs solved the wrong-shaped problem for today's tree: they were
about **where to store RGB**, and the answer turned out to be "nowhere — stream
it". That is shipped and hardware-verified.

What is left is a bounded insertion: a native-rate 560×192 `CLK_14M` RGB
producer into a chain that already carries RGB888, with every machine-side input
already exported. Memory cost ~30 Kbit / ~4 M10K blocks of 118 free. No new PLL,
no raster change, no `video.json` change.

The three things that can actually go wrong, in order:

1. **RGB/blanking pairing** (§4) — take `HBL_O`/`VBL_O` from the pipeline, not
   the machine, or DE and RGB desynchronise by the pipeline latency.
2. **ALM fit** (§6) — unknown until a map run; gate on it first.
3. **File collisions with the M1 follow-ups** (§7) — do Task 1 first.

And the one process decision that must be made before copying any file:
**pin or fork the four video modules, explicitly** (§8).
