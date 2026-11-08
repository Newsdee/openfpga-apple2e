# Build archive: 2026-11-06 10:19-10:32 — v0.3.4b (HDV read-window/OOR fix)

Purpose: rebuild after the 2026-11-06 expert review of the corrupted
SmartportHD images. The 01:41 build (sibling archive) contained only the
first-half 0.3.4 fixes (arm race, timeout, `W` counter); this build adds the
expert-review fix set and **supersedes the 01:41 staged bitstream**.

## What changed in this build (vs the 01:41 build)
- `src/fpga/core/hdv_bridge.sv`:
  - Read decode narrowed to the real 512-byte window
    (`bridge_addr[11:9] == 0`): out-of-window reads (0x01F01200+) now
    return 0 instead of wrapping to word 0 — the mechanism that cyclically
    rotated sectors on hardware when the framework's 128-word 0x0184 DMA
    started k words in.
  - New `hdv_oobcnt` output: out-of-window reads of the last 0x0184 (= the
    host's start offset k), counted arm-entry → done.
- `src/fpga/core/apple2e/apf_stream_video_top.v`: `hdv_oobcnt` wired in;
  HDV debug sync widened 24 → 32 bits (adds the oobcnt field).
- `src/fpga/core/apple2e/sdram_status_overlay.v`: HDV debug line now
  `S=S F=F N=NN M=M W=NN K=NN` (line moved to X0=402, 26 chars on the
  560-px raster).
- `sd_root/Cores/Newsdee.Apple2e/interact.json`: the write-protect option's
  Writable value is now "Writable (EXPERIMENTAL)" (warning per expert
  review; option id/address unchanged).
- `verilog/hdv_bridge/tb_hdv_bridge.sv` (sim only): captures now go
  through a registered `rd_pipe` read stage (models core_bridge_cmd's
  one-clock-late bridge_rd_data_out); new T8c/T8d k=1/k=2 DMA tests
  (in-window words exact, out-of-window = 0, oobcnt = k); host model no
  longer leaves `bridge_wr` asserted after a replay (it had hammered
  RAM[508..511] and masked exactly this bug class); T10/T11 write-count
  expectations 4→6 / 5→7.
- `docs/RELEASE_NOTES_0.3.4.md`: expert-review + test-gap sections,
  updated interpretation matrix, "Rebuild required" resolved by this build.

## Compile (Quartus 17.0.2 Lite, owner-launched)
- A&S Successful 10:22:51 → fitter Successful 10:31:47 → asm Successful
  10:32:09 → rbf 10:32. build_id.mif bumped by the owner at 10:19:01
  (predates the 10:22 map start, so the rbf carries it):
  `20261106 / 00101901 / c2558012` (01:41 build had
  20261106 / 00012757 / 9e605638; 0.3.3 had 20261105 / 00023110 / c7e43be4).
- All modified sources (hdv_bridge.sv 10:11, top 09:56, overlay 09:58,
  build_id 10:19) predate the map start — the rbf contains every fix.
- Fit: Successful. ALM 13,979 / 18,480 (76 %), registers 14,553, pins
  224/224, block memory bits 1,557,504 (UNCHANGED — the W0 gate), RAM
  193/308, DSP 29/66, PLL 2/4.
  - ALM deltas: +101 vs 0.3.3 (13,878), +82 vs the 01:41 build (13,897) —
    the 32-bit debug sync, the oob counter, and the widened overlay line.
- Timing: TNS 0.000 on every constraint; clk_74a setup slack +2.287 ns,
  hold +0.497 ns.
- Warnings: no new correctness classes. Zero 10268 blocking/NBA notes
  (the 01:41 build had 9). Remaining map noise is the standing set
  (14320 PLL/ram synthesized-away nodes, 13410 unused APF pins, 10230/
  13310/13010 informational, 276027 dual-clock RAM note in the pre-existing
  sdram sector-fetch buffer); asm: 1 benign 18236 NUM_PARALLEL_PROCESSORS.

## Sim (before compile)
`bash verilog/hdv_bridge/run_hdv_bridge.sh`:
`HDV BRIDGE ALL CHECKS PASSED`, `read_cmds=6 write_cmds=7 failures=0`,
zero warnings (15 checks incl. T8a-T8d, T10/T11 with the updated
write-count expectations).

## Repackage
`repackage.bat` (11:29): rbf 1,779,020 B → rbf_r staged in
`sd_root/Cores/Newsdee.Apple2e/` (paired with the updated interact.json in
the same dir).
- sha256 in  (apf_stream_video.rbf): 1f308784f2568d412c91091c3a8b0159b38617d261e1fa61607d501c26884b47
- sha256 out (bitstream.rbf_r):     9182aa707f23ad7ec13e8ed6095bb16cc84fd2d6b0ffb402ae7e66143dd2a89c

## Version/commit state
`core.json` in the tree still says 0.3.4 (uncommitted, as is the whole
0.3.4 fix set). This build REPLACES the 01:41 staged bitstream: if the
owner ships it, it is 0.3.4-final; if the owner wants to mark the expert-
review delta separately, bump core.json/build_id to 0.3.5 at commit time
(the staged rbf_r and the 01:41 archive NOTE record the lineage either
way). Commit decision left to the owner.

## Hardware re-test plan (throwaway media only)
Copy+ folder test with **Hard Disk Write Protect = Writable** on a fresh
copy of SmartportHD.HDV (never the golden original). Read the debug line
`S=S F=F N=NN M=M W=NN K=NN`:
- W=128 / F=0 / K=0 → core clean AND framework DMA aligned.
- W=128 / F=0 / K>0 → framework starts k words in; K is the exact evidence
  for the host-side alignment fix (the narrowed decode no longer rotates
  the sector, but the first 4k bytes still land shifted).
- W<128 / F=1 → framework gave up mid-DMA (or timeout fired).
- Freeze > ~5 s → the 3.6 s timeout did not fire; chase the FSM state
  shown in S.
Full protocol: `docs/RELEASE_NOTES_0.3.4.md` ("Interpreting the hardware
re-test").
