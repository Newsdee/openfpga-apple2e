# PHASE 2 STATUS & RESTART HANDOFF — 2026-10-19

Session was repeatedly cut by loop-police. This file captures the full
state so a fresh agent (or a later session) can resume without re-deriving
anything. Read top to bottom; it is self-contained.

## 1. Where we are in the color-pipeline plan

- Phase 0 (APF contract check): **DONE** — Apple II native 560×192 /
  910×262 @ 14.318 MHz is legal APF input (active ≤ 800×720, 47–61 Hz,
  ≤ 50 MHz pixel clock).
- Phase 1 (streaming pattern prototype): **DONE, hardware-verified.**
  `Newsdee.Apple2eStreamProto` shows clean 7 colour bars + ID region at
  70:24 aspect on the real Pocket. Direct 14.318 MHz RGB streaming into
  the APF DDR pad works; no frame buffer needed.
- Phase 2 (real machine video + full-color OSK through the streaming
  path): **COMPILED, STAGED, ON HARDWARE — IMAGE WRONG, diagnosing.**

## 2. Phase 2 files (all in the repo, NOT yet committed)

| file | role |
|---|---|
| `src/fpga/core/apple2e/apf_stream_video.v` | NEW: thin streaming adapter. 24-bit RGB + DE/HS/VS straight to APF, 14.318 MHz domain, no buffer, no CDC |
| `src/fpga/core/apple2e/apf_stream_video_top.v` | NEW: `stream_video_core_top` — copy of Phase 1 top; pattern generator replaced by `apf_stream_video`; OSK's new `video_rgb24` wired in |
| `src/fpga/core/apple2e/apple2e_osk.v` | MODIFIED: added `output wire [23:0] video_rgb24` = the already-composited `osk_rgb` (machine 1-bit→RGB + full-color OSK overlay + transparency). 1-bit `video_out` unchanged |
| `src/fpga/apf/apf_top_stream.v` | NEW APF wrapper, top `apf_top_stream` |
| `src/fpga/apf/apf_stream.qip` | NEW QIP |
| `src/fpga/apf_stream_video.qsf/.qpf` | NEW, revision `apf_stream_video` |
| `apf_stream_video_build.bat` | NEW build/reverse/stage script |
| `sd_root/Cores/Newsdee.Apple2eStreamVideo/` | package, `video.json` 560×192 @ 70:24 |
| `src/fpga/core/apple2e/apf_stream_proto_pll.v` | REUSED (14.318 MHz 0° + 90° @ 17,468 ps) |

Working core (`apple2e_core`) is untouched and still passes.

## 3. Compile result (user-compiled 2026-10-19 ~17:18)

- A&S Successful; Fitter Successful: **3,191/18,480 ALMs (17%)**,
  1,795 regs, M10K 39%, RAM 49%, worst setup +5.228.
- RBF: 1,314,180 B, sha256 `4a4c63c7…c96b884`.
- Reversed + staged:
  `sd_root/Cores/Newsdee.Apple2eStreamVideo/bitstream.rbf_r`
  sha256 `87c488c7da7d152c25ccc782a4129763ae6bae9dd58ebbb5f6e8f5819a2c8f41`.

## 4. Hardware symptom (capture WIN_20261019_17_28_31_Pro.jpg)

Pocket display, core `Apple2eStreamVideo`:

- **Top third: black.**
- **Middle: large uniform PINK/SALMON band** with a single small white
  dot near centre.
- **Bottom: blue-ish region with what looks like garbled/rotated text**
  (owner: "some garbage which may be the output of the real core").
- No colour bars (so Phase 1 pattern is correctly gone — this is the
  machine path).

## 5. Ranked hypotheses

