# AGENTS.md — Apple IIe **Analogue Pocket** core

## Purpose

Operational guide for an agent working in `apple2e-pocket/` with no prior
conversation context. Work as an FPGA/HDL engineer, preserve existing behaviour,
explain decisions in plain language, and validate at the narrowest useful level
before widening scope.

The **workspace-root `../AGENTS.md` covers the MiSTer project** (`Apple-II_MiSTer/`)
and does not mention the Pocket at all. Its general HDL rules, MSYS byte-safety
rules and Git-safety rules **do** apply here; its Quartus revision names, source
lists, `files.qip`, CONF_STR/OSD bit allocation and Verilator simulator sections
**do not** — this project has different equivalents, recorded below.

Read this file and `README.md` before editing. For current task context see the
newest `docs/PLAN_*.md` and `docs/BRIEF_*_KICKOFF_*.md`.

## Non-negotiables (learned the hard way)

1. **One Quartus process at a time.** All runs share `src/fpga/db`. Concurrent
   compiles corrupt it and produce mutually inconsistent reports. See
   "Build discipline" for the 2026-10-25 incident.
2. **Never edit RTL while a compile is in flight.** The compile reads sources at
   unpredictable times; editing underneath it yields results that describe no
   coherent source snapshot.
3. **Never delete `src/fpga/db/`.** It is the only thing that makes a rebuild take
   ~1 minute instead of ~30.
4. **`sd_root/Cores/Newsdee.Apple2e/` is the single source of truth**
   for all core manifest JSONs. There are deliberately no copies at the repo root;
   `apf_stream_video_build.bat` **fails the build** if one reappears.
5. **Do not commit unless asked. Do not start a full Quartus compile unless asked**
   — the owner runs those.
6. **Preserve unrelated uncommitted work.** Multiple agents have worked this tree
   concurrently. Before finishing, re-check `git status` and confirm you did not
   clobber someone else's edits.

## Repository map

```
src/fpga/                     Quartus project (revision apf_stream_video, top apf_top_stream)
  apf_stream_video.qsf        source list - register every new file here
  apf/                        Analogue APF shell (bridge, pad, ddio, build_id_gen.tcl)
  core/apple2e/               Pocket-specific integration + glue  <-- edit here
  output_files_apple2e/       reports, .sof/.rbf
  db/  incremental_db/        synthesis cache - NEVER delete db/
machine/                      machine core; several files BYTE-PINNED to the MiSTer donor
  apple2.v keyboard.v ...     pinned - checked by check_machine_sync.sh
  osk/                        on-screen keyboard
verilog/                      Verilator harnesses
  tb/                         self-driving SystemVerilog testbenches
  pocket_boot/                boot smoke harness
tools/                        probes (ram_repro*, woz_fingerprint.py)
sd_root/                      EXACT card layout - copy to the Pocket SD root
  Cores/Newsdee.Apple2e/   all manifests + bitstream.rbf_r
  Platforms/apple2e.json
docs/                         plans, briefs, expert reviews, handovers
refs/                         reference material: basicassets/, nes-pocket/
check_machine_sync.sh         pinned-file parity check vs the donor
apf_stream_video_build.bat    full compile + stage; errors on root-level manifests
repackage.bat                 bitstream-only repackaging
```

Donor repository: `../Apple-II_MiSTer` (MiSTer core). Reference for pinning
revision is recorded in the relevant `NOTICE.md`. Note `refs/myc64-pocket` lives
at the **workspace root**, not under this project.

