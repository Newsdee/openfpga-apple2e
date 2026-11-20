# Release 0.4.1 — 2026-11-20

**Beeper volume attenuation ladder; diagnostic console out.**

0.4.1 ships the beeper volume slider in its final form and removes the
transport-diagnostic serial console that had ridden along in the 0.4.0
development builds. No other machine behavior changes from 0.4.0.

## What changed

### Beeper Volume slider, final ladder (attenuation)

The 0.4.0 build shipped a beeper ladder that *amplified* (2x/4x/6x/8x);
hardware testing showed the beeper sits wrong above the Mockingboard
(whose top stop is already rail-clamped), and the user wanted the beeper
**softer**, not louder. The ladder now attenuates toward the 0.3.6
baseline:

| Stop | Level |
|---|---|
| 0 | Off (true silence) |
| 1 | ×1/4 (default) |
| 2 | ×1/2 |
| 3 | ×1 — the 0.3.6 beeper, bit-exact |

Attenuation is arithmetic right-shifts of the signed beep word after the
duty/DC tracker (no re-convergence); the Mockingboard and floppy ladders
are untouched. Verified in the chain TB: off=0, ×1/4≈6.8k, ×1/2≈13.7k,
×1≈27.4k swing — exact 2.0× steps, no stop can reach the 16-bit rails,
so the beeper always sits below the maxed MB.

### The "dead beeper" mystery, resolved

The Beeper Volume slider had been reported inert on two consecutive
builds (22:32, 23:31 on 2026-11-19). Both were the same bad-placement
builds that also failed floppy and HDV loads. On the good-placement
builds the slider works; the diagnosis was a placement-sensitive
marginality in the shared host→machine region (the beeper gain crosses a
2-FF CDC — a legitimate placement-sensitive construct), not a wiring or
option-manager bug. No beeper-specific fix was needed; see the expert
briefs for the evidence trail.

### Diagnostic console removed

The devkey UART console (SSY/SSH/SO transport taps, added to instrument
the placement regression) is compile-gated out of this build
(`DEVKEY_DIAG=0`): ~957 ALMs freed (17,063 → 16,106, 92% → 87%),
`u_devkey_uart` absent from the map. The console code (now with
delta-printing: idle 3 lines/2 s, on-change bursts during activity)
stays in the tree, gated, for the next diagnostic.

## Build

- Commit `b5a3881`, 2026-11-20 10:44, Standard Fit
- 16,106 / 18,480 ALM (87%), 17,250 registers, DSP 29
- STA: mp2 setup 1.504 ns, clk_74a 3.665, bridge 10.437, TNS 0
- `bitstream.rbf_r` SHA-256 `1304d6f3f6e9d3c82a1022d8a0c0c42b6b21ae5cbe478173d8ec414a04f55024`
- **Hardware-validated 2026-11-20**: floppy load, HDV load, savestate
  save + load all pass (the standing three-way gate).

## Known issues (carried from 0.4.0)

- **Transport placement sensitivity**: across the 10-build hardware
  series, ~3/10 placements of this netlist family fail floppy/HDV
  loads (placement-dependent, not slack- or density-predictable;
  8 pass / 4 fail). This 0.4.1 bitstream is one of the passing
  placements, HW-verified. A structural fix (CDC/registration
  hardening in the shared host→machine region) is in progress and is
  the target of the next release; diagnostic tooling for it (the
  delta-print console) is in the tree, gated off here.
- **Mockingboard state is not in the savestate blob**: the card resets
  on sleep/wake (audio-only feature; machine state round-trips).

## Packaging

`sd_root_release/Apple2e_Pocket_0.4.1.zip` (cores + assets + platforms;
`cartridge_adapter: -1`, platform year 1983).
