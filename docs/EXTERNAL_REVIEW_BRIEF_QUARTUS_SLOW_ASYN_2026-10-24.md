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
| Design scale | ~8,978 / 18,480 ALM (49%), 2 PLLs, ~150 M10Ks, 0 DSP; top `apf_top_stream` |
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
- The design's scale cannot explain the grind: at 14:36 today, A&S of a **pathologically broken
  1,053,672-register netlist (100× the real one)** finished in a few minutes — as an
  incremental run, admittedly, but scale is clearly not the limiting factor here.

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

## 7. Ruled out so far

- **Stale/poisoned db state** — wiped; clean run still grinds (though in a different shape:
  600 MB RAM, single-core, no I/O).
- **Design scale** — the 100×-larger broken netlist A&S'd in minutes.
- **Process hang / I/O block** — it's at 99.7% CPU (in-process computation), not waiting.
- **RTL logic error** — Verilator elaboration clean; 7 sim suites PASS; earlier today the same
  netlist elaborated in Quartus A&S without issue (16:53 run got through to TDS).
- **Disk full / other builds running** — 3.6 TB free; no other Quartus or sim processes.

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
   - `set_global_assignment -name TIME_DRIVEN_SYNTHESIS OFF` and re-run (isolates the TDS phase)
   - A&S-only run (`quartus_map`) to separate from fitter
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