1. **Machine video is not a clean white "Ready" screen — the machine
   itself is producing odd/garbage video in this build** (pink+blue+text).
   The bottom text region may be real machine output (owner's hunch).
   Causes to check: reset differences (Phase 1 top was proven to boot the
   machine in sim; but hardware reset path / `machine_reset` timing vs
   `apf_video` era), video mode at power-on (Apple-logo color stripes are
   rainbow — pink not among them, so logo alone doesn't explain pink).
2. **OSK full-color overlay is being drawn covering the middle of the
   screen** — the pink band's shape (a horizontal panel across mid-screen)
   matches a keyboard panel. In the working 1-bit core the panel renders
   as white-on-black, so `osk_rgb` being pinkish would have been invisible
   in the 1-bit path (bit 17 of a pink pixel is 1 → white). Need to check
   the OSK overlay's default visibility + panel colors in
   `machine/osk/virtual_keyboard_overlay.sv`.
3. **Sync/timing mismatch between the machine's real HBL/VBL and the APF's
   expectations** (HS/VS pulse placement, HS within 3 clocks of VS on the
   first line after VS — KB-014). Phase 1 used clean self-generated timing;
   Phase 2 uses the machine's actual HBL/VBL, which may have edges in
   places the APF dislikes (e.g. during machine reset the HBL/VBL can
   bounce → APF mis-lock → banding).
4. RGB bit-order or polarity — unlikely to produce *uniform pink over a
   large area* from a 1-bit machine source (white/black are symmetric),
   but the OSK colors would be swapped (minor, check later).

## 6. Diagnostic plan (cheapest first)

**A. On-Pocket, 30 seconds each (owner does these, no rebuild):**
1. Press **START** (OSK visibility toggle). If the pink band disappears →
   hypothesis 2 confirmed (pink = OSK panel in full color).
2. Wait ~30 s after boot (full boot to Ready). If the image settles into
   white-with-text → transient boot-video issue (hypothesis 1 partial).
3. Toggle **SELECT** (transparency cycle). If the pink fades in steps →
   confirms pink is the OSK overlay being blended (hypothesis 2).

**B. Sim frame capture (no hardware, this repo's tools):**
A dedicated Phase 2 harness is ready (see §9 for the exact run commands):
`verilog/tb/tb_phase2_shots.sv` + `verilog/verilate_phase2_shots.sh`
+ `verilog/ppm2png.py`. It instantiates machine + OSK + `apf_stream_video`
(the exact Phase 2 DUT) and dumps two 24-bit color frames (boot screen
with OSK closed ~0.64 s; machine + open full-color OSK after Q+Enter
~1.75 s) plus hard APF-contract checks (RGB=0 outside DE, 1-cycle
HS/VS, HS ≥ 3 cycles after VS, 560 px/line × 192 lines).

This single capture resolves hypotheses 1, 2 and the sync question at once:
- sim frame white+panel → hardware pink is a sync/APF issue (hypothesis 3).
- sim frame pink → the OSK overlay itself is pink (hypothesis 2, fix in
  overlay/composite, still in the non-canonical `apple2e_osk.v` layer).
- sim frame garbage → machine problem in this top (hypothesis 1).

**C. If B shows clean sim + wrong hardware:** add a 2-line fix in
`apf_stream_video.v`: gate all HS/VS/DE output with a "machine locked"
flag that only sets after N stable frames post-reset (kills reset-time
sync bounce), plus enforce HS ≥3 cycles after VS. Rebuild, re-test.

## 7. Exact restart commands

Phase 2 sim capture (the decisive test — run these in MSYS2 UCRT64 bash):

```bash
cd /e/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog
# 1) build (one-time; add 'clean' to rebuild from scratch)
/c/msys64/ucrt64/bin/bash verilate_phase2_shots.sh
# 2) run — CWD MUST be the Apple-II_MiSTer root (ROM paths are CWD-relative)
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer
/e/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/obj_dir_phase2/Vtb_phase2_shots
# 3) convert the two PPMs to PNGs and open them
cd /e/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog
/c/msys64/ucrt64/bin/python.exe ppm2png.py shots/phase2_frameA.ppm shots/phase2_frameB.ppm
# then read: shots/phase2_frameA.png  (boot screen, OSK closed)
#            shots/phase2_frameB.png  (machine + full-color OSK open)
```

Interpretation matrix (decisive):
- **frameA/frameB clean (white Ready screen, beige OSK panel)** and the
  hardware shows pink/garbage → the bug is in the APF/sync path on
  hardware → go to §6C (gated sync) / §8 (regenerate sync like Phase 1).
- **frameB shows the panel tinted pink-ish in sim** → the composite
  itself is off (check the `video_rgb24` path in `apple2e_osk.v` and the
  overlay blend) — fix in RTL, re-sim, then re-compile.
- **frames show garbage** → the machine is misbehaving in this harness
  (compare against `verilate_p2b_shots.sh` baseline, which is known-good).
- The sim also prints the APF-contract result (`PHASE2 APF contract
  PASS/FAILED`): a FAILED contract (e.g. HS < 3 after VS) is a direct
  explanation of a mis-locked APF display.

Do NOT commit until the pink issue is resolved and hardware re-verified.
Working core bitstream (known good, sha256 `6fe89807…f4de83`) remains in
`sd_root/Cores/Newsdee.Apple2e/`.

## 8. Open decision (for expert/owner)

Whether to keep the streaming path's sync derived directly from machine
HBL/VBL (true native) or to *regenerate* clean sync (as Phase 1 did) and
only take pixel data from the machine. Phase 1 proved regenerated sync is
APF-clean; the machine's real HBL/VBL has never been proven APF-clean on
hardware. If B/C point at sync bounce, regenerating sync in
`apf_stream_video.v` (free-running 910×262 counters like Phase 1, with
machine pixels sampled under DE) is the minimal-risk fix and keeps the
no-buffer architecture.

## 9. Phase 2 sim harness (added 2026-10-19 evening)

**Update 2026-10-19 night (post expert review):**
- Expert findings applied: DUT sync fixed (HS now 5 clocks after the
  line-start HBL rising edge, inside blanking, 328 clocks before DE; VS
  gated to blanking) and the TB got bounded `$finish`, one-shot captures,
  HS/DE overlap check (the failing rule), hard-fail line geometry, and a
  correct watchdog. See `docs/EXPERT_BRIEF_PHASE2_SYNC_2026-10-19.md`.
- **Sim: `PHASE2 APF contract PASS`** (all violations 0; HS→DE 328, VS→HS 4).
- Captured frames are clean: machine boots to Ready; full-color OSK panel
  (beige 0xD0C4B1) composites correctly — **no pink in the content**.
- Old PPMs from before the fixes are NOT evidence. New captures:
  `shots/phase2_frameA.png` (boot) / `shots/phase2_frameB.png` (OSK open).
- Pre-existing quirk noted (out of scope): machine renders white-on-black
  (also present in the known-good P2b sim captures); frame rate ~52.4 Hz
  (line period ~1041 clocks, not 910).
- **Next gate: recompile `apf_stream_video` (user), restage, Pocket re-test.**

- `verilog/tb/tb_phase2_shots.sv` — machine + OSK + `apf_stream_video`
  (exact Phase 2 DUT wiring), 24-bit frame capture, APF contract checks,
  PPM dumps at ~frame 30 (boot, OSK closed) and ~frame 82 (OSK open,
  Q+Enter pressed).
- `verilog/verilate_phase2_shots.sh` — build (pattern-identical to
  `verilate_p2b_shots.sh`; DUT file swapped to `apf_stream_video.v`,
  Mdir `obj_dir_phase2`).
- `verilog/ppm2png.py` — stdlib-only P6 PPM → PNG converter.
- Outputs: `verilog/shots/phase2_frameA.ppm/.png`,
  `verilog/shots/phase2_frameB.ppm/.png` (shots/ is gitignored).

Run commands: see §7. The other open items (on-Pocket button tests,
§6C gated-sync fix, §8 sync-regeneration decision) are unchanged.
