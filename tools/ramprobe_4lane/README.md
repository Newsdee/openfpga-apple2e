# ramprobe_4lane — port-A write-path param legality probe

Created 2026-11-20 for `docs/PLAN_HDV_M10K_2026-11-20.md` (expert
amendment 3). The hdv_ram conversion (four 128×8 BIDIR_DUAL_PORT
altsyncrams) must decide how the **port A write path** (host DMA word
writes + walk_out byte writes, 74a domain) is specified.

## What is probed

Two instances, identical common shipping param set (BIDIR_DUAL_PORT,
128×8, `OUTDATA_REG_* = "UNREGISTERED"` 1-cycle reads,
`ADDRESS_REG_B = "CLOCK1"`, `READ_DURING_WRITE = NEW_DATA_NO_NBE_READ`,
dual clock 74a/14a), differing only in the port A write-path spelling:

| Hierarchy | Port A write path | Precedent |
|---|---|---|
| `u_omit` | `INDATA_REG_A` / `WRCONTROL_WRADDRESS_REG_A` **omitted** | `hdd.v` `u_sector_ram` omits exactly these and is A&S-clean + fit-verified; its comment: port A resolves **same-cycle writes** (probe X, 2026-10-29) |
| `u_none` | explicit `"NONE"` | INDATA_REG_* value space includes NONE (per the 2026-10-29 ramprobe findings), but this exact spelling was never A&S-tested in this project — the param space produced Error 272006 cascades before |

Note: this supersedes the expert's assumption in amendment 3 that the
omitted spelling resolves to a registered (2-stage) port A write path —
`hdd.v`'s in-repo evidence says the opposite (port A unregistered, port B
registered). If confirmed here, the walk_out tail-byte race that
motivated "option (ii)" does not exist and `wo_landed` needs no
deepening at all.

## Run (Analysis & Synthesis only — no fit needed, ~1 min)

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\tools\ramprobe_4lane
C:\intelFPGA_lite\17.0\quartus\bin64\quartus_map ramprobe_4lane
```

## Read these, in order

1. **Param-resolution errors.** Any of these = the spelling is illegal:
   - `Error 272006` (illegal parameter value) — the known failure of
     this param space
   - `Error 14000` (unsupported READ_DURING_WRITE value)
   - `Error 287078` + a wall of `287013` "defined but never used" —
     the cascade symptom of a failed param resolution
2. **Block-RAM implementation.** Map summary per hierarchy: both
   instances should show ~1,024 block-memory bits each (True Dual Port),
   not logic-register demotion; the "uninferred RAM" warning list must
   stay empty.
3. **Resolved write-path behavior** (only if you want it, e.g. from the
   `db/*.tdf` resolved-param dump of the run): `u_none` should resolve
   to the same unregistered port A write path as `u_omit`.

## Outcome

- Both clean → adopt the explicit `"NONE"` spelling in `hdv_bridge.sv`
  (self-documenting) and record the probe result in the plan.
- `u_none` fails, `u_omit` clean → omit the params (hdd.v precedent) and
  note that `"NONE"` is rejected on 17.0.2.
- `u_omit` also fails → stop; the common shipping set needs rework
  (unexpected — it is hdd.v's set at a different size — bring it back
  to the expert).

## Result (2026-11-20 11:38 run, `quartus_map ramprobe_4lane`)

**A&S successful, 0 errors** (1 warning = NUM_PARALLEL_PROCESSORS
environment noise). Both instances elaborated and implemented as block
RAM ("Implemented 16 RAM segments" = 8 per 1-Kbit instance; no
demotion, no uninferred-RAM warnings). **Both instances resolved to
the SAME megafunction entity** (`db/altsyncram_l7e2.tdf` — one generated
entity shared by `u_omit` and `u_none`, verified in
`db/ramprobe_4lane.hier_info`: `u_none.wren_a =>
altsyncram_l7e2:auto_generated.wren_a`), i.e. explicit `"NONE"`
resolves identically to the omitted default. The resolved entity's
param list (in the tdf) carries **no** `INDATA_REG_*` /
`WRCONTROL_WRADDRESS_REG_*` params — the write paths resolve by
default: per `hdd.v`'s probe-X evidence, **port A same-cycle
(unregistered) writes**, port B registered. Consequence for the
conversion (recorded in the plan): the amendment-3 tail-byte race does
not exist (port A writes are NBA-identical to today's array),
`wo_landed` unchanged, explicit `"NONE"` spelling adopted.
**Verdict: first outcome — adopt `"NONE"`.**
