# Expert review request — Apple IIe Pocket: OSK key-flood / no-key regression

Prepared: 2026-10-19 ~15:00 +08:00. Repo: `E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket`
(GitHub `Newsdee/openfpga-apple2e`, branch `main`). Owner: **Newsdee**.

This is a **request for expert review**, not a set of implemented fixes. It
records the full state, the evidence, and the specific questions I need answered
before changing more RTL. Companion docs: `OSK_KEYBOARD_FLOOD.md` (the diagnosis
that needs correcting), `KEYBOARD_FIX_HANDOFF_2026-10-19.md` (working state),
`REVIEW_RECOMMENDATIONS_2026-10-19.md` (the owner's read-only review, L1–L4).

> **CURRENT STATUS — 2026-10-19 15:00 +08:00:** Protocol-correct source baseline
> restored. Staged Attempt-2 bitstream is historical and does **not** match these
> sources. CPU-read tracing has improved, but **duplicate character processing and
> the hardware flood's root cause remain unproven.** Do **not** implement
> consume-on-`$C000`; next step is instruction/output-level tracing and the
> deterministic protocol regression.

---

## 0. TL;DR

The Apple IIe Pocket core has a virtual on-screen keyboard (OSK). When a key is
fired, the machine should type **exactly one** character. It does not:

- **Original** (`READ_KEY` ack only on `$C010` read / `$C01X` write, byte-identical
  to the proven MiSTer core): one tap **floods** the screen with many copies of
  the same key.
- **Attempt 1** (a `$C000` read also sets `READ_KEY`): one tap → **nothing**.
- **Attempt 2** (combinational `KEY_READ_C` strobe, page-wide decode): one tap →
  **nothing** (confirmed on hardware just now).

The on-hardware key-press **count row ticks on every tap**, so the OSK→keyboard
latch is working (the key *is* latched). The failure is entirely in the
**machine read/acknowledge path**.

I have **not** been able to reproduce the flood in simulation: the P2a sim shows
the key typed cleanly (one poll reads `key_ready=1`). The review's L2 says the
sim cannot establish the real CPU-cycle timing. I need an expert to pin the
**root cause** before more RTL changes.

---

## 1. Background: the keyboard path

```
APF buttons (cont1_key, 32-bit, APF domain)
   │  apple2e_osk.v: 3-stage sync → debounce → press-latch (release-confirm)
   ▼
virtual_keyboard_controller.sv  (machine domain, 14.318 MHz)
   │  virtual_event / virtual_pressed / virtual_code  (one toggle per press,
   │  one per release;  virtual_key_down state)
   ▼
keyboard.v  (machine domain)
   │  latches key:  key_pressed=1, virtual_data=1, virtual_code_latched=code
   │  K = {key_pressed, virtual_code_latched}        (bit 7 = "key ready")
   │  cleared when  reads=1  (== machine READ_KEY)
   ▼
apple2.v  (the machine)
   │  $C000-$C00F read  → returns K, does NOT set READ_KEY   (KEYBOARD_SELECT)
   │  $C010 read        → sets READ_KEY (A[3:0]==0)          (C01X_SELECT)
   │  $C01X write       → sets READ_KEY
   │  READ_KEY (registered, 1-cycle pulse) → back to keyboard.reads
   ▼
6502 (65C02)  →  BIOS (apple2e.hex)  →  types the key
```

Key facts (verified):
- `K[7]` = `key_pressed` = "key ready". The BIOS types a key when it reads a
  `$C000` with bit 7 set (verified: a `$C000` read returning `0xD1` types `Q`).
- The **only** things that clear `key_pressed` are: `reads` (== `READ_KEY`), the
  OSK closing, and reset. The **only** things that set `READ_KEY` are the `$C010`
  read and the `$C01X` write (in the byte-identical baseline).
- `READ_KEY` is a **registered** 1-cycle pulse.

---

## 2. What I measured (P2a sim, `tb_apf_video`, local machine sources)

These numbers are from the **sim** (two-state, fast CPU). They do **not**
reproduce the hardware flood/blackout.

- `c000_reads ≈ 3,003,284` — the BIOS polls `$C000` essentially constantly.
- `c010_reads = 14` — the BIOS reads `$C010` only 14 times over the whole run.
- KFP trace, one `Q` virtual press:
  ```
  t=2601434045000 kp=1 D_IN=0a vd=1 vc=51   ← press: key_ready=1, code=Q
  t=2601438455000 kp=1 D_IN=d1 sel=1        ← ONE $C000 poll reads 0xD1 (ready)
  t=2601438525000 kp=0 D_IN=51 sel=1        ← cleared
  ```
- So in the sim, the key is latched, **one** poll reads it, and it is cleared.
  **No flood, no blackout.** This is why the sim passed while hardware failed.

The **wrapper** test (real `apf_top`) shows the ready flag going `1→0→1→0`
(~148 ns apart) — a re-assertion the P2a sim does not show. I could not trace
what re-asserts it (the virtual-event trace showed a single press).

---

## 3. The three builds and their hardware results

| Build | Ack mechanism | Sim | Hardware (one A tap) |
|---|---|---|---|
| Baseline (MiSTer-identical) | `READ_KEY` on `$C010` read / `$C01X` write only | clean (no flood) | **FLOOD** (many of the same key) |
| Attempt 1 | + `$C000` read sets `READ_KEY` | clean | **Nothing** |
| Attempt 2 | combinational `KEY_READ_C` (page-wide) OR'd into `reads` | clean (1 poll) | **Nothing** (confirmed now) |

Common to all: the **count row ticks** (OSK→latch works). So the divergence is
the machine read/ack path, not the OSK.

---

## 4. What the owner's review (L1/L2) says, and where I agree/disagree

- **L1 (High):** `KEY_READ_C` decodes `A[15:8]==8'hC0/8'hC1` = **whole 256-byte
  pages**, so it also fires for `$C019` (VBL), `$C030` (speaker), `$C061`
  (game), `$C100` (slot ROM). Unrelated I/O can clear a pending key. — **I agree;**
  the decode must be the exact keyboard registers (the machine already has
  `KEYBOARD_SELECT` / `C01X_SELECT` for that).
- **L2 (High):** reading `$C000` does **not** clear the strobe (on a real II,
  `$C010` clears it); the combinational ack fires on a 14 MHz address decode
  **without waiting for the CPU's completed read**, so the ready bit can vanish
  before the 6502 samples `K`. — **I agree this is a real risk**, and it is the
  likely reason both attempts give "nothing" on hardware.

**My uncertainty (the crux):** if `$C000` must *not* clear the key, and the
baseline (only `$C010` clears) **floods** on hardware, then *what* is supposed
to clear the key so a single tap types once? The baseline's `$C010`-only ack is
what floods. So either:
  (a) the BIOS is expected to read `$C010` to ack and it isn't (then why does
      the proven core not flood?), or
  (b) the key is *not* meant to be held across many `$C000` polls in this core's
      OSK, and the OSK/key-latch needs a one-shot consume that the machine's
      `$C010`-only ack does not provide.

