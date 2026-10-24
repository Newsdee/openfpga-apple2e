# TODO — Quartus warning cleanup (after successful M1 compile)

**Status:** PARKED — not a blocker. The **M1 WOZ A&S is now SUCCESSFUL**
(2026-10-20 23:59:15). Clean this up *after* hardware acceptance, as a pass on a
known-working baseline.

**This is NOT a pure style pass.** The first task is a **correctness triage**:
several warnings concern *observable* signals / intended arithmetic, and a
successful compile does **not** prove truncation, uninitialized state, or
procedural ordering is correct. Fix only after establishing intended behaviour.

---

## 1. Baseline inventory (successful A&S, 2026-10-20 23:59:15)

- **351** total warning *occurrences*; **123** unique (code + file:line) *sites*.
  (The earlier 117 was the *failed* pre-`pend` run, where elaboration stopped
  early and missed the mapper-analysis warnings below. Do not use it.)
- Record timestamp + source revision with every re-measure. Distinguish
  occurrences vs unique sites vs distinct messages at the same site.

### Group A — Verilog source (review / fix in RTL): 147 occurrences

| Code | Occ | Meaning | Triage class |
|------|-----|---------|--------------|
| 10230 | 78 | Truncated value on assignment (width) | **Review consumers/bounds**, then explicit width (some cosmetic, some may hide a bug) |
| 10275 | 25 | Dangling comma in port-connection list | Cosmetic (low risk) |
| 10036 | 18 | Object assigned but never read | **Review** — some are observable/dead, don't assume |
| 10030 | 11 | Net has no driver / initial value | **Review** — some are intended arithmetic (e.g. `audgen_accum`) |
| 10762 | 3 | Case completeness not checkable (too many states) | **Review case semantics** — some already have a default or hold-behaviour |
| 113027 | 2 | `.mif` address range uninitialized | Acceptable (documented ROM gap, Quartus supplies zero) |
| 113028 | 1 | 253/256 build_id addresses uninitialized | Same as above |
| 10858 | 1 | Object used but never assigned | **Review** — `host_4C` is an observable bridge-read register |
| 10027 | 1 | Index expression too narrow for array | **Review intent** (OSK button strip) |
| 18236 | 1 | `NUM_PARALLEL_PROCESSORS` not set | Low-risk global (set in QSF) |
| 13004/13009/13024/13032/13039/13040 | 6 (1 each) | Verilog style/width singletons | Review each |

### Group B — mapper/fitter analysis (informational, not RTL fixes): 204 occurrences

| Code | Occ | Meaning |
|------|-----|---------|
| 14320 | 75 | Synthesized-away nodes (mapper optimization) |
| 13410 | 66 | Pin stuck at GND (APF template unused pins) |
| 13010 | 21 | `altddio_bidir` I/O standard notes |
| 13310 | 18 | Register converted to equivalent circuit |
| 15610 | 8 | No output dependent on input pin (dead APF input) |
| 13033 | 5 | Pin fed by VCC |
| 276027 | 3 | Inferred dual-clock RAM (`sdram_sector_fetch` `sbuf` — expected) |
| 14285 / 14284 | 3 / 3 | PLL / node synthesized away |
| 21074 | 1 | 8 input pins that do not drive logic |
| 12241 | 1 | 47 hierarchies with connectivity warnings (see Connectivity report) |

**Group B disposition:** leave visible — these are the mapper's expected
optimization notes + the APF template's unused pins. Reducing them (trimming
unused APF pin declarations) is *shared-interface* (APF template) work, not part
of this pass; do it deliberately if ever wanted.

---

## 2. Correctness triage (do this before any cleanup)

| Class | Advice |
|-------|--------|
| Undriven signals, truncations, narrow indices | Review the actual consumers and bounds **now**; fix only after establishing intended behaviour. |
| Mixed blocking/nonblocking (`10268`, 5×) | Review assignment ordering; do **not** automatically rewrite or suppress. |
| Trailing commas, processor-count | Reasonable low-risk cleanup once the baseline is captured. |
| Documented ROM-init gaps (`build_id.mif`) | Usually acceptable where Quartus explicitly supplies the intended zero. |

---

## 3. Specific warnings with clear (source-verified) explanations

