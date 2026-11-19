# Build archive — 2026-11-15 22:09 `apf_apple2` (devkey E0: button→LED self-test)

Diagnostic build. NEVER ship as-is (see "Diagnostic contents").

## Contents (delta vs 18:10 build `5c47855f…`)

- `devkey_uart.v`: `led` normal branch now ORs the synced button
  (`led = test_mode ? btn_s2 : (ss_busy | rx_blink | btn_s2)`) — press the
  dongle button ⇒ LED, any time. +1 ALUT.
- Everything else as the 18:10 diagnostic: `OVL_SS_DIAG = 1'b1`
  (`sdram_status_overlay.v` — the 95% utilization), devkey UART RX/TX,
  savestate read-grant fix, `core.json: "cartridge_adapter": 0` (cart power).

## Hashes

- `apf_apple2.rbf`       = `0530ce99ae90dfc1da5833fd9e511e00f0611c91ec59843f8cefb640db67137d` (1,872,828 B)
- `bitstream.rbf_r`     = `4bf0cac43eb82e23e55a549ca566a0633a08777c10a0855b3f19151c2206951d` (reversed, as staged on the card 11-15 22:26)
- `core.json`           = as staged on card (`cartridge_adapter: 0`)

Staged via the validated Perl bit-reversal transform (`C:/Temp/bitrbf.pl`,
hash-identical to `tools/rbf2rbf_r.py` output on the archived 10-25 pair) —
no Python in agent sessions.

## Numbers (22:09 fit)

- 17,555 / 18,480 ALMs (95%), 16,966 registers, timing clean.
  (+25 ALMs vs 18:10's 17,530: leaf re-layout, not the +1 OR.)

## Why this build exists — and what it proved (E0 result)

Bench test 11-15 evening:
- **Button press → LED on** (immediate). Proves cart power ON under this
  core, button pin `bank3[0]` mapped, LED pin `bank0[5]` mapped, FPGA drives
  the cart pod.
- **RX dead**: typed bytes (PuTTY, COM4) → no `rx_blink` LED, no effect.
- **Wire A/B** (`tools/com4_probe.ps1`): core running ⇒ clean ~5.76 kHz
  core-gated periodic signal (identical 18:10 vs 22:09); core list ⇒
  0 bytes. Our 116,015-bps `ID` stream never decodes.
See `docs/EXPERT_BRIEF_DEVKEY_UART_AB_RESULTS_2026-11-15.md` (+ pass 1
`EXPERT_BRIEF_DEVKEY_UART_GARBAGE_2026-11-15.md`).

## Post-hoc decode (11-15 late, expert)

Dongle board pinout transcription solved the finger map
(bank0[7:4] = CLK, /WR, /RD, CS; bank3[0] = A0; pin30 = /CS2; pin31 = /IRQ):
agg23 map vindicated at finger level; the CP210x UART pair on THIS board
revision is routed to different fingers than the reference (or a broken /WR
trace). H1 (FPGA TX loop) effectively dead. Next: discovery build (unique
frequency per drivable finger) — see pass-2 brief §5.

## Revert / ship checklist for this line

- `OVL_SS_DIAG` → `1'b0` before any shipping build.
- `core.json` `cartridge_adapter` → `-1` for release packaging.
- discovery-build diagnostics (31 Hz LED blink, /CS2 drive) are
  diagnostic-only — strip before shipping.
