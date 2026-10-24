# EXTERNAL REVIEW BRIEF — Quartus 17.0.2 Lite A&S compile-time blowup (openFPGA Apple IIe Pocket core)

Date: 2026-10-24 17:50 local. Target: a small, behaviorally-verified Cyclone V design whose
Analysis & Synthesis suddenly takes >10 min single-core grinding (vs. historical "under 7 min"
full compiles). We want an outside FPGA-SE eye on (a) whether this is expected, (b) known
Quartus-17 TDS pathologies, (c) what to measure/try next. Everything below is self-contained.

## 1. The question

- A clean-db `quartus_map` (Analysis & Synthesis) of a ~9,000-ALM design sits at **99.7% of ONE
  core, 2 threads, 600 MB RAM, zero file I/O, zero new messages** — grinding for 10+ min with
  no visible progress (last phase message: "Timing-Driven Synthesis is running").
- Historical full compiles (A&S + fitter + STA + asm) on this project finished in **under
  7 minutes** — but (see §4) every one of those was an *incremental* smart-recompilation run
  reusing a db/ that had accumulated since 2026-10-19. We have **never measured a from-scratch
  A&S** for this design. The core question may be calibration, not regression.

## 2. Environment

| Item | Value |
|---|---|
| Host | Windows, MSYS2 UCRT64 tooling; disk E: 3.6 TB free / 36% used |
| Quartus | Prime **17.0.2 Build 602 (2017) Lite Edition** |
| Device | Cyclone V **5CEBA4F23C8** (openFPGA / Analogue Pocket SoC) |
| Design scale | ~8,978 / 18,480 ALM (49%), 2 PLLs, 190 M10Ks, 0 DSP; top `apf_top_stream` |
| Known host quirk | Endpoint AV agent (`mc-fw-host`) on this host has a documented history of
  interfering with freshly built/launched binaries (kills fresh PEs mid-session). No known
  interference with Quartus itself, but it *does* scan disk writes. |

## 3. Design summary (what A&S is compiling)

Apple IIe machine core (65C02 + 128 KB RAM + video) + WOZ floppy engine (byte-pinned, from the
MiSTer core) + a Pocket-specific SDRAM storage subsystem (bridge → 64 KB sector buffer → WOZ
transport) + APF video/audio template wrappers. Two user clocks (74.25 MHz proto, 143.18 MHz
machine) plus PLLs. No custom constraints changes recently; SDC untouched.

**Everything is behaviorally green in simulation**: full-design Verilator elaboration clean
(0 errors), 7 simulation suites PASS (storage, transport, mount, boot, overlay, unit), and the
design previously fit/compiled on this exact toolchain (M1 hardware-verified build, 2026-10-23:
Fitter Successful, STA TNS 0.000, +1.08 ns slack on the critical path).

## 4. Baseline reframing (important)

The db/ fragment timestamps show **every compile since 2026-10-19 was incremental** (smart
recompilation merging hundreds of `.cnf.hdb` fragments across runs). The "under 7 min" figure
is therefore an *incremental* figure. Today we hit the first **clean from-scratch A&S** in days
(the db had to be wiped after a poisoned run, §5). So:

- We do not know how long a clean A&S of this design *should* take in Q17.0.2 Lite.
- The 1M-register netlist A&S'd in minutes shows scale alone is not the limiting factor —
  *but* (per the expert review, §11) runtime also depends on structure and optimization
  difficulty, not just register count, so this is evidence, not a proof.

## 5. Today's run timeline (all local time, 2026-10-24)

| Time | Run | Outcome |
|---|---|---|
| ~10:50 | A&S with a 65,536-iteration `for` loop (new RAM-clear code) | Fast fail: Error 10106 "loop must terminate within 5000 iterations" (1:43 elapsed) — as expected, fixed by nesting 256×256 |
| ~14:30–14:39 | A&S of the nested-loop (synchronous clear) version | A&S **succeeded in minutes** but the two 64K×8 machine RAMs **lost M10K inference** (sync if/for clear pattern) → 1,053,672 registers; fitter then failed Error 170011 (495,239 combinational nodes) — as diagnosed, fixed by async-reset idiom |
| ~16:52–17:05+ | A&S of the fixed RTL **on top of the poisoned db** (smart recompilation) | Elaborated fine (RAMs inferred — only the 10 known small/async RAMs uninferred), then "Timing-Driven Synthesis is running" at 17:05; then **silent 30+ min at 100% CPU, 6 GB RAM** → user killed it |
| ~17:33 | db/ deleted entirely (256 MB of fragments); clean full compile launched | A&S in progress; at 17:48: **99.7% of one core, 600 MB RAM, no I/O, no new messages since 17:38:12** (10 min wall, ~10:01 process CPU time) |

