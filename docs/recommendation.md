# Recommendation: investigate the Pocket OSK flood without changing its protocol

Date: 2026-10-19, approximately 14:48 +08:00  
Project: `apple2e-pocket`  
Audience: the agent continuing the keyboard investigation

## Purpose and authority

This is an investigation handoff, not an implemented fix. The owner requested
this document. Obtain authorization before implementing the proposed RTL or
test changes, and before running a full Quartus compile.

Read the workspace `AGENTS.md`, the project [README](../README.md), and
[the expert-review request](EXPERT_REVIEW_KEYBOARD_FLOOD_2026-10-19.md).
Preserve unrelated uncommitted work, generated images, media, and mixed
line endings. Work in Pocket; do not change the tagged MiSTer video pipeline
or propagate experimental keyboard changes into MiSTer.

The original hardware flood is **not yet root-caused**. The two attempted
acknowledgement changes reportedly produce no character on hardware.
Do not introduce a third workaround before obtaining decisive evidence.

## Executive recommendation

1. Establish a protocol-correct, reproducible diagnostic baseline.
2. Repair the monitors so they measure actual CPU transactions and keyboard
   latch events.
3. Test the keyboard protocol independently of BIOS behaviour.
4. Explain the reported ready-bit reassertion using a complete state trace.
5. Validate the actual wrapper and generated Q17 implementation.
6. If simulation still differs from hardware, capture the same events on
   hardware and fix the first demonstrated divergence.

Do not claim completion from controller-event counts, a passing boot smoke
test, or an RBF that was merely reassembled from an older fitted design.

## 1. Non-negotiable keyboard contract

- `$C000` reads the keyboard data/strobe. It does **not** acknowledge the key.
- `$C010` is the keyboard strobe-clear address.
- Preserve the existing IIe `$C01x` write acknowledgement behaviour unless a
  separately justified compatibility correction is required.
- Unrelated status, speaker, gameport, and slot-ROM accesses must not clear
  a pending key.
- A pending key can legitimately survive multiple `$C000` reads.
- One OSK tap producing one software-entered character does not imply that
  exactly one `$C000` read may observe bit 7 set.

