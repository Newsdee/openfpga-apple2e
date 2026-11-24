# WOZ multi-block port — step results (worktree `apple2e-pocket-wozmb`, base 0.4.4 / `acae14b`)

All runs: Verilator 5.050 `--binary --timing`, MSYS2 UCRT64. Worktree created
2026-11-23 from the released 0.4.4 tip so the uncommitted 0.4.5 video work
stays out (PLAN_WOZ_GS_MULTIBLOCK constraint).

Donor: `Apple-II_MiSTer` `4cb1d2c1798793e82f18a343eb945f1f1d206d06`
("WOZ: multi-block SD track reads + TMAP range guard", GS-derived
`6f745a8`/`c3822f8`/`47f6e4f`), parent `d4ffea6`.

## Step 1 — control baseline (`run_control.bat 0`)

Full stack: ported-or-baseline engine + 0.4.4 single-block transport +
`sdram_sector_fetch` + `sdram_word_owner` + `io_sdram_pocket` + `tb_dram_model`,
deterministic WOZ2 image (`gen_mb_image2.py`, 22 blocks; T0=13, T1=4, T2=2).

Result: **ALL PASS (PORT=0)**. Baseline metrics in `BASELINE_PORT0_044.md`
(P0 boot 4676 cyc; P1 scan 1961 cyc/3 fetch; P2 track-0 58523 cyc/13 fetch/
6656 writes; P4 headline re-seek 8522 cyc; P5 cross-pair 1329 cyc; P6 readback
3073 cyc). All track bytes exact vs image oracle.

## Step 2 — controller port + TMAP guard (`run_control.bat 1`)

Donor controller/wrapper diff applied (`git apply -p2 --directory=src/fpga/core`),
top glue widened (`apf_stream_video_top.v`: 14-bit `woz_sd_buff_addr`,
`woz_sd_blk_cnt0/1`, drive-2 SD outputs explicit).

Result: **ALL PASS (PORT=1)** — phase metrics byte-identical to PORT=0
(same cyc/ack/fetch/writes per phase) with the old single-block transport
consuming `[8:0]` only. Guard checks: TMAP ids 160/255 → no fetch, no BRAM
write, no spurious `track_data_valid`; id 159 (legal, unmapped) → clean
empty-track handling; reload of track 0 after the invalid-id storm byte-exact.

## Step 3 — burst transport (`run_control.bat 2`, `run_transport_mb.bat`)

New module `src/fpga/core/apple2e/sdram_woz_transport_mb.v` (0.4.4
`sdram_woz_transport.v` untouched; independently reviewable, selectable at
the top). One engine request → up to 32 blocks in ONE `sd_ack` window: ACK
rise before byte 0, ACK held through intra-burst gaps (window release +
edge re-arm of the fetcher, one outstanding fetch), one ACK fall at burst
end; mid-burst fetch fault → deterministic short answer + `oor_fault` (no
window published on a fault, so no stale bytes); OOR at acceptance
(incl. 17-bit widened sum) → fault, no ACK; engine `sd_wr` → invariant fault.

- Control TB **PORT=2: ALL PASS** — every track load now ONE ack window
  (13→1, 4→1, 2→1), all bytes exact, guard intact. Headline re-seek
  P4: 8461 cyc vs 8522 (0.4.4) — modest on-Pocket (host is on-chip);
  the MiSTer-side win is per-round-trip host latency, which the hardware
  A/B will show.
- DUT TB **`run_transport_mb.bat`: ALL PASS** — 4-block (2048 B exact),
  32-block max width (16384 B exact, 31 gaps), 1-block parity, mid-burst
  EOF short answer (512 B, oor_fault, recovery), OOR-at-acceptance,
  mid-burst eject (clean abort + remount), mid-burst DUT+fetcher reset
  (held window self-releases, recovery). Global invariant every cycle:
  no `sd_buff_wr` while `sd_ack` low.

## Step 4 — controller differential TB (`run_eng.bat`)

`tb_woz_mb_eng.sv` (donor-TB adapted, no donor scratch dependency): fake host
with FULL / SINGLE / MIXED (short answers ≤5 blocks) modes, two generated
images (`gen_mb_eng_image.py`: WOZ2 82 blocks with 13/1/32/33-block tracks;
v1 14 blocks with TRKS data at absolute byte 256 → nonzero
`trks_byte_offset`, `v1_bit_count=0x1234`).

