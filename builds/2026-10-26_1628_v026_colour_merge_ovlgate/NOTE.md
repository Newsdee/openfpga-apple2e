# Build 2026-10-26 16:28 — core 0.2.6 (colour merge + OSK overlay gate)

## Identity
- Revision `apf_stream_video`, top `apf_top_stream`, device 5CEBA4F23C8,
  Quartus Prime 17.0.2 Build 602 Lite.
- core.json: `Apple2e` **0.2.6**, date_release 2026-10-26.
- This is the **0.2.6 public-release candidate**: it bundles the two
  in-scope changes (no separate 0.2.6a/b cuts — owner decision 2026-10-26:
  keep 0.2.6 reserved for the public release, put all current fixes into it).

## Changes vs 0.2.5
1. **Merged Display Mode + Colour Preset** into one writeonly "Colour Preset"
   list (interact.json id 4, 7 options @ 0x01F00004):
   0=NTSC //e, 1=Old TV, 2=AppleWin, 3=Muted (colour + preset [1:0]),
   4=Monochrome, 5=Green, 6=Amber (SCREEN_MODE = [1:0]+1).
   `0x01F00008` is now dead (no latch); the 01F0xxxx read-back wildcard is
   byte-identical to the proven 09:26 form (J7/J9 constraint).
2. **Diagnostic overlay hidden while the OSK is open**: `ovl_debug_en` is now
   purely the ~293 ms post-reset boot window (J11 "keyboard open shows
   diagnostics" escape hatch removed per owner request). Bridge debug reads
   (0xF9xxxxxx) still available.

### Compile note (owner ran it)
- First attempt (16:05) FAILED: the new decode wires used SystemVerilog size
  casts (`2'(expr)`) — Verilator accepts, Quartus 17 `.v`=Verilog-2001 rejects
  (Error 10170 at apf_stream_video_top.v:301-302). Fixed to Verilog-2001-safe
  form (2-bit wire, self-determined add); behaviour identical, re-verified in
  Verilator. Trap documented in AGENTS.md ("The Verilog-2001 trap").
- Successful compile 16:18 A&S / 16:23 fitter.

## Resources (fit.summary, final timing models)
- ALM 8,983 / 18,480 (49 %)   [0.2.5: 8,981 → +2]
- Registers 8,188             [0.2.5: 8,143 → +45 (32-bit word + 3-bit CDC)]
- Block memory 1,544,220 bits (49 %), RAM blocks 192, DSP 29, PLL 2 — unchanged
- Pins 224/224 (100 %)

## Timing
- TNS 0.000 on all clocks/corners (clk_74a, machine divclk mp1/mp2,
  bridge_spiclk; setup/hold/recovery/removal/min-pulse all met).
- Tightest setup slack observed in sta.summary: +0.811 ns (Slow 1100mV 85C).

## Artifacts
- `apf_stream_video.rbf`     sha256 e27a8757cd0a666dde60fd29f8c8339b930b2a304ab2238783a324080bc12270 (1,636,556 B)
- `bitstream.rbf_r`          sha256 2f2e93c64fd74c180b4ab40e58671ed0af5cfc569538da30dbc01177a768c168 (1,636,556 B)

## Sim verification (pocket_boot harness, 0 fatals, no new warnings)
- COLOUR probe: all 7 values decode correctly (v=0..3 → SCREEN_MODE 0 +
  preset 0..3; v=4..6 → SCREEN_MODE 1..3, preset 0). The probe caught a real
  decode bug on the first run ([2:1] part-select mapped 4→2, 5→2 — Monochrome
  unreachable); fixed to [1:0]+1 and re-verified.
- 0x01F00008 confirmed dead (write changes nothing; read = wildcard).
- OVL probe: after the boot window closes, opening the OSK (START) gives
  osk_visible=1 and ovl_debug_en=0 — overlay hidden while keyboard is open.
  (Required a non-`--smoke` soak: `--smoke` exits at the WOZ-mount milestone.)
  The OSK-close sub-check is a non-fatal wait (controller command queue can
  delay the 2nd toggle in full-machine sim — probe-side, not DUT; the gate no
  longer references osk_visible at all).

## Hardware results
PENDING — owner to test on the Pocket:
- [ ] Colour Preset list: all 7 options take effect (4 colour, 3 mono)
- [ ] Diagnostics hidden while OSK open; still visible in the ~293 ms boot
      window; still available via 0xF9xxxxxx bridge debug reads
- [ ] No regression: disk boot, joystick (Absolute), 555 audio, Reboot option
