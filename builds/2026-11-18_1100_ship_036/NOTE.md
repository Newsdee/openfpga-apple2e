# 2026-11-18 11:00 — 0.3.6 RELEASE CANDIDATE (shipping tree, diagnostics flagged out)

First SHIP-class build of the savestate era. All diagnostic overlays are
compile-flagged OFF; the savestate feature itself ships.

- Fit: 14,823/18,480 ALM (80%), assembler successful 11:00.
  (vs 15,975/86% at 09:54 with the SS overlay line + devkey console on:
  the DEVKEY_DIAG gate removes devkey_uart entirely - 0 references in the
  fit report - plus the ssd_snap CDC path and the SS overlay line.)
- Gates (verified in the map report, both hierarchy levels):
  OVL_SS_DIAG=0, OVL_SS_ONLY=0, DEVKEY_DIAG=0, manager SS_DBG=0.
- What SHIPS in 0.3.6 (vs 0.3.5):
  * Savestate SAVE and LOAD through the host's .sta slot file
    (the whole saga: save command-wedge fix, load wr_ovf queue-persistence
    fix, one-word load-base correction - all hardware-validated on the
    diagnostic builds 13:13 / 11:34 / 23:19).
  * IDLE_PERIOD console-verbosity knob (no console itself - DEVKEY off).
- What does NOT ship: devkey serial console (SSD/SSX/SS HD lines), overlay
  text (OVL_SS_DIAG/ONLY), SS HD header latches (SS_DBG), LED_TX, DUT tap
  wiring. All remain in-tree behind the flags (git fbccf45 = full diagnostic
  tree) for the next diagnostic cycle.
- rbf    sha256: 11:00 build (see fit/asm reports, apf_apple2.*)
- rbf_r  sha256: 3b27bbd5117f26792f64f9bbccfcfb468596d3b3457d881741cbbd415424f140
  staged: sd_root_release/Cores/Newsdee.Apple2e/ + K:\Cores\Newsdee.Apple2e\
  (hash-verified identical; card now PREVIEWING the 0.3.6 RC).
- Release package: sd_root_release/Apple2e_Pocket_0.3.6.zip (11 entries,
  same layout as 0.3.5: Cores/Newsdee.Apple2e/ x9 + Assets + Platforms).
- core.json: version 0.3.6, date_release 2026-11-18, description +savestate.

### 11:3x re-cut ("save not supported" fix)
First RC cut was packaged from the stale 0.3.5 release core.json, which has
`sleep_supported: false`. The host gates its Save States feature on that flag
(spec: "sleep/save-state uses host 00A0/00A4"), so the Pocket refused the
menu. The dev-era card core.json (sd_root, flipped during savestate bring-up
- commit 358096a) has `sleep_supported: true`, which is why every diagnostic
build saved fine. Fixed: sleep_supported=true in the RC core.json + K: copy
+ zip re-cut (zip sha256 68a65533...). Bitstream unchanged (no rebuild).
`cartridge_adapter` intentionally stays -1 (dev-era 0 powered the dev-key
dongle; 0.3.6 has no console, so shipping keeps cart power off).
- Sim validation of the shipping tree (pre-compile): M0/M1 fast, integration
  (default + UNPACED), roundtrip, cmdrace, devkey, minirepro G0 - see
  session record 2026-11-18 (ladder run after the generate-scope fix).

PREVIEW CHECKLIST (user, on hardware):
1. Core menu shows "Apple2e 0.3.6".
2. Boots Apple II normally (no devkey console chatter on the dongle).
3. One save + one load cycle: save OK, load restores (loading a .sta
   written by the diagnostic core is legal - same core name/format).
4. If a feature is added before release, re-version this RC (0.3.6-r2 etc.)
   or fold it in and re-cut the zip.
