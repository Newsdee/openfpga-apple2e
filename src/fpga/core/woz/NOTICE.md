# WOZ floppy engine — port of the MiSTer Apple II core

These files are a port of the WOZ floppy engine from the active MiSTer Apple II
core:

```
source: E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/woz/
```

**5 of the 6 files are byte-identical** to the MiSTer source. **One
(`disk_ii_woz.sv`) carries a single documented M1 corner-case fix** (see the
deviation section below) and is therefore NOT byte-identical. The Pocket core
provides the SDRAM-backed sector fetcher (`sdram_sector_fetch`) and the
machine-domain transport (`sdram_woz_transport`) that replace MiSTer's HPS
`sd_*` byte bus.

## SHA-256 pin (verified 2026-10-21)

| File                     | SHA-256 | Status |
|--------------------------|---------|--------|
| `disk_ii_rom.v`          | `8aba944c730a3347d5747bbc55afe2e20e1ab576995db23ad11ffe084539e08c` | byte-identical |
| `disk_ii_woz.sv`         | `68671241dade97262327e1916d501f5da4c89dfb6f43ba5ab8881e2bdfb83066` | **M1 fix applied** (was `d85d9d5bcf79b08e3d6d5580229017893904bf2917e7575be752d5e22b80d9fc`) |
| `flux_drive.v`           | `30500ab058667b52094ab7ea95416efe4d87a2b4347b2eda6ff39e23ea4b554b` | byte-identical |
| `woz_bram.sv`            | `bc6b9c98c8084307e6d5fce7f3601204f71b0ba49e58b248f01a915e7a7785d8` | byte-identical |
| `woz_cell525.sv`         | `5857587e6c4a9addd40f7ee08ed505931496ef44faa1bea82c1050526be76c4c` | byte-identical |
| `woz_floppy_controller.sv` | `d87fcd18c3efc01ae95d17d2bc20aa7c0616ce120fcda495394cb0c0134f29c4` | byte-identical |

Re-verify the 5 byte-identical files:

```bash
cd apple2e-pocket
for f in disk_ii_rom.v flux_drive.v woz_bram.sv woz_cell525.sv woz_floppy_controller.sv; do
  diff <(sha256sum "src/fpga/core/woz/$f") \
       <(sha256sum "E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/woz/$f") || echo "DRIFT: $f"
done
```

## Deviation: `disk_ii_woz.sv` M1 mount corner-case fix (2026-10-21)

**What changed.** In the per-drive `mount` re-pulse machine, the reset-release
branch previously latched the (stale) `media_present`:

```systemverilog
            end else if (dd_reset_d) begin
                remount_pending <= media_present;            // OLD (buggy)
            end else if (!mounted_d && mounted_in) begin
```

When the host's `IMG_MOUNTED0` 0->1 edge lands on the *same* engine clock cycle
as the reset-release edge (`dd_reset_d == 1`), the higher-priority `dd_reset_d`
branch samples `media_present` **before** the `!mounted_d && mounted_in` latch
below it takes effect (both are nonblocking), AND it shadows the direct
mount-edge branch. Result: `remount_pending` is set to the old 0, the mount edge
is consumed without a re-pulse, and the internal `mount` never rises — the
WOZ controller never starts its header scan. On the Pocket this produced
`RD=00000` (zero SDRAM reads) with the CPU actively polling the drive, i.e. the
machine stalled at the Apple logo after a disk load.

**The fix.**

```systemverilog
            end else if (dd_reset_d) begin
                remount_pending <= (!mounted_d && mounted_in)
                                    ? (IMG_SIZE != 64'd0)
                                    : media_present;         // NEW (fixed)
            end else if (!mounted_d && mounted_in) begin
```

The reset-release branch now uses the *simultaneous* mount event's image size
when one is present (which is exactly the collision case), falling back to the
latched `media_present` otherwise. This also keeps the zero-size-eject case
correct (a zero-size event sets `remount_pending` to 0).

