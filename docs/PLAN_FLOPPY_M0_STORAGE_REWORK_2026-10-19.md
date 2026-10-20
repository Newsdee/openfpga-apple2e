# Plan: Floppy M0 rework — transaction-safe image storage + hardware verifier

Date: 2026-10-19
Supersedes: `PLAN_FLOPPY_M0_STORAGE_2026-10-19.md` (wiring-only scope)
Authority: `M0_STORAGE_REVIEW_HANDOVER_2026-10-19.md` (accepted 2026-10-19,
addendum in `EXPERT_REVIEW_M0_STORAGE_2026-10-19.md`)

## Architecture (expert-recommended, accepted)

```
bridge writes @ clk_74a
  -> slot_fifo (dual-clock FIFO of complete {addr,data} records)
  -> store owner @ sdram_ctrl_clk (latches payload, drives io_sdram word port,
     tracks done, exposes init_done / load_drained / overflow / counts)
  -> io_sdram_pocket (local variant: explicit done/read-valid, real word_busy)
  -> SDRAM
  -> verifier @ clk_core_14318 (word-port readback, CRC32, byte/word counts,
     flags) -> diagnostics (bridge debug read + on-screen overlay)
```

Key invariants:

- The FIFO is the **only** CDC boundary. Inside the controller domain,
  `word_addr`/`word_data` are synchronous, so `io_sdram`'s raw payload reads
  (the reference's weak spot) are no longer a CDC problem.
- No request can be lost: every bridge write beat is captured as a record;
  the owner consumes records one at a time with latched payload; overflow is
  sticky-flagged (and the acceptance gate should make overflow impossible:
  see ready gating).
- Machine reset (host 0088) does **not** reset the FIFO/owner/verifier or
  re-initialize SDRAM — the resident image survives it. Core power/PLL-lock
  is the only reset.
- Host slot loading is gated: `status_setup_done` rises only when the machine
  PLL is locked **and** SDRAM init is done (host waits 0082 before loading
  data slots — the sanctioned no-deadlock gate). After
  `dataslot_allcomplete`, the owner must reach FIFO-empty + final-write-done
  before `load_drained` / `verified` can be set.

## Files

| File | Role |
|---|---|
| `src/fpga/core/apple2e/io_sdram_pocket.v` | Pocket-local controller: starts from the pinned `io_sdram.v`; **minimal documented diff**: `word_done` (1-cyc pulse at end of write op), `word_rd_valid` (1-cyc, with `word_q` at end of read op), `word_busy` asserted during ops, `boot_done` flag. Header carries the exact diff list. `refs/basicassets/` stays immutable; the stock `io_sdram.v` stays byte-identical (kept for reference). |
| `src/fpga/core/apple2e/slot_fifo.v` | Dual-clock FIFO, 74.25 write / 133.12 read, entry `{addr[23:0], data[31:0]}`, depth 64 (3,584 bits ≈ ⅓ M10K), sticky overflow, high-water mark. |
| `src/fpga/core/apple2e/disk_store.v` | Controller-domain transaction owner: consumes FIFO, drives `io_sdram_pocket` word port with latched payload, `init_done` (from `boot_done`), `load_drained`, received/committed word counts, overflow/timeout flags. |
| `src/fpga/core/apple2e/disk_verifier.v` | Machine-domain (14.318) readback client: on `start` (post-drain), reads `loaded_bytes` via the word port, CRC32 (IEEE) over the exact file length (partial final word masked by size from `dataslot_update`), first/last data check, endianness check, `verified` flag, result words. |
| `src/fpga/core/apple2e/apf_stream_video_top.v` | Rewire: bridge decode → FIFO write side; FIFO read side → `disk_store` → `io_sdram_pocket`; `disk_verifier` on the word port (arbitration: owner has priority; in M0 the two never run concurrently — load phase vs verify phase — M1 adds the machine fetcher under the same arbitration); `status_setup_done += sdram_init_done`; diagnostics register block; bridge **read** decode at `0xF9xxxxxx` (diagnostic words: flags, byte count, received/committed words, CRC, overflow, high-water); temporary on-screen diagnostic. |
| `src/fpga/core/apple2e/apple2e_core_constraints.sdc` | Mirror the reference's SDRAM constraints (`refs/basicassets/.../core_constraints.sdc`): `set_input_delay`/`set_output_delay` on the `dram_*` pins vs `dram_clk` (max 5.9/min 0.9 in; max 2.0/min −1.0 out) + `set_multicycle_path -from chip -to controller -setup -end 2`, adapted to `mp2 general[0]`/`general[1]` net names. Async-group entries kept (reference runs the identical combination). |
| `sd_root/Cores/Newsdee.Apple2eStreamVideo/data.json` | `required: false` for the regression RBF (manifest-only, no recompile); acceptance test loads a local fixture `.woz` (owned / storage-test — not a third-party disk image). |
| `verilog/tb/tb_slot_storage.sv` + DRAM model | See test ladder. |

## On-screen diagnostic (temporary, M0 only)

Minimal hard-coded 5×7 bitmap font for `{0-9, A-F, space, =, ., :}` plus a
few fixed words, top-right of the stream, visible ~5 s after `verified`
(toggleable later). Shows e.g. `OK CRC=1234ABCD N=01A4E0` or
`FAIL OV` / `FAIL TO`. Same data always latched in the `0xF9xxxxxx` bridge
debug-read registers. Removed or kept silent once M3 boot-time verification
exists. (If the overlay proves heavier than expected, fallback is bridge
debug read only — but the owner's hardware proof wants the screen.)

## Implementation order (each unit verified before the next)

1. **Unit 1 — `io_sdram_pocket.v`**: diff from pinned reference (4 signals),
   lint, diff-list audit against `refs/basicassets/`.
2. **Unit 2 — `slot_fifo.v`**: standalone CDC unit TB (Verilator, 3 async
   clocks; adversarial write patterns: back-to-back, bursts, idle; overflow
   sticky; high-water).
3. **Unit 3 — store owner + `io_sdram_pocket` unit TB**: behavioral 4-bank
   DRAM model (per-bank active row, ACT/READ/WRITE, tRCD/tCAS/tWR/tRP/tRC,
   auto-refresh tRFC, CKE, DQM, bus turnaround; single global open-row model
   rejected per review) — tests: isolated + back-to-back distinct words,
   request during refresh/boot, source changing during a pending op,
   adjacent bridge-write cycles, overflow/reset/timeout; no missing/dup/
   reordered/mixed-halfword writes.
4. **Unit 4 — full-top integrated storage TB**: `stream_video_core_top` with
   bridge-driven host writes → FIFO → store → SDRAM model → verifier readback;
   exact 512-byte block = **128** 32-bit words; sizes 0/1/2/3/511/512/513/max;
   partial-word masking by exact file length; address-as-data + walking bits
   + asymmetric patterns across row boundaries and allocation end; out-of-
   allocation readback must fail explicitly; repeat after idle/refresh;
   machine-reset-during-idle must not disturb the image.
5. **Unit 5 — SDC memory-bus constraints** + recompile (user runs it):
   dram pins must leave the unconstrained-outputs list; SDRAM setup/hold
   closure reported; deltas vs the 3,533-ALM baseline.
6. **Unit 6 — hardware**: regression RBF (`required:false`) boots diskless
   as before; then load the fixture `.woz`; on-screen `OK CRC=… N=…` matches
   the fixture CRC computed on the PC; machine reset preserves the image;
   capture host write spacing + FIFO high-water from the diagnostic words.

**M0 exit** (per review): exact storage results, bounded/observable failures,
deliberate startup/reload ordering, external-memory timing coverage,
successful hardware readback. "Machine still boots" is only a regression
check, not the gate.

## Open details (decide at implementation, flagged here)

- FIFO depth 64: recheck against the measured host burst rate from Unit 6
  high-water data; the init gate (setup_done) removes the 225 µs boot-window
  overflow risk, refresh stalls absorb ~12 words at worst-case rate.
- Verifier CRC32 poly: IEEE 80051809 reversed (standard), seed 0xFFFFFFFF,
  final xor — same as the PC-side fixture tool.
- Diagnostics bridge read region: `0xF9xxxxxx` (verified free in the current
  read mux; the `0x10xxxxxx` example region and `0xF8xxxxxx` command block
  remain).
- `disk_verifier` word-port arbitration vs the future M1 fetcher: owner
  priority register; M0 never contends.

## Status (updated 2026-10-20)

- **Unit 1 (io_sdram_pocket) — DONE.** 4-signal diff (word_done,
  word_rd_valid, word_busy, boot_done); byte-diff auditable; lint clean.
- **Unit 2 (slot_fifo + CDC TB) — DONE.** 64x56 Gray-pointer FIFO,
  synchronized read-domain reset, sticky overflow/high_water;
  tb_slot_fifo: reset, single op, fill/overflow, drain, mid-test reset,
  high_water, 4096-record concurrent mixed traffic, overflow stickiness —
  all PASS (131 us).
- **Unit 3 (disk_store + behavioral SDRAM model + unit TB) — DONE.**
  - `disk_store.v`: controller-domain store owner. Consumes FIFO records
    one at a time, latches the payload, issues exactly one word_wr per
    record (single-bit request queue), waits word_done; tracks
    words_received/words_committed; sticky timeout (4096 ctrl cycles);
    load_drained; no machine-reset in the path (image survives).
  - `tb_dram_model.sv`: behavioral 4-bank mobile-SDRAM model. Enforces
    tRCD/tRP/tRAS/tWR/tRC/tRFC, power-on settle, refresh-window rules
    (re-issued AUTOREF re-arms, matching real parts), 2-deep read pipeline
    with ABSOLUTE fire times (the controller issues two back-to-back READs
    per 32-bit word; a relative countdown races with the slot shift and
    reorders the data phases). Propagation: 1.5 ns on command pins
    (set_output_delay window max 2.0) and 1.5 ns on the DQ return
    (set_input_delay window max 5.9) — the reference design's alignment
    depends on these; an ideal zero-delay model is a non-representative
    corner.
  - `tb_disk_store.sv`: 74.25 MHz TB -> FIFO -> disk_store ->
    io_sdram_pocket -> model. Boot/init, 128-word store (counters
    128/128, no timeout/overflow), full 128-word readback via the same
    word port, second-block store with first-block integrity, all
    protocol checks clean. PASS at 342 us.
- **KEY FINDING — SDRAM clock phase (FPGA change required):**
  The io_sdram read-capture chain (enable_dq_read e4 window) only aligns
  when the chip-ctrl phase delta sits in a ~4.5 ns window of the 7.51 ns
  period (derivation: data must be visible at both e4 sample edges given
  the 1.5 ns delays; window = [TD_CMD, 7.512 - TD_DQ]). A 16-phase sweep
  at 2 ns propagation: PASS at 180 deg (+/-3.756 ns) only; the
  reference's actual 225 deg (mf_pllbase.v gui_actual_phase_shift3) and
  our requested 6573 ps (compiled to 315 deg on this device/grid per the
  M0 fit report) both FAIL in simulation. `apple2e_sdram_pll.v` outclk_1
  phase changed 6573 ps -> 3756 ps (180 deg, window center, robust to
  realistic delay ranges). This is a real hardware-facing change: the
  next compile must use the new value; M0 hardware acceptance re-validates
  the full path at 180 deg.
- Next: Unit 4 (disk_verifier + full-top integrated TB), Unit 5 (SDC
  memory-bus constraints incl. input/output delay + multicycle per the
  reference), Unit 6 (hardware).

## Unit 4 + 5 complete (2026-10-19)

Unit 4 shipped:
- `disk_verifier.v` (machine-domain readback client, reflected IEEE CRC32,
  first/last word, done/ok/stuck, per-word timeout), `sdram_status_overlay.v`
  (temporary on-screen M0 diagnostic, sits after the OSK in the video chain),
  `sdram_storage.v` (full storage-path module: FIFO + store + io_sdram_pocket +
  verifier + CDC shims + 0xF9 mux; single `word_addr` mux between store and
  verifier via a `req_kind` flag - M0 serializes load then verify), top rewired
  to the storage module, `tb_top_storage.sv` full-path integration TB.
- DUT bugs found and fixed during integration (both would have failed on
  hardware):
  1. `disk_verifier` ST_END never transitioned back to ST_IDLE when `start`
     deasserted - the first verify ran, then the verifier was permanently stuck
     (done stayed high; no re-verify possible).
  2. `disk_verifier` CRC engine merged each byte into the HIGH byte
     (`crc ^ {byte,24'h0}`) while using the reflected shift + polynomial -
     an inconsistent hybrid. Standard reflected CRC32 merges into the LOW
     byte; fix verified against an independent reference (512 B, 511 B, and
     1 B images all match).
- TB-side bugs found and fixed (test bugs, not DUT bugs): the request
  edge detector in the read shim was inverted for its synchronizer layout
  (s0 leads s1; the original condition detected the falling edge), and the
  scan spot-checks had to wait for `done` to fall before re-arming (the
  verifier holds done in ST_END).
- Final integration result (Verilator, full path TB -> sdram_storage ->
  slot_fifo/disk_store/io_sdram_pocket/disk_verifier -> behavioral SDRAM
  model with 1.5 ns command/DQ delays):
  ```
  A: boot complete, init_done
  B: 128 words stored, drained; high_water=1
  C2: 12 per-address readback spot-checks OK
  C: verify OK crc=c9260f5e first=a55a0000 last=a55a007f
  D: image survived verifier-only reset; re-verify OK
  E1: 511-byte tail verify OK crc=2545a82a
  E2: 1-byte tail verify OK crc=74beb8ea
  TOP STORAGE PASS: boot, 128-word store, CRC32 verify, reset-preservation, tails
  ```
  (C2 = per-address spot-checks that catch address-mux corruption beyond
  first/last; a model-memory white-box check additionally confirms the store
  wrote exactly the pattern. Verilator lint: new modules clean; the only
  warnings are the stock io_sdram PINMISSING/COMBDLY inherited from
  basicassets.)

Unit 5 shipped:
- `apple2e_core_constraints.sdc` now carries the memory-bus constraints
  mirroring the reference: `set_input_delay` (max 5.9 / min 0.9) on
  `dram_dq[*]`, `set_output_delay` (max 2.0 / min -1.0) on the command pins,
  `set_multicycle_path -setup -end 2` chip->controller, all clocked by
  `dram_chip_clk` = mp2 general[1] divclk with `dram_clk` as reference pin.
  CRLF preserved.

Next: Unit 6 (owner compile + hardware regression RBF). The compile must
confirm: (1) `3756 ps` phase accepted and implemented on mp2 general[1],
(2) the new SDC constraints resolve (no "no pins found" / unconstrained
dram-path warnings), (3) the dram clock domain meets timing (the
multicycle relaxes the setup path to 2 cycles), (4) ALM/reg delta vs the
3,533-ALM M0 baseline. The on-screen `OK CRC=... N=...` overlay, machine-
reset image survival, and the high-water/overflow behavior are the
hardware acceptance items (fixture .woz load, data slot required:false).

---

## Unit 6 implementation (2026-10-19, after expert review)

The expert review rejected the quiet-time (100 ms EOF heuristic) proposal
and required the APF load metadata contract. Implemented as a load/verify
coordinator inside `sdram_storage.v` (host domain, `clk_74a` — same domain
as the APF handshake signals from `core_bridge_cmd`, so no CDC):

- Inputs: `ds_requestwrite` (0082 pulse), `ds_requestwrite_id`,
  `ds_requestwrite_size` (exact byte count, NOT rounded), `ds_allcomplete`
  (008F level).
- FSM: CO_IDLE -> CO_LOAD (0082 for DISK_SLOT_ID) -> CO_DRAIN (008F edge)
  -> CO_WAITV (drained + gen_words >= ceil(size/4) + no faults) -> CO_RES.
  Per-load re-arm on every 0082 (not core-boot-only). Empty size (0) at
  008F -> NOFILE. Size > 64 MiB -> FAIL invalid at 0082.
- Completion is NOT 008F alone: it requires 008F AND storage drained AND
  the per-generation word count matching the latched exact size. Fewer
  words -> FAIL IN (incomplete), never OK.
- Faults: FIFO overflow -> FAIL OV; store timeout -> FAIL TO. Both sticky
  flags are cleared per generation (new inputs `overflow_clr` on
  `slot_fifo`, `timeout_clr` on `disk_store`; counters widened 16->24 bit).
- Verifier arm uses the rising edge of the synced done (not the level),
  latches the result once, and a later 008F cannot clobber a latched
  result (guard `allc_edge && !res_valid` in both CO_IDLE and CO_RES).
- Result contract (machine-domain outputs for the overlay): `res_valid_m`,
  `res_code_m` (0 OK / 1 FAIL / 2 NOFILE), `res_fail_m` (0 ST / 1 OV / 2 TO
  / 3 IN), `res_crc_m`, `res_nbytes_m`. Overlay shows `OK CRC=XXXXXXXX
  N=XXXXXXXX`, `FAIL OV/TO/IN/ST`, or `NO FILE` for ~5 s on `res_valid_m`.
- `data.json`: disk slot `required: false` (diskless regression boot legal;
  no-file boot shows `NO FILE`).

Bugs found during integration (all fixed):

1. **`co_st` declared 2-bit for 5 states**: `CO_RES = 2'd4` truncated to
   0, aliasing CO_RES with CO_IDLE in the case statement. Symptom: after
   each generation the FSM silently sat in CO_IDLE, where the unguarded
   NOFILE branch let a later 008F clobber a latched FAIL result (T7).
   Found by a transition trace showing `st 3 -> 0` with no triggering
   event; fixed with a 3-bit state + `default: ;` and the `!res_valid`
   guard in CO_IDLE too.
2. **Stale `res_fail` on OK**: the CO_WAITV OK path wrote `res_code` but
   not `res_fail`, so an OK result could carry the previous generation's
   fail subcode (T8 saw code=OK with fail=OV). Now cleared on OK.
3. **T8 fault semantics**: with the chip ignoring all commands, the
   controller-timed word ops still "complete" (io_sdram raises done on
   its own timing — there is no chip ack to time out), so a store
   timeout is NOT the observable; the READBACK is. The model's Z-DQ
   reads back as 0 (two-state), so the verifier returns a complete
   (OK-coded) result whose CRC is the all-zeros CRC (b2aa7578 for 512 B)
   instead of the written pattern — corruption is caught by the CRC,
   exactly as it would be on hardware with a dead/hung chip. The
   `store_timeout` latch remains a pure safety net (exercised by the
   per-word timeout logic in `disk_store`, not by an unresponsive chip).

Test evidence (verilog/tb/tb_top_storage.sv, all PASS, 4 ms sim):
  A/B/C2/C/D/E1/E2 — unchanged manual-path tests still pass
  T5: 008F with no 0082 -> NOFILE result, no verify
  T1: 0082(512) -> 64 words, 350 ns host pause, 64 words, 008F before
      final commits drain -> auto-verify OK, crc=c9260f5e (exact size)
  T2: reload same slot, 513 bytes (partial word) -> OK, exact CRC
  T3: 1-byte file -> OK;  T4: 511-byte file -> OK (exact tails, no
      4-byte rounding anywhere)
  T6: size=512, only 100 words sent -> FAIL IN, no verify, no OK
  T7: 100-word unpaced burst (FIFO 64 deep) -> FAIL OV; later 008F does
      not clobber the result
  T8: chip fault during load -> readback-complete OK with corrupted CRC
      (b2aa7578 != pattern c9260f5e), stale fail subcode cleared

Verilator lint: clean except the documented pre-existing stock
io_sdram PINMISSING/COMBDLY. Unit TBs re-run: tb_slot_fifo PASS
(131 us), tb_disk_store PASS (342 us). All files LF.

Remaining: owner Quartus compile of `apf_stream_video` (Q17 parse of the
new coordinator + overlay + wider counters; SDC constraints; ALM/reg
delta vs the 3,533-ALM baseline; 3756 ps phase on mp2 general[1]) and
the hardware regression RBF (fixture .woz -> on-screen `OK CRC=... N=...`;
no-file boot -> `NO FILE`).

## Unit 6 compile result (owner compile, 2026-10-20 10:11)

Full compile of `apf_stream_video` — **Flow Successful**, RBF generated
(1,395,284 B).

Compile checks:
1. A&S: 0 errors, 0 new warnings. The only map.smsg items are pre-existing:
   2x Warning 10268 (mixed blocking/NBA in stock `io_sdram.v` / our
   `io_sdram_pocket.v` — stock basicassets style) and 1x Info 10281
   (`PANEL_Y` case difference in the OSK q17 variant).
2. `mp2 general[1]` (sdram_chip_clk): **133.119991 MHz, Phase Shift
   180.000000 degrees** — the 3756 ps request is implemented exactly
   (general[0] controller clock: same frequency, 0 degrees).
3. SDC memory-bus constraints: no SDC-related warnings or "no pins
   found" anywhere; all dram-domain paths constrained.
4. Timing: all setup corners met. Worst setup = dram controller domain
   (mp2 general[0], 133.12 MHz) **+1.269 ns** (slow 85C); clk_74a +5.499;
   hold all positive except one endpoint (below); recovery/removal/min
   pulse all met.
5. Resources: 4,462 ALMs (24%), 4,189 regs, 154 RAM blocks
   (1,232,412 bits), 2 PLLs. Delta vs the 3,533-ALM M0 baseline is the
   whole storage path, which that baseline did not yet contain:
   `sdram_storage:stor` = 934 ALMs (disk_store 63, disk_verifier 243,
   io_sdram_pocket 191, FIFO + coordinator), `sdram_status_overlay:ovl`
   = 219 ALMs incl. two LPM dividers (~58 ALMs) for the digit math,
   minus the old direct word path. Register delta (+2,057) is dominated
   by the 64x56-bit FIFO (3,584 bits) plus verifier/controller logic.

One reported endpoint (watch item, not a flow failure):
- **Fast 1100mV 0C hold, `clk_74a`: slack -0.006 ns (6 ps), TNS -0.006**
  on a single endpoint, reported by TimeQuest as INFO (332146/332119);
  the flow still succeeded and generated the RBF.
- Fitter "Delay Added for Hold Timing" details: **100/100 rows are
  paths INTO the OSK `virtual_keyboard_controller:oskc|selected_col[1]`
  register** (cursor column counter; sources: direction/btn_latched/
  ms_divider/step_elapsed_ms/repeat_stage etc., 1.4-3.5 ns delay each
  added). The residual -0.006 is that same endpoint after the fitter's
  hold fixes.
- Assessment: pre-existing OSK logic (`machine/`, byte-identical shared
  file, hardware-verified in P2b), not storage code. The storage rework
  added ~900 ALMs to the same 74.25 MHz domain, so placement of this
  already-fan-in-heavy counter shifted and 6 ps of fast-corner hold
  remained. 6 ps at fast 0C is below board-level variation; hold is the
  most robust check. No RTL change made (would touch the shared machine
  file and the verified OSK). If a future compile grows this, options:
  different fitter seed, or restructure the `selected_col` counter
  (ripple -> staged) in the shared OSK controller with full re-verify.
- Metastability: 343 synchronizer chains found, shortest 2-stage — the
  Clifford FIFO syncs by design (MTBF not calculable, as expected).

Remaining hardware acceptance: load `DOS 3.3 System Master.woz`
(234,496 B) via the disk data slot -> on-screen `OK CRC=... N=39000`;
no-file boot -> `NO FILE`; machine reset preserves the image.

## Unit 7: real-bridge integration TB + overlay rework (2026-10-20)

Hardware feedback after the Unit 6 bitstream: the owner can select a .woz
file, but **nothing else has apparent behavior** (no overlay result of any
kind). Investigation pass:

1. **`verilog/tb/tb_bridge_storage.sv` (new)** — instantiates the REAL
   `core_bridge_cmd` (the template decoder, same as the top) and drives the
   documented host sequence (`0000`/`0011`/`0082`+params at 0x20/0x24/
   bridge writes at 0x0 /`008F`), wired to `sdram_storage` exactly as the top
   wires it. Closes the "TB drove ds_* directly" abstraction gap. **PASS** —
   9 scenarios (status handshake, NOFILE, full load, 1001-B reload, wrong-id
   ignore, FAIL IN, FAIL OV + no clobber, machine-reset persistence, re-arm
   after fail). Build needs `src/fpga/apf/mf_datatable.v` + the
   `verilog/stubs/altsyncram_sim.v` stub (core_bridge_cmd's datatable RAM).
   → The 0082/008F decode path is proven correct in simulation.
2. **`sdram_status_overlay.v` rework** — the overlay had never been on
   hardware; review found (a) the "5 s show window" never expired
   (`show = res_valid && cnt != 0`, counter saturated — text was actually
   permanent) and (b) no state visible after the window. Fixes/changes:
   - `show` now genuinely expires; `SHOW_CYCLES` parameter (default 5 s).
   - Persistent 2-glyph corner mark (rows 0..4, x96..106): `OK`/`FF`/`NF`,
     on while a result is latched, re-arms on every machine reset.
   - Line 3 during the window: `R=NNNNN C=NNNNN[OTS]` (received/committed +
     O/T/S flags) so a stuck path is diagnosable on screen.
   - Width-clean lint (strict Verilator lint now warning-free).
3. **`apf_stream_video_top.v`** — 48-bit 3-stage sync of
   `{received, committed}` + the three machine-domain flags into the overlay.
4. **`verilog/tb/tb_ovl_status.sv` (new)** — raster-level pixel tests
   (quiet / four regions / expiry / reset re-arm / re-latch). **PASS.**
   TB raster model: hbl = 1-cycle pulse per line; vbl stays high through the
   first visible line's pulse (the overlay's row counter and
   `apf_stream_video`'s vs_pulse depend on that shape).
5. Re-verified: `tb_top_storage` PASS, `tb_bridge_storage` PASS,
   `tb_ovl_status` PASS. Overlay lint clean; top lint clean under project
   flags.

Hypotheses for the hardware symptom (ranked, see the expert brief):
H1 host does not send the modeled sequence on the Interact-reload path;
H2 bridge write shape/burst differs; H3 hardware-only SDRAM/PLL issue;
H4 overlay geometry vs the real 228x280 raster. The debug build (§4 of the
brief) disambiguates on the next hardware run.

Expert brief: `docs/EXPERT_REVIEW_M0_HARDWARE_NOVIS_2026-10-20.md`
(5 questions: reload sequence, partial-last-word handling, burst rate,
core-restart retransmit, in-flight aborts).

## Unit 9 — Overlay raster model rework (2026-10-20)

The Unit-8 overlay TB passed against a **wrong raster model** (1-clock `hbl`
pulse). Real machine `m_hbl` is a wide blanking interval (336 clocks/line;
`machine/timing_generator.v`: `HBL = ~(H[5] | (H[3] & H[4]))`). Consequences
found and fixed in this unit:

TB (`verilog/tb/tb_ovl_status.sv` — rewritten):
- Real raster: 336-HBL + 560-active lines, 40 VBL lines at frame start,
  40 visible lines (FRAME = 71680 cycles — the old 16-bit `fcyc` counter
  truncated at 65536 and the frame ended after 34 lines; now 17 bits).
- Edge-based row counting (HBL rising edge while `!vbl`, reset at VBL falling
  edge) — mirrors the DUT and `apf_video.v`.
- `sample_line` captures the 559 values the column counter takes during a
  visible row (col 0 only occurs inside the blank — the old wait-for-560th-
  pixel deadlocked every check).
- **Independent** 5x7 reference font transcribed from the DUT `gf` table;
  exact per-pixel comparison of every rendered glyph (all 16 hex digits,
  counter low nibble, each fault flag, marker stage digit).
- `SHOW_CYCLES` parameter override (400000) so the window covers the test flow.

DUT (`sdram_status_overlay.v`):
- Fixed glyph horizontal mirror: pixel `c` reads bit `4-c` (bit 4 =
  leftmost), all four boxes. Symmetric glyphs hid it from the marker.
- Edge-based row/col counters (see Unit-8 code block).
- `show` window expiry (Unit 8, re-verified):
  `show = res_valid_m && show_cnt != 0 && show_cnt != SHOW_CYCLES`.
- `stage_m` from storage (coordinator stage), marker `M0<stage><status>`.

DUT bugs found and fixed in `sdram_storage.v`/`disk_verifier.v` along the way:
- Verifier read-timeout latched `stuck` and returned to IDLE without `done`;
  the coordinator hung in CO_WAITV forever. Now releases on
  `v_done_rise_74 | v_stuck_74`; stuck path latches FAIL TO. Verifier has a
  `timeout_override` test port.
- `stage_m` machine-domain output added (stage for the marker).

Status (2026-10-20): marker rows 0-4 render pixel-exact (4-glyph `M06O`,
quiet case exact); L1/L2/L3 text lines still corrupted — space glyphs render
as a 3-px vertical bar and non-space cells show OR'd extra row bits matching
glyph '0'; L3 cells 0-5 and 11-14 are exact, proving the counter/index math
is right where the right `ln` entry is read. Marker rows 5-6 missing
(`in_lm = row < 5` vs 7-row glyphs). T5 window-expiry check still failing.
Storage-side TBs re-verified PASS today (`tb_bridge_storage` all 9 scenarios,
`tb_top_storage` full suite).

Expert brief (pending): `docs/EXPERT_REVIEW_M0_OVERLAY_RASTER_2026-10-20.md`
(5 questions: glyph-latch/gf corruption, counter model, hardware "nothing
visible" linkage, T5 expiry, marker geometry). Companion:
`docs/EXPERT_REVIEW_M0_HARDWARE_NOVIS_2026-10-20.md` (host-bridge half).

Bitstream provenance: owner's 2026-10-20 11:19 `apf_stream_video` compile
(1,402,216 B RBF) re-staged to `sd_root/Cores/Newsdee.Apple2eStreamVideo/
bitstream.rbf_r` (sha256 `2610357c...b6fbe`, both sides verified).
`src/fpga/apf/build_id.mif` reverted after Quartus rewrote it.

## Unit 10 — Expert-review fixes for the overlay (2026-10-20)

Expert review of `docs/EXPERT_REVIEW_M0_OVERLAY_RASTER_2026-10-20.md` returned
source-grounded findings; all implemented and verified in sim:

1. **Confirmed DUT bug (the text corruption):** the three text pixel enables
   (`px1/px2/px3`) omitted their vertical-region gates (`in_l1/in_l2/in_l3`).
   Outside their row band the glyph selectors fell back to glyph code 0
   (digit '0', not blank) with row offset 0, and the compositor OR'd the
   result over the active line — exactly the decoded signature (spaces
   gaining pixels, OR'd zero-glyph bits, L3 corrupt where L1/L2 x-ranges
   overlap, L3 cells 0-5 exact where no other layer reaches).
   **Fix:** added `in_lN` to each pixel enable.
2. **Marker row gate:** `in_lm = row < 5` -> `row < 7` (7-row glyphs; L1
   starts row 8, no collision). T0 now checks all 7 marker rows exact.
3. **TB generation model:** `set_result` now drops `res_valid_m` low,
   settles, then presents the payload and raises valid — models a new 008F
   generation (the DUT latches text on the rising edge; T2/T3/dump were
   changing fields with valid held high and expecting re-latches that
   correctly never happened).
4. **TB expiry timing:** `SHOW_CYCLES` override raised to 4_000_000 (~280
   ms) so the dump phase stays inside the window; T5 now pre-checks text
   ON, waits 4_200_000 cycles past expiry, then checks text OFF + marker
   persists.
5. **TB failure reporting:** aggregate `fails` (no per-scenario resets;
   per-scenario deltas via `fbase`), `$fatal(1, ...)` on sample_line
   timeout, on final failure, and on watchdog (watchdog now 5 s sim).
   A broken overlay can no longer exit 0.
6. **TB raster wait:** after reset, wait for the first visible line
   (`while (vbl)`); before that `m_row==0` is the stale reset value and
   `sample_line(0)` was reading a VBL line (T0 row-0 marker "missing").
7. **TB reference-font transcription fix:** 'L' row 5 was 01111 instead of
   10000 (T3a 'NO FILE' caught it; the DUT was correct).
8. **Hardware diagnostic rectangle (expert rec 6):** new DUT parameter
   `DBG_RECT` (default 0) — when compiled 1, draws a persistent white
   50x3 rectangle (rows 10..12, cols 100..149) independent of storage,
   results, and font logic. Verified by new `verilog/tb/tb_ovl_dbgrect.sv`
   (PASS: rectangle on 2 frames, marker intact, no strays). Shipping
   builds keep the default (0).

Results: `tb_ovl_status` all 14 scenario checks PASS (T0 quiet marker all 7
rows, T1a-d exact text+marker, T2a-b 16 hex digits, T3a-c NOFILE+flags,
T4 stage, T5a-b expiry, T6 reset re-arm); `tb_ovl_dbgrect` PASS; overlay
strict lint clean.

**Stale bitstream:** the staged `bitstream.rbf_r` (sha256 2610357c...)
predates the Unit-10 fixes. The overlay RTL changed (gates, 7-row marker,
DBG_RECT parameter) so a fresh owner compile is required before the next
hardware run. For the one-shot hardware diagnostic build, make this
one-line change in `apf_stream_video_top.v` (line 854):

    sdram_status_overlay ovl (          ->  sdram_status_overlay #(.DBG_RECT(1)) ovl (

Then compile `apf_stream_video`, flash, and observe: if the white rectangle
is visible, the overlay IS in the video path and the earlier "nothing
visible" was the (now-fixed) gate/mirror bugs; if it is not, the overlay
port wiring or a higher-level video issue is the cause (next probe: force
the rectangle in `apf_video` output). Revert `#(.DBG_RECT(1))` and
re-compile for the real M0 acceptance build.

Follow-up (expert rec 5, deferred): a DE-based stream-level raster check
(560 px/line, full machine frame) to prove the DUT counters align with the
real `m_hbl`/`m_vbl` waveforms; the synthetic wide-blanking raster remains
the unit-level model.