The current (clean) run is the one we're stuck on. Its low RAM (600 MB vs. the poisoned
run's 6 GB) says it is *not* carrying the old 1M-register state.

## 6. What changed in the RTL since the last green build (2026-10-23)

Small, and all simulation-verified. The only **structural** netlist change:

1. **Machine RAM (2 × 64K × 8) gained an async clear + initial zero-fill** — the "Reboot on disk
   change" feature. Previously: plain inferred M10Ks, no reset, no init. Now:

```verilog
// clk_core_14318 domain; ram_clear_m = output of a 2-phase FSM in the same domain
// (4,096-cycle clear phase + 1,024-cycle reset-hold phase, async-reset by the
//  base machine reset, never by its own output)
integer ram_clr_a;
integer ram_clr_b;
reg [7:0] ram_main [0:65535];
reg [7:0] ram_aux  [0:65535];

initial begin                          // power-on state -> MIF (zero)
    for (ram_clr_a = 0; ram_clr_a < 256; ram_clr_a = ram_clr_a + 1)
        for (ram_clr_b = 0; ram_clr_b < 256; ram_clr_b = ram_clr_b + 1) begin
            ram_main[{ram_clr_a[7:0], ram_clr_b[7:0]}] = 8'd0;
            ram_aux [{ram_clr_a[7:0], ram_clr_b[7:0]}] = 8'd0;
        end
end

always @(posedge clk_core_14318 or posedge ram_clear_m) begin
    if (ram_clear_m) begin             // standard async RAMARST idiom
        for (ram_clr_a = 0; ram_clr_a < 256; ram_clr_a = ram_clr_a + 1)
            for (ram_clr_b = 0; ram_clr_b < 256; ram_clr_b = ram_clr_b + 1) begin
                ram_main[{ram_clr_a[7:0], ram_clr_b[7:0]}] <= 8'd0;
                ram_aux [{ram_clr_a[7:0], ram_clr_b[7:0]}]  <= 8'd0;
            end
    end else begin
        // normal single-cycle read/write (read-during-write = write wins),
        // main+aux share one 16-bit data path via m_ram_aux
    end
end
```

   The 16:53 run's A&S log confirms this synthesizes as intended: "Found 10 instances of
   uninferred RAM logic" lists only the 8 known tiny overlay RAMs + 2 known WOZ-engine BRAMs —
   `ram_main`/`ram_aux` are inferred (M10K + RAMARST).
2. `reboot_ctl.v` — a ~30-line 2-phase FSM (12-bit counters) in the machine domain.
3. One 32-bit bridge-register latch (bridge domain) + one 3-stage synchronizer + one case in an
   existing read mux.
4. Fingerprint-diagnostics logic (present in the last green build) now **gated off** by a
   parameter — a logic *reduction*.
5. 25 synchronizer instances converted from positional to named port connections — no netlist
   effect. A 21-bit constant written in final form — no effect.

No SDC, constraint, QSF, or device setting changed (one VERILOG_FILE line added for
`reboot_ctl.v`).

## 7. Ruled out so far (per the expert review, these are now *weakened*, not proven)

- **Stale/poisoned db state** — wiped; clean run still grinds (though in a different shape:
  600 MB RAM, single-core, no I/O). *Weakening: fragment timestamps show db history, not
  which phases were actually reused — but the poisoned state is now gone either way."
- **Design scale** — the 100×-larger broken netlist A&S'd in minutes. *Weakening: runtime
  depends on structure/optimization difficulty, not just register count."
- **Process hang / I/O block** — 99.7% CPU rules out simple idle waiting; *an optimizer can
  still loop or make little progress at full CPU."
- **RTL logic error** — Verilator elaboration clean; 7 sim suites PASS; Quartus elaborated it
  at 16:53 (reached TDS). *Weakening: simulation passing selected scenarios does not prove
  synthesis compatibility — which is exactly what the new isolated RAM reproducer (tools/ram_repro)
  is for."
- **Disk full / other builds running** — 3.6 TB free; no other Quartus or sim processes.
- There is **no reliable "over ten minutes means stuck" threshold**; the missing clean baseline
  (this design has never had a clean-from-scratch A&S in Q17.0.2) prevents a useful comparison.

## 8. Snapshot of the current run (17:48)

```
quartus_map.exe  PID 90424   WS=603,884 KB   2 threads
% Processor Time: 99.7 / 99.7   (10 s samples)
TotalProcessorTime: 00:10:01    (process started ~17:38)
db/apf_stream_video.*: 21 files, last write 17:38:12 (silent since)
Last A&S phase message: "Timing-Driven Synthesis is running"
```

