# Release 0.4.4 — 2026-11-22

**joy2key per-slot "Custom (.a2k profile)" options + off-switch; joy2key
profiles become tracked and ship in the release.**

0.4.3 (a2k big-endian capture + WOZ scan-window flux, both unchanged here)
plus the joy2key activation redesign requested after 0.4.3's one gap:
*once a profile was loaded it could not be switched off* — a present file
forced joy2key on no matter what the DPad/Fire options said. This release
makes the profile an explicit, per-slot *source selection*, and turns the
`.a2k` profile set into real release content (first zip to ship the
profiles).

## What's new over 0.4.3

### joy2key: "Custom (.a2k profile)" on DPad Keys and Fire Keys

Each option now independently says where its key table comes from:

| DPad Keys | Fire Keys | dpad bytes (0-3) | face/shoulder bytes (4-15) |
|---|---|---|---|
| preset (Cursor/IJKL/IJMK/A-Z) | preset (U-O/Space-Return) | that preset | that preset (file ignored) |
| **Custom** | preset | **loaded file** (blank if absent) | preset |
| preset | **Custom** | preset | **loaded file** (blank if absent) |
| **Custom** | **Custom** | **loaded file** | **loaded file** (the full profile) |

- **Off-switch (the 0.4.3 glitch):** set an option to Off — or any preset —
  and the loaded profile is ignored for those keys. No more "how do I turn
  off my profile".
- **Mixing is a feature:** e.g. profile dpad + preset Space/Return fire keys.
- Custom with no file loaded = blank (off), so "Custom" is also a safe
  default-Off state.
- **One-time behavior change from 0.4.3:** a present profile no longer
  activates by itself. After updating, pick Custom once to use a loaded
  profile (the old auto-activation is what made the off-switch impossible).
- `off.a2k` (shipped, all 16 bytes zero) remains the explicit "off
  profile" — and was the only off-switch on 0.4.3.

RTL: per-slot source selection in `apf_stream_video_top.v`
(`j2k_dir_custom` = DPad value 5, `j2k_btn_custom` = Fire value 3; each
selects between the latched `.a2k` bytes and the preset table per table
index; the file-presence term is out of `j2k_en`). `interact.json` adds the
option values. Sim: `pocket_boot` J2K section covers the full state
sequence — Custom no-file = off, Custom + file = profile, presets with
file present = ignored, byte-change reload, unmount = off, presets
restored.

### Joy2key profiles: tracked in the repo and shipped in the zip

- `sd_root/Assets/apple2e/common/Joy2key/` (and `disk.a2k`, the Assets
  README) are now git-tracked via a `.gitignore` exception (the bulky
  `.woz`/`.hdv` fixtures stay untracked). The layout:
  - generic layouts: `IJKL_layout`, `QAOP_layout`, `cursor_space_enter`
  - `Game Specific\`: Alien Typhoon, Castle Wolfenstein, Karateka,
    Snake Byte, Thunderbirds GX
  - `Others\`: `tester.a2k` (label test — each button types its own slot
    letter; the profile that found the 0.4.3 endian bug)
  - `off.a2k`: every button does nothing
- The Assets README documents the 16-byte format (slot order, 0 = no key,
  >127 stored as no key) and the Custom activation rules.
- `Apple2e_Pocket_0.4.4.zip` is the first release containing the profiles
  (0.4.2/0.4.3 shipped the README only).

## Build

- Fitter Successful 2026-11-22 22:58, Standard Fit, `DEVKEY_DIAG=0`
  (shipping diagnostics off).
- 11,226 / 18,480 ALM (61 %, +19 over 0.4.3), 12,829 registers, RAM
  202/308 (66 %), pins 224/224, DSP 29, PLL 2.
- STA: TNS 0.000 all corners (min setup slack 1.571 ns).
- Build roll: `builds/2026-11-22_2258_customopt_044/`.
- `apf_apple2.rbf` SHA-256
  `dd7a3924d4d17ab89328c53aec57c329d94efa38405f42dc73f821e4b4202ecf`;
  `bitstream.rbf_r` SHA-256
  `4b07f7ec9b84c6d463cfd30481de81cb9b03059c870423837dd89c7d8c3e3e93`.

## Hardware verification (2026-11-22, user)

- UI reports 0.4.4; boot and WOZ loads clean.
- Custom + loaded profile maps correctly (per the profile's table).
- Off-switch works: profile loaded + DPad/Fire set to Off/preset → those
  keys stop following the profile.
- Mixed sources (preset on one option + Custom on the other) behave per the
  table above.
- User verdict: "works great".

Sim note: the `pocket_boot` harness elaborates and compiles clean with the
new J2K sequence; the final functional `--smoke` run was still
host-AV-blocked at packaging time (freshly linked test PEs killed; rerun
command in the build roll's NOTE).

## Known issues

Carried from 0.4.3 (no change):
- M10K transport placement gate: still validated by consecutive clean
  hardware rolls; a bad roll can corrupt host→machine transfers.
- The WOZ scan-window fix (0.4.3) is also backportable to the MiSTer core
  (same module) — see
  `E:\MiSTer\Apple-II_FPGAdev\WOZ_SCAN_WINDOW_BACKPORT_2026-11-22.md`.
- Mockingboard state is not captured in savestates.

## Packaging

`Apple2e_Pocket_0.4.4.zip` = `Cores/Newsdee.Apple2e/` (9 files, no
`interact_beeper_swap.json`) + `Assets/apple2e/common/` (README, `disk.a2k`,
`Joy2key/` full tree) + `Platforms/apple2e.json`. First release to ship the
joy2key profiles.
