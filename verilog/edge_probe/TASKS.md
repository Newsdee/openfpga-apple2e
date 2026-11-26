# edge_probe task list (PLAN_VIDEO_40COL_ENCODER_EDGE_2026-11-25)

## Status

1. [DONE] Map DUT hierarchy: CPU/RAM/ROM instances, video landmarks.
2. [DONE] Fixture: fixture_gen.py - gr/t40/t80/hgr 6502 programs, real
   soft-switch accesses (NOTE: $C00x switches latch on WRITE only - STA,
   not BIT), TB-only RAM deposit + reset-vector patch + host re-reset.
3. [DONE] Edge probe: tb_video_edge.sv + run_edge.bat; per-tick CSV at the
   4 plan boundaries, native PPM frame, DLB serialized-byte dump, SCAN7F
   marker-line scanner, automatic scoreboard with fixture-derived windows.
4. [DONE] Scoreboard + preset sweep: +6-sample uniform right shift in ALL
   modes (gr/t40/t80/hgr) and ALL presets; encoder admission clean; this is
   translation, not first-edge attenuation.
5. [DONE] RESULTS.md: first divergence = hshift_idx (-8 donor calibration)
   in video_pipeline_q17.sv:284; candidate = 6-clock sel_hbl delay in
   Pocket glue (VBL_ALIGN precedent). Awaiting owner review - the plan
   forbids production RTL inside the diagnostic task.
6. [TODO, after owner review] Apply candidate, re-run all four modes x
   presets through this harness (expect first_lit 0/266/280/546 40-col,
   0/364/532 HGR), regression the ntsc parity harness, then hardware A/B.
7. [TODO] Mixed-mode boundary lines (GR row 19/20) - needs the line_cnt vs
   display-line map (RESULTS.md coordinate caveat); aim via DL monitors.

## Deferred (owner request 2026-11-25)

8. **Visual video preview .bat** — run the Pocket harness with an SDL window
   (or PPM/animation dump) so the owner can SEE the rendered video like the
   MiSTer core's preview, to visually check fixes and exercise OSD sliders
   interactively. Slower realtime-ish run is acceptable; debugging/review
   tool only, not a gate. Do AFTER measurements/fixes land.
   Notes: pocket_boot already has an SDL interactive mode (`--exe` +
   pocket_main.cpp, build.sh); likely path is a new `run_video_preview.bat`
   around that with the fixture program preloaded, or a frame-streaming
   variant (PPM sequence + ffplay) if SDL perf is poor. Check slider/OSD
   hookups exist in pocket_main before promising interactive sliders.
   The edge_probe PPM output already gives static frames; the preview adds
   live/interactive viewing.