**Why the engine was touched at all.** The bug is in the MiSTer engine's mount
logic, not in the Pocket glue. The MiSTer HPS host does not exercise this exact
timing (its reset-vs-mount ordering differs), so it is latent there; the
Pocket's reset-around-reload data-slot path (`data.json` `parameters` bit 6)
lands the mount edge on the reset-release cycle and triggers it. The fix is a
genuine bug fix (it strictly improves the coincident-edge case and is a no-op
for the non-coincident cases), verified in Verilator by
`verilog/tb/tb_woz_mount_race.sv` (buggy engine loses the mount at the
coincidence; a second reset recovers it) and
`verilog/verilate_woz_mount_race_fixed.sh` (the fixed engine recovers at the
coincidence and issues its first read).

**Upstream.** This should be offered upstream to the MiSTer Apple II core.
Until accepted, the Pocket carries the fix and this NOTICE records the
deviation. If MiSTer adopts it, re-import byte-identical and restore the
"byte-identical" status for `disk_ii_woz.sv` here.


## Multi-block SD track reads + TMAP range guard (2026-11-23)

**Donor.** `Apple-II_MiSTer` commit `4cb1d2c1798793e82f18a343eb945f1f1d206d06`
(2026-11-23, "WOZ: multi-block SD track reads + TMAP range guard (backport
from Apple-IIgs upstream)", parent `d4ffea6`), itself the landing of three
Apple-IIgs commits: `6f745a8` (batch track reads), `c3822f8` (advance by the
blocks actually returned), `47f6e4f` (guard invalid track-map indices).

**What was ported** (see `docs/PLAN_WOZ_GS_MULTIBLOCK_2026-11-23.md`):

1. **Controller (`woz_floppy_controller.sv`)** - byte-level port of the
donor diff: track reads request up to 32 blocks per host round trip
(`sd_blk_cnt` = min(blocks_left,32)-1), advance `blocks_processed` / `sd_lba`
by `rd_chunk` = the blocks the host actually returned (`rd_last_blk` from the
ported `sd_buff_blk`), and the TMAP range guard (`track_id_in_map =
track_id < 160`) that gates bit reads, ready/valid, and seek triggers.
The save path and header scan remain single-block (donor behavior).
2. **Wrapper (`disk_ii_woz.sv`)** - donor diff: `SD_BUFF_ADDR` widened 9->14
bits (`[13:9]` = block-in-request, `[8:0]` = byte), `SD_BLK_CNT0/1` outputs,
`SD_BUFF_BLK0/1` inputs.
3. **Top glue (`apple2e/apf_stream_video_top.v`)** - `woz_sd_buff_addr`
widened to 14 bits and the new signals wired. The 0.4.4 single-block
`sdram_woz_transport` consumes `[8:0]` only, so with the old transport the
engine sees `[13:9]=0` on every strobe and behavior is byte-identical to
0.4.4 (verified: control-TB PORT=1 metrics identical to PORT=0).
4. **New module (`apple2e/sdram_woz_transport_mb.v`)** - the Pocket burst
transport (plan step 3). One engine request (sd_rd + sd_lba + sd_blk_cnt)
is answered with up to 32 consecutive 512-byte blocks inside ONE sd_ack
window: ACK rises before block 0 byte 0, stays high through intra-burst
gaps (window release + edge re-arm of the existing
`sdram_sector_fetch`, one outstanding fetch), and falls once after the
final block. Mid-burst fetch faults (a whole sector beyond EOF) end the
burst deterministically as a short answer + `oor_fault` (lifecycle
unmounts; no stale bytes - a fault publishes no window). OOR at
acceptance (sd_lba[31:16] set, or the 17-bit widened sum crossing 16-bit
sector space) faults with no ACK. `sd_wr` from the engine is still the
invariant fault. The 0.4.4 `sdram_woz_transport.v` is UNCHANGED; the two
modules are independently reviewable and the top selects between them
(step 3 lands the batching separately from the step 2 safety fix).

**SHA-256 of the ported set (2026-11-23):**

| File | SHA-256 |
|------|---------|
| `woz_floppy_controller.sv` | `a9159600574a98223f49fef8307b98b42766509c6a0fa94782531a72fd957120` |
| `disk_ii_woz.sv` | `7e48fbf4130990c2a217621920f9acd04c2a68762afc703aa9ca0dd61125b328` |
| `apple2e/sdram_woz_transport_mb.v` | `fd087f1abca05a2578548af0ca329fa62a4695c51c740a175b5f7d3607d55908` |
| `apple2e/apf_stream_video_top.v` | `0042be8dddd660c5ed56f6b5963138cda854aca079d9fdd3fc6c61aea8ec8610` |

