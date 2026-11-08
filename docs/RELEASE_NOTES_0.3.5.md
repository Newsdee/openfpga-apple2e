# Apple IIe for Analogue Pocket — 0.3.5

The first release with **working hard-disk writes**. The hard disk (HDV) is now
readable **and** writable, and writes are reliable — but it defaults to
**read-only**, so you opt in to writing and your images are safe by default.

## Writable hard disk

- The hard disk (HDV) can now be **written to**, and the changes persist to your
  `.hdv` image on the SD card (ProDOS saves, directory writes, a drive lamp that
  lights on writes).
- **Default is read-only.** Nothing writes to your image until you turn writing
  on, so a disk you boot is not modified by accident.
- Writes are **byte-exact**. An earlier internal build that first added writable
  HDV produced corrupt images; that is fixed here and trusted with real media.
- The **floppy is unchanged** — it's still read-only (floppy write-back is coming
  in a later release).

## Boot Media (combined option)

The old "Boot Media" and "Hard Disk Write Protect" options are merged into one.
Pick both the boot source and the hard disk's write state together:

| value | name |
|---|---|
| 0 | Both, read-only *(default)* |
| 1 | Both, write |
| 2 | Floppy (no HD) |
| 3 | HDD, read-only |
| 4 | HDD, write |

Choose **"Both, write"** or **"HDD, write"** to enable hard-disk writing.

> **Note if you ran an earlier build:** the separate "Hard Disk Write Protect"
> option no longer exists. If you had set it to Writable, pick a "write" value
> above to re-enable it (the option defaults to read-only).
