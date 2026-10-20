# EXPERT DESIGN BRIEF — Video modes (composite color + B&W/Green/Amber) for the Apple IIe Pocket core

**Date:** 2026-10-19 · **Author:** Newsdee (with assistant) · **Status:** design request
**Companion brief:** `docs/EXPERT_DESIGN_FLOPPY_WOZ_2026-10-19.md` (independent work
item, no shared RTL — review both, sequence either order).

Goal: give the Pocket **streaming** core the Apple IIe's full display-mode set —
**composite color (16 colors)** plus the **B&W / Green / Amber** monochrome modes —
by porting the already-built, hardware-verified video pipeline from the active
MiSTer project. Everything below is stated or referenced by path.

## 1. Current Pocket video path (what changes)

```
apple2.v (machine, 14.318 MHz)
  -> VIDEO (1-bit) + COLOR_LINE + EARLY_VIDEO + mode flags
  -> apple2e_osk.v:  m_rgb = video_in ? 24'hFFFFFF : 24'h000000   <-- hardcoded
  -> virtual_keyboard_overlay (24-bit composite, works as-is)
  -> apf_stream_video (native 560x192 @ 14.318, APF-clean HS/DE)
  -> APF DDR pad
```

The one-line change at the center of this milestone is replacing the
hardcoded `m_rgb` white/black with real per-pixel RGB from the video
pipeline. The stable 1-bit frame-buffer core
(`Cores/Newsdee.Apple2e`) is **out of scope** (color there needs a 24-bit
frame buffer — a separate, larger change).

## 2. What already exists (the asset)

`Apple-II_MiSTer/rtl/video/` (active MiSTer project, hardware-verified,
includes the 2026-08/09 color-video feature set):

| File | Role |
|---|---|
| `video_pipeline.sv` | Top of the video path. **Runs on CLK_14M** (our machine clock — no new PLL). Inputs: `VIDEO, HBL, VBL, COLOR_LINE, TEXT_MODE, LO_RES_TEXT, SCREEN_MODE[1:0], COLOR_PALETTE[1:0], RUN_FILL_OK, NTSC_VERTICAL_COMB, EARLY_VIDEO, HGR_MODE, HGR80_MODE, GR2, COL80, DHIRES_MODE`, custom-palette loader (`ioctl_*`), `reset`, `machine_ce`, and composite display controls (`use_composite, comp_preset, comp_hue_adj, comp_bright_st, comp_sat_st, comp_contrast_st`). Outputs: `R/G/B[7:0]` + `HS, VS, HBL_O, VBL_O`. |
| `vga_controller.v` | Windowing/timing cleanup + RGB path (the big color-video feature file: windows, comb filter, presets). |
| `apple_composite.sv` | Apple composite signal model (16-color NTSC/PAL generation). |
| `composite_decoder.sv` | Composite → 16-color decode. |
| `video_mode_decode.v` | Mode detection helpers. |

Canonical wiring reference: `Apple-II_MiSTer/rtl/apple2_top.v` lines ~596–627
(`video_pipeline vp(...)` instance showing every input source).

**The mode set is exactly what we want, already implemented:**
- `SCREEN_MODE`: `00` Color, `01` B&W, `10` Green, `11` Amber.
- `COLOR_PALETTE`: `00` //e NTSC (original), `01` //gs, `02` AppleWin, `03` //c PAL.
- `use_composite`: Display Type — RGB monitor vs Color-TV (composite) path.

**All `video_pipeline` inputs are already exposed by `apple2.v`** (verified:
`VIDEO, COLOR_LINE, EARLY_VIDEO, TEXT_MODE, HGR_MODE, HGR80_MODE, GR2, COL80,
DHIRES_MODE, HBL, VBL` — all outputs of the module). No machine file changes.

## 3. Proposed integration (for review)

1. Copy `rtl/video/*.sv|v` byte-identical into the Pocket repo (consistent
   with the repo's byte-identity invariant: `machine/video/` + extend
   `check_machine_sync.sh`; generate q17 variants if Quartus 17 needs them,
   per the OSK precedent `tools/gen_osk_q17.py`).