Reference: [Apple II I/O register map](https://www.kreativekorp.com/miscpages/a2info/iomemory.shtml).

The current experimental `KEY_READ_C` in
[machine/apple2.v](../machine/apple2.v) violates this contract: its upper-byte
comparisons select whole `$C0xx` and `$C1xx` pages, and it adds clearing on
keyboard polling itself. Narrowing the comparisons alone is not a fix.

The phrase "clear on the completed CPU keyboard read" in the expert request
must be made precise:

- Completed `$C000` read: retain the key.
- Acknowledgement-register access: perform the defined clear.

Do not add an OSK-only "consume on first poll" mechanism to mask the fault.

## 2. Correct the interpretation of the existing evidence

### Raw read counters are master-clock residency counters

In [tb_apf_video.sv](../verilog/tb/tb_apf_video.sv), `c000_reads` and
`c010_reads` increment on every 14 MHz edge while the relevant address is
selected. They are not CPU-enable qualified.

Therefore `c010_reads = 14` could represent roughly one held CPU bus access,
not 14 independent acknowledgements. Millions of polling samples versus a
small number of strobe-clear samples do not establish a missing BIOS ack.
Include acknowledgement writes in any new accounting.

### D_IN briefly showing a key does not prove CPU acceptance

The reported trace shows `D_IN = D1` and a ready-bit clear separated by a
master-clock interval. It does not identify a CPU sampling edge. A key can
appear on that combinational bus and vanish without being consumed.

Simulation **can** establish logical CPU-cycle timing when the actual
sampling edge and pre-edge data are observed. It cannot establish physical
FPGA timing safety or metastability behaviour.

### The on-screen counter is upstream of latch acceptance

In [apple2e_osk.v](../src/fpga/core/apple2e/apple2e_osk.v),
`key_press_cnt` counts a controller event toggle with `kb_v_pressed`.
It does not count keyboard-latch acceptance or CPU-entered characters.

A single count supports correct controller event generation. It does not
prove that the keyboard latch accepted exactly once, and does not isolate
the failure entirely to the machine.

### The wrapper's current low-duration counter cannot start

In [tb_wrapper_kbd.sv](../verilog/tb/tb_wrapper_kbd.sv):

- `kp_low` is initialized to zero.
- The falling-edge condition assigns zero.
- Incrementing requires `kp_low > 0`.

It cannot reach four, so its zero consumption count is a monitor defect.
Do not treat that result as hardware evidence. Do not merely repair this
filter and retain ready-bit falling edges as the definition of consumption.

Also inspect the final verdict: `$finish(fail)` does not give the simulator
a failing process exit. Use a failure mechanism such as `$fatal`.

## 3. What comparison with MiSTer actually establishes

The reviewed canonical Pocket keyboard and OSK-controller sources matched
their MiSTer counterparts. MiSTer's
[keyboard instance](../../Apple-II_MiSTer/rtl/apple2_top.v) also uses the
virtual-key interface and `.reads(read_key)`.

The adjacent `joy_to_key` feature is a separate input path, not a special
OSK acknowledgement mechanism.

Relevant differences to control when comparing:

- MiSTer builds with `JOY_TO_KEY`; Pocket currently does not.
- Surrounding reset and input integration differ.
- Pocket synthesis uses generated Q17 OSK variants, whereas simulation
  has used canonical sources.
- Board-level clock/reset behaviour and the exact loaded image matter.

Do not describe these differences as causes without evidence. Source parity
does not certify current MiSTer hardware behaviour. A same-program,
same-key-sequence MiSTer hardware test is useful corroboration if available,
but is not a prerequisite for the deterministic protocol test below.

## 4. Phase A: establish a controlled baseline

With authorization:

1. Remove the experimental acknowledgement path from the diagnostic
   baseline, restoring the normal machine-to-keyboard `READ_KEY` path.
   Account for the added port and all affected wrapper/test connections.
   This is a baseline for investigation, not a claim that the flood is fixed.
2. Preserve the valid OSK host-reset separation, Apple-button connections,
   and corrected `reads` input direction.
3. Record source revision/worktree snapshot, source and ROM hashes, build
   macros, CPU selection, Quartus revision, and the staged bitstream hash.
4. Keep the known failing image identifiable. Do not overwrite unrelated
   user artifacts or use broad resets/checkouts to obtain the baseline.

**Exit criterion:** the implementation under test and the exact acknowledgement
contract are unambiguous, reproducible, and independent of the broken
`KEY_READ_C` experiment.

## 5. Phase B: instrument the actual CPU boundary

For the selected WDC CPU, the execution block in
[cpu_65c02.sv](../machine/cpu/wdc65c02/cpu_65c02.sv) advances under:

```text
ce && !stall && rdy && !in_stp
```

The machine supplies `ce` from `CPU_EN`, derived from its registered phase
transition and `machine_ce`. Inspect the active CPU and reset conditions;
do not substitute a similarly named phase signal without establishing its
cycle relationship.

Maintain two distinct observation streams:

### CPU transaction stream

At actual CPU sampling/advance edges, record:

- CPU PC/state or opcode context where available.
- Address, read/write, and pre-edge CPU input data.
- `CPU_EN`, reset, stall/wait state, and selected CPU.
- Whether this is a keyboard-data read, acknowledgement read/write, or
  unrelated I/O transaction.

Do not sample newly launched post-edge address/data and label it as the
transaction just consumed. Use explicit testbench sampling discipline to
avoid races with nonblocking assignments.

### Keyboard state stream

At machine-clock resolution, capture:

- `virtual_active` and its delayed copy.
- `virtual_event`, `old_virtual_event`, `virtual_pressed`, and code.
- `key_pressed`, `virtual_data`, latched code, `akd`.
- Keyboard FSM state and repeat timer.
- Reset and the actual keyboard `reads` input.
- Controller event count separately from latch-accept count.

The existing `READ_KEY` implementation is not necessarily a one-master-clock
pulse: it can be assigned high repeatedly while the acknowledgement address
remains selected. Distinguish asserted cycles, assertion edges, completed
acknowledgement transactions, and actual latch clears.

**Exit criterion:** a short trace can explain exactly when a virtual event
was accepted, what the CPU sampled, and what cleared or reasserted the latch.

## 6. Phase C: deterministic protocol regression

Use a small controlled CPU program or bus-level test before drawing
conclusions from BIOS boot. Include an actual-CPU test to validate timing.

| Test | Required result |
|---|---|
| One virtual press | Keyboard accepts the intended code and sets ready. |
| Two completed `$C000` reads before ack | Both observe the pending key; polling does not clear it. |
| Proper acknowledgement access | Ready clears according to the register contract. |
| Poll after ack | Ready remains low until another legitimate input event. |
| Speaker/status/gameport/slot accesses with pending key | Pending key is preserved. |
| Second physical press | A second key can be accepted and acknowledged. |
| Press near acknowledgement / varying CPU phase | Deterministic, documented event priority; no accidental duplicate or premature loss. |
| OSK close/open and host reset | No stale or fabricated press; intended reset behaviour preserved. |

Check key data as well as ready state. For simultaneous press/ack cases,
inspect existing assignment priority and preserve intended behaviour rather
than inventing a new queueing policy.

Then add a BIOS-level test that proves exactly one character is entered for
one tap. Do not equate each ready-positive poll with a character. Observe a
well-defined software output event or a controlled screen/cursor change,
excluding boot redraws and unrelated writes.

Every failed requirement must produce a nonzero test exit. Demonstrate that
a deliberately broken early-clear path and duplicate-event path are detected.

## 7. Phase D: explain the ready-bit reassertion

The reported `1 -> 0 -> 1 -> 0` sequence is a useful lead, not something to
filter away.

With Pocket's current non-`JOY_TO_KEY` build and stable `virtual_active`,
[keyboard.v](../machine/keyboard.v) sets `key_pressed` through acceptance of
a virtual press event. The `reads` path only clears it. Acknowledgement
alone cannot cause the subsequent rise.

For each actual low-to-high transition, identify the responsible set path:

- Accepted virtual press event.
- PS/2 FSM key-ready state after leaving the virtual path.
- Repeat-timer path outside the virtual-active branch.
- Joy injection, if the build configuration enables it.

Correlate with reset, mode transitions, event-history state, and simultaneous
assignments. Remember that later nonblocking assignments in the same
sequential block can override earlier ones on that edge.

If no legal set path explains a rise, investigate the observer's scheduling,
testbench force/release operations, source/build mismatch, or synthesis
implementation. Do not declare metastability or a compiler bug by exclusion
without first checking those concrete possibilities.

**Exit criterion:** every observed reassertion has a demonstrated cause, or a
minimal reproducible trace identifies the precise remaining contradiction.

## 8. Phase E: align simulation and hardware evidence

- Use the actual Pocket wrapper, local machine sources, and local ROMs.
- Exercise the generated Q17 controller/overlay variants with the same
  focused tests, or establish their relevant behavioural equivalence.
- Validate generated-file freshness and accurately enforce the intended
  Pocket/MiSTer source relationship.
- Repair documentation that still asserts `$C000` clears the key.
- Preserve meaningful warnings; separate known template/stub warnings from
  new correctness-sensitive warnings.

If simulation still does not reproduce the protocol-correct baseline's
hardware flood, use a small SignalTap capture or targeted diagnostic trace
triggered on the first virtual press. Capture the same CPU/latch events as
the simulation. RAM blocks are already around 70% used; keep instrumentation
bounded and inspect its resource/timing impact.

| First observed divergence | Investigation target |
|---|---|
| CPU never samples ready high | Event acceptance, premature clearing, data/sample timing. |
| CPU samples ready but no acknowledgement follows | CPU/ROM execution and software path; trace PC and transactions. |
| CPU accesses ack but latch stays high | Decode, wiring, or sequential assignment priority. |
| Latch clears then rises again | Event history, active-mode transition, repeat path, reset. |
| Latch remains clear but the display fills | CPU-visible data, execution, or display interpretation; not automatically a key-latch fault. |

A fresh assembly alone is insufficient. With owner approval, synthesize and
fit the relevant source snapshot, inspect reports, assemble, convert, and
verify that the staged `.rbf_r` equals the per-byte bit reversal of that RBF.
Record the tested image hash with each hardware observation.

## Completion criteria and scope

The task is complete only when:

1. The original failure has an evidence-backed explanation.
2. The correction preserves `$C000`/`$C010` behaviour and unrelated I/O.
3. Focused tests fail for the original defect and pass for the correction.
4. Actual-wrapper and Q17-relevant validation are complete.
5. An identified hardware image types one character per tap without the
   flood or blackout, including repeated presses and reset/modifier checks.
6. Documentation, source-parity checks, warnings, and build provenance agree.

Keep experimental corrections Pocket-local. Only consider a shared MiSTer
change after proving a shared defect and running the applicable regression
tests. Do not broaden this keyboard task into unrelated video, floppy, or
timing cleanup; track those existing review findings separately.
