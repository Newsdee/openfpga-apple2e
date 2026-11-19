# Build archive — 2026-11-15 23:07 `apf_apple2` (devkey DISCOVERY build)

Diagnostic bitstream — fingerprinted the CP210x finger. NEVER ship.
Discovery RTL reverted in the worktree the same evening (see NOTE
"Revert status").

## Purpose (EXPERT_BRIEF_DEVKEY_UART_AB_RESULTS_2026-11-15.md §5)

Drive every drivable cart finger with a UNIQUE frequency so the wire probe
(`tools/com4_probe.ps1`) names the finger the CP210x RXD actually sits on:

| Finger | Signal in this build |
|---|---|
| /WR (`bank0[6]`) | 116,015-bps `ID` stream (unchanged) |
| /RD (`bank0[5]`, LED) | ~31.0 Hz 50% blink |
| /CS2 (`pin30`) | 116,015-bps `ID` stream (`dir=1`; expert-assessed low risk) |
| /IRQ (`pin31`) | left as INPUT (zero-risk option; not driven) |
| A0 (`bank3[0]`) | read: any edge → 110 µs LED flash (saturates under an edge storm) |

Gated by `devkey_uart #(parameter DISCOVERY=1)`; `/CS2` drive in
`apf_stream_video_top.v`.

## Hashes

- `apf_apple2.rbf`   = `83c44e6e0fa82ba0d59374b38bcbc4db6da81a1948674a5ceff9328e683ef3c2` (1,881,928 B)
- `bitstream.rbf_r` = `d1365049350a648b0d81b2c8e4e844a10c6eb47b59799f7d34be32baacb3ac24` (staged + on card 11-15 23:22)

## Numbers

17,618 / 18,480 ALMs (95%), 16,902 regs, timing clean. A&S 22:56, fit
23:07. Warning delta vs 22:09: old "pin30 fed by GND" gone; 3 new expected
warnings from the /CS2 drive (`pin30_dir` stuck at VCC, `pin30~synth` node,
inserted always-enabled tri-state buffer). No new errors.

## RESULT (bench, 2026-11-15 ~23:30)

- **LED blinked once at boot, then solid; button press had no visible
  effect.** Decoded: `a0_flash` saturated ⇒ **A0 is edge-stormed
  continuously** once the core runs (mainboard/cart-power domain; our
  design reads `bank3`, does not drive it).
- **Wire probe (core running):** no clean `ID` text at 115200/116015
  (⇒ CP210x RXD is NOT on /WR and NOT on /CS2); no 31 Hz signature
  (⇒ NOT on /RD); the ~5.76 kHz core-gated signal persists
  bit-identically (`05 00 10 FA` @230400).
- **Conclusion:** the CP210x RXD sits on a finger we do not drive —
  almost certainly an A-bus line (A0 proven active). The UART link is
  **unfixable in core RTL** on this board revision. Next: N5 — ask
  agg23/RndMnkIII for this dev-kit revision's CP210x RXD/TXD routing.
  The 5.76 kHz is mainboard A-bus activity gated by core/cart power.

## Revert status (2026-11-15 evening)

- `apf_stream_video_top.v`: `/CS2` drive reverted to the original
  `pin30 = 1'b0 / dir = 1'bz`; `#(.DISCOVERY(1))` removed from the
  `devkey_uart` instance.
- `devkey_uart.v`: the `DISCOVERY` parameter + blink/flash logic KEPT in
  the file at its default `0` (pruned in synthesis; TB behavior
  unchanged) — a documented diagnostic option for a future board with a
  correct UART routing.
