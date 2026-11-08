# Build 2026-11-07 15:02 -- diagnostic + OOB-encoded readback (framework-ticket trace build)

**Supersedes:** the 2026-11-07 12:01 diagnostic build (always-on overlay, OOR
= 0) and the 10:32 0.3.4b bitstream. This is a **DIAGNOSTIC build, not for
shipping** (OVL_DEBUG=1 overlay + OOB_ENCODE=1).

## Contents vs 10:32 (0.3.4b)
- `hdv_bridge.sv`: new `OOB_ENCODE` parameter (default 0 = shipping behavior,
  OOR reads return 0). In this build it is 1 via `.OOB_ENCODE(OVL_DEBUG)`:
  out-of-window reads (`0x01F01200+`) return
  `{16'hA5A5, addr[9:2], 8'h00}` = the out-of-window **word index**.
  Purpose (framework ticket refinement): the tail words of each corrupted
  sector in the next HDV image record the host's actual OOR read addresses in
  order -> k per transfer, monotonicity, skips; answers the k=1-vs-2 question
  from the file itself.
- `apf_stream_video_top.v`: `.OOB_ENCODE(OVL_DEBUG)` on the bridge instance;
  the two `DIAGNOSTIC` overlay lines (OVL_DEBUG=1, ovl_debug_en=1) remain so
  the S/F/N/M/W/K line is visible after the test.
- Nothing else changed.

## Compile (owner-launched, 2026-11-07)
- A&S: Successful Sat Nov 07 14:53:29
- Fitter: Successful 15:01:58 -- ALM 15,859/18,480 (86 %), registers 15,143,
  pins 224/224, block memory bits 1,557,504 (UNCHANGED), RAM 193, DSP 29,
  PLL 2.
- STA: all TNS 0.000; clk_74a setup slack +2.047 ns.
- Assembler: 15:02, RBF 1,830,476 B.
- Warnings: zero new correctness classes; zero Warning (10268); standing
  18236 (NUM_PARALLEL_PROCESSORS) only.
- Build ID baked in: 0E0=20261107, 0E1=00144959, 0E2=a4453008.

## Sim (pre-compile gate)
- `verilog/hdv_bridge/run_hdv_bridge.sh` -- TB DUT runs `.OOB_ENCODE(1'b1)`:
  T8c/T8d now assert the exact encoded OOR values (index 128 @ 0x200;
  128/129 @ 0x200/0x204).
  `HDV BRIDGE ALL CHECKS PASSED`, read_cmds=6 write_cmds=7 failures=0,
  15/15 PASS. (Shipping zero-return is the parameter default; a one-line
  mux.)

## Staged
- `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r`
  sha256 2866e254492a2e578286a0189e266c271b57854430ac6a8d6bc750c6864986e1
  (round-trip bit-reverse == compiled RBF
  4e317240caf84fdfea81ef0035002b0e81f9ffda86a937fa15520dff40b22782,
  1,830,476 B).

## Hardware test procedure
1. Copy `sd_root/Cores/Newsdee.Apple2e/` to the Pocket card under `Cores\`
   (SHA-256 the rbf_r to confirm), **full reboot**.
2. Mount a fresh throwaway copy of SmartportHD.HDV, Writable.
3. Boot, Copy+, create folder, hit the livelock, force-reboot.
4. Recover the HDV from the card -> expect the same 5 damaged sectors; the
   tails now contain A5A5 A5 XX 00 words = the host's OOR read sequence.
5. Decode: first A5A5 index = 128 + k (k = host start offset for that
   transfer); indices must be consecutive; compare k across sectors/runs
   (answers framework ticket Q3).

## Revert before any shipping build
- `apf_stream_video_top.v`: `OVL_DEBUG` -> 1'b0; `ovl_debug_en` ->
  `(dbg_win_cnt != OVL_DBG_WIN_CYCLES)`.
- `OOB_ENCODE` needs no revert (default 0 = shipping behavior); the top-level
  `.OOB_ENCODE(OVL_DEBUG)` can stay (it evaluates to 0 in shipping).