## 9. Questions for the reviewer

1. **Calibration:** for a ~9K-ALM Cyclone V design with Timing-Driven Synthesis ON, what does a
   *clean* (no smart-recompilation state) `quartus_map` typically take in Q17.0.2 Lite on a
   modern desktop? Is 10–60 min plausible, or does >10 min of silent single-core grinding
   indicate a stuck TDS iteration?
2. **Known Q17 pathologies:** any documented TDS hangs/grinds in 17.0.x — in particular around
   (a) inferred block RAMs with an async reset (RAMARST) + initial content, (b) large (64K-depth)
   inferred RAMs, (c) Windows file-locking of db/ by AV agents, (d) `.cnf.hdb`/smart-recompilation
   corruption?
3. **The RAM idiom:** does the async-reset + `initial` zero-fill pattern on 2 × 64K × 8 inferred
   RAMs plausibly make TDS grind (e.g., reset-domain / arst fanout analysis over 131K RAM bits)?
   Would a different idiom (no `initial`, or sync clear, or no clear at all) change the TDS work?
4. **Diagnostics to collect:** what would you want from this machine to distinguish "slow but
   progressing" from "stuck" — perfmon counters, `quartus_map --verbose` output, the `.qmsg`
   decode, Windows Event Log / AV scan logs? (We can provide any of these.)
