# OSK keyboard flood — diagnosis, root cause, fix

Status: **root cause found; fix identified; pending implementation + hardware verification.**
Last updated: 2026-10-19.

This document is the resume point for the "one A-tap floods the screen with the
selected key" hardware bug. Read top to bottom; the fix is at the end.

## Symptom (hardware)

- Pocket, P2b OSK build (press-latch + on-hardware count diagnostic).
- Open the OSK (START), tap **A** (fire) once → the text screen floods with
  the selected key (Q) — "whole rows / the whole screen".
- The typing **keeps going as long as the OSK is open**; it stops immediately
  when the OSK is closed (START again).
- DPad, L (panel position), SELECT (transparency) all work.
- Only the fire/A key does this.

## Diagnosis timeline (what was ruled out)

1. **Button / CDC / latch = CLEAN.** The on-hardware key-press counter
   (panel bottom-margin count row) showed **exactly 1 block lit, static**
   after one A-tap. That is **one** virtual key-press event. So the button,
   the 3-stage CDC synchronizer, the press-latch, and the OSK controller are
   all producing exactly one event per tap. The flood is **not** a button or
   controller problem.
2. Therefore the single key is being **read over and over** by the CPU —
   it is **not being acknowledged**. This is the machine's key-acknowledge
   path, and it is **hardware-specific** (the sim does not flood).

## Root cause

In this core's address decode (`machine/apple2.v`), the keyboard
acknowledge `READ_KEY` (which clears the key) is generated **only** on:

- a **`$C010` read** (`C01X_SELECT & we==0 & A[3:0]==0`), and
- a **`$C01X` write** (`C01X_SELECT & we==1`).

A **`$C000` read** (`KEYBOARD_SELECT & we==0`) returns the key (`K`) but does
**not** set `READ_KEY`. On a real Apple II, reading the keyboard register
(`$C000`) acknowledges/clears the key — this core is missing that.

**Sim probe (decisive):** the BIOS polls the keyboard almost exclusively via
`$C000`:

```
summary: ... rk=56 ... c000_reads=2848426 c010_reads=14
```

- `c000_reads = 2,848,426` — the CPU reads `$C000` constantly (its main poll).
- `c010_reads = 14` — `$C010` is read almost never.

So in the **sim**, the key only gets acked by the 14 stray `$C010`/`$C01X`
accesses (a timing coincidence) → one visible character, no flood. On
**hardware**, that coincidence does not line up, so the key is never acked →
the CPU's `$C000` poll re-reads the same key forever → the screen floods.
Closing the OSK clears `key_pressed` (the OSK-close path in `keyboard.v`),
which is why the flood stops when the OSK is closed.

`KEYBOARD_SELECT` = `$C000-$C00F` (`A[7:4]==0`); `C01X_SELECT` =
`$C010-$C01F` (`A[7:4]==1`). They are mutually exclusive.

## Why the sim never caught it (lesson)

- The P2b sim check **G6a counts *controller* key-press events**
  (`q_press_cnt` = `kb_v_event` rising edges with code `Q`), **not machine
  reads**. A clean fire = 1 controller event, so G6a passes even when the
  machine re-reads that one event forever. The sim's flood is also masked
  because the 14 stray `$C010` accesses ack the key.
- **Lesson:** a "one press = one key" check must count **machine
  acknowledgements** (`READ_KEY` pulses that clear the key) or actual
  characters entered, **not** controller events. Controller-event counting
  cannot see a re-read bug.

## The fix (final: `KEY_READ_C` one-shot ack)

> **Superseded approach:** the first attempt made a `$C000` *read* set
> `READ_KEY` (ack the key). That flipped the flood into a total blackout:
> `READ_KEY` is a *registered* signal, so the poll that sets it still samples
> `key_ready=1`, and the clear lands a cycle late. In sim that yields two
> polls reading the key (two Qs); in hardware the poll phase collapses the
> ready window to zero → **nothing**.

**Root of the residual bug:** the BIOS polls `$C000` every ~70 ns, but
`key_ready` (bit 7 of the data bus) is only held for a couple of machine cycles
before the registered `READ_KEY` clear arrives. A poll either sees it (→ typed,
maybe twice) or misses it entirely (→ nothing), depending on phase. The ack must
therefore land on the **same machine cycle** as the consuming read.

**The fix:** add a **combinational** key-read strobe `KEY_READ_C` to the
machine that pulses on the exact cycle the CPU reads/writes the keyboard
registers (`$C000` read, `$C010` read, `$C01X` write), and feed it to the OSK
keyboard as an *extra* clear of the virtual key's ready flag. Clearing on the
combinational read (not the 2-cycle-late `READ_KEY`) means the single poll that
reads `key_ready=1` is the poll that clears it → exactly one keystroke.

`machine/apple2.v` (combinational, no `always` block → no new state):

```verilog
assign KEY_READ_C = (A[15:8] == 8'hC0 & !we)        // $C000 read
                  | (A[15:8] == 8'hC1 & we)         // $C01X write
                  | (A[15:8] == 8'hC1 & !we & A[3:0] == 4'h0); // $C010 read
```

`apple2e_osk.v` passes it to the keyboard as an OR with the existing `reads`
(`.reads(reads | key_read_c)`), so the registered `READ_KEY` path is preserved
for the proven PS/2/joy behavior and the combinational one-shot handles the
virtual key. `apple2e_core_top.v` wires `machine.KEY_READ_C` → `osk.key_read_c`.

### Byte-identity decision (resolved: Option B)

