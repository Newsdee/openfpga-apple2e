# .a2k joy-keymap editor (Pocket)

`a2k_editor.html` is a byte-identical copy of
`Apple-II_MiSTer/tools/a2k_editor.html` (self-contained HTML+JS, no network).
It edits the 16-byte `joy_map` table consumed by `machine/osk/joy_to_key.v`
(packed layout: bytes 0-3 = directions right/left/down/up, 4-9 = A/B/L/R/X/Y,
10-15 = the same six with Select held) and saves a 16-byte `.a2k` file.
Bytes > 127 are blanked, matching the module's `ioctl_data > 127 -> 0` rule.

## Pocket workflow (differs from the MiSTer "Load Joy Map" OSD item)

The Pocket has no file-load OSD option. Instead the profile is **auto-loaded by
game name**: the core declares an `a2k` data slot (`data.json` id 3,
`parameters` bit2 = filename cloned from the disk slot, read-only,
`required: false`, max 16 bytes). So:

1. Pick a disk, e.g. `Jungle Hunt.woz`.
2. In the editor, set the mappings, Save, and name the file
   `Jungle Hunt.a2k` (same base name as the disk).
3. Put both files on the Pocket SD card (same directory). Mounting
   `Jungle Hunt.woz` makes APF look for `Jungle Hunt.a2k` and DMA its 16
   bytes to bridge address `0x01F10000`; the core captures them and the
   loader pushes the table through the donor's ioctl arm.
4. A present `.a2k` (exactly 16 bytes) **replaces the whole table**,
   overriding the DPad Keys / Fire Keys preset options. Missing (or not
   16 bytes) -> the presets stay in force. A machine reset keeps the last
   loaded table (donor "table survives reset" semantics); remounting a disk
   without a profile drops back to the presets.

No other SD card or core changes are needed. The editor's help line about
"OSD -> System & BIOS -> Load Joy Map" describes the MiSTer path; ignore it
here.
