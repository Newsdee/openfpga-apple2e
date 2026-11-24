# Step-1 control: 0.4.4 baseline (PORT=0, 0.4.4 controller + single-block transport)

Run: `verilog/woz_mb/run_control.bat 0` (2026-11-23, Verilator 5.050, full Pocket
stack: controller -> sdram_woz_transport -> sdram_sector_fetch -> sdram_word_owner
-> io_sdram_pocket -> tb_dram_model).

Image: `mb_image2.hex` (gen_mb_image2.py) - WOZ2 5.25", 22 blocks = 11264 B:
meta 3, t0 = 13 blk/51200 bits @3 (donor shape), t1 = 4 blk/20480 @16,
t2 = 2 blk/8192 @20. t0+t1 = quarter-track physical pair 0 (track_id[7:1]==0);
t2 = pair 1.

Result: **TB WOB MB CONTROL: ALL PASS (PORT=0)** - every track's BRAM bytes
exact vs the image oracle (6656 + 2048 + 1024 bytes).

| Phase | cyc | ~µs | ack (round trips) | fetch (window fills) | ready_wait | tstrb | ewr |
|---|---|---|---|---|---|---|---|
| P0 boot/store 2816 words | 4676 | 327 | 0 | 0 | 0 | 0 | 0 |
| P1 mount/scan (3 meta blocks) | 1961 | 137 | 3 | 3 | 9 | 3 | 0 |
| P2 load t0 (50000-cyc settle + 13 blocks) | 58523 | 4088 | 13 | 13 | 39 | 13 | 6656 |
| P3 load t1 (in-pair hop, 4 blocks) | 2635 | 184 | 4 | 4 | 12 | 4 | 2048 |
| **P4 reload t0 (HEADLINE: protected-loader re-seek, in-pair, 13 blocks)** | **8522** | **595** | **13** | **13** | **39** | **13** | **6656** |
| P5 load t2 (cross-pair seek, 2 blocks) | 1329 | 93 | 2 | 2 | 6 | 2 | 1024 |
| P6 check-track t2 (readback walk) | 3073 | 215 | 0 | 0 | 0 | 0 | 0 |

1 machine cycle = 69.844 ns. Per-block cost (old transport) ≈ 655 cyc ≈ 45.8 µs
(stream 512 + S_HOLD/S_RELEASE + fetch round trip + engine per-block handling).

## Findings

1. **Settle semantics (documented, pre-existing):** settle counts only in
   S_IDLE and gates on `track_id[7:1]` (physical track). Quarter-track hops
   inside a physical pair (the "copy-protection nudge" case) load at once -
   that is P3/P4 (no 50k wait). P2 (first load after mount) pays the full
   50000-cycle (3.49 ms) settle.
2. **Cross-pair seek race (pre-existing, in 0.4.4 AND the MiSTer donor):**
   the settle-counter reset (`<= 0`, NBA) and the load gate
   (`settle_counter >= settle_lim`) evaluate in the SAME cycle inside S_IDLE;
   the gate sees the stale saturated counter (50000) and starts the load
   immediately - the reset lands one cycle too late. So the FIRST seek across
   a physical-pair boundary skips the settle wait (P5: 1329 cyc, no 50k).
   The engine's own log even prints "settled after 50000 cycles". Subsequent
   same-pair seeks do wait the full 50k. Not fixed in this port (behavior
   preservation); the donor change does not alter this path.
3. **`disk_mounted` is deliberately immediate** (media-present; the ROM polls
   /DIP) - scan completion is the internal `woz_valid`; the harness P1 phase
   waits on it hierarchically.
4. The engine's "settled after %0d" display prints the saturated counter, not
   elapsed time since the last reset.

## What step 2/3 must match or beat

- Step 2 (ported controller, old transport): bytes + progress must equal the
  rows above (13 round trips per 13-block load; P4 = 8522 ± a few cycles).
- Step 3 (burst transport): P4/P2 should fall to 1 round trip per track load
  (13 window fills remain - batching does not remove SDRAM fills); seek-to-
  valid latency drops by ~12 × (per-block handshake) ≈ ~700 cyc per 13-block
  track in sim. The protected-loader budget comparison is made against P4.
