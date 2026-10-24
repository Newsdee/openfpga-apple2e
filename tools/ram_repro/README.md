# ram_repro — isolated Quartus A&S test for the machine-RAM clear idioms

Created 2026-10-24 after the external expert review of
`docs/EXTERNAL_REVIEW_BRIEF_QUARTUS_SLOW_ASYN_2026-10-24.md`. The review's
central claim: the Cyclone V M10K has **no runtime content-clear pin**, so the
whole-array async-clear idiom (`or posedge ram_clear` + 256×256 nested clear,
commit-9085041 era) is not a supported block-memory operation — and the
shipping design was changed to a sequential **write-sweep** on that basis.

This folder isolates the question in the cheapest possible A&S run: four
independent 64K×8 inferred RAMs, identical read/write behavior (the streaming
top's `ram_main`/`ram_aux` structure), differing only in the clear idiom:

| Hierarchy | Variant | Clear idiom |
|---|---|---|
| `u_plain` | `ram_v_plain` | none — the known-good M1 structure |
| `u_init` | `ram_v_init` | plain + `initial` zero-fill (power-on state only) |
| `u_async` | `ram_v_async` | the disputed whole-array async clear (exact 16:53-era structure) |
| `u_sweep` | `ram_v_sweep` | the new shipping write-sweep (counter, one address/cycle, `clear_done`) |

`ram_clear` and `we` are top inputs so Quartus cannot constant-fold the
branches away.

## Run (Analysis & Synthesis only — no fit needed)

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\tools\ram_repro
C:\intelFPGA_lite\17.0\quartus\bin64\quartus_map ram_repro
```

Healthy expectation: well under a minute (this design is ~1/40th the core's
scale).

## Read these, in order

1. **A&S wall time.** If even this tiny design grinds in TDS, the cause is
   tool/host-level, not the RAM idiom. If it's fast, the full-core grind is
   design-structure-related (proceed to a clean baseline of the core itself).
2. **Map report, per hierarchy** (`ram_repro.u_async`, `.u_sweep`, ...):
   - registers and block-memory bits per variant — `u_plain`/`u_init`/`u_sweep`
     should show ~512,000 block-memory bits (64K×8) and a handful of registers
     each;
   - if `u_async` shows ~524,288 logic registers (inference demoted) or its own
     clear-controller logic, the disputed idiom is the A&S difficulty source;
   - if `u_async` shows a clean M10K, Quartus DOES infer it — the TDS grind has
     a different cause.
3. **Map log "uninferred RAM" warnings** — which hierarchies, if any, are
   listed (the known-good full-core run listed exactly the 10 expected small
   RAMs and NOT `ram_main`/`ram_aux`).

Device: 5CEBA4F23C8 (same as the core), top `ram_repro`. No SDC, no db/ state —
a clean run by construction.
