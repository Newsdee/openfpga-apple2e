# Build 2026-11-26 — 0.4.6: HBL_ALIGN video fix on WOZ 0.4.5 base

## Contents
WOZ 0.4.5 (`53451f9`: TMAP guard + multi-block-safe WOZ controller) **plus** the
video alignment fix series (hardware rounds 1–3, all modes aligned per owner):

- `5d3a8f3` video: align decoded picture to the DE window (fixes 40-col left
  black strip). Root cause per `PLAN_VIDEO_40COL_ENCODER_EDGE_2026-11-25` +
  `verilog/edge_probe` harness: the donor `hshift_idx` tap (HSHIFT_COMP-8,
  MiSTer vga_controller calibration) lands the decoded picture 6 samples right
  of the Pocket DE window in every mode/preset. Fix: HBL_ALIGN bypass on the
  early-video grid.
- `cb9455c` video: key the HBL_ALIGN bypass on `EARLY_VIDEO` (= COL80 |
  (HIRES&DHIRES)), not `HGR80_MODE` (fixes 16-colour DHGR, which reads
  HGR80_MODE=0/COL80=1).
- `76ffec6` docs: edge-probe RESULTS — hardware round 3 FINAL, all modes aligned.
- `cd1b010` docs: 80-col last-cell finding — owner hardware check OK, closed
  no-action.
- `06218fc` / `3ebc153` build_id for round-2/round-3 compiles.

## Bitstream
- `bitstream.rbf_r` (APF per-byte bit-reversed, via `tools/rbf2rbf_r.py`):
  sha256 `8df43c0316daf5d764d8dedd7831a44011787253f23567900c0732f3170ee089`
  — verified identical to the K: card copy; source
  `output/bitstream_apple2.rbf_r`.
- Raw `.rbf` sha not recorded: the video session's round-3 Quartus reports
  (fit/map/summary) were not captured in-tree. Hardware validity is
  established by three successful boots (rounds 1–3).
- `build_id.mif` at HEAD = round-3 build id (`3ebc153`).

## Metadata
9 files, `core.json` version **0.4.6** (bumped 2026-11-26 so the video-fix
build is launcher-distinguishable from WOZ 0.4.5 — the two share no other
user-visible identifier; the 0.4.5 WOZ bitstream was `99c6fb1b…`).

## Verification status
- Hardware: rounds 1–3 done (owner), "all modes aligned", 80-col last-cell
  check OK. See `76ffec6` / `cd1b010`.
- NOT yet run after round 3: the full regression set (WOZ boot, disk swap,
  floppy audio, HDV read/write) on this exact bitstream — WOZ path is
  unchanged by the video commits, but the roll has not been re-exercised.
