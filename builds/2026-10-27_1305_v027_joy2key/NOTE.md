# Build 2026-10-27 13:05 — core 0.2.7 (joy2key)

## Identity
- Revision `apf_stream_video`, top `apf_top_stream`, Cyclone V 5CEBA4F23C8,
  Quartus Prime 17.0.2 Lite.
- Compile: owner-run 2026-10-27 13:00 (A&S) / 13:05 (fitter+asm), all
  Successful.
- RTL tip: `749fde6` (feat: joy2key) on top of `e87fcfd` (0.2.6, still
  local-only, unpushed).

## What this build adds vs 0.2.6
- Joy2key: gamepad-to-keystroke injection via the MiSTer donor
  `joy_to_key.v` (byte-pinned import, `JOY_TO_KEY=1` macro).
- Two new writeonly OSD options (both default Off):
  - Direction Keys (id 5, 0x01F00008): Off / Cursor Keys / IJKL / IJMK / A Z
  - Fire Buttons  (id 6, 0x01F0000C): Off / U O / Space Return / U O + Space Return (Select)
- Everything from 0.2.6 (merged Colour Preset list, diagnostics hidden
  while the OSK is open) is in this bitstream too — a single hardware
  test covers both checklists. The pure-0.2.6 image is preserved at
  `builds/2026-10-26_1628_v026_colour_merge_ovlgate/bitstream.rbf_r`
  (restore to the card by copy-back if an A/B is ever wanted).

## Resources / timing
- ALM 9,138 / 18,480 (49%)  [0.2.6: 8,983 — +155 for joy_to_key]
- Setup worst slack +1.205 ns (Slow 1100mV 85C, clk_core_14318 corner group)
- Hold  worst slack +0.124 ns (Fast 1100mV 0C)
- TNS 0.000 all corners

## Artifacts (SHA-256)
- apf_stream_video.rbf    f89c6e0cae28c725406e9a6766aeb1f858dc9026fa4112f45e69ba77bd69b346
- bitstream.rbf_r         4cda9b6c54610c54edcb4b27186e2f2cbcba1714f3835a9bf47867ee70b6f02c
- staged at sd_root/Cores/Newsdee.Apple2e/ (core.json 0.2.7,
  date_release 2026-10-27)

## Sim verification (pre-compile, see commit 749fde6)
pocket_boot, 0 fatals, no new warnings, no EOL churn:
- Off/Off: blank table, presses emit nothing
- all 4 direction presets x 4 directions: exact spec codes
- all 3 fire presets + Select layer (A->Space, B->Return)
- composition (dir+btn independent bytes)
- end-to-end through keyboard.v (kbd.joy_valid + latched code)
- NON-VACUITY: swapped joy_j2k bits 2/3 -> probe fails (up/down
  transposed, code=0b expected 0a). The donor "Bug B" trap is covered.

## Hardware checklist (pending)
1. OSD: two new lists present, both default Off, selection sticks
   (readback wildcard unchanged).
2. Off/Off: no keys typed while playing (paddles unaffected).
3. Direction Keys = Cursor Keys: D-pad arrows type I/J/K/L in a text
   editor (plus the Absolute paddle motion at the same time - the
   intended double duty).
4. IJKL preset: IJKL letters on the same motions.
5. Fire Buttons = U O: A/U, B/O keys.
6. Fire Buttons = U O + Space Return (Select): with the Select button
   held, A types Space and B types Return (space-separated typing).
7. With any preset on: keys stop being typed while the on-screen
   keyboard is open (both paths gated by the same term).
8. Regression: disk boot, colour presets, diagnostics hidden while OSK
   open, 555 audio, Reboot option.