I do **not** know which is correct, and I do not want to keep guessing.

---

## 5. The central open question (updated per expert review)

**What causes one virtual press to be processed repeatedly, and where is the
first demonstrated divergence from the standard keyboard protocol?**

A consume-on-first-read change (in *any* module) is **not** a candidate: it is
still read-to-clear behaviour and would break the `$C000`-reads / `$C010`-acks
contract, and no general mechanism both guarantees one ready-positive read *and*
holds the strobe until `$C010`.

Sub-questions (to be answered by instruction/output-level tracing + the protocol
regression, not by an exactly-one-read requirement):

1. Does the proven MiSTer core's OSK actually type exactly one character per tap?
   (It uses the **same** `apple2.v`, `keyboard.v`, controller, and **byte-identical**
   ROMs. If it works, what differs — its key path, its OSK integration
   (`apple2_top.v`'s `joy_to_key` + `keyboard`, not the Pocket's `apple2e_osk.v`),
   reset/integration, or the loaded image?)
2. Between the observed `$C000` reads and the `$C010` ack, **which instructions**
   perform the reads, **what happens to the returned values**, and **how many
   times** does software actually accept/output the character?
3. Does the reported flood involve **repeated acknowledgement cycles, a
   persistent ready bit, or ready-bit reassertion**? (Separate normal polling
   from duplicate processing.)
4. Where is the first demonstrated divergence from the standard protocol — in
   event handling, the keyboard latch, CPU execution, or elsewhere?
