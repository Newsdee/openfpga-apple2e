# WOZ floppy engine — byte-identical port

These 6 files are a **byte-identical** port of the WOZ floppy engine from the
active MiSTer Apple II core:

```
source: E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/woz/
```

They are imported unchanged (M1 is a port, not a design): the engine is
complete and hardware-proven on MiSTer, so its behavior is authoritative and
must not drift. The Pocket core provides the SDRAM-backed sector fetcher
(`sdram_sector_fetch`) and the machine-domain transport
(`sdram_woz_transport`) that replace MiSTer's HPS `sd_*` byte bus.

## SHA-256 pin (verified byte-identical to source, 2026-10-21)

| File                     | SHA-256 |
|--------------------------|---------|
| `disk_ii_rom.v`          | `8aba944c730a3347d5747bbc55afe2e20e1ab576995db23ad11ffe084539e08c` |
| `disk_ii_woz.sv`         | `d85d9d5bcf79b08e3d6d5580229017893904bf2917e7575be752d5e22b80d9fc` |
| `flux_drive.v`           | `30500ab058667b52094ab7ea95416efe4d87a2b4347b2eda6ff39e23ea4b554b` |
| `woz_bram.sv`            | `bc6b9c98c8084307e6d5fce7f3601204f71b0ba49e58b248f01a915e7a7785d8` |
| `woz_cell525.sv`         | `5857587e6c4a9addd40f7ee08ed505931496ef44faa1bea82c1050526be76c4c` |
| `woz_floppy_controller.sv` | `d87fcd18c3efc01ae95d17d2bc20aa7c0616ce120fcda495394cb0c0134f29c4` |

Re-verify with:

```bash
cd apple2e-pocket
for f in disk_ii_rom.v disk_ii_woz.sv flux_drive.v woz_bram.sv woz_cell525.sv woz_floppy_controller.sv; do
  diff <(sha256sum "src/fpga/core/woz/$f") \
       <(sha256sum "E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/woz/$f") || echo "DRIFT: $f"
done
```

If a future MiSTer engine change is needed, re-import byte-identical and
re-pin the hashes here — do not hand-edit the Pocket copies.
