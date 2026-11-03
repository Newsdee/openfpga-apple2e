# NOTICE - hid_to_ps2.sv (verbatim import)

- File: `hid_to_ps2.sv` (this directory)
- Import policy: **verbatim, zero edits** (owner decision 2026-11-02). Do
  not modify this file in place. If a local change is ever required, it
  becomes a derivative with a divergence note here (and re-diff against
  upstream first).
- Upstream: https://github.com/desaster/openfpga-PCXT
  - Commit: `b448ddbb37ea47dbc99713a067e3849c29fb421d` (2026-07-27,
    "bump up the HDD dataslots to 2GB maximum size"; upstream/main was
    fetched same-day and the checkout was 0 commits behind)
  - Path: `src/fpga/core/hid_to_ps2.sv`
  - License: GPL-3.0-or-later (repo LICENSE; the file itself carries no
    individual notice, so it inherits the repo license)
- SHA-256 of imported bytes:
  `3e625d0c6b18c51564efbe43285e59808bef7ada4fa2694e4493d30e0b004b11`
- Purpose: USB-HID (Pocket docked keyboard, PAD slot 3, type 0x4) ->
  PS/2 Set-2 event stream `ps2_key[10:0] = {strobe, pressed, ext,
  code[7:0]}` feeding the donor `machine/keyboard.v` PS/2 path (the socket
  currently tied to `11'h0` in `apple2e_osk.v`).
- Related-but-NOT-imported: PCXT's `pocket_keyboard.sv` is a behavioral
  reference only (report-stabilization / set-diff patterns will be written
  as our own glue in `apple2e_osk.v` / top, not copied - PCXT's consumer
  interface (KFPS2KB ready/valid serial) differs from ours).