**ALL PASS**:
- A 13-block FULL → 1 request (sd_blk_cnt=12), 6656 B exact
- B 13-block SINGLE → 13 requests, exact LBA sequence
- C 13-block MIXED → 3 requests (5,5,3), exact LBA sequence [3,8,13]
- D 1-block → 1 request (cnt=0), 512 B exact
- E 32-block → 1 request (cnt=31, max width), 16384 B exact
- F 33-block → 2 requests [49,81] (32+1 split), 16896 B exact
- G v1 nonzero-offset → 1 request (cnt=13, 14 blocks), 6656 B exact,
  bit_count=0x1234 captured at raw 6648/6649
- H guard: id=160 → no request, no valid; cached restore with no request
- no early `track_data_valid` in any phase (monitored every cycle while the
  phase's blocks were still outstanding)

## Existing regression suite (plan gate list)

| Gate | Status on this worktree |
|------|-------------------------|
| scan-window `run_t5_scanwin.bat` (ported controller) | **PASS** (`run_scanwin_wt.bat`, "TB WOZ SCANWIN: ALL PASS") |
| sector fetch `tb_sector_fetch` | not re-run: DUT files (`sdram_sector_fetch.v`, `sdram_word_owner.v`, `io_sdram_pocket.v`) byte-identical to 0.4.4 (`git diff` clean in worktree); 0.4.4 PASS logs remain valid. The full-stack control/transport TBs above exercise the same stack with the ported controller. |
| mount `tb_woz_mount_ctl` | not re-run: `woz_mount_ctl.v` unchanged; same argument. |
| mount-race `verilate_woz_mount_race_fixed.sh` | not re-run: uses the pinned `disk_ii_woz_patched.sv` copy (module `_patched`); the M1 fix region of the live `disk_ii_woz.sv` is untouched by the donor diff (worktree `git diff` shows only the SD_BLK_CNT / 14-bit SD_BUFF_ADDR additions). |
| integrated machine `tb_woz_machine` | **known-blocked** (pre-existing hang after T0a since ~2026-10-21, PLAN addendum #1; verified 2026-11-22). Annotated, not gating; the other gates carry the pass/fail weight per the plan. |

## Open / owner actions

**Decision (2026-11-24, final): the hardware candidate SHIPS build A** -
ported controller + TMAP guard on the **0.4.4 single-block transport**
(`apf_stream_video_top.v` instantiates `sdram_woz_transport`; the 14-bit
`woz_sd_buff_addr` plumbing stays, `[13:9]` read as 0). Tagged **0.4.5a**
for the hardware A/B (`builds/2026-11-24_wozmb_guard_only_A_045/`,
bitstream `99c6fb1b…`); **shipped and accepted as 0.4.5 on 2026-11-24**:
hardware regression set (ordinary WOZ boot, disk swap, floppy audio, HDV
read/write) and the protected-loader run both passed on the same
bitstream (owner: "it all works fine").

**Option B (burst transport) FAILED ON HARDWARE and is parked.**
2026-11-24 bisection: build B (0.4.5, burst transport) boots (after the
rbf_r bit-reversal packaging fix) but disk selection never loads: Apple
polls forever (cursor spinning), no mount; user reset (the "reboot").
Build A (same ported controller + guard, 0.4.4 transport) **loads the same
disk fine** on the same card. So the burst transport - which passed every
sim gate (control PORT=2, transport DUT TB, engine TB, scanwin) -
deadlocks on real SDRAM timing. Prime suspect: the intra-burst fetch
re-arm (S_GAP: sector_done release, wait fetch_busy low + 1 margin cycle,
fresh 0->1 edge) - the fetcher's edge-based acceptance can miss the re-arm
when the real SDRAM controller's post-done drain differs from the
behavioral model; 0.4.4's field-hardened stale-window guard (2026-10-22)
proves the fetcher re-arm is finicky on hardware. Fix if B is revived:
make the re-arm self-healing (bounded re-pulse retries until accepted)
and re-run the transport DUT TB with a fetcher model that adds
drain variability. Until then B stays in-tree, sim-proven, NOT wired.

1. ~~Final acceptance~~ **DONE 2026-11-24**: regression set +
   protected-loader run passed on 0.4.5 (see decision above).
2. Offer the M1 mount fix upstream to MiSTer (flagged in NOTICE.md).
