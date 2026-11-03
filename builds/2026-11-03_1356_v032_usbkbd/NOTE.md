# Build archive: 2026-11-03 13:56 — v0.3.2 docked USB HID keyboard

Purpose: 0.3.2 adds **docked USB HID keyboard** support (PLAN_USB_KEYBOARD_2026-11-02).
A USB keyboard in the Pocket dock (Player-3 slot, controller type 4) is delivered by
the framework as a raw HID report (`cont3_key[31:28]=type`, `[15:8]=mods`, `cont3_joy`
= HID usage slots 1-4, `cont3_trig` = slots 5-6). It is routed through the verbatim
`hid_to_ps2.sv` (PCXT import) into the existing OSK/PS2 path, so a docked keyboard
types into the machine exactly like the on-screen keyboard does.

## What changed (vs 0.3.1 joystick build f5105e2f)
- `src/fpga/core/apple2e/apple2e_osk.v` (WP1 glue): `cont3_key`/`cont3_joy`/`cont3_trig`
  ports, 2FF sync (pad/74a -> machine 14.318 MHz) + 4-cycle report-stabilization gate
  (discards a torn multi-word crossing), type gate (`cont3_key[31:28]==4`, else presents
  an all-zero idle report so a hot-unplug / non-keyboard breaks cleanly), `hid_to_ps2`
  instance, `ps2_usb` -> `virtual_keyboard_controller.ps2_key` (replaces the old 11'h0 tie).
- `src/fpga/core/hid_to_ps2.sv` + `NOTICE_hid_to_ps2.md`: verbatim PCXT import
  (SHA-256 `3e625d0c…`); diffs reports for make/break, typematic comes from the
  downstream OSK controller.
- `src/fpga/core/apple2e/apf_stream_video_top.v` (WP2): live `apple2e_osk` instance
  connects the real `cont3_*`.
- `src/fpga/core/apple2e/apple2e_core_top.v` (WP2): legacy/monochrome instance ties
  `cont3_*` to 0.
- `src/fpga/apf_stream_video.qsf` (WP3): registers `core/hid_to_ps2.sv`.
- `verilog/pocket_boot/build.sh` (WP3): adds `hid_to_ps2.sv` to the sim file list.
- `verilog/tb/tb_pocket_kbd.sv` + `run_kbd_suites.{sh,bat}` (WP4): unit TB, 14/14 green.

No `interact.json`/`data.json`/`video.json` change (a docked keyboard is a hardware
input, not an OSD option or media slot). `core.json` bumped 0.3.1 -> 0.3.2.

## Compile (Quartus 17.0.2 Lite) — shipping-clean (OVL_DEBUG=0)
- `OVL_DEBUG=1'b0`: debug text/lines off for shipping; drive lamps stay (not OVL_DBG-gated).
  (First 0.3.2 pass was compiled with OVL_DEBUG=1 inherited from the joystick probe;
  recompiled 14:12 with OVL_DEBUG=0 for the shipping bitstream.)
- Fit: Successful. ALM 11,544 / 18,480 (62%).
- STA: TNS 0.000 (all 80 constraints met).
- ASM: Successful. `.rbf` 1,718,520 bytes.
- Resources: registers 14,519; block memory 1,557,504 / 3,153,920 (49%);
  pins 224 / 224 (100%); DSP 29 / 66 (44%).
- A&S registers `core/hid_to_ps2.sv` + `core/apple2e/apple2e_osk.v` (USB-kbd sources
  confirmed in the map report).

## SHA-256
- source `.rbf`:        `1c4dad6ccba2b4b5d64ebdb05fb9399cb9d0216d6069cc3bbf08e6d52e1c0082`
- `bitstream.rbf_r`:    `cc058003629fc42446a791143d4cf8fe35507f1674f3e809032d21b284fc53d3`

## Unit TB (run_kbd_suites.bat) — PASS (all checks)
Proven (hard checks): USB pass-through with the OSK closed (unshifted 'A'=0x41 make +
reads-ack), break clears `akd` (key-down), two-key order independence, rollover
no-garbage, hot-unplug no-stuck + replug, torn-word no-phantom, LAlt->closed_apple +
release, reset idle. Recorded findings (probes, not hard-fail):
- Shift latches `kbd.shift=1` but does not flip the ROM case (stays uppercase) through
  the raw-PS/2 pass-through — a donor `keyboard.v`/ROM case-bit observation, not a
  USB-transport or TB bug.
- Open-Apple is unreachable over USB as wired (GUI modifier maps to `0x00`; Launch-App-1
  does not reach `0x1F`). `closed_apple` works via LAlt/RAlt.

## Hardware test (WP5)
1. Copy `sd_root/Cores/Newsdee.Apple2e/` -> card (bitstream.rbf_r + core.json changed).
2. Reboot, connect a USB keyboard in the dock.
   - Type into BASIC / ProDOS: keys should appear (uppercase unshifted).
   - LAlt -> closed_apple (Cmd-Apple). Shift should type (case per the finding above).
   - Hot-unplug with a key held: no stuck key.
   - Built-in Pocket keyboard (type 0x1) still flows to `cont1_key` unchanged.
3. On-screen keyboard still works as before (the USB path is additive).

## Pending
- Warning triage / QSF noise suppression still deferred (blocked on exact Quartus 17
  `SUPPRESS_MESSAGE` syntax).
- Optional: open-Apple over USB (a Pocket glue mapping, e.g. a candidate HID usage ->
  PS/2 0x1F) if the owner wants it — separate pass, do not touch the pinned hid_to_ps2.