After this port `woz_floppy_controller.sv` and `disk_ii_woz.sv` are NO
LONGER byte-identical to the MiSTer source (the SHA table above the
M1-fix section is the pre-port pin).

**Deviations from the donor:**

- **Write-back path is dead on the Pocket (unchanged by this port).** The
donor's save path (`S_SAVE_TRACK`, `sd_wr` to the host) is carried into the
ported controller, but Pocket write-back is still unreachable: `D1_WP`
is hardwired at the top and `flux_drive` gates `write_strobe_d1` on
`!WRITE_PROTECT`, and the transport treats an engine `sd_wr` as an
invariant fault -> `woz_mount_ctl` unmount. Keep WP hardwired; do not wire
a write-capable path in this work. The MiSTer host (HPS) answers `sd_wr`
real writes - the Pocket host does not.
- **The batched host is a new Pocket module, not the MiSTer HPS.** The
donor's protocol changes presuppose a host that answers `sd_blk_cnt+1`
blocks per request; on the Pocket that role is
`sdram_woz_transport_mb.v` (this work). **Hardware outcome (2026-11-24):
the candidate SHIPS build A** (ported controller + TMAP guard on the
0.4.4 single-block transport; `woz_tr` = `sdram_woz_transport`), **shipped
and accepted as 0.4.5 on 2026-11-24** (regression set + protected-loader
run passed on hardware). The burst transport **failed on hardware**
(disk select never loads; Apple polls forever) while passing every sim
gate - bisection: same controller + 0.4.4 transport loads the same disk
fine. B is parked in-tree (unwired) with the suspect documented (intra-
burst fetch re-arm vs real-SDRAM drain; see
`verilog/woz_mb/STEP_RESULTS.md`). The 0.4.4 `sdram_woz_transport.v`
stays the production host; `sdram_woz_transport_mb.v` stays registered
in `apf_apple2.qsf` but uninstantiated.
- **Pre-existing cross-physical-pair settle race** (0.4.4 and donor alike):
the first physical-track change can skip the settle window because the
reset and the load gate evaluate in the same cycle. Not introduced, not
fixed by this port; documented in the step-1 baseline notes.

**Verification (all in this worktree, Verilator 5.050 --binary --timing):**

- `verilog/woz_mb/run_control.bat 0|1|2` - full stack (engine + transport +
  sector fetch + word owner + io_sdram_pocket + DRAM model), deterministic
  WOZ2 image: PORT=0 (0.4.4 baseline) and PORT=1 (ported controller + old
  transport) are ALL PASS with identical phase metrics (byte-exact tracks,
  TMAP guard: ids 160/255 produce no fetch/write/valid, 159 legal-unmapped
  clean, reload after invalid ids byte-exact). PORT=2 (ported controller +
  burst transport) is ALL PASS: every track load completes with ONE ack
  window (13->1, 4->1, 2->1), all bytes exact.
- `verilog/woz_mb/run_transport_mb.bat` - burst-transport DUT against the
  real SDRAM stack: 4-block, 32-block (max width), 1-block parity,
  mid-burst EOF short-answer + oor_fault + recovery, OOR at acceptance,
  mid-burst eject, mid-burst reset; global invariant: no strobe while ACK
  low (every cycle).
- `verilog/woz_mb/run_eng.bat` - engine-level differential TB (fake host):
  13-block FULL (1 request), SINGLE (13 requests), MIXED short answers
  (5,5,3 -> 3 requests with exact LBA sequence); 1-block, 32-block, 33-block
  (32+1 split, 2 requests [49,81]); v1 image with nonzero TRKS byte offset
  (14 blocks, 1 request, v1_bit_count captured at raw 6648/6649); id-160
  guard (no request/valid, cached restore). All bytes exact, no early
  track_data_valid.
- Remaining (owner): existing Pocket regressions (sector fetch, mount,
  mount-race, scan-window; `tb_woz_machine` is known-blocked, pre-existing
  hang since ~2026-10-21 - annotate, do not gate on it), one clean Quartus
  compile of the candidate, and the hardware A/B of the two exact
  bitstreams (0.4.4 vs this candidate) on the same protected loader
  image, >=5 launches each.