5. **Bisection knobs:** we're prepared to run —
   - `set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF` and re-run (isolates the
     TDS phase; the expert review confirmed from the installed assignment defaults that Q17.0.2
     uses `SYNTH_TIMING_DRIVEN_SYNTHESIS`, not `TIME_DRIVEN_SYNTHESIS` — our earlier draft name
     was wrong)
   - A&S-only run (`quartus_map`) to separate from fitter
   - **Isolated 4-variant RAM reproducer first** (`tools/ram_repro/`, added in the review-
     response commit): plain / plain+init / async-clear / sweep-clear, same 64K×8 dimensions and
     write-first behavior — `quartus_map ram_repro` in that directory. This is now the
     recommended first experiment (the expert's step 1).
   - Clean A&S of the last known-good core (pre-reboot-feature tip) in a separate build location
     to establish the clean-baseline number.
   - Same project on another machine / another Quartus version (18.1/19.1 Standard?)
   - Disabling the endpoint AV agent for the run (owner-controlled)
   Is there a better order or additional first test?

## 10. Reproduction

```
cd E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\src\fpga
C:\intelFPGA_lite\17.0\quartus\bin64\quartus_map apf_stream_video
# full flow:
C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh --flow compile apf_stream_video
```

Project files: `apf_stream_video.qsf` (sources listed explicitly), top `apf_top_stream`,
device 5CEBA4F23C8. Clean db state: delete `src/fpga/db/` before running. The RTL is at
git `main` (github.com/Newsdee/openfpga-apple2e, tip `9d5e1db`); the last fully-green Quartus
build (M1, hardware-verified) is one commit-series behind (fingerprint logic ungated, no
reboot feature).

— Prepared by the implementing engineer; functional simulation state: ALL GREEN. This is purely
a synthesis-infrastructure question.

---

## 11. Response to the external expert review (2026-10-24)

The review's central claim — **M10K reset controls do not clear stored memory contents at
runtime** — was verified against the installed Quartus 17.0.2 device model (`cyclonev_atoms.v`,
`cyclonev_ram_block`: ports are `init_file`, per-port `data_out_clear`, `address_clear`,
`clr0/clr1` — **no content-clear pin**). We agree, and have **changed the shipping design**:

### 11.1 What changed in the RTL (this commit)

- **The async-clear idiom is no longer the shipping design.** The machine RAMs are now
  cleared by a **sequential write-sweep**: a 16-bit counter walks 0..65535, writing zero to
  both banks one address per machine cycle (65,536 cycles ≈ **458 µs at 143.18 MHz** — the
  machine clock is 143.18 MHz, not 14.318; the "14.318" figure in the review came from a typo
  in our own `reboot_ctl.v` docstring, now fixed). The RAM `always` block is a plain
  clock-only process with a single write (the sweep or the machine's normal write), exactly
  the M1 structure plus one address/data mux — normal M10K inference, and identical to what
  the testbenches model. The `initial` zero-fill is kept as the power-on (MIF) state only.
- **`reboot_ctl` now handshakes on `clr_done`** (the sweep's completion pulse) instead of a
  fixed 4,096-cycle window, with a 131,072-cycle safety timeout so the machine can never be
  stuck in reset. HOLD (1,024 cycles) is unchanged. Total reboot ≈ 465 µs — still
  imperceptible between disk images.
- **Testbench coverage gap closed:** `tb_u6_boot` previously modeled the clear as its own
  synchronous full-array clear (a different RAM model than the shipping one, as the review
  noted). It now models the exact sweep (counter + per-cycle writes) and re-verifies the
  full cold-reboot window through the real machine (U6-R). `tb_reboot_ctl` gained a
  `clr_done` handshake model and a timeout-path test (all 7 cases PASS).

### 11.2 New first experiment: the isolated RAM reproducer

`tools/ram_repro/` (qpf + qsf + `ram_repro.v`, lint-clean): four independent 64K×8 inferred
RAMs with identical read/write behavior, differing only in the clear idiom —

| Variant | Clear idiom |
|---|---|
| `u_plain` | none (the known-good M1 structure) |
| `u_init` | plain + `initial` zero-fill |
| `u_async` | the disputed whole-array async clear (exact structure of the 16:53-era code) |
| `u_sweep` | the new write-sweep (shipping design) |

`ram_clear` is a top input so the clear branches cannot be constant-folded away. Run
`quartus_map ram_repro` from `tools/ram_repro/`. Read the per-hierarchy map summaries
(registers, block-memory bits, uninferred-RAM warnings) and the A&S wall time: if `u_async`
demotes to ~524K logic registers (or grows its own clear engine) while the others infer
into M10Ks, the disputed idiom is confirmed as the A&S difficulty source; if it infers
cleanly and A&S is fast, the TDS grind has another cause and we proceed to the
baseline/bisection steps in §9.5.

### 11.3 Agreed corrections adopted

- "Ruled out" statements weakened to the review's more defensible form (§7).
- `SYNTH_TIMING_DRIVEN_SYNTHESIS` is the correct Q17.0.2 assignment name (§9.5).
- Baseline M10K count corrected to 190 (§2).
- Evidence hygiene: the `output_files_apple2e/` reports are preserved; note the poisoned
  `db/` was deleted **before** the review landed (it had already been characterized in §5 —
  6 GB working set, `.smart_action.txt = SOURCE`, silent 30+ min) and cannot be restored.
- The NTSC port work stays parked until this issue is resolved.

### 11.4 Where we disagree (lightly)

The review's 4.58 ms clear-time figure used 14.318 MHz; the machine clock is 143.18 MHz
(`clk_core_14318`, per the PLL config and every M1 document), so the sweep is 458 µs —
10× cheaper than quoted, which strengthens the sweep design, not weakens it. And the
absent content-clear pin in the installed atom model is strong evidence for the review's
hardware claim; we no longer need to argue the RAMARST question, because the shipping
design no longer depends on it.

**Status at push time:** sweep RTL lint-clean (full-top Verilator, 0 errors); `tb_reboot_ctl`
PASS (7/7 incl. handshake + timeout); `tb_u6_boot` re-running (sweep semantics); the
reproducer is ready for `quartus_map`. The in-flight clean full-core A&S (pre-sweep RTL)
remains the calibration data point for §9.1 either way.

## 12. Resolution (2026-10-24 evening): the slow A&S was the sweep's lost RAM inference

### 12.1 The bisect ladder

Ran a series of tiny single-purpose projects (all `quartus_map` only, device
5CEBA4F23C8) while the full core stayed uncompiled:

| Project | Contents | A&S result |
|---|---|---|
| `tools/ram_repro_plain` | 1× 64K×8 plain M1-shape RAM (no clear, no initial) | **OK, 10 s** — 3 registers, 524,288 block-memory bits (inferred) |
| `tools/ram_repro_init` | plain + `initial` zero-fill | **OK, 19 min** (contended run) — inferred, 524,288 bits |
| `tools/ram_repro_async` | whole-array async-clear idiom (the disputed RAMARST form) | A&S "successful" (see §12.2 caveat) |
| `tools/ram_repro_sweep` v1–v4 | the sweep written four different ways | **FAIL: Error 276003 + Info 276007** "RAM logic ... is uninferred due to asynchronous read logic" |
| `tools/ram_repro` (4-variant control) | all four in one project | silent TDS grind, killed at ~28 min (no output) |

The sweep variants v1–v4 covered: if/else two-writes-in-exclusive-branches,
one muxed write port with a separate read block, one muxed write port with an
unconditional bypass read, and the plain if/else shape with a muxed write
address. **All four failed identically** with the same 276007 on the array
declaration. An uninferred 64K×8 bank is ~500K logic registers — i.e. the
1,053,672-register map of the 17:05 failing full-core run, and the
multi-hour single-core TDS grind on a 4-RAM design. The host, the AV agent,
the TDS phase, and the "clean vs incremental" question were all red herrings
for the grind itself: **a design whose big RAMs fail inference is exactly
the kind of design Q17's TDS grinds on for an unbounded time.**

### 12.2 Inference matrix (the decisive experiment)

`tools/ram_repro_matrix` — one project, six independent 64K×8 RAMs, each the
known-good plain shape with exactly one modification; the per-instance
276007 warnings name the culprits:

| Instance | Modification | Inferred? |
|---|---|---|
| u_a | none (baseline) | **yes** |
| u_b | + separate counter always-block (no array access) | **yes** |
| u_c | write ADDRESS through a 2:1 mux | **NO** |
| u_d | write DATA through a 2:1 mux | **yes** |
| u_e | write ENABLE OR'd with a second signal | **yes** |
| u_f | c+d+e+b combined | **NO** |

**Quartus 17.0.2 will not infer a single-port M10K when the write ADDRESS
is conditional** — mux or if/else — while muxed write data or write enable
are fine. The 276007 "asynchronous read logic" text is a misleading label;
the poison is the conditional write address, full stop. (Caveat on the
async idiom: its standalone A&S "succeeded" but reported N/A totals — we
did not verify its final inference; it remains hardware-semantically
unsupported per the installed atom model, so it stays out of the shipping
design either way.)

### 12.3 The shipping fix: sweep the bus, keep the RAMs plain

The RAM block in `apf_stream_video_top.v` is now **byte-identical to the
proven M1 shape** (plain single-port per bank, per-bank enable, write-first
bypass) and never sees a conditional write address. The sweep is a small
FSM (`ram_sweep_ctl.v`, machine clock) that drives the *bus* — we/addr/aux
through a four-wire combinational overlay on `m_ram_addr_f/_di_f/_aux_f/
_we_f` — writing zeros through both banks one 65,536-address pass each
(131,072 cycles ≈ 0.92 ms; data hardwired to 0). The machine (CPU + Disk II)
is in cold reset for the whole window (reboot_ctl holds `cold_reset` until
the FSM's `done` handshake + 1024-cycle HOLD; CLR_TIMEOUT raised to 262,144
= 2× the sweep), so hijacking the RAM write port is safe: `apple2` and
`disk_ii_woz` are reset-gated and see only the raw machine nets.

Probe result (`tools/ram_repro_sweep` v5 = the exact shipping structure,
real `ram_sweep_ctl` included): **A&S Successful in 12 s — 29 registers,
1,048,576 block-memory bits (both banks M10K), no 276003/276007.**

### 12.4 Verification state at push

- Full-top Verilator lint (`--top stream_video_core_top`): clean.
- `tb_reboot_ctl`: unchanged contract, PASS (7/7).
- `tb_u6_boot`: RAM model now mirrors the shipping structure (plain banks +
  overlay + real `ram_sweep_ctl` instance); U6-R expects the two-pass
  window ~131,136 cycles (131,072 sweep + 64 HOLD) — re-running.
- Quartus: the owner's next clean full-core compile should now be a normal
  clean A&S (the design no longer contains any uninferred-RAM netlist).
  Expect ~190 M10Ks, ~15K registers, Fitter Successful, TNS 0.000.
- Safety net: the 09:24 known-good pre-closeout RBF is backed up at
  `known_good/2026-10-24_0924_pre_closeout/` (sha256
  e46034c94fdbb6ae2d12d360c5040a97230562a4745308cff312de1842ef3cbf) with a
  restore NOTE; the staged card's `bitstream.rbf_r` still matches it.

### 12.5 What we got wrong (for the record)

1. We treated the TDS grind as a host/tool mystery for ~24 hours. The
   reproducer that finally cracked it was the *inference* reproducer — the
   error text (276003/276007) was present in every failing run's log, and
   the "silent 100% CPU" symptom is exactly what a 1M-register netlist
   does to TDS. Lesson: on any A&S stall, first check the last completed
   phase's messages for uninferred-RAM warnings before blaming the host.
2. The interim `RAMARST` idiom (commit 9085041) was never proven to infer
   either — it was chosen to dodge 170011 on evidence that was actually the
   *previous* (synchronous-clear) failure. The expert review's hardware
   objection was right on both counts.
3. "Lint-clean" (Verilator elaboration) was taken as A&S prevalidation.
   It proves the RTL parses and elaborates; it says nothing about Quartus's
   RAM inference. The repro-first rule (probe the structure alone, require
   the block-memory bits count, then touch the core) caught this in 12
   seconds per iteration.