Device: Cyclone V **5CEBA4F23C8** — 18,480 ALMs, 3,153,920 memory bits, 308 M10K,
66 DSP, 4 PLL, 224 pins. Toolchain: **Quartus Prime 17.0.2 Lite**
(`C:\intelFPGA_lite\17.0\quartus\bin64\`).

## Build discipline

### Cold cache vs warm cache — a 23× difference

Measured on this design, same size, different cache state:

| Condition | Analysis & Synthesis |
|---|---|
| warm `db/`, no top-level source change | **00:01:16** |
| cold `db/`, or a top-level source changed | **00:27:07** (~33 min wall for the flow) |

Quartus's A&S cache is invalidated for a changed module **and everything
instantiated above it**. `core/apple2e/apf_stream_video_top.v` sits directly under
`apf_top_stream`, so **any edit to it costs a full ~30-minute synthesis.** Editing a
leaf module (`pdl_timer.v`, `sdram_status_overlay.v`) does not.

Consequences:

- **Batch top-level edits.** Collect several `apf_stream_video_top.v` changes into
  one compile instead of one compile per change.
- Also invalidating: adding or removing source files, and editing the `.qsf`.
  **`apf/build_id.mif` is NOT one of these** — it is regenerated on every build
  (`PRE_FLOW_SCRIPT_FILE`) and its date/time/hash words do change, but the
  generator's own comments state that *"MIF bram contents like above won't affect
  the random seed or trigger recompilation"*. The Verilog variant
  (`generateBuildID_Verilog`) would force a recompile and is deliberately
  commented out. Do not chase the MIF as a cause of slow builds.

### Cold A&S took ~26 minutes for a 6,700-ALM design - root cause found and fixed (measured 2026-10-25)

The earlier hypothesis ("database I/O; move to NVMe") was **wrong** - the
cost was **single-threaded CPU time spent processing the procedural RAM
zero-initialization representation** (the nested 256x256 `initial` loop that
zero-filled the 64 KiB main/aux RAM, entered in commit 9085041). The
"Elapsed Time Per Partition: Top 00:00:41" reading is misleading: the
partition timer does not account for the memory-initialization merge pass
that runs outside it. CPU time ~= wall time (26:40 vs 25:55) is the
tell-tale of a single-threaded phase.

Controlled probe evidence (tools/ram_repro_*, identical one-bank 64Kx8 RAM,
5CEBA4F23C8, same volume and host):

| Init representation            | A&S wall | CPU (single-thread) |
|--------------------------------|----------|---------------------|
| none / plain                   | ~16 s    | 3 s                 |
| nested 256x256 zero loop       | 19:13    | 18:52               |
| $readmemh 64 KiB zero image    | 1:28     | 1:13                |

The fix (shipped 2026-10-25): the loop was replaced by two `$readmemh` calls
from the canonical `src/fpga/rtl/roms/ram_zero_64k.hex` (65,536 x "00";
`*.hex text eol=lf` in .gitattributes so checkouts stay byte-exact). Full-core
result: **A&S 25:55 -> 2:14 (11.7x), total flow 30:15 -> 7:24**, with
bit-identical resources (8,060 ALM / 6,696 regs / 1,527,836 mem bits),
hardware-verified (power-on boot + reboot-on-load). Cold `quartus_map` after
a top-level edit is now on the order of minutes, not ~27.

Open follow-ups: (1) the runtime clearing sweep already zeroes both banks
after every cold reset and Cyclone V M10K power-up contents are defined -
removing configuration-time init entirely (the "none" probe is just as fast)
is a hardware-verified decision, deliberately NOT made as part of the
build-speed fix; (2) the 19:13 loop number is historical (2026-10-24); a
fresh loop-repeat control (~20 min) was not run - the plain/none/file
numbers are fresh (2026-10-25).

Lessons that survived the correction: a stage that is slow despite a short
per-partition timer means look for work OUTSIDE the partition (init
processing, netlist passes) instead of blaming disk I/O; `flow.rpt` stage
totals plus "Total CPU time" are the honest numbers (CPU ~= wall implies a
single-threaded phase). The endpoint-AV interference documented in this file
is real for *simulation* builds (it kills freshly linked executables), but it
is not the A&S bottleneck.

- **`quartus_map` alone is the cheap interface check** - and after the
  2026-10-25 file-init fix even a cold run is on the order of minutes for
  this design (A&S 2:14), so it is a legitimate shortcut after a top-level
  edit again.
- A "stuck at 22%" progress bar is **normal**: the netlist synthesis/optimisation
  phase emits no messages for tens of minutes and `db/*.map.qmsg` stops growing.
  Prove liveness with CPU time, not the log —
  `powershell "Get-Process quartus_map | Select Name,CPU"` sampled ~8 s apart. A
  pegged core means it is working. Peak A&S virtual memory is ~5.1 GB; a few
  hundred MB means it is still early.

### Verify report coherence before reading any number

Reports in `output_files_apple2e/` are overwritten **per stage, not per run**. A
map-only run updates `map.summary` while leaving `fit.summary` from an earlier
full compile — so the two can describe **different designs**. Before trusting
resource numbers:

1. Compare mtimes of `map.summary`, `fit.summary`, `sta.summary`, `asm.rpt`. They
   must belong to one run (fit/asm/sta within a couple of minutes of each other).
2. Confirm no RTL file has an mtime **inside** the compile window:
   `ls -lt --time-style=+%H:%M:%S src/fpga/core/apple2e/*.v machine/*.v`.
3. Confirm only one Quartus process was running.

### Acceptance baseline

Three coherent full builds exist; know which one you are comparing against.

**Current reference - 2026-10-25 11:02** (first coherent full build *including*
the joystick; `joystick_input:u_joy` and `pdl_timer:u_pdl` both present in the
netlist, rbf staged to `sd_root` at 11:41):

```
Fitter        6,688 / 18,480 ALMs (36 %)
Registers     6,255 (fit)  /  5,738 (map)
Memory bits   1,527,836 / 3,153,920 (48 %)   <-- unchanged, inference fine
RAM blocks    190 / 308      DSP 4 / 66      PLLs 2 / 4
Worst slack   +0.900 ns, all corners positive, TNS 0.000
Stage times   A&S 25:49 | Fitter 3:38 | Asm 0:07 | STA 0:21 | total 29:55
```

The **4 DSP blocks are expected and benign**: `pdl_timer.v` ports the donor's
`2800 + 22 * $signed(axis)` and Quartus infers DSP for those multiplies. Record
the change from the old 0-DSP baseline; do not "fix" it. (22*x is expressible as
16x+4x+2x if the DSPs are ever needed elsewhere.)

Earlier references, for delta tracking:

| Build | ALMs | Regs (fit/map) | Mem bits | DSP | Notes |
|---|---|---|---|---|---|
| 2026-10-25 11:02 | 6,688 (36%) | 6,255 / 5,738 | 1,527,836 | 4 | **current**; + joystick |
| 2026-10-25 00:59 | 6,489 (35%) | 6,101 / 5,708 | 1,527,836 | 0 | `OVL_DEBUG=0` overlay gate |
| 2026-10-24 22:30 | 7,962 (43%) | 6,573 / 6,067 | 1,527,836 | 0 | overlay still drawing; slack +1.104 ns |

Read the deltas, not the absolutes: 22:30 -> 00:59 dropped 1,473 ALMs because
`OVL_DEBUG=0` folds the overlay drawing logic away (**intended - do not
"recover" it**); 00:59 -> 11:02 added 199 ALMs, 154 registers and 4 DSPs for the
joystick, which is the right order of magnitude for ~240 lines of donor logic.

**`1,527,836` block memory bits has been identical across all three** and is the
single most important regression check. Any change means a RAM was inferred that
should not have been, or one stopped being inferred - stop and investigate before
proceeding.

### Stage the bitstream

A successful compile writes `output_files_apple2e/apf_stream_video.rbf`, but the
**card copy is separate**: `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r`.
It is easy to finish a build and leave the card stale. After an accepted build,
verify the staged file's mtime and size actually moved:

```bash
ls -l --time-style=+%m-%d_%H:%M:%S \
  src/fpga/output_files_apple2e/apf_stream_video.rbf \
  sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r
```

`apf_stream_video_build.bat` performs the copy and validates the manifests; prefer
it over ad-hoc copying.

## The RAM-inference trap (has cost hours twice)

Quartus 17 will not infer block RAM from idioms that simulate correctly. Observed
here:

- An async-clear idiom produced **1,053,672 registers** instead of RAM.
- A write-sweep with a **muxed write address** produced fitter **Error 276003**.

Proven-good shapes are in `tools/ram_repro_plain` and `tools/ram_repro_init`
(3 registers, 524,288 block memory bits). Rule of thumb from `tools/ram_repro_matrix`:
**a muxed write ADDRESS breaks inference; muxed DATA or an OR'd ENABLE are fine.**
The shipping RAM-clear uses a bus-overlay sweep (`ram_sweep_ctl.v`) driving
we/addr/aux through the normal bus so the RAM block stays plain single-port.

Symptom of the failure mode: a compile that runs for **hours** in the Fitter, not
minutes. If the Fitter is thrashing, check the register count in `map.summary`
before waiting it out.

## Core JSON files

All manifests live **only** in `sd_root/Cores/Newsdee.Apple2e/`
(`core.json`, `data.json`, `interact.json`, `video.json`, `audio.json`,
`input.json`, `variants.json`) plus `sd_root/Platforms/apple2e.json`. Root-level
copies were removed in commit `c40a26d` after they silently drifted (empty
`data_slots`, a missing option, a 320×240 `video.json` contradicting the shipping
native 560×192 stream). The build script now errors if any reappear.
`refs/basicassets/` and `archive/sd-legacy/` keep their own JSONs and are not part
of the package.

Budgets — do not re-derive, these are settled and hardware-validated:

- **`interact.json`: `variables[] ≤ 16`, but "list options don't count"** — a
  multi-way `list` costs ONE entry regardless of option count (`options ≤ 16`).
  Spend entries on *variables*, not choices.
- Skill **KB-079**: the 17th+ entry is not merely hidden, it is **never persisted**,
  with no error, warning or log line anywhere in the toolchain.
- Second combined cap: **interact + user-reloadable data slots ≤ 20**. `data.json`
  `parameters: 9` has bit0 set, so the disk slot already spends 1.
- `input.json`: `controllers[] ≤ 4`, `mappings[] ≤ 8` of `{id, name ≤19 chars, key}`,
  keys ∈ `pad_btn_a/b/x/y`, `pad_trig_l/r`, `pad_btn_start`, `pad_btn_select`.
  **The d-pad is not remappable.** A non-empty `input.json` is what enables the
  user remap UI.
- The Pocket gives almost no feedback on malformed JSON. Validate against the skill
  reference and check Tools → Developer → Builds and `/System/Logs/`.

Planned allocation (4 of 16): `Reboot on load` (exists) + 1 joystick + 2 video
(`Display Mode`, `Colour Preset`).

## Pinned files and CDC

- **Do not edit byte-pinned files under `machine/`** (e.g. `apple2.v`,
  `keyboard.v`, `joystick_input.sv`). They are synchronised with the donor and
  verified by `check_machine_sync.sh`. Put Pocket-specific behaviour in glue under
  `src/fpga/core/apple2e/`.
- Every pinned import needs a **`NOTICE.md`** recording donor repo, revision, file,
  that it is byte-pinned, and any local deviation with its reason — mirroring
  `src/fpga/core/woz/NOTICE.md`. Known example: the donor comment at
  `machine/apple2.v:119` labels gameport bits 3/2/1 `pb3 pb2 pb1`, but the real
  Apple II convention is `$C061`=PB0, `$C062`=PB1, `$C063`=PB2. **There is no
  PB3.** Record it in the NOTICE; do not edit the pinned comment.
- **CDC (skill KB-009):** pad signals arrive in the 74.25 MHz pad domain; machine
  logic runs at 14.318 MHz. The 3FF pattern in `apple2e_osk.v` is acceptable for a
  quasi-static button bitmap (a torn read costs one frame) — **but write that
  justification in a comment.** Do **not** copy `refs/myc64-pocket`, which syncs
  whole 32-bit buses under its own comment *"XXX: This is not the right way to do
  clock domain crossing"*. Keep multi-bit state inside one domain where possible.

## Testbenches

Self-driving SystemVerilog TBs live in `verilog/tb/`. Working invocation
(MSYS2 UCRT64, from the repo root):

```bash
cd E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket
# VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
verilator_bin --binary --timing -j 4 --top tb_ovl_status \
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
  --Mdir verilog/obj_dir_ovl \
  src/fpga/core/apple2e/sdram_status_overlay.v verilog/tb/tb_ovl_status.sv
./verilog/obj_dir_ovl/Vtb_ovl_status
```

Environment facts (all previously cost time; see workspace-root `AGENTS.md`):

- Use **`verilator --binary`**, not `--exe` — `--binary` supplies the
  `sc_time_stamp()` stub that `--timing` links need.
- Use **native `mingw32-make`**, never MSYS `/usr/bin/make` (it strips `TMP` from
  recipe children → `Cannot create temporary file in C:\WINDOWS`).
- The `--binary` link step calls a bare `make`; ucrt64 ships only
  `mingw32-make.exe`. Put a shim dir on `PATH` containing a copy renamed `make.exe`.
- Export `VERILATOR_ROOT`, put `C:\msys64\ucrt64\bin` on `PATH`, and call
  `verilator_bin.exe` directly (the Perl wrapper is broken under MINGW64 Perl).
- Run exes with CWD at the repo root — DUT `$readmemh` paths are CWD-relative.
- **Host AV kills freshly linked C++ exes.** Chain `rm <exe> && make && <exe>` in
  one command and run the most important tests first. If a one-line probe compile
  exits 1 with no output and no stderr, the AV block is active: stop retrying, fall
  back to `verilator --lint-only -sv`, and document the exact re-run command.
- Regression gate for anything touching input or the OSK: **`tb_wrapper_kbd`,
  `tb_kbd_protocol`, `tb_osk_ctrl` must pass unchanged.**
- `tb_phase2_shots.sv` defaults to `DEC=1`; shipping is `DEC2X=0` — pass `DEC=0`
  explicitly.

## Editing and Git safety

The repo mixes LF and CRLF. Preserve untouched bytes; never normalise a whole file.
After edits, run these from **inside a git repository** (`apple2e-pocket/`, or the
relevant sibling repo) — **not** from the workspace root:

```bash
cd E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket
git diff --check
git diff --numstat
git diff --numstat --ignore-all-space   # should be close to the above
bash ../eol_guard.sh                    # CR-count drift vs HEAD
```

> **`eol_guard.sh` is vacuous at the workspace root.** `E:/MiSTer/Apple-II_FPGAdev`
> is *not* a git repo, so its `cd "$(git rev-parse --show-toplevel)"` resolves to
> `cd ""` (a no-op in bash), `git diff` returns nothing, and the script prints
> "no CR-count drift" and **exits 0** regardless of the true state. Always confirm
> it actually inspected files — it prints one `EOL-DRIFT`/`ok` line per modified
> file, so **no per-file lines at all means it checked nothing.** This trap caused
> a whole session of falsely-reported "eol_guard clean" results (2026-10-25).

Known recurring drift, all from Quartus rewriting files with CRLF: `apf/build_id.mif`
(regenerated every build), `apf_stream_video.qsf`, `tools/ram_repro/ram_repro.qsf`.
Check whether the diff is pure EOL or carries real content (`--numstat` vs
`--numstat --ignore-all-space`); the `.qsf` legitimately gains a line per newly
registered source file. Decide consciously whether to keep or revert the EOL churn.

MSYS `sed`/`awk`/`cat -A` silently mangle `\r` (CRLF counts always read 0). Use
`od -c`, `xxd`, `tr -cd '\r' | wc -c`, or `perl` in `:raw` mode. LLM edit tools can
flatten a whole file's line endings; if that happens, rebuild from
`git show HEAD:<file>` with byte-exact `perl :raw` replacements rather than
re-normalising by hand. When scripting edits to CRLF files, anchor on **exact line
equality**, never a substring — a label like `:errmanifest` also matches
`goto :errmanifest` and will corrupt the file. Remove temporary scripts before
finishing.

Quartus may rewrite `apf_stream_video.qsf`; review such changes and keep only
intentional settings. `apf/build_id.mif` and `.qws` files churn as build noise.
Note the workspace-root `AGENTS.md` is **not version controlled** (the root is not
a repo), so edits to it leave no diff trail — state explicitly what was changed.

## Completion checklist

Before calling work complete, report:

- behavioural requirement and owning module;
- clock, reset, width, signedness and language-boundary implications;
- exact files changed, including any mirrored/pinned copies and their `NOTICE.md`;
- narrow TB result plus the regression gate, when applicable;
- Quartus status: which stages ran, **whether the reports are from one coherent
  run**, and new vs known warnings;
- resource delta against the acceptance baseline — call out any movement in
  **block memory bits**, registers, ALMs, DSP, PLLs, and worst slack;
- whether `bitstream.rbf_r` was staged, with its new mtime/size;
- remaining hardware-only checks, naming the actual software to test;
- `eol_guard.sh` result and confirmation that no stray temp files remain.

Explain the outcome in plain language first, then give the technical detail needed
to reproduce it.
