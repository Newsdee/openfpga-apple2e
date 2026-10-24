# Expert review — M1 WOZ: Quartus 17 compile blocker + M0/M1 regression gate

**Date:** 2026-10-20
**Project:** `apple2e-pocket` — Apple IIe core for Analogue Pocket (openFPGA/APF)
**Repo:** `E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket` (remote `Newsdee/openfpga-apple2e`, branch `main`)
**Status:** M0 (SDRAM storage) hardware-accepted. M1 (WOZ floppy) Units 1–6 complete in Verilator.
Unit 7 (regression + owner Quartus compile + hardware) is in progress and **blocked by a Quartus
Analysis & Synthesis error in the byte-identical WOZ engine**.

This brief is self-contained. It has no prior conversation context. It asks you to (a) ratify how to
fix a Quartus-only Verilog error in a file we treat as byte-identical, and (b) advise on closing the
M0/M1 simulation gate (one toolchain flake + one TB watchdog to re-verify).

---

## 0. RESOLUTION (2026-10-20, post-expert-review)

**The expert chose Option D and it is applied.** The MiSTer reference registers five WOZ
files as **SystemVerilog** (`files.qip`: `disk_ii_woz.sv, woz_floppy_controller.sv, flux_drive.v,
woz_bram.sv, woz_cell525.sv`), with only `disk_ii_rom.v` as Verilog. A continuous assignment to
a variable is **legal in SystemVerilog** — so the `output reg`+`assign` in `flux_drive.v` is not
a defect in the reference; Pocket simply registered all six as Verilog. **Fix (applied,
`apf_stream_video.qsf`):** register those five as `SYSTEMVERILOG_FILE`. This preserves
byte-identity + the existing SHA-256 pin; **no engine file is edited.** (Option A — the 2-line
`reg`→`wire` port fix — is now unnecessary unless matching the reference's language mode still
fails.)

Also applied from the review:
- **Regression runner defects fixed** (`run_m0m1_regress.sh`): absolute exe path, stderr captured
  *inside* the command substitution, PASS now requires `runrc==0`, build/link gated on exit
  status (not just `%Error`/exe existence).
