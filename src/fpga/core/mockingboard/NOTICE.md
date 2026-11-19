# mockingboard/ - donor import from the MiSTer Apple II core

Byte-identical port of the MiSTer Apple II core's Mockingboard (Model A
clone: 2x 6522 VIA + 2x AY-3-8910 PSG, 6 stereo channels). No
modifications: the Pocket-side integration (slot-4 IO decode, PD mux,
IRQ/NMI merge, audio mixing into `speaker_i2s.v`) lives in
`apple2e` top-level files, so the donor files stay diff-able against
the upstream tree.

```
source: E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/mockingboard/
donor head at import (2026-11-18): Apple-II_MiSTer working tree (newsdee)
provenance: mockingboard.v top by W. Soltys (GPL-family MiSTer core);
via6522.v by Thomas Skibo (BSD-2, per its header); YM2149.sv by MikeJ /
Sorgelig (permissive, per its header - same file used by the openFPGA
examples)
```

## SHA-256 pin (verified 2026-11-18)

| File               | SHA-256 | Status |
|--------------------|---------|--------|
| `mockingboard.v`   | `bf620b78089892da29e7372d689107063b79add593856b990fad9045cbb6616e` | byte-identical |
| `via6522.v`        | `ff7241af83f06dc594476d491ed13ab8ccd7eb1a264e776efae6ac0f2ed6878e` | byte-identical |
| `YM2149.sv`        | `47bc1c7e7209dcb406ace197fa7b43dc20fa93ff11113c024bd789cc3d410675` | byte-identical |

Re-verify:

```bash
sha256sum src/fpga/core/mockingboard/{mockingboard.v,via6522.v,YM2149.sv}
cmp -r src/fpga/core/mockingboard ../Apple-II_MiSTer/rtl/mockingboard \
    (excluding schematic.gif, not imported)
```

Line endings: CRLF throughout (as in the donor files) - do not normalize.

## Interface facts (verified in donor source + MiSTer apple2_top.v
instantiation, used by the Pocket integration)

- Module name `MOCKINGBOARD` (uppercase).
- `I_RW_L` = 1:read / 0:write; the MiSTer donor instance wires
  `.I_RW_L(~cpu_we)` and `.I_IOSEL_L(~IO_SELECT[4] | ~mb_inslot)` and
  `.I_RESET_L(~reset)` - the Pocket integration mirrors that exactly
  (`~m_cpu_we`, `~m_io_sel[4] | ~mb_inslot_m`, `~machine_reset`).
- `OE = ~I_IOSEL_L` is NOT gated by `I_ENA_H`: the top-level PD mux
  selects the card on `m_io_sel[4] & mb_inslot_m`, not on OE, so a
  disabled card never reaches the bus.
- IRQ: `O_IRQ_L` (LEFT VIA) / `O_NMI_L` (RIGHT VIA), both forced inactive
  (high) when `I_ENA_H=0` - safe to AND into the machine's interrupt
  inputs with no extra gating.
- Audio: `O_AUDIO_L/R` are 10-bit unsigned SUMS of three 8-bit PSG
  channel levels (AY-3-8910 volume table, per-channel max 0xFF, sum max
  765). They are plain sample sums, not PWM - safe to mix arithmetically.
- Clocking: `CLK_14M` + `PHASE_ZERO/R/F` qualifiers (PSG on
  `PHASE_ZERO_F`, VIA on `PHASE_ZERO_R`) - the Pocket machine exports the
  same three signals, so the donor's own timing discipline carries over.