**Diagnostic concatenation — `sdram_storage.v:599`:**
`diag_rd_data_r = {27'd0, co_st, res_fail, res_code, res_valid};` — the fields
occupy 8 bits, so this is 35 bits truncated to the 32-bit reg. **Fix:** change
the leading pad to `24'd0` (24 + 8 = 32). Preserves the current low-32-bit result
exactly. No generic cast needed.

**Shared synchronizer — `common.v:74-75`:**
Edge pulses are explicitly disabled for `WIDTH != 1`, but the vector expression
still emits width diagnostics. If cleaning up, use an explicit scalar expression
(or a generate branch) that preserves: normal edge detection for width 1;
constant-zero edge outputs for wider buses. **Do not** substitute a reduction-OR
edge detector — that introduces different semantics.

**Audio accumulator — `apf_stream_video_top.v:680` (`audgen_accum[21:0]`):**
Incremented by `CYCLE_48KHZ` (245,760) and wrapped at 742,500 — **both divisible
by 4** — so bits `[1:0]` never change, which is why Quartus flags them as
effectively undriven. This is intended arithmetic, **not** a dead declaration.
Do **not** remove the accumulator or add an arbitrary tie-off. Review the intended
initialization; explicit init/reset is a *behaviour* decision, not formatting.

**Narrow OSK index — `apple2e_osk.v:342`:**
`wire [3:0] dbg_btn = (dbg_x - DBG_PANEL_X) / 3'd3;` intentionally selects buttons
0–15 within the 48-pixel strip (48/3 = 16). The warning is indexing the wider
`cont1_key_s3`. An explicit low-16-bit view expresses the intent better than
widening the index. Preserve the strip bounds and current button mapping.

**"Add a default" is NOT a universal fix (10762):**
- The top-level bridge mux **already has a default**, yet the completeness warning
  fires (case expression has too many states to enumerate).
- The clocked command decoder's unmatched cases **hold** register values (no
  default = hold). A zero-default would *change* that behaviour.
- Review case semantics rather than mechanically inserting defaults or switching
  `casex`.

**`host_4C` (`core_bridge_cmd.v`)** is an **observable** bridge-read register — it
cannot simply be deleted as dead code. Establish its protocol-defined value and
initialize/tie it appropriately.

---

## 4. Source-preservation policy (tightened)

"Everything outside WOZ can be fixed" is too broad. Layers, in order:
- **Canonical machine RTL** (`machine/`) — unchanged (byte-identical to MiSTer).
- **Generated OSK variants** (`virtual_keyboard_overlay_q17.sv`, etc.) — change
  via the generator (`tools/gen_osk_q17.py`), never hand-edit. **Caveat:** the
  generator states Verilator uses the *canonical* files, not the Q17 variants —
  so a generator change is **not** proven by the regression suite alone. Add a
  focused **generated-vs-canonical OSK comparison** (geometry, glyphs,
  transparency, boundary coordinates).
- **Pinned SDRAM reference** (`io_sdram.v`) — unchanged; Pocket-local changes
  (`io_sdram_pocket.v`) stay consistent with the regeneration mechanism.
- **APF shared/template** (`apf/`) — treat any change as a shared-interface change.
- **WOZ** (`woz/`) — byte-identical, SHA-256 pinned (`NOTICE.md`); its warnings
  are only *suppressible*, never fixed by editing.

---

## 5. Revised order

1. Capture the current successful build + warning inventory (done — this note).
2. **Classify the potentially-functional warnings (Group A)** and document the
   intended semantics for each.
3. Fix low-risk local issues in small groups (diagnostic concat, trailing commas,
   `NUM_PARALLEL_PROCESSORS`, OSK low-16-bit index view, synchronizer scalar).
4. Validate generated variants **separately** from canonical RTL (OSK
   generated-vs-canonical comparison).
5. Keep reviewed imported warnings **visible or narrowly allowlisted** — avoid
   global suppression.
6. Rerun targeted tests, then the full M0/M1 regression + boot gate, before
   hardware.

## Acceptance

**"No unexplained new warnings or *changed warning sites*"** — not merely "no new
warning categories" (a new truncation bug can share an existing code). After each
group, re-run A&S and diff the (code, file:line) set against the baseline in
§1. Re-run the M0/M1 regression (10/10) + `tb_u6_boot`, and confirm the
`machine/` OSK files and the WOZ `NOTICE.md` hashes are intact.

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\src\fpga
quartus_map apf_stream_video --read_settings_files=on --write_settings_files=off
```
