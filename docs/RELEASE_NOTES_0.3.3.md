# Apple IIe for Analogue Pocket — 0.3.3

**Writable hard disk (opt-in).** The HDV is now writable when you say so.
Nox Archaist in-game saves, ProDOS bit-map/directory writes, and a drive
lamp that lights on writes.

## Hard Disk Write Protect option (new)

- New core option **Hard Disk Write Protect**: `Protected` (default) /
  `Writable`.
- **Protected is the default.** With it (and on every boot until you change
  it), the HD behaves exactly like 0.3.0–0.3.2: C0F0 WRITE returns PROTECT,
  the 0x0184 write leg never arms, and the write path is inert but present.
- Set it to **Writable** and ProDOS writes go straight to the `.hdv` on the
  SD card — one atomic 512-byte sector transfer per block (no caching), so a
  power-off mid-write can at worst lose that one block; it cannot tear an
  earlier one.
- The option applies to the **hard disk only**. Floppy write-back is
  unchanged and stays locked in this release.

## Drive lamps

- The green HD lamp now lights on **HD write** activity as well as reads
  (ARM_WRITE/WRITE bridge states, monostable ~140 ms hold, same as reads).
  RED remains the floppy's per the 0.3.0 media reassignment (bright = read,
  dark = spin); WHITE = HD block completed.

## Under the hood

- Un-gate, not a build: the write FSM, sector-buffer walk and 0x0184 host
  read port already shipped inert in 0.3.0; this release replaces the two
  protect ties with the option and adds the option latch (default protected).
- The 0x0184 data leg — never exercised before — is now proven in sim:
  full write round-trip (C0F8 write → 0x0184 capture → 0x0180 re-read →
  C0F8 readout, byte-exact, with a deliberate-mismatch non-vacancy check),
  consecutive slotoffsets, mixed read/write back-to-back, protect toggle
  mid-flight, and write-leg host timeout → C0F1 error (no stale optimistic
  status).
- Durability contract (what survives Quit vs. sleep vs. power-off) is being
  measured on hardware against throwaway media; the measured result will be
  added here and to the option's notes.

## Build

- 0.3.3 bitstream compiled clean (Quartus 17.0.2 Lite, 2026-11-04): TNS 0.000,
  all 80 constraints met, 0 A&S errors, fits with margin (75 % ALM, memory
  bits bit-identical to 0.3.2). Archive + SHAs:
  `builds/2026-11-04_1030_v033_hdvwrt/NOTE.md`.

## Install — TWO files

This release changes **both** the bitstream and the options menu. Copy
**both** `bitstream.rbf_r` **and** `interact.json` from
`Cores\Newsdee.Apple2e\` to the card (easiest: copy the whole folder again).
The pair is matched:

- new bitstream + old `interact.json`: the option is missing from the menu;
  the HD stays protected (the RTL default) — nothing breaks, you just
  can't enable writes.
- old bitstream + new `interact.json`: the option appears but writes to an
  address the old core ignores — nothing breaks, writes stay impossible.

Only the matched pair enables the feature.

## Notes / known limitations

- Floppy disk remains read-only (write-back is the next milestone, W1).
- Writes persist per-sector as they happen; the framework-level
  shutdown/sleep/power-off behaviour of the last in-flight block is the
  item being measured (see Under the hood).