- **`tb_disk_store` root cause found + fixed** (expert's protocol-mismatch candidate): `rd_back`
  fired a *1-cycle* `word_rd` pulse; the edge-latch port queue needs the level *held* until the op
  completes (a pulse races the 3FF sync + auto-refresh and can be dropped). Changed to a held
  level + re-run: `DISK STORE PASS`.
- **Brief corrections** (below): top entity is `apf_top_stream`; run Quartus from `src/fpga`;
  the hash-check used `cmp` on file bytes (the old `diff <(sha256sum)` compared the full line
  including the differing file name); warning classification corrected.

**Unit 7 status:** Option D applied; full M0+M1 regression re-running (target 10/10 +
full-machine boot); owner A&S + full compile next.

---

## 1. What this is / what is done

The Pocket Apple IIe core streams native machine video + a full-color OSK to the APF DDR pad
(hardware-accepted). Floppy is the current milestone:

- **M0 — external-SDRAM image storage** (host `0082` load → FIFO → store → CRC32 verify →
  coordinator OK/mount). **Hardware-accepted** on the Pocket (owner screenshots: NO FILE diskless,
  OK CRC after a `.woz` load, reset re-arm). Committed `44c2144`.
- **M1 — WOZ floppy machine fetcher.** The Disk-II/WOZ engine from the active MiSTer core is
  ported in **byte-identical** (6 files, SHA-256 pinned, `src/fpga/core/woz/NOTICE.md`). A
  controller-domain **sector fetcher** + machine-domain **transport** replace MiSTer's HPS `sd_*`
  byte bus so the engine reads sectors from Pocket SDRAM. Units 1–6 all **pass in Verilator 5.050**:
  - Unit 2 sector ownership, Unit 3 host-paced transport, Unit 4 mount/lifecycle + `data.json`
    parameters `73` (0x49), Unit 5 engine import + integration TB, Unit 6 full-machine boot TB.
- The active Quartus project is **`apf_stream_video`** (top `apf_top_stream`), device
  **5CEBA4F23C8**, **Quartus Prime Lite 17.0.2**. Fit baseline (pre-Unit-5 owner compile):
  5,157/18,480 ALMs (28%), 4,422 regs, 154/308 RAM blocks, min slack 0.320 ns.

The **owner launches Quartus compiles** (the agent does not run long compiles). The owner ran the
Unit-7 compile and it **fails in Analysis & Synthesis**.

---

## 2. PRIMARY BLOCKER — Quartus `Error 10219` in `flux_drive.v`

### 2.1 The exact error (owner output)

```
Error (10219): Verilog HDL Continuous Assignment error at flux_drive.v(627):
  object "STEP_EVENT" on left-hand side of assignment must have a net type
Error (10219): Verilog HDL Continuous Assignment error at flux_drive.v(628):
  object "TRACK0_EVENT" on left-hand side of assignment must have a net type
...
Error: Quartus Prime Analysis & Synthesis was unsuccessful. 2 errors, 26 warnings
Error (293001): Quartus Prime Full Compilation was unsuccessful.
```

A&S fails on exactly these 2 errors → the fitter/timing never run → no RBF. **26 warnings** are
pre-existing (the `map.smsg` shows 5× Warning 10268 "always contains both blocking and nonblocking"
in the engine + storage, plus processor-count / dangling-port-list style warnings); none are the
blocker (the 2 errors are).

### 2.2 Root cause (verified against source)

`src/fpga/core/woz/flux_drive.v` declares two ports as **`output reg`**:

```verilog
85:    output reg         STEP_EVENT,      // head actually moved (servo or snap)
86:    output reg         TRACK0_EVENT,    // head pressed against the track-0 stopper
```

but drives them with a **continuous assignment** (`assign`), which in Verilog requires a **net**
type on the LHS:

```verilog
620:    // Expose internal state for parent-level sense computation
621:    // (Verilator evaluation order workaround: submodule input ports may be stale
622:    //  when combinational outputs are computed, so parent can compute sense directly)
627:    assign STEP_EVENT        = step_event_r;
628:    assign TRACK0_EVENT      = track0_event_r;
```

`step_event_r` / `track0_event_r` are ordinary procedural `reg`s (1-cycle pulses, driven in the
stepper always-block at lines ~1024/~1030). The intended design is: an always-block reg computes the
1-cycle pulse, and the **output port is a continuous alias** of it. The declaration should therefore
be a **net** (`output`/`output wire`), not `output reg`. `output reg` + `assign` is illegal for a
synthesizable net — Quartus rejects it (10219).

**Verilator tolerates the pattern** (it elaborates the port as a net despite the `reg` keyword), which
is why all the M1 Verilator TBs pass and the defect only surfaced in Quartus. This is the classic
"sim-green, synthesis-red" mismatch the project rules warn about.

### 2.3 Scope is exactly 2 ports (verified exhaustively)

I scanned all 6 engine files for any `output reg` port that is also the LHS of an `assign`. Only
these two match:

```
STEP_EVENT    <- flux_drive.v
TRACK0_EVENT  <- flux_drive.v
```

Every other `output reg` port (`FLUX_TRANSITION`, `EJECT_REQ`, `SD_TRACK_STROBE`, `WRITE_*`,
`sd_lba`, `sd_rd`, `sd_wr`, `cell_*`, `dbg_*`, …) is driven **procedurally** and is legal. So the
fix is **exactly 2 lines**.

### 2.4 The minimal fix

```diff
-    output reg         STEP_EVENT,      // head actually moved (servo or snap)
-    output reg         TRACK0_EVENT,    // head pressed against the track-0 stopper
+    output wire        STEP_EVENT,      // head actually moved (servo or snap)
+    output wire        TRACK0_EVENT,    // head pressed against the track-0 stopper
```

Behavior is unchanged: the port is still a continuous alias of the same 1-cycle `_r` reg; only the
net-type of the port declaration is corrected. This should clear both 10219 errors with no logic,
timing, or resource change. (It does **not** touch the `assign` lines, the `_r` regs, or the
comment.)

---

## 3. The policy conflict this creates (the decision I need)

`src/fpga/core/woz/NOTICE.md` pins all 6 engine files by SHA-256 and states the policy explicitly:

> "If a future MiSTer engine change is needed, re-import byte-identical and re-pin the hashes here —
> **do not hand-edit the Pocket copies**."

**The byte-identical reference has the same defect.** I verified (2026-10-20) that the Pocket
`flux_drive.v` is byte-identical to the MiSTer source:

```
Pocket : 30500ab0…c4b554b   src/fpga/core/woz/flux_drive.v
MiSTer : 30500ab0…c4b554b   E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/woz/flux_drive.v
```

(identical SHA-256, empty `diff`). So the `output reg`+`assign` pattern lives in the MiSTer reference
too. Two implications:

1. Whatever fix is needed here, the MiSTer reference would need it as well (its Quartus either used
   a more permissive version, or its last successful A&S predates these `assign` workaround lines
   added for Verilator).
2. Fixing the Pocket copy **necessarily breaks the byte-identity pin** for `flux_drive.v`
   (its SHA-256 changes).

### Options for the expert to choose among

- **A. Minimal in-place fix + re-pin.** Apply the 2-line `output reg`→`output wire` fix to
  `src/fpga/core/woz/flux_drive.v`, update the `flux_drive.v` row in `NOTICE.md` with the new SHA-256,
  and add a one-line note that this is a Quartus-17 synthesis-compatibility fix (net-type only, no
  behavior change). Simplest; keeps one source of truth; the pin becomes "byte-identical except this
  documented net-type fix."
- **B. Generated Quartus variant.** Keep `flux_drive.v` byte-identical (canonical, sim + the pin),
  and generate a `flux_drive_q17.v` (or a build-time sed) that only Quartus compiles, swapping the
  2 port declarations. Mirrors the existing `machine/` policy ("Quartus-17 variants are generated,
  not canonical edits"). Preserves the pin but adds a second file + generation step to keep in sync.
- **C. Fix upstream in MiSTer, re-import.** Patch the MiSTer reference (out of this project's scope)
  and re-import byte-identical + re-pin. Cleanest lineage, but depends on changing the MiSTer repo.

**My recommendation (for you to confirm/override):** **Option A.** The intent of the byte-identity
policy is "don't let the engine's *behavior* drift from the hardware-proven MiSTer reference." A
net-type correction to a continuously-assigned port changes no behavior, so a documented 2-line
deviation (re-pinned hash + rationale in NOTICE.md) honors that intent while unblocking the compile.
Option B's extra file + generator is more moving parts than the fix warrants. (I did **not** want to
choose unilaterally because the policy is explicit, so I'm putting the decision to you.)

**Regardless of A/B/C**, the sim must be re-verified after the change (a WOZ TB + the full-machine
TB) to confirm the net-type change is behavior-neutral in Verilator.

---

## 4. M0/M1 simulation gate — state and the 3 items to close

I ran a fresh M0+M1 regression (`verilog/run_m0m1_regress.sh`, superset source list, one obj_dir per
TB, correct CWD per TB). **7 of 10 pass; 3 need characterization.** Importantly, **Unit 6 added no
RTL** (only a new TB + build script), so the M0/M1 RTL is at the Unit-5 state, where all of these TBs
last passed. My reading: the 3 "failures" are **test-harness/toolchain artifacts, not RTL
regressions** — but I want your agreement on the close-out criteria before I re-verify.

| TB | Result | My analysis |
|----|--------|-------------|
| tb_slot_fifo | **PASS** | — |
| tb_sector_fetch | **PASS** | — |
| tb_woz_mount_ctl | **PASS** | — |
| tb_woz_transport | **PASS** | — |
| tb_top_storage | **PASS** | — |
| tb_ovl_status | **PASS** | — |
| tb_ovl_dbgrect | **PASS** | — |
| **tb_bridge_storage** | BUILD-FAIL | **My script's superset source list omitted `mf_datatable.v`** (an APF module `core_bridge_cmd` instantiates). Not an RTL issue. I added it; the build then succeeded ("BUILD OK"). The run still needs a clean confirmation. |
| **tb_disk_store** | FAIL (watchdog) | Ran to its **2 ms watchdog** (`[2000000000] … WATCHDOG: 2 ms deadline exceeded`). Likely the Unit-5 store-protocol changes (level-held `word_wr`, edge-latch port queue) made a store operation slower than this TB's 2 ms bound — i.e., a **TB deadline to re-tune**, not necessarily a defect. Needs a clean re-run to confirm the store completes (just later). |
| **tb_woz_machine** | no ALL PASS marker | Needs a clean re-run. My re-link hit a **transient g++ link error** (`'-fuse-linker-plugin', but liblto_plugin.dll not found`) — a toolchain flake, not an RTL issue. Note: the host **AV/endpoint layer intermittently kills freshly-linked C++ PEs** (rc=127, no output); builds/runs must be chained and re-tried. |

**The two known-environment hazards (so you can judge whether these are blockers):**
- **AV/endpoint layer** kills fresh PEs (rc=127 / no output; `AmServiceEnabled=False` but an
  endpoint agent is present). Mitigation: `rm exe && make && run` in one chained command; re-try;
  it flaps open/closed over time.
- **g++ link flake** (`liblto_plugin.dll not found`) — intermittent; a clean re-link has succeeded
  previously in this session.

### Close-out I propose for Unit 7 (your sign-off?)
1. Fix the 2-line Quartus defect (per §3 decision).
2. Re-verify in Verilator that the fix is behavior-neutral: re-run `tb_woz_machine` (the M1
   integration TB) + `tb_u6_boot` (full machine) — both must be ALL PASS.
3. Clean re-runs of `tb_bridge_storage` (source list fixed) and `tb_disk_store` (confirm the store
   completes; re-tune its 2 ms watchdog if that's all it needs) so the gate is 10/10.
4. Hand the project to the owner for the Quartus compile (the agent does not run long compiles).
5. Hardware acceptance on the Pocket: DOS 3.3 **CATALOG with expected directory entries** (C7 — a
   prompt/non-blank frame is insufficient), diskless boot (NO FILE), reset persistence, and the
   0x49 reload (Interact → reset around reload → new generation usable).

---

## 5. Reproduction

### 5.1 The Quartus error (owner-driven; the agent does not run long compiles)

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\src\fpga
quartus_map apf_stream_video --read_settings_files=on --write_settings_files=off
```
(Analysis & Synthesis is the failing stage; a full `quartus_sh --flow compile apf_stream_video`
also fails at A&S.) The 2 `10219` errors in `flux_drive.v(627)/(628)` are the blockers.

### 5.2 The regression (Verilator 5.050, MSYS2 UCRT64)

```bash
# from the repo root, in an MSYS2 shell (the script sets up PATH/VERILATOR_ROOT/make-shim itself):
bash verilog/run_m0m1_regress.sh
```
It builds each TB into `verilog/obj_dir_rr_<tb>/` and runs it (CWD = `verilog/` for most;
CWD = repo root for `tb_woz_machine`, which reads `verilog/tb/golden/dosmaster_16k.hex`). A green
run prints `REGRESSION SUMMARY: PASS=10 FAIL=0`. The full-machine TB `tb_u6_boot` (the slowest,
~4 min; CWD `verilog/u6/`) is driven by `bash verilog/verilate_u6.sh` and reports `TB U6 BOOT: ALL PASS`.

### 5.3 The byte-identity check

```bash
cd apple2e-pocket
for f in disk_ii_rom.v disk_ii_woz.sv flux_drive.v woz_bram.sv woz_cell525.sv woz_floppy_controller.sv; do
  cmp -s "src/fpga/core/woz/$f" "E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/woz/$f" || echo "DRIFT: $f"
done
```

---

## 6. Facts the expert should not need to re-derive

- Toolchain: **Quartus Prime Lite 17.0.2** (device `5CEBA4F23C8`, top `apf_top_stream`);
  **Verilator 5.050** (Verilog-2001 mode, `--binary --timing`); **MSYS2 UCRT64** under `C:\msys64`;
  Python `/c/msys64/ucrt64/bin/python.exe`.
- The WOZ engine block protocol is **host-paced** (the Pocket transport walks `sd_buff_addr`,
  presents `sd_buff_dout`, strobes `sd_buff_wr`); the engine consumes one byte per strobe while ACK
  is high. (This is why the engine "reads" via the Pocket transport, not MiSTer's HPS bus.)
- The engine's `RESET`/`DD_RESET` is tied to the machine reset; its mount is a **held level**
  latched on the `IMG_MOUNTED` rising edge; a zero-size edge ejects.
- `disk_ii_rom` is inline-init; `woz_bram` is uninitialized scratch (no `$readmemh`); the only
  TB-level `$readmemh` golden is `verilog/tb/golden/dosmaster_16k.hex` (repo-root CWD) and
  `verilog/u6/golden/dosmaster_full.hex` (full 234,496 B, CWD `verilog/u6/`).
- `data.json` disk slot: `required: false`, `parameters: 73` (0x49: reloadable + read-only +
  Reset Enter/Exit around reload), `extensions: ["woz"]`, platform-common path
  `Assets/apple2e/common/disk.woz`.

## 7. Decisions requested

1. **§3: which option (A/B/C) for the `flux_drive.v` 10219 fix** — and do you ratify Option A
   (2-line `output reg`→`output wire`, re-pin the `flux_drive.v` hash, note the deviation in
   NOTICE.md)?
2. **§4: close-out criteria for the sim gate** — is "10/10 TB green + behavior-neutral re-verify +
   owner Quartus + hardware CATALOG" the right definition of Unit 7 done? Is re-tuning
   `tb_disk_store`'s 2 ms watchdog an acceptable fix (vs. treating it as a defect)?
3. Anything you see in the §2 root-cause analysis that would change the fix (e.g., if the port is
   actually used as a `reg` somewhere I missed — my scan says it is not).
