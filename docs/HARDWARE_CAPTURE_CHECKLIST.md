# Hardware capture checklist — restored baseline (2026-10-19)

Purpose: the sim is clean at all three levels (keyboard-latch protocol,
machine+OSK+BIOS, full `apf_top` wrapper) and **cannot reproduce the reported
flood**. This captures the **hardware** evidence the sim can't see, on the
restored baseline, so the expert can tell us where the physical divergence is.

## Provenance (record the exact image you flash)

| field | value |
|---|---|
| git HEAD | `3458294` |
| `machine/apple2.v` sha256 | `7033992ef69a826a3e8ce715bc760423551a6059545e6723ea351f94cf7a651d` (= MiSTer, byte-identical) |
| `apple2e.hex` sha256 | `0d840a42e268c578…` (stock BIOS, unchanged) |
| `keyboard.hex` sha256 | `0212f9efc95117c0…` |
| source RBF sha256 | `6fe89807573c2443bef3786a281355fa031ba4ddb3ae4395a8aafbafcfe4de83` (1,507,028 B) |
| staged `.rbf_r` sha256 | `4e15aa12ddad211ec2528556deb73807e2e25835829304ab6ec50cc18f71d5e0` |
| fit / timing | 3,355/18,480 ALMs (18%), 1,980 regs, 56% M10K; worst setup +4.953 (clk_74a), worst hold +0.408 |

This is **not** the stale Attempt-2 `be707178…` image (that one contains the
removed `KEY_READ_C` experiment and must not be used to infer baseline
behaviour).

## Setup

1. `apple2e_build.bat` (compile → convert → stage) or the manual
   `apple2e_build.bat`-equivalent you are running.
2. Copy the SD image to the Pocket; boot the Apple IIe core.
3. Wait for the Apple logo (P2a exit) — the machine is up and idle.

## Test — one clean tap

1. **START** (`face_start`) → the OSK panel opens.
   - [ ] panel appears? (y/n)
2. Let it idle ~1 s (no buttons).
   - [ ] idle: no characters appearing? (y/n)
3. **One single tap** of **face-A** (fire) — press and release cleanly, then
   wait.
   - [ ] how many characters appeared? (count, or "many/flood" / "1" / "0")
4. Read the **on-hardware count row** (panel bottom, `key_press_cnt`):
   - [ ] **how many blocks lit in the left 8-block row?** (0 / 1 / 2 / …)
   - [ ] is the **MANY** bar (right side) lit? (y/n)
5. Read the **debug button strip** (panel bottom, the 2-px button blocks):
   - [ ] is the **fire** button block lit once, then off? (or does it stay / re-lit?)
6. Do **one more tap** of face-A.
   - [ ] second tap: how many characters? (count)
   - [ ] did the count row increment by 1 (or more) between taps?

## Interpretation

| observation | means |
|---|---|
| count row = **1 block**, MANY bar off, **many** characters typed | button side is **clean** (one event); the flood is **downstream** (machine decode / on-device BIOS timing) — the sim-clean path. Needs a targeted on-hardware trace. |
| count row = **many blocks** / MANY bar lit, many characters | the **button / debounce / latch** side is re-firing (the OSK sees multiple events) — upstream. |
| count row = **1 block**, **exactly one** character | baseline is **clean** on hardware — the flood is not reproduced on this image; compare provenance carefully. |
| count row = **0**, no characters | the key isn't reaching the machine — check the OSK open state / the count-row gating (it's only drawn while OSK active). |

## What to send back

- The filled-in checklist above.
- The two sha256s (source RBF + staged `.rbf_r`) + the fit/timing lines.
- A photo of the screen after one tap (count row + debug strip visible) if
  possible — the earlier photo didn't show the count row clearly.

Do **not** implement any source ack change based on this; the expert's next
step is a **targeted on-hardware trace** of the physical path the sim abstracts.
