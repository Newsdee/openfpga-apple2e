# Apple IIe for the Analogue Pocket

An Apple IIe for the [Analogue Pocket](https://www.analogue.com/pocket/), built on the
[openFPGA](https://github.com/open-fpga) / APF platform. It runs real Apple II / IIe
software from a floppy disk and/or a ProDOS hard disk, with a full on-screen keyboard,
joystick and paddle support, a docked USB keyboard, and seven colour presets.

> **New here?** Copy the `Cores/`, `Platforms/` and `Assets/` folders from this repo's
> `sd_root/` to the root of your Pocket's SD card, drop a `.woz` floppy image on the
> card, reboot into **Apple2e**, and select the floppy in Core Settings. It boots to the
> Apple logo and a `Ready.` prompt. Everything else you need is a one-line description
> further down.

## What it does

- **Boots real Apple IIe software** — a 65C02 CPU with the standard Applesoft + Monitor
  ROMs, 64K of RAM. Load a floppy or a hard disk and it runs.
- **Floppy disk** — mount a WOZ (`.woz`) Disk II image. It reads **and writes**, so a
  game that saves its state writes back to your image file.
- **Hard disk** — mount a ProDOS `.hdv` image (up to 2 GiB). Readable **and writable**
  (since 0.3.5). It appears to the machine as the hard-disk volume (ProDOS volume 2 /
  the DOS "HD" drive).
- **On-screen keyboard** — press **START** to open a full Apple II keyboard on screen.
- **Joystick & paddles** — the d-pad and face buttons drive the Apple II paddle port,
  so both digital and analog (paddle) games work.
- **Docked USB keyboard** — the Pocket dock's physical keyboard works as a PS/2 Apple
  keyboard.
- **Colour presets** — NTSC //e, Old TV, AppleWin, Muted Sharp, Monochrome, Green, Amber.
- **Joy2key profiles** — map the d-pad / face buttons to keystrokes for games that
  expect a specific keyboard layout (`.a2k` file).

Video is a native 560×192 stream (no frame buffer), tuned for the Pocket's 10:9 panel.

## Install

1. Copy the `Cores/`, `Platforms/` and `Assets/` folders from this repo's `sd_root/`
   to the **root** of your Pocket's SD card. `Cores/Newsdee.Apple2e/` holds the
   bitstream (`bitstream.rbf_r`) and the core's JSON manifests — they ship as a pair.
2. Put your disk images on the card (a `.woz` for the floppy, a `.hdv` for the hard
   disk), then select each one in the Pocket's **Core Settings** — see
   [Media](#media-floppy--hard-disk--joy2key) below.
3. Reboot the Pocket into **Apple2e**.

That's the whole install. (Building the core from source is in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).)

## Media (floppy, hard disk, joy2key)

The core has three optional **data slots**. To use one, pick its image in the
Pocket's **Core Settings** menu — each slot shows a *"Reload …"* action that opens a
file browser filtered to that slot's file type (`.woz` / `.hdv` / `.a2k`). The image
you select is what the machine sees in that slot. Nothing is pre-loaded: the floppy
and the HDV are read live from the card on every disk access, which is what makes the
HDV writable (0.3.5+).

| Slot | What | File | Notes |
|---|---|---|---|
| **disk** | **Floppy** (Disk II / WOZ) | `.woz` | Up to 4 MiB. Reads and writes (saves persist to the image). Boots the machine like a real WOZ disk. |
| **hard disk** | **Hard disk** (ProDOS HDV) | `.hdv` | Up to 2 GiB (effectively any HDV). Streamed live from the card (not pre-loaded); readable **and writable** (0.3.5+). Shows up as the HD volume (ProDOS volume 2 / DOS "HD" drive). |
| **joy2key profile** | **Joy2key map** | `.a2k` | 16 bytes. Joystick-to-keyboard map (used by the DPad/Fire Keys options below). |

To boot a particular floppy, it's the one you mount in the **disk** slot — or use the
**Boot Media** option to steer (boot both, floppy only, or hard disk only).

Disk images are widely available: WOZ (`.woz`) for floppies, raw ProDOS partition
images (`.hdv`) for the hard disk.

## Controls

### On-screen keyboard (OSK)

Press **START** to open or close the panel.

| Button | Action |
|---|---|
| D-pad | move the cursor |
| A | press the selected key |
| X | Space |
| Y | Backspace (hold to repeat) |
| L1 | move the panel top / bottom |
| R1 | Enter |
| SELECT | cycle panel transparency |
| START | OSK on / off |

The panel's Caps / Ctrl / Shift keys latch like the real machine, and the arrow keys
and the Apple-logo key behave as on the hardware.

### Joystick / paddles

With the OSK **closed**, the d-pad and face buttons drive the Apple II paddle port:

| Button | Apple II |
|---|---|
| D-pad | paddle X / Y — snap to the extremes (Absolute) or accumulate (Relative) |
| A | fire 0 (`$C061`) |
| B | fire 1 (`$C062`) |
| X | centre both paddles |
| Y | second fire / IIe shift (`$C063`) |

**Joystick Mode** (Core Settings) picks **Absolute** — the default, snaps instantly to
the d-pad extremes, good for digital-only games — or **Relative** (slow / normal / fast),
which accumulates a virtual paddle position. Paddle reads use the classic one-shot
interval, so both paddle and digital games work.

## Core Settings

The Pocket's **Core Settings** menu (the core's "OSD") exposes six options:

| Option | What it does |
|---|---|
| **Reboot on load** | Reset the machine when the core loads. On / Off (default **On**). |
| **Boot Media** | What the machine boots from, **plus** the hard disk's write state, in one pick: **Both, read-only** (default) · **Both, write** · **Floppy (no HD)** · **HDD, read-only** · **HDD, write**. |
| **Joystick Mode** | **Absolute** (snap) or **Relative** (slow / normal / fast). |
| **Color Preset** | NTSC //e · Old TV · AppleWin · Muted Sharp · Monochrome · Green · Amber. |
| **DPad Keys** | Map the d-pad to keys — Off / Cursor keys / IJKL / IJMK / A·Z·left·right — for joy2key profiles. |
| **Fire Keys** | Map the face buttons to keys — Off / U·O / Space·Return. |

## Disk format notes

- **Floppy:** `.woz` is the modern WOZ standard and the only format that writes back
  (saves). Other formats, if converted on the fly, are read-only.
- **Hard disk:** `.hdv` is a raw ProDOS partition image. A `.2mg` image can be turned
  into an HDV by stripping its 64-byte header (`dd if=x.2mg of=x.hdv bs=64 skip=1`).

## Licensing

**GPL-3.0-or-later** (see [LICENSE](LICENSE)). The machine RTL derives from the Newsdee
`Apple-II_MiSTer` core (GPL-3); the APF shell is Analogue's `open-fpga/core-template`;
`hid_to_ps2.sv` is imported verbatim from `openfpga-PCXT`. Full provenance and the GPL
source-provision statement for the shipped bitstream are in the `LICENSE` and `NOTICE*`
files.

## Credits

This core builds on a long lineage of Apple IIe work:

- **Stephen Edwards** — the original Apple II+ core (Altera DE2); the root of the machine.
- **Gyurco** — the original MiST port, and many later improvements.
- **Sorgelig / Alexey Melnikov** — the MiSTer framework the machine was ported under.
- **Kitrinx** — the 6502 / 65C02 CPU code and the NTSC colour encoding.
- **AlanSWX** — WOZ floppy support (the Disk II drive).
- **Steven A. Wilson** — the ProDOS hard-disk (HDV) interface.
- **Newsdee** — this Pocket port, on-screen keyboard, colour tuning and presets, and the main curator of the MiSTer FPGA Apple2 core.
- **Analogue** — the openFPGA `core-template` APF shell the core is built on.

The MiSTer core's Mockingboard, Saturn, Super Serial, and Mouse cards are not part of
this core, so they are not credited here.

## For developers

- **Build, project layout, Verilator test harnesses, and the JSON-manifest rules:**
  [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).
- **Release and milestone history:** [`docs/CHANGELOG.md`](docs/CHANGELOG.md).
- **Operating guide for contributors and agents:** [`AGENTS.md`](AGENTS.md).
- Per-release notes: [`docs/RELEASE_NOTES_*`](docs/).