5. Should any fix port back to `Apple-II_MiSTer/rtl/apple2.v`, or stay Pocket-only
   with a documented `check_machine_sync.sh` exception? (The owner's review says
   do **not** propagate a wrong `$C000`-clear to the MiSTer source.)

---

## 6. What to do next (updated per expert review — plan, not done)

1. **Correct the handoff's conclusion** (done above): keep the raw trace; remove
   the unsupported "each read types Q" annotations; the duplicate-character
   processing and the hardware flood's cause **remain unproven**.
2. **Complete the deterministic protocol regression** (the contract test in
   `recommendation.md`): two completed `$C000` reads before the ack **retain** the
   pending key; a proper `$C010` ack **clears** it; unrelated I/O (speaker/status/
   gameport/slot) leaves a pending key **unchanged**; the next press works; every
   failure gives a **nonzero exit**. This asserts the contract — **not** an
   exactly-one-read requirement.
3. **Trace the software** between the reads and the ack: which instructions do
   the reads, what happens to the returned values, how many times software
   accepts/outputs the character, and whether the flood is repeated acks / a
   persistent ready bit / reassertion.
4. **Improve the CPU-boundary probe** to capture, together: current pre-update
   CPU address/RW/input, the advance condition including reset/stall/wait,
   PC/opcode/state, whether the read is consumed, both ack reads **and** writes,
   and a **separate** software character-output observation.
5. **Obtain matching hardware evidence** on the restored baseline (clear source +
   image provenance); do not infer the baseline's hardware behaviour from the
   Attempt-2 image.
6. Then — and only if the evidence shows a real defect — a fresh owner-authorized
   compile of `apple2e_core`, convert/restage the `.rbf_r` from one consistent
   snapshot, and the hardware typing test.

---

## 7. Current code state (updated 2026-10-19 15:00 — uncommitted)

- `machine/apple2.v`: **byte-identical to MiSTer** (the `KEY_READ_C` experiment
  was fully removed in Phase A). The machine-to-keyboard path is the normal
  registered `READ_KEY` (`$C010` read / `$C01X` write).
- `apple2e_core_top.v` / `apple2e_osk.v`: no `key_read_c`; the OSK keyboard's
  clear is `.reads(reads)` (the machine `READ_KEY`) again. The valid OSK
  host-reset separation, Apple-button GAMEPORT wiring, and `reads` direction are
  preserved.
- `check_machine_sync.sh`: standard byte-identity check (no special-case).
- `verilog/tb/tb_apf_video.sv`: CPU-boundary probe added (Phase B); P2a PASSes
  on the baseline (`rk=56`).
- **Staged `be707178…` bitstream = the STALE Attempt-2 build** (does not match
  these sources).
- TBs (`tb_apf_video.sv`, `tb_p2b_shots.sv`, `tb_wrapper_kbd.sv`) connect the
  new port; `verilate_apple2e.sh` / `verilate_p2b_shots.sh` compile the local
  `machine/` sources.
- **Staged bitstream** (`be707178…`, `sd_root/Cores/Newsdee.Apple2e/`) = Attempt 2
  → hardware-confirmed **nothing**.

### Validation state (be precise)
- P2a sim: PASS (but does **not** reproduce the hardware flood/blackout).
- Wrapper test: **K1 unreliable** (counts a fast `1→0→1→0` as 2; a glitch filter
  returned 0). Per L3 it must be reworked.
- Quartus A&S: 0 errors, 225 warnings. Last full compile: 3,357 ALMs (18%),
  setup slack 4.660 — meets.
- **Sim is now standalone** (CWD = `apple2e-pocket/src/fpga`, local machine
  sources + local ROMs, no `Apple-II_MiSTer` dependency) — verified PASS.

---

## 8. Constraints / ground rules

- Quartus Prime Lite 17.0.2, device `5CEBA4F23C8`; the **owner** runs full
  compiles; I may run short `quartus_map`.
- Preserve mixed EOLs; keep `machine/` in sync via `check_machine_sync.sh`.
- Do **not** propagate an unproven `$C000`-clear into the MiSTer source.
- RAM is at 70%; be careful with any new memory.

**Bottom line:** I need the root cause of "why does a held OSK key flood in this
core but (reportedly) not in the proven core, and what is the correct,
CPU-cycle-safe acknowledgement that yields exactly one character per tap."
Everything else follows from that answer.
