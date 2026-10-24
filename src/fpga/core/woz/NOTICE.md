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
