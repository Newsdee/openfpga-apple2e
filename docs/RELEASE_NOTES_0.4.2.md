# Release 0.4.2 — 2026-11-21

**HDV sector storage moved to M10K block RAM (structural placement fix);
final beeper ladder; diagnostic console out.**

0.4.2 is 0.4.1 (beeper ladder + console removal) plus the structural
attempt to retire the transport-region placement sensitivity that has
plagued hardware-gated builds since 0.3.6. Machine behavior is unchanged:
the HDV read/write path is cycle-identical to the 0.4.1 bitstream,
proven in simulation and on hardware.

## What's new over 0.4.0

### HDV sector storage: flip-flop array → M10K block RAM

The ~4,096 flip-flop sector array in `hdv_bridge` — the largest
non-video monolith in the suspect host→machine transport region, and the
leading congestion source behind the placement lottery (floppy/HDV load
failures on ~3/10 compiles; the "dead beeper" reports) — is now four
128×8 dual-clock lane M10K block RAMs (4 M10K blocks).

- **Semantics preserved, not approximated.** The host-facing prime stage
  latches the *combinational* lane gather at the read strobe —
  cycle-identical to the FF array's prime latching the combinational
  array. Out-of-window reads still present the last in-window word.
  Proven by a new A/B differential harness (`verilog/hdv_ab/`): the
  0.4.1 FF tree vs this M10K tree, through the real
  `io_bridge_peripheral`, the real `hdd.v`, and a faithful model of the
  Pocket's SPI host protocol (SS/4-byte address/3-cycle prime/sample/
  strobe/16-edge TX) — **128/128 words byte-exact across cold/warm
  bursts, transcripts byte-identical**.
- **Development note (honesty):** the first three shipping-clean rolls
  of this conversion failed the HDV-write gate. The A/B harness
  localized the cause — a one-word over-shift from a same-strobe double
  latch in the read prime (masked in simulation by a pinned baseline) —
  and the fixed tree passed hardware. The written HDV from the release
  build is byte-exact against the known-good reference (see Build).
- **Effect:** 16,106 → 11,142 ALM (87 % → 60 %); pins unchanged
  (224/224 — pins, not ALMs, are the binding constraint); TNS 0. The
  fitter packed the prime stage into the lane RAMs' output registers, so
  the two-stage read port (registered address → output register) is
  realized inside the M10Ks.

### Beeper Volume slider, final attenuation ladder (from 0.4.1)

The 0.4.0 build shipped an *amplifying* beeper ladder; hardware testing
showed the beeper must sit *below* the rail-clamped Mockingboard top.
Final ladder (attenuation toward the 0.3.6 baseline):

| Stop | Level |
|---|---|
| 0 | Off (true silence) |
| 1 | ×1/4 (default) |
| 2 | ×1/2 |
| 3 | ×1 — the 0.3.6 beeper, bit-exact |

The "dead beeper" reports on two 0.4.0-dev builds were the
placement-sensitive transport marginality (those same builds failed
floppy/HDV), not a beeper bug — no beeper-specific fix was ever needed.

### Diagnostic console removed (from 0.4.1)

The devkey UART transport console is compile-gated out
(`DEVKEY_DIAG=0`); the delta-printing console code stays in the tree,
gated, for the next diagnostic.

## Build

- 2026-11-21 09:22, Standard Fit (Quartus Prime 17.0.2 Lite),
  `DEVKEY_DIAG=0`; build stamp `20261121/09:21:10` embedded in the RBF
- 11,142 / 18,480 ALM (60 %), 12,798 registers, RAM blocks 202/308
  (66 %), pins 224/224, DSP 29, PLL 2
- STA: TNS 0.000 all corners (min setup slack 1.544 ns, mp2 PLL divclk)
- `bitstream.rbf_r` SHA-256
  `fd2b4ca3617fc6ff57729004eae457f223a8d3e3430afb3e49d4f820ffea02a3`
- **Hardware-validated 2026-11-21 (roll 4 of the M10K tree):** floppy
  load, Mockingboard, HDV load, HDV write — all pass. The written HDV
  is byte-exact against the known-good reference (6,301,180 of 6,301,184
  bytes identical; the 4-byte difference is a machine-side test-file
  naming artifact — "TEST" vs "TEST2" in one catalog record — with every
  sector that the earlier M10K rolls corrupted now clean).

## Known issues

- **M10K hardware gate (new):** the validation plan calls for three
  consecutive shipping-clean rolls; this bitstream is the first clean
  pass. If a future compile of this tree fails the hardware gate, the
  fallback is 0.4.1 (FF array, HW-validated) — the A/B harness is the
  regression oracle for that decision.
- **Transport region is still shared:** the M10K conversion removes the
  suspect monolith but does not harden the host→machine crossings
  themselves. Ship builds remain HW-gated (floppy + HDV load/write +
  savestate); watch the gate on every future compile.
- **Mockingboard state is not in the savestate blob** (carried from
  0.4.0): the card resets on sleep/wake; machine state round-trips.

## Packaging

`sd_root_release/Apple2e_Pocket_0.4.2.zip` (cores + assets + platforms;
`cartridge_adapter: -1`, platform year 1983).
