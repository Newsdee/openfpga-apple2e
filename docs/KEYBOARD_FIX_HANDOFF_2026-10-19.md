# OSK keyboard fix — handoff / current state

Updated: 2026-10-19 ~11:30 +08:00. Companion to
[OSK_KEYBOARD_FLOOD.md](OSK_KEYBOARD_FLOOD.md) (the diagnosis) and
[REVIEW_RECOMMENDATIONS_2026-10-19.md](../REVIEW_RECOMMENDATIONS_2026-10-19.md)
(the owner's read-only review). **This file is the current working state and the
correct next steps.**

> **CURRENT STATUS — 2026-10-19 15:40 +08:00:** Protocol-correct source baseline
> restored. Staged Attempt-2 bitstream is historical and does **not** match these
> sources. The sim is **clean at all three levels** (keyboard-latch protocol
> regression, machine+OSK+BIOS, and the full `apf_top` wrapper): one character
> per press, no flood, no reassertion (the earlier "reassertion" was a defective
> monitor). The reported **hardware flood is hardware-only** and not yet
> reproduced. Do **not** implement consume-on-`$C000`. Next step: recompile the
> restored baseline and capture matching **hardware** evidence.

## 2026-10-19 15:00 — Phase A baseline + Phase B CPU-boundary (observations, not yet a root cause)

Implemented per [recommendation.md](recommendation.md) (owner-authorized):

**Phase A (baseline):** removed the experimental `KEY_READ_C` entirely (machine,
`core_top`, OSK, all TBs, sync checker). `machine/apple2.v` is **byte-identical to
MiSTer** again; the machine-to-keyboard path is the normal registered `READ_KEY`
(`$C010` read / `$C01X` write). The valid OSK host-reset separation, Apple-button
GAMEPORT wiring, and the `reads` input direction are preserved. P2a sim **PASSes**
on this baseline (`rk=56`). Provenance recorded below. **The staged
`be707178…` bitstream is the STALE Attempt-2 (`KEY_READ_C`) build and does NOT
match these sources** — it must be recompiled before any hardware test.

**Phase B (CPU-boundary probe):** added a probe that samples at the 6502
advance edge (`d1.CPU_EN` = `machine_ce && falling(PHASE_ZERO)`) and records the
keyboard-register reads qualified to that edge. **Data-labeling caveat (expert
correction):** the displayed `d_in_pre` is the value captured one master-clock
edge *earlier*, which is **not automatically** the input the CPU sampled at the
current edge; the relevant current input is `D_now` (valid when the monitor
samples before nonblocking updates and the TB does not drive inputs on that
edge). The probe still needs to capture, *together*: the current pre-update CPU
address/RW/input data, the actual advance condition **including reset/stall/wait**,
PC/opcode/state, whether the read is consumed by the instruction, **both
acknowledgement reads and writes**, and a **separate** software character-output
observation. It has not been rebuilt to that standard yet.

**The trace (one `Q` press, baseline protocol) — raw observation, corrected labels:**
```
press → key_ready=1 (vc=51, akd=1)
CPUK kind=C000R D_now=d1 kp=1 rk=0   ← a $C000 read with the ready bit set
CPUK kind=C000R D_now=d1 kp=1 rk=0   ← a second $C000 read (polling)
CPUK kind=C01XW D_now=51 kp=0 rk=1   ← the ACK is a $C01X WRITE → clears the key
```
**The acknowledgement is a `$C01X` write, not a `$C010` read.** Whole-run
CPU-qualified counts confirm it: `cpu_c000_read=203014`, `cpu_c010_read=1`,
`cpu_c01x_write=3`. This BIOS acks the keyboard by *writing* to `$C010-$C01F`;
the machine sets `READ_KEY` on both a `$C010` read and a `$C01X` write (per the
byte-identical source), so the write is the operative ack here.

**What this does and does not show:** it shows two CPU-qualified `$C000` reads
returning the ready bit before a `$C01X`-write ack. It does **not** show two
typed characters — software may legitimately read to test readiness, read to
confirm, ack, and process **one** character, and some bus reads may not be used
as character input at all. Two ready-positive reads followed by an ack is
**compatible with correct operation**, not a duplicate-typing signature.

**Corrected contract (supersedes the old "$C000 clears the key" diagnosis in
[OSK_KEYBOARD_FLOOD.md](OSK_KEYBOARD_FLOOD.md)):** on this IIe, `$C000` reads
data/strobe and does **not** ack; `$C010` acks. A pending key *legitimately*
survives multiple `$C000` reads. The two attempted fixes failed for the reasons
the review predicted: the registered `$C000`-ack cleared *before* the CPU sampled
`K` (nothing), and the combinational page-wide `KEY_READ_C` over-cleared on
unrelated `$C0xx`/`$C1xx` and raced the 6502 sample (nothing).

**Corrected counter note:** the master-clock residency counters
(`c000_reads`/`c010_reads`) count a *held* bus access repeatedly and are **not**
directly comparable to CPU-qualified transaction counts until they are qualified
the same way; do not read a "missing ack" off their ratio.

**Protocol regression (Phase C) — `verilog/tb/tb_kbd_protocol.sv`: PASS (16
checks).** A focused, self-driving bench on the `keyboard` module asserts the
contract, not an exactly-one-read requirement: one press sets ready+code; two
`$C000`-class reads (no `reads` pulse) **retain** the key; a `$C010`-class ack
(one `reads` pulse) **clears** it; polling after the ack stays low; a new key
survives unrelated I/O (no `reads`); the next press is accepted and acked; OSK
close clears a pending key with no fabricated press; reset is clean. Every
failure raises `$fatal` (nonzero exit). **This is a negative result for the
keyboard latch: it behaves per the contract**, so the flood (if it is real) is
**not** a key-latch defect — it must live in software character processing, the
machine decode, or a ready-bit reassertion source. The machine's `$C000`/
`$C010`-write decode is verified separately by the P2a sim (`cpu_c010_read=1`,
`cpu_c01x_write=3` = the acks; the two `$C000` reads are polling, not acks).

**CPU-execution trace + BIOS disassembly (Phase B, software side).** The P2a
probe now logs PC+opcode at each 6502 advance, and `apple2e.hex` (the stock
BIOS) disassembles to a **one-character** handler: `$C28B LDA $C000` (poll),
`$C298 LDA $C000` (fetch), `$C29B STA $C010` (ack). The BIOS does a *poll* then a
*fetch* then an *ack* — **one** character per press. The two `$C000` reads in the
trace are the poll and the fetch (a `BPL` branches to the fetch only when bit 7
is set). So the software does **not** process the character more than once.

**Reassertion trace (Phase D, full `apf_top` wrapper) — the anomaly was a monitor
artifact.** The old wrapper `kp_low` filter could not start (fresh 1→0 reset it
to 0, increment needed >0), so it mis-counted. With the corrected filter + a
`0→1` transition trace logging `cont1_key[4]`/`btn_raw`/`btn_stable`/
`btn_latched`/`kb_v_event`/`kb_v_pressed`/`key_press_cnt`, the full `apf_top`
shows **exactly one** `0→1` (the single initial press) and **no reassertion**:
`key_press_cnt=1`, `key_ready cleared 1×`, wrapper PASS. **The "1→0→1→0
reassertion" that seeded this investigation was a defective-monitor artifact, not
a real hardware event.**

**Net result — the sim is clean at every level; the flood is hardware-only.**
Three independent sim levels all type **one** character per press: the
`keyboard` module (protocol regression), the machine+OSK+BIOS (P2a), and the full
`apf_top` (wrapper). None reproduces the flood or a reassertion. **Therefore the
flood is a hardware-only behaviour that the current sim cannot reproduce.**

**Next step (per the expert, point 4):** obtain **matching hardware evidence on
the restored baseline** — recompile `apple2e_core` from these exact sources
(current provenance below), flash, and capture the on-hardware count row +
key behaviour for one clean tap. Do **not** infer the baseline's hardware
behaviour from the stale Attempt-2 `be707178…` image. If the hardware still
floods on the clean baseline, the divergence is in the **physical** path the sim
abstracts (APF pad/button timing, POC/bridge, or the on-device BIOS timing) and
needs a targeted on-hardware trace, not another source ack change.

**Fresh restored-baseline bitstream (compiled 2026-10-19 15:28, owner):**
`apple2e_core.rbf` sha256 `6fe89807573c2443…` (1,507,028 B) → staged
`bitstream.rbf_r` sha256 `4e15aa12ddad211e…`. Fit: 3,355/18,480 ALMs (18%),
1,980 regs, 56% M10K; worst setup +4.953 (`clk_74a`), worst hold +0.408 — meets
timing, assembles clean. Staged to
`sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r` (output == sd_root, verified).
Capture protocol + interpretation table: [HARDWARE_CAPTURE_CHECKLIST.md](HARDWARE_CAPTURE_CHECKLIST.md).

**What remains unproven (and is the real open question):** whether one physical
tap causes **repeated software character acceptance/output** (a flood), and
where the first demonstrated divergence from the standard protocol is. That
requires instruction/output-level tracing between the reads and the ack (which
instructions do the reads, what happens to the returned values, how many times
software actually accepts/outputs the character), **not** a consume-on-first-read
change in any module. A consume-on-first-read would *still* be read-to-clear
behaviour and would violate the contract, so it is **not** a candidate.

**Next (Phase C, per the recommendation and the expert):** build the
deterministic **protocol regression** — two completed `$C000` reads before the
ack retain the pending key; a proper `$C010` ack clears it; unrelated I/O
(speaker/status/gameport/slot) leaves a pending key unchanged; the next press
works; every failure gives a **nonzero exit**. This test asserts the contract,
**not** an exactly-one-read requirement. Then trace the software between the
reads and the ack. See the open question in
[EXPERT_REVIEW_KEYBOARD_FLOOD_2026-10-19.md](EXPERT_REVIEW_KEYBOARD_FLOOD_2026-10-19.md) §5.

**Baseline provenance (2026-10-19 15:00):**
- git HEAD `3458294` (worktree has the Phase A/B edits uncommitted)
- `machine/apple2.v` sha256 `7033992ef69a826a…` (== MiSTer `rtl/apple2.v`)
- ROMs: `apple2e.hex` `0d840a42e268…`, `keyboard.hex` `0212f9efc951…`,
  `video2.hex` `6ff309a54087…` (all byte-identical to MiSTer)
- build: Verilator 5.050 `--binary --timing`, WDC 65C02 (`cpu=1'b1`),
  CWD `apple2e-pocket/src/fpga` (standalone, local machine + ROMs)
- P2a: `PASS frames=198 rk=56 cpu_kbd_read=203014 c010_reads=14`

## TL;DR (current state — supersedes the older sections below)

**Authoritative state is the "DECISIVE EVIDENCE" section above.** Short version:

- The experimental `KEY_READ_C` fix has been **removed** (Phase A). 
  `machine/apple2.v` is **byte-identical to MiSTer** again; the path is the
  normal registered `READ_KEY` (`$C010` read / `$C01X` write). This is the
  **baseline** the flood reproduces against.
- A **CPU-boundary probe** (Phase B) now samples the 6502 only at its real
  advance edge with pre-edge data. It establishes the **root-cause signature**:
  the ready bit survives **multiple** CPU `$C000` reads before the `$C010` ack
  fires, and the 6502 types on *every* such read (2 in sim, many on hardware
  → the flood).
- **Contract corrected:** `$C000` reads and does **not** ack; `$C010` acks; a
  pending key *legitimately* survives several `$C000` reads. So a one-tap
  → one-character result cannot come from holding the key for one `$C000` read.
- **No third workaround has been added** (per the recommendation). The fix is a
  **mechanism decision** still open for owner/expert review (expert-review doc §5).
- The staged `be707178…` bitstream is the **stale Attempt-2** build and does **not**
  match the current (baseline) sources — recompile before any hardware test.
- Sim is standalone (CWD = `apple2e-pocket/src/fpga`, local machine + ROMs).

> The sections below ("The regression and the (current) fix", "What is currently
> in the tree", the `KEY_READ_C` KFP trace) are **superseded** — they describe the
> now-removed `KEY_READ_C` experiment. They are retained only as the historical
> record of the two failed attempts and the review's L1/L2 reasoning.

## The regression and the (current) fix

### Symptom (owner, hardware)
- Open OSK, tap A → **no character** (nothing entered); the on-hardware key-press
  count row (bottom-left) still ticks on each press.
- So: OSK detects the press (count row), but the machine never types the key.
- This is the opposite of the original **flood** (one tap → many of the same key).

### Why the earlier attempt backfired
The first fix made a `$C000` **read** set `READ_KEY` (ack the key). `READ_KEY` is
a *registered* signal: the poll that sets it still samples `key_ready=1`, and the
clear lands a cycle late. In sim that gives **two** polls reading the key; in
hardware the poll phase collapses the ready window to **zero** → nothing.

### What is currently in the tree (`KEY_READ_C` one-shot)
- `machine/apple2.v`: new combinational output `KEY_READ_C` (module-header port,
  direction, and an `assign`). **This expression is what the review flags (L1).**
- `apple2e_core_top.v`: wires `machine.KEY_READ_C` → `osk.key_read_c`.
- `apple2e_osk.v`: new `key_read_c` input; the keyboard's clear is
  `.reads(reads | key_read_c)`.
- `check_machine_sync.sh`: special-cases `apple2.v` and verifies the Pocket copy
  equals the MiSTer copy **plus exactly** the three `KEY_READ_C` insertions.
- TBs updated to connect the new port: `tb_apf_video.sv`, `tb_p2b_shots.sv`,
  `tb_wrapper_kbd.sv`; build scripts `verilate_apple2e.sh`,
  `verilate_p2b_shots.sh` now compile the **local** `machine/apple2.v`.

Sim evidence (P2a `tb_apf_video` KFP trace, Q press):
```
t=2601438455000 kp=1 D_IN=d1 sel=1  ← exactly ONE poll reads key_ready=1 (0xD1)
t=2601438525000 kp=0 D_IN=51 sel=1  ← cleared on that read
```
So in the *sim* the machine logic yields one keystroke.

## Where the review overrides the current fix (READ THIS)

The owner's review (`REVIEW_RECOMMENDATIONS_2026-10-19.md`, latest section) is
**read-only guidance, not yet implemented**. It supersedes the current approach:

- **L1 (High) — `KEY_READ_C` decodes unrelated addresses.** It compares
  `A[15:8] == 8'hC0 / 8'hC1`, i.e. whole 256-byte **pages**, not the keyboard
  register ranges. Review's read-only eval shows it also pulses for
  `$C019` (VBL status), `$C030` (speaker), `$C061` (game button), and `$C100`
  (slot ROM). ORed into the keyboard `reads`, unrelated I/O/slot accesses can
  clear a pending keystroke.
- **L2 (High) — the `$C000`-clear premise and the cycle timing are wrong.**
  On a real Apple II, `$C000` **reads** keyboard data/strobe; **`$C010` clears
  the strobe**. The combinational ack changes that software-visible contract and
  fires on a 14 MHz address decode **without waiting for the CPU's enabled
  bus-consumption cycle** — so the ready bit can vanish before the 6502 samples
  it. Naming it "same-cycle/one-shot" does not make it safe. The review also
  cautions that the "millions of `$C000` polls vs. a handful of strobe clears"
  ratio, by itself, is **not** proof of a missing acknowledgement.
- **L3 (Medium) — the wrapper test can exit 0 on failure** (`$finish(fail)` is
  not an exit status) and its K1 check does not prove exactly one CPU-consumed
  character.
- **L4 (Medium) — the parity gate / docs were stale** (addressed here: the sync
  checker was updated to the `KEY_READ_C` contract; re-validate after the fix
  changes).

**Net: the `KEY_READ_C` approach should be reworked, not shipped.** The
recommended direction (per L2): preserve normal `$C000`/`$C010` semantics, and
clear the key on a **completed CPU keyboard read** (the bus-consumption
boundary), distinguishing a *held address* from a *completed CPU transaction*.
Trace together: the virtual event, the key latch, the CPU address/data, the CPU
read-enable, and the acknowledgement.

## Sim CWD / standalone (answers the "why Apple-II_MiSTer?" question)

The sim commands historically ran with CWD = `Apple-II_MiSTer` **only because**
the machine ROMs are loaded by CWD-relative `$readmemh`/`rom` paths:
- `machine/apple2.v` → `rom #(8,14,"rtl/roms/apple2e.hex")`
- `machine/keyboard.v` → `rom #(8,11,"rtl/roms/keyboard.hex")`
- `machine/apple2_font_rom.v` / `machine/video_generator.v` → `rtl/roms/video2.hex`

Both `Apple-II_MiSTer/rtl/roms/` and **`apple2e-pocket/src/fpga/rtl/roms/`**
contain those files, so the sim does **not** need the MiSTer tree. **Verified:**
the P2a sim runs and **PASSES** with CWD = `apple2e-pocket/src/fpga` using the
local `machine/` sources + local ROMs:
```
cd /e/MiSTer/Apple-II_FPGAdev/apple2e-pocket/src/fpga
/c/msys64/usr/bin/bash -c 'export PATH=/c/msys64/ucrt64/bin:$PATH; \
  E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/obj_dir_p2a/Vtb_apf_video'
# → PASS: frames=198 ... (summary rk=14, c000_reads=3003284, c010_reads=14)
```
**Next step (recommended):** update the `verilog/README.md` and the
`run_*.bat`/docs to make the Pocket `src/fpga` CWD the documented sim CWD, so the
Pocket repo is self-contained for simulation (no `Apple-II_MiSTer` dependency).

## Current validation state (be precise about what is proven)

| Check | Result | Notes |
|---|---|---|
| P2a `tb_apf_video` (local `machine/` + `KEY_READ_C`) | PASS | one poll reads `key_ready=1` (sim) |
| P1 smoke `tb_apple2e_smoke` (local `machine/apple2.v`) | PASS | |
| Wrapper `tb_wrapper_kbd` | **FAIL on K1 as currently written** | see below |
| Quartus A&S (`quartus_map apple2e_core`) | 0 errors, 225 warnings | `KEY_READ_C` synthesizes |
| Sync checker `check_machine_sync.sh` | OK | `apple2.v` = MiSTer + 3 `KEY_READ_C` lines |
| Sim standalone (CWD = `src/fpga`) | PASS | no MiSTer dependency |

**Wrapper K1 caveat:** K1 counts `key_ready` `1→0` transitions. In the real
wrapper the flag shows **two** clears ~148 ns apart (a `1→0→1→0` blip as the
combinational clear races a re-sampling poll), while the P2a sim shows one. A
glitch-filter attempt (`kp_low==4`) returned **0** (the flag does not stay low 4
cycles), so the "2×" is a real fast re-assertion, not a 1–2 cycle glitch. This is
consistent with the review's L2 (the combinational clear does not align to the
CPU's read). **Do not ship K1 as-is**; per L3 it must (a) `$fatal` on failure,
(b) verify a CPU-visible consumed character, and (c) not be satisfiable by
unrelated strobe activity.

## Files changed in this session (uncommitted)

- `machine/apple2.v` — `KEY_READ_C` port + assign (**flagged by L1/L2**; the
  `$C000` read-ack was reverted, so `READ_KEY` logic is byte-identical to MiSTer
  except this addition).
- `src/fpga/core/apple2e/apple2e_core_top.v` — `m_key_read_c` wire + connections.
- `src/fpga/core/apple2e/apple2e_osk.v` — `key_read_c` input + `.reads(reads | key_read_c)`.
- `check_machine_sync.sh` — `apple2.v` special-case for the `KEY_READ_C` addition.
- `verilog/tb/tb_apf_video.sv` — `KEY_READ_C` wiring + temporary KFP/VEV/KPR traces.
- `verilog/tb/tb_p2b_shots.sv` — `KEY_READ_C` wiring.
- `verilog/tb/tb_wrapper_kbd.sv` — K1 rework (consumption count) — **incomplete**.
- `verilog/verilate_apple2e.sh`, `verilog/verilate_p2b_shots.sh` — local
  `machine/apple2.v` (standalone).
- `docs/OSK_KEYBOARD_FLOOD.md` — "The fix" section updated to `KEY_READ_C`
  (now **outdated** per the review; correct it when reworking).

## Fresh `KEY_READ_C` bitstream (staged 2026-10-19 14:42) — for the hardware datapoint

Owner full-compiled `apple2e_core` at ~14:28. **This image contains the current
`KEY_READ_C` fix (the one the review flags, L1/L2)** — so the hardware result is
a *datapoint*, not a validation of a shipping design.

- Source RBF sha256: `59cb4a556630644ce8ac134830fa7e077120a7c86f17adda5ddcf3450cd16348`
- Staged `.rbf_r` sha256: `be707178cca157e7c5670306f5bea37e23b56ed302d0a2ffa3a36b10b0da7cc2`
- Size: 1,528,916 bytes
- Fit: **Successful** — 3,357 ALMs (18%), 1,958 registers, 217 RAM blocks (70%)
- Timing: worst setup slack **4.660** (`clk_74a`), hold **0.374** — meets
- Assembler: successful (RBF produced)
- A&S (earlier, 11:12): 0 errors, 225 warnings
- Staged to: `output/bitstream.rbf_r` **and** `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r`
  (both hashes verified equal).

**SD copy for the hardware test:**
- Copy `sd_root/Cores/Newsdee.Apple2e/` and `sd_root/Platforms/apple2e.json` to the SD card.
- Boot Pocket → **Computer → Apple IIe**.
- Open OSK with **START**, tap **A** once.
- Expected (per the review, L1/L2): **not a clean one character** — likely "nothing"
  (L1: an unrelated `$C019`/`$C030`/`$C061` read lands in the window and wipes the
  pending key) or "2×" (L2: the combinational clear races the 6502's read). The
  count row should still tick on the tap.

**Interpreting the result:**
- **Nothing** → consistent with L1 (over-broad decode clears on an unrelated read)
  and/or L2 (clear before the CPU samples `K`). → rework per L1/L2.
- **Exactly one** → surprising (would mean the L1/L2 risks didn't bite); still
  rework to remove the over-broad decode and the CPU-cycle misalignment.
- **Two / many** → L2 re-assertion (and possibly L1). → rework per L1/L2.

Either way the next action is the **L1/L2 rework**, then a fresh compile of the
reworked design.

## Next steps (recommended order)

1. **Rework the keyboard ack per review L1/L2** (owner authorization required to
   change RTL):
   - Drop the whole-page `KEY_READ_C` decode; reuse the machine's existing
     address decoder / consume it at the correct bus-consumption boundary.
   - Preserve `$C000` (read) / `$C010` (clear) semantics; clear the key on a
     **completed** CPU keyboard read, not a raw 14 MHz address decode.
   - Trace virtual event + key latch + CPU address/data + CPU read-enable + ack.
2. **Fix the wrapper test (L3):** `$fatal` on failure; assert a CPU-visible
   consumed character; make unrelated strobes unable to satisfy K1; drive real
   OSK command resets and measure their durations/modifier holds.
3. **Make the sim CWD standalone (verified):** document `src/fpga` as the sim CWD
   in `verilog/README.md` + runners; drop the `Apple-II_MiSTer` dependency.
4. **Reconcile parity + docs (L4):** after the rework, make
   `check_machine_sync.sh` enforce the final intended contract; correct
   `OSK_KEYBOARD_FLOOD.md` (remove the `$C000`-clear premise); do **not**
   propagate the incorrect diagnosis into the MiSTer source.
5. **Then** address the still-open original findings: #3 video CDC/reset,
   #4 capture right-edge flush, #6 timing coverage — each with a focused test.
6. **Owner-authorized fresh compile** of `apple2e_core`, inspect warnings +
   timing coverage, convert/restage the `.rbf_r` **from one consistent source
   snapshot**, and run the hardware typing/reset/video tests.

## Do / don't

- **Do** keep the Pocket repo self-contained (local `machine/` + local ROMs).
- **Do** run the narrowest sim first after each RTL edit.
- **Don't** start a full Quartus compile without the owner's permission.
- **Don't** treat the staged `.rbf_r` or earlier sim passes as validating the
  current (uncommitted) sources.
- **Don't** normalize EOLs or churn unrelated files; preserve the mixed-EOL
  files (see `AGENTS.md`).