`machine/apple2.v` diverges from `Apple-II_MiSTer/rtl/apple2.v` by **only** the
`KEY_READ_C` addition (module-header port + direction + the combinational
assign). The original `$C000` read-ack was reverted, so `READ_KEY` logic is
byte-identical to MiSTer. `check_machine_sync.sh` special-cases `apple2.v` and
verifies the pocket copy equals the MiSTer copy **plus exactly** those three
`KEY_READ_C` insertions (any other drift fails the check). The MiSTer project
is left untouched.

## Verify before / after the fix

Sim (run from `Apple-II_MiSTer` CWD):

```sh
cd /e/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog && bash verilate_p2a.sh
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer
/c/msys64/usr/bin/bash -c 'export PATH=/c/msys64/ucrt64/bin:$PATH; E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/obj_dir_p2a/Vtb_apf_video'
```

- Expect `PASS: frames=198 ...` with `G6a`/`G6b`/`G6c`/`G6d` green.
- The sim will still pass *without* the fix (the 14 stray `$C010` acks mask
  it), so the sim is a **regression** check, not a proof of the fix.
- After the fix, `rk=` (READ_KEY pulses) should rise noticeably (the `$C000`
  poll now acks) — use that as the sim-visible confirmation that the `$C000`
  read path now generates acknowledgements.
- The `c000_reads`/`c010_reads` probe (added to `verilog/tb/tb_apf_video.sv`)
  documents the polling split; keep it for now, remove before the final
  commit.

Then: Quartus A&S (`quartus_map Apple-II`-equivalent for `apple2e_core`),
owner full compile, restage the `.rbf_r`, and **hardware test**: open OSK, tap
A once → expect exactly one character, no flood, count row = 1.

## Files touched in this session (diagnostic, not the fix)

- `src/fpga/core/apple2e/apple2e_osk.v` — on-hardware key-press counter
  (`key_press_cnt`) + panel count row (diagnostic).
- `verilog/tb/tb_apf_video.sv` — `c000_reads`/`c010_reads` probe + summary line.

## Resolution (bundled keyboard fix + wrapper test)

The flood fix was implemented and, per the owner's direction, bundled with the
keyboard/reset integration findings from `REVIEW_RECOMMENDATIONS_2026-10-19.md`
and covered by a wrapper-level regression test.

**Fixes (all in the Pocket core):**
1. **Flood fix** — `machine/apple2.v`: a `$C000` keyboard read now sets `READ_KEY`
   (the read-ack), so the BIOS's constant `$C000` poll acknowledges a key instead
   of re-reading it forever. This is the one intentional divergence from the
   MiSTer source (2 lines); `check_machine_sync.sh` verifies it is the ONLY diff.
2. **Finding 8** — `src/fpga/core/apple2e/apple2e_osk.v`: `reads` is now an INPUT
   to the OSK (the machine drives the read strobe, not the OSK); the dangling
   `open_apple`/`closed_apple` OSK outputs are now routed out of the OSK module.
3. **Finding 2** — `src/fpga/core/apple2e/apple2e_core_top.v`: the OSK is reset
   by the host/POC reset only (`osk_reset = ~rst_sync[1] | ~lock_sync[1]`), NOT
   by the OSK's own command reset (the OSK survives a command reset; the machine
   still resets via `machine_reset = osk_reset | osk_cmd_reset`). The Apple-button
   state is wired from the OSK to the machine `GAMEPORT[1]`/`[2]` (the MiSTer bit
   map), so the machine can see the virtual Apple keys.

**Sim now builds the Pocket sources (finding 7):** `verilate_p2a.sh`,
`verilate_apple2e.sh`, and the new `verilate_wrapper.sh` all compile
`apple2e-pocket/machine/*` (what Quartus builds), not the sibling MiSTer `rtl/`.
`check_machine_sync.sh` proves those are the machine core + the one intended fix.

**Wrapper-level regression test** (`verilog/tb/tb_wrapper_kbd.sv`, build
verilate_wrapper.sh`, run with CWD = `Apple-II_MiSTer`): instantiates the real
`apf_top` wrapper, issues Reset Exit over the real bridge SPI, drives `cont1_key`
(sim-only override), and verifies through the actual wrapper:
- K1 one OSK fire = one key-press event AND the machine consumes it
  (`key_ready` clears after the fire - the one-shot `KEY_READ_C` ack).
- A1/A2/A0 Open-/Closed-Apple reach `GAMEPORT[1]`/`[2]` (forced + every-cycle).
- R1/R1b/R2/R3 reset separation: `osk_reset` = host reset only; a forced
  `osk_cmd_reset` resets the machine but NOT the OSK.

**Validation (all PASS, local machine sources + `KEY_READ_C` one-shot fix):**
- P2a `tb_apf_video` KFP trace: the virtual press latches `key_ready=1` and
  exactly **one** `$C000` poll reads `D_IN=0xD1` (key ready) before the
  combinational `KEY_READ_C` clears it on that same read - one keystroke.
  (The superseded `$C000` read-ack gave two polls in sim / zero in hardware.)
- `tb_wrapper_kbd`: PASS (K1, A1/A2/A0, R1/R1b/R2/R3).
- P1 smoke `tb_apple2e_smoke`: PASS (full machine + APF wrapper).
- Quartus A&S: `0 errors, 225 warnings` (the `KEY_READ_C` port synthesizes).

**Remaining (owner):** full compile of `apple2e_core`, restage the `.rbf_r`, and
the decisive hardware test: open OSK, tap A once -> exactly one character, no
flood, count row = 1. The on-hardware count row / debug strip are still in the
build as hardware diagnostics; remove or gate them before the final commit.
