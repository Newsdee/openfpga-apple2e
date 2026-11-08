# Apple IIe for Analogue Pocket — 0.3.2

First public release since **0.2.5**. Three releases landed: **0.3.0** (hard disk),
**0.3.1** (relative joystick), **0.3.2** (docked USB keyboard). Everything is
backwards-compatible — existing `.woz` disks, `.a2k` joy2key profiles, and the
built-in on-screen keyboard all work as before.

## Docked USB keyboard (0.3.2)
- A **USB keyboard in the Pocket dock** (Player-3 slot) now types into the machine.
  It's routed through the same path as the on-screen keyboard, so keys, LAlt →
  closed-Apple, and typematic behave like the native keyboard.
- **Hot-plug safe**: unplug a key-held keyboard and it breaks cleanly (no stuck key);
  replug resumes. Coexists with the built-in Pocket keyboard and the on-screen keyboard.
- No new settings — it just works when you plug one in.

## Hard disk (HDV) — read-only (0.3.0)
- Mount a **raw `.hdv`** in the **Hard disk** data slot and boot from HD under
  ProDOS 8/16 (Total Replay, Nox Archaist, …). No `.2mg`/`.po` — raw HDV only.
- **Boot Media** option: `Both` / `Floppy` / `HDD`. `HDD` takes the HD card off the
  bus so the floppy path stays clean; the HD is a size-driven auto-mount.
- **HDV auto-boot** (gated by the existing **Reboot on load** option) — select an
  HDV and it cold-reboots into ProDOS after a short settle, so it boots on load.
- **Drive lamps** (top-right, always on, not affected by the debug overlay):
  green = HD read, bright red = floppy read, dark red = floppy spinning, white = HD
  block completed.

## Joystick — relative mode (0.3.1)
- New **Joystick Mode** option: `Absolute` / `Relative`. `Relative` drives the
  Apple paddle/stick continuously from the d-pad (the donor's relative ladder), so
  paddle games feel right. Rate-tuned (1 ms step) to stop where you release it.
- The built-in d-pad (absolute) is unchanged as the default.

## Video & identity (0.3.0)
- **Aspect presets**: Integer now matches Fit (10:9) for a clean undistorted 560-px
  stream; color presets unchanged (NTSC //e, Old TV, AppleWin, Muted Sharp,
  Monochrome, Green, Amber).
- **Core icon** (36×36) in the core browser + platform image.
- Shipping overlay is clean: on-screen diagnostics are hidden; the drive lamps stay.

## Under the hood
- Mixed-language (VHDL/Verilog) integration hardened; HDV bridge byte-order fix so
  the host DMA reads match the real Pocket (this is why HD images now boot).
- Warning triage: behavior-neutral width fixes + documented verified-benign guards.
- Resource footprint on the 5CSEBA6U23I7 fits with margin (ALM ~62–72% by build,
  all timing constraints met).

## Notes / known limitations
- Shifted (lowercase) typing latches the key but the ROM case isn't flipped through
  the forwarded path — a quirk in the donor `keyboard.v` ROM case mapping, not a
  transport bug. Closed-Apple works (LAlt); open-Apple isn't reachable over USB.
- HDV is **read-only** (no write-back to the SD card in this release).

## Install
Copy the whole `Cores\Newsdee.Apple2e\` folder (from the ZIP) to your SD card, or
unzip the whole archive to the card root. Requires Pocket framework **2.0+**.
To use a hard disk: put a `.hdv` in `Assets\apple2e\common\`, name the slot **Hard
disk**, and set **Boot Media = HDD** (or leave `Both`).
