# .a2k joy-keymap editor (Pocket)

`a2k_editor.html` is a byte-identical copy of
`Apple-II_MiSTer/tools/a2k_editor.html` (self-contained HTML+JS, no network).
It edits the 16-byte `joy_map` table consumed by `machine/osk/joy_to_key.v`
(packed layout: bytes 0-3 = directions right/left/down/up, 4-9 = A/B/L/R/X/Y,
10-15 = the same six with Select held) and saves a 16-byte `.a2k` file.
Bytes > 127 are blanked, matching the module's `ioctl_data > 127 -> 0` rule.

## Pocket workflow (differs from the MiSTer "Load Joy Map" OSD item)

The Pocket has no file-load OSD option. Instead the profile is **auto-loaded
from the SD card**: the core declares an `a2k` data slot (`data.json` id 3,
`parameters` bit 2 = filename cloned from the disk slot, `required: false`,
max 16 bytes, platform-common Assets location). The host DMAs the file to
bridge address `0x01F10000` on mount; the core captures the bytes and the
joy2key loader pushes the table through the donor's ioctl arm.

**The disk slot has a FIXED filename: the host loads `disk.woz` and therefore
looks for `disk.a2k`** (in `Assets/apple2e/common/`, next to the disk).
The game-name clone only applies when you re-pick the disk *by name* through
the interact browser (the disk slot is user-reloadable): loading
`JungleHunt.woz` that way makes the host look for `JungleHunt.a2k`.

The profile slot is also **user-reloadable** (`parameters` bit 0): the core UI
shows a **"joy2key profile"** media option next to the disk. Picking any
`.a2k` there (the spares in `Joy2key\` included) overrides the table for the
current session — the choice does NOT persist (bit 9 unset), so the next
boot returns to the cloned name (`disk.a2k`). If you swap the disk via its
browser, re-pick the profile to match.

So the practical steps are:

1. Make or pick a profile. Ship spares live in
   `Assets/apple2e/common/Joy2key/` (byte-identical copies of
   `Apple-II_MiSTer/Joy2key/`: IJKL_layout, QAOP_layout,
   cursor_space_enter, AlienTyphoon, CastleWolfenstein, ThunderbirdsGX).
   Or open `a2k_editor.html` in a browser, set the mappings, and Save.
2. **Name it `disk.a2k`** and put it next to `disk.woz` (boot path), or
   `<DiskName>.a2k` if you load that disk by name via the browser.
3. Boot/mount: the present 16-byte `.a2k` **replaces the whole table**,
   overriding the DPad Keys / Fire Keys preset options. Missing (or not
   exactly 16 bytes) -> the presets stay in force.
4. To revert: delete (or rename away) the `.a2k` and remount. A machine
   reset keeps the last loaded table (donor "table survives reset"
   semantics); the host re-DMAs on the next mount.

No other SD card or core changes are needed. The editor's help line about
"OSD -> System & BIOS -> Load Joy Map" describes the MiSTer path; ignore it
here.
