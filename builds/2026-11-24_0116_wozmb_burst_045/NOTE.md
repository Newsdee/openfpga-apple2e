# Build 2026-11-24 01:16 — WOZ multi-block port, option B (version 0.4.5)

Base: 0.4.4 release (`acae14b`) + WOZ multi-block port, worktree
`apple2e-pocket-wozmb` (see `docs`/`verilog/woz_mb/STEP_RESULTS.md` and
`src/fpga/core/woz/NOTICE.md` in that worktree).

Contents vs 0.4.4:
1. WOZ controller multi-block protocol + TMAP range guard (donor
   `Apple-II_MiSTer 4cb1d2c17`, GS-derived; safety fix = the correctness
   value).
2. Burst transport `sdram_woz_transport_mb` wired in as the WOZ host
   (up to 32 blocks per engine request, one sd_ack window).
3. 14-bit `SD_BUFF_ADDR` ([13:9]=block-in-request, [8:0]=byte) +
   `SD_BLK_CNT0/1` plumbing.

Compile: Quartus 17.0.2 Lite, rev `apf_apple2`, clean A+S (01:09) + fit
(01:15) + STA + asm (01:16). 11,358/18,480 ALM (61%), 12,865 registers,
224/224 pins; RAM 202/308. Delta vs 0.4.4 (11,226 ALM / 12,829 reg):
+132 ALM / +36 reg, RAM identical. Slacks all positive; critical 1.361 ns
(0.4.4: 1.571 ns). No new warning classes (all smsg entries are the
pre-existing 10268/10281 family).

Sim validation (all PASS, Verilator 5.050, worktree):
- run_control.bat 0/1/2 (full stack, byte-exact tracks, guard intact;
  PORT=2 = this exact DUT pair, one ack window per track)
- run_transport_mb.bat (burst-transport DUT edge cases)
- run_eng.bat (engine differential: 1/32/33-block, mixed short answers,
  v1 offset, id-160 guard)
- scan-window regression (ported controller)

bitstream.rbf_r = bit-reversed apf_apple2.rbf (tools/rbf2rbf_r.py)
sha256 a6da0e68077fc7095f57232c15d0916a617b6351c3f436e4d3abdf051bf6e4ef
(raw .rbf sha256 dc880dc9df63ead0cf3220f360d1bc194245727fa0ac6ac6332a7eb911382599;
1,747,904 bytes)

PACKAGING GOTCHA (learned 2026-11-24): the APF .rbf_r is NOT a renamed
.raw .rbf - every BYTE is bit-reversed (tools/rbf2rbf_r.py). Staging a
plain rename produces a bitstream the Pocket loads as garbage, which
boots to "ERROR IN FRAMEWORK: RS: BRIDGE NOT RESPONDING". The first
staging of this build used a plain rename and failed on hardware for
exactly that reason; the bitstream.rbf_r here is the corrected
reversed file. (The 2026-11-23 13:53 video-fix build failed the same
way - that "open bridge error" was this packaging bug, not the DE fix.)
Always verify with: python tools/rbf2rbf_r.py <raw.rbf> /tmp/x && sha256sum.

Hardware expectation vs 0.4.4: protected-loader loads get the TMAP
guard (ids >= 160 can no longer trigger fetches/valid); track loads batch
(ACK round trips reduced); on-Pocket timing gain is modest (~0.7% of
headline re-seek) — the guard is the correctness value.