2. Instantiate `video_pipeline` in `apf_stream_video_top.v` (machine domain):
   feed it the machine flags; take `R/G/B` → 24-bit `m_rgb` in
   `apple2e_osk.v` (replace the hardcoded white/black); OSK composite and the
   streaming adapter stay untouched.
3. **Mode control via `interact.json`** (the Pocket has no OSD): radio options
   writing bridge registers that the core decodes into `SCREEN_MODE` /
   `COLOR_PALETTE` / `use_composite`. v1 set (rec): Screen Mode (4), Palette
   (4), Display Type (RGB/Color TV); everything else (presets, hue, bright/
   sat/contrast, NTSC comb) hardcoded to verified defaults, exposed later.
4. `machine_ce`: the pipeline freezes composite state when machine_ce is low
   (MiSTer save/OSD-pause). Pocket has no pause yet — tie to 1 for now (it
   also becomes the future savestate/sleep freeze point — see the floppy
   brief §6).

## 4. Resource context

Streaming core currently: **3,330/18,480 ALMs (18%), 1,893 regs, 152/308
M10K** — ~15k ALMs and ~156 M10Ks free. The pipeline (composite decoder +
vga windowing) is the heaviest video block in the MiSTer core; the first
Pocket fit must capture the ALM/M10K/STA delta explicitly (project resource-
comparison rules). If the delta is tight, question 1's "subset" option is
the lever.

## 5. Questions (numbered — answer each)

1. **Native grid vs windowing:** we stream the machine's *native* 560×192
   raster. `video_pipeline` outputs RGB on its own timing (`HS/VS/HBL_O/
   VBL_O` after `vga_controller` windowing). Can we use the pipeline's
   per-pixel RGB on the native grid as-is, or should the Pocket instantiate
   a subset (e.g. `apple_composite` + `composite_decoder` directly) to skip
   the vga windowing? Which is lower-risk / smaller?
2. **Sync source:** should `apf_stream_video` keep deriving sync from the
   machine's `HBL/VBL` (current, proven) or switch to the pipeline's
   `HS/VS/HBL_O/VBL_O`? Any correctness difference at the native grid?
3. **v1 option set:** confirm/harden the recommended interact options and
   the hardwired defaults for the rest.
4. **Custom palette loader:** leave the `ioctl_*` palette interface
   unconnected in v1? (It maps to a memory-mapped palette download in
   MiSTer.)
5. **Porting risk:** do the five files need q17 variants or other Quartus-17
   accommodation (the OSK needed them; `dpram` inference failed once — see
   repo AGENTS notes in the parent workspace)?
6. **Test ladder:** propose Verilator TBs — e.g. known color-pattern checks
   for TEXT/HGR/DHGR/EGR across SCREEN_MODE × COLOR_PALETTE (the active
   project's `docs/video/` and its color-video test assets may be reusable —
   point me at them if so), plus a full-frame capture regression like our
   Phase-2 shots TB.
7. **Sequencing/interaction:** confirm floppy (brief 1) and video modes are
   truly orthogonal for the streaming top (they touch different modules;
   only the fit budget is shared).

## 6. References

- Pipeline + wiring: `Apple-II_MiSTer/rtl/video/*.sv|v`,
  `Apple-II_MiSTer/rtl/apple2_top.v` (vp instance ~596–627; SCREEN_MODE /
  COLOR_PALETTE / use_composite port comments ~186–198).
- Color-video history/docs: `Apple-II_MiSTer/docs/video/` (incl.
  `VIDEO_RENDERING_ISSUES.md`) and the parent workspace
  `docs/porting/PLAN_POCKET_CORE.md`.
- Pocket files to touch: `src/fpga/core/apple2e/apple2e_osk.v` (`m_rgb`),
  `src/fpga/core/apple2e/apf_stream_video_top.v` (pipeline instance),
  `sd_root/Cores/Newsdee.Apple2eStreamVideo/{interact.json,core.json}` (new
  interact options; `framework.version_required` unchanged — interact is a
  1.x feature).
