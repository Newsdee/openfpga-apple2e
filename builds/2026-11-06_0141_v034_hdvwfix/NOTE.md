# Build archive: 2026-11-06 01:27-01:41 — v0.3.4 HDV write-leg corruption fix

Purpose: 0.3.4 fixes the HDV write corruption found in the 0.3.3 hardware
test (Copy+ folder creation left SmartportHD.HDV unbootable: rotated
ProDOS header/directory sectors). Root cause and fix:
`docs/RELEASE_NOTES_0.3.4.md` + `scratch_hdv_corrupt/NOTES.md` (root-cause
section).

## What changed in this build (vs 0.3.3)
- `src/fpga/core/hdv_bridge.sv`:
  - 0x0184 arm now waits for a commit count (`wo_landed == 512` CDC byte
    writes into the sector RAM, no write in flight) instead of a fixed
    guard after the walk-done edge. On async clocks the old arm could beat
    the final commit, so the host DMA'd the PREVIOUS write's content
    (the corruption).
  - Counter reset on the raw walk-request level rising edge (not the 2FF
    edge); done requires the walk running >= 1 cycle (kills the same-cycle
    stale-512 race; sim-proven: old code armed 377 ns after execute).
  - Timeout (3.6 s) now covers every non-IDLE state (a lost walk-done edge
    used to hang cpu_wait forever); faults latch + release the CPU.
  - New `hdv_wrcnt` output: host 0x0184 read words of the last write
    (want 128), counted from arm entry through done.
- `src/fpga/core/apple2e/apf_stream_video_top.v`: `bridge_rd` wired into the
  bridge; debug sync widened 16 -> 24 bits (adds the wrcnt field).
- `src/fpga/core/apple2e/sdram_status_overlay.v`: HDV debug line now
  `S=S F=F N=NN M=M W=NN` (W = host read words of last 0x0184).
- `sd_root/Cores/Newsdee.Apple2e/core.json`: 0.3.3 -> 0.3.4.
- `src/fpga/apf/build_id.mif`: 20261106 / 00012757 / 9e605638
  (bumped by the owner immediately before this compile; 0.3.3 had
  20261105 / 00023110 / c7e43be4).
- `verilog/hdv_bridge/tb_hdv_bridge.sv` (sim only): new T8 double-write
  same-sector byte-exact capture + non-vacancy check, T11 write-leg timeout
  recovery, 2FF edge-detector bit-order fix, framework DMA startup latency
  modeled.
- No new interact options: `interact.json` unchanged from 0.3.3 (still
  ships as a pair with the bitstream).

## Compile (Quartus 17.0.2 Lite, owner-launched)
- Coherent single run: A&S 01:31 -> fitter 01:40 -> asm rbf 01:41 -> STA
  01:41 (build_id.mif mtime 01:27:57 predates the 01:28 map start, so the
  rbf carries the 0.3.4 ID).
- Fit: Successful. ALM 13,897 / 18,480 (75 %), registers 14,594, pins
  224/224, RAM 193/308, DSP 29/66, PLL 2/4.
- **ALM delta vs 0.3.3 (13,878): +19** — the commit counter (10b), wrcnt
  (8b), req/state delay regs, and the widened 24-bit debug sync. Block
  memory bits UNCHANGED (1,557,504 — the W0 gate).
- Timing: TNS 0.000 all constraints; clk_74a setup slack +2.163 ns (0.3.3:
  +0.719 ns — fitter seed variance, both clean).
- Warnings: no new ones (9 pre-existing 10268 blocking/NBA notes in
  io_sdram/pdl_timer/woz/vga; 1 benign asm NUM_PARALLEL_PROCESSORS).

## Sim (before compile)
`bash verilog/hdv_bridge/run_hdv_bridge.sh`:
`HDV BRIDGE ALL CHECKS PASSED`, `read_cmds=6 write_cmds=5 failures=0`
(13 checks incl. T8a/T8b double-write, T11 write-leg timeout).

## Repackage
`repackage.bat` (this archive's companion): rbf 1,783,328 B -> rbf_r staged
in `sd_root/Cores/Newsdee.Apple2e/`.
- sha256 in  (apf_stream_video.rbf): edc6b99f42355f1ad38ada22cbe1727a53697d49298b202fe1b9a5265b4c4ff2
- sha256 out (bitstream.rbf_r):     5c83219ca0c3f9dc82a9f6797770b5dd5346bcf3f240880b322767f5cb174e39

## Hardware re-test plan (throwaway media only)
Copy+ folder test with Writable HDV; read the debug line:
W=128/F=0 => core clean. W<128/F=1 => framework gave up mid-DMA (host side).
Golden original: `sd_root_release/SmartportHD.HDV` (never write to it).

## ADDENDUM (2026-11-06, after expert review of the corrupted images)

**This archive's bitstream is NOT the current core.** The expert review of
the two corrupted SmartportHD images concluded the deterministic
4 B/8 B sector rotations are most plausibly the 0x0184 read-back
misalignment: the 7-bit word select wrapped inside the 4 KB decode arm
(reads at 0x01F01200+ returned word 0) combined with the framework's
registered read port (core_bridge_cmd's bridge_rd_data_out is one clock
late), so a DMA starting k words in came back cyclically rotated 4k
bytes. The fixes for that (narrowed read window, `hdv_oobcnt` OOR counter,
`K=NN` overlay field, `interact.json` "Writable (EXPERIMENTAL)" warning)
landed in the worktree AFTER this 01:41 compile, plus two harness fixes
(the T8 round-trip test had read the DUT's combinational output — it was
vacuous against the misalignment — and the TB host model left bridge_wr
asserted after a replay, which masked exactly this bug class).

- A fresh owner-launched compile + repackage is REQUIRED before any
  further hardware write test; the staged `bitstream.rbf_r` in this
  archive lacks the narrowed decode and the K field.
- Updated sim result after the addendum changes:
  `HDV BRIDGE ALL CHECKS PASSED`, `read_cmds=6 write_cmds=7 failures=0`
  (adds T8c/T8d k=1/k=2 DMA tests; T10/T11 write-count expectations
  updated 4->6 / 5->7).
- Full history: `docs/RELEASE_NOTES_0.3.4.md` ("Expert review" section).
