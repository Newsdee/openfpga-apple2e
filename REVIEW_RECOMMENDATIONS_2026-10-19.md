# Apple IIe Pocket review and implementation handoff

Initial review: 2026-10-19, approximately 01:27 +08:00  
Latest review: 2026-10-19, approximately 11:11 +08:00  
Scope: build setup, APF packaging, machine integration, video, keyboard/reset,
and validation coverage in `apple2e-pocket`.

## Instructions for the next agent

This document records read-only reviews and their recommendations. The owner
requested this documentation update, not implementation by the reviewing
agent. Obtain authorization before changing RTL, scripts, constraints, or
manifests. Other work has addressed some initial findings; the latest status
below supersedes the original review and implementation order.

Work in this Pocket repository, not a MiSTer sibling. Read the workspace
`AGENTS.md` and this repository's [README](README.md). Preserve existing
uncommitted changes, generated images, and mixed line endings. Do not start a
full Quartus compile without the owner's permission.

Recheck the current sources before acting: the reviewed worktree contained
ongoing P2b OSK work, including modified tracked files and untracked OSK,
keyboard, font-ROM, generator, and test files. Their untracked status is not
permission to discard them.

The findings below distinguish source-level defects from hardware risks.
A successful compile or two-state simulation does not establish safe
clock-domain crossings or external interface timing.

## Latest status: read this section first

The build/package setup and reset wiring have improved, but the newest
keyboard acknowledgement change introduces correctness problems. Do not
treat earlier test passes or the existing bitstream as validation of the
current sources.

### Status of the original findings

| Original finding | Status at latest review |
|---|---|
| 1. Wrong build/staging path | Addressed in source: `apple2e_build.bat` targets the correct revision/package and README distinguishes P0. The reviewer has not executed the new build flow. |
| 2. OSK reset feedback / Apple buttons | Wiring addressed: separate host/PLL-only OSK reset and Apple-button GAMEPORT connections are present. Actual Warm/Cold/Self Test command durations and behavior remain unverified. |
| 3. Video CDC / reset release | Still open: first-stage event detection, separate buffer synchronization, and display reset release are unchanged. |
| 4. Partial pixel word | Still open: capture still skips the first active sample and does not flush the final partial word. |
| 5. Advertised disk loader | Addressed for bring-up: the staged disk-slot list is empty. This is not an implementation of floppy loading. |
| 6. Timing coverage | Still open: two unconstrained clocks, four input ports, 22 output ports, and unmatched constraint filters remain. |
| 7. Test/source alignment | Partially addressed: local machine sources and a wrapper test are now used. Canonical/Q17 coverage, sibling runtime ROM dependency, and the test defects below remain. |
| 8. Keyboard read-strobe direction | Fixed: `reads` is an input; the previous undriven warning is gone. |

### L1. High: new keyboard acknowledgement decodes unrelated addresses

In [machine/apple2.v](machine/apple2.v), `KEY_READ_C` compares `A[15:8]`
against `8'hC0` and `8'hC1`. This selects whole 256-byte pages, not the
keyboard-register ranges described in its comment.

Read-only evaluation of the expression produced:

| Access | KEY_READ_C |
|---|---|
| Read $C000 (keyboard) | 1 |
| Read $C019 (vertical-blank status) | 1 |
| Read $C030 (speaker) | 1 |
| Read $C061 (game button) | 1 |
| Read or write $C100 (slot ROM space) | 1 |

[apple2e_osk.v](src/fpga/core/apple2e/apple2e_osk.v) ORs this signal into
the keyboard's `reads` input. Unrelated I/O/slot accesses can therefore
clear pending keystrokes.

**Recommendation:** establish the correct keyboard acknowledgement contract
first (L2), reuse the existing address decoder, and qualify any strobe at
the appropriate bus-consumption boundary. Do not just change the comparison
width while leaving the protocol problem below intact.

**Acceptance:** unrelated reads and writes must leave the key latch
unchanged. Exercise keyboard, status, speaker, gameport, and slot-ROM
addresses, including accesses while a key is pending.

### L2. High: the $C000-clear premise and clock timing are incorrect

[OSK_KEYBOARD_FLOOD.md](docs/OSK_KEYBOARD_FLOOD.md) states that reading
$C000 acknowledges/clears a key on a real Apple II. That premise is wrong:
$C000 reads keyboard data/strobe; $C010 clears the strobe. See the
[Apple II I/O register reference](https://www.kreativekorp.com/miscpages/a2info/iomemory.shtml).

The new combinational acknowledgement changes that software-visible
contract. It also reaches a keyboard register clocked every 14 MHz cycle,
without waiting for the CPU's enabled bus-consumption cycle. The CPU input
reads K directly, so the ready bit can disappear before the CPU samples it.
This is not made safe merely by naming the signal "same-cycle" or "one-shot".

**Recommendation:**

- Diagnose the flood while preserving normal $C000/$C010 semantics.
- Trace the virtual event, key latch, CPU address/data, CPU enable, and
  acknowledgement together; distinguish a held address from a completed
  CPU transaction.
- Do not infer a missing acknowledgement from millions of idle keyboard
  polls versus a handful of strobe clears. That ratio alone is not a bug.
- Correct the diagnosis document and do not propagate its proposed
  $C000-clear behavior into the MiSTer source.

**Acceptance:** repeated $C000 reads retain a pending key until the proper
acknowledgement; one OSK press is received as one character by software;
idle polling, release, repeated presses, and modifier/reset commands work.
Validate CPU-visible transactions, not just controller-event counts.

### L3. Medium: the wrapper test can fail with a successful process exit

[tb_wrapper_kbd.sv](verilog/tb/tb_wrapper_kbd.sv) ends with `$finish(fail)`.
The argument is not a process exit status. The existing generated Verilator
main returns zero after `$finish`, including the test's failure path.

Its K1 check counts one controller event and requires at least one
`READ_KEY` assertion. It neither proves exactly one CPU-consumed character
nor monitors the new `KEY_READ_C` acknowledgement. Unrelated strobe activity
can satisfy it. The reset tests force the command-reset net; they do not
establish the actual command controller's pulse/hold sequence.

**Recommendation:** use `$fatal` for failure; check CPU-visible keyboard
transactions or entered characters; drive actual OSK reset commands and
measure their durations and modifier holds. Retain the useful structural
Apple-button and reset-separation checks.

**Acceptance:** a deliberately broken acknowledgement or command-reset
implementation must cause a nonzero test exit. Zero accepted characters
and duplicate characters must both fail.

### L4. Medium: the parity gate and documentation are stale

[check_machine_sync.sh](check_machine_sync.sh) permits one specific
two-line `READ_KEY` modification. The current machine instead adds a
`KEY_READ_C` port and expression. Read-only inspection verified that the
Pocket copy is not identical to MiSTer and the expected two-line exception
is absent. Neither permitted case matches, so the current check would fail.

The [README](README.md) still claims byte-identical machine RTL, and the
keyboard diagnosis document describes an older implementation.

**Recommendation:** after resolving L1/L2, accurately document the intended
source relationship and make the parity gate enforce that exact contract.
Do not broaden the exception to ignore arbitrary machine changes. Make
parity and Q17-generation freshness explicit validation gates.

### Latest validation and artifact provenance

- Read-only Verilator lint of the current local QSF source set completed
  with exit 0. It was not warning-clean; 26 undriven warnings remain,
  largely in unused template interfaces. The old OSK `reads` warning is
  gone. No new functional simulation or Quartus compile was run by the
  reviewer.
- Latest mapping report: approximately 02:16. Latest fitting report:
  approximately 02:21, with 3,368 ALMs and 217 RAM blocks (70%).
  Relative to the original review this is +4 ALMs, unchanged RAM blocks.
- The wrapper executable is from approximately 02:06. The current
  machine/OSK sources were edited around 11:02. Earlier reported passes
  do not validate those edits.
- The RBF and assembler report were updated at approximately 10:57,
  but mapping/fitting reports remain from the earlier build. Reassembly
  does not demonstrate fresh synthesis/fitting of changed RTL.
- A byte comparison found that the staged Apple IIe `.rbf_r` does NOT
  equal the bit-reversed current RBF. Equal file sizes do not establish
  identical contents. The staged file is from approximately 02:22.
- The latest sources therefore lack a demonstrated matching test/build/
  staged-image chain. Rebuild and restage from one consistent source
  snapshot after the logic and tests are corrected.

### Revised implementation order, if authorized

1. Resolve L1/L2: correct keyboard semantics, address decode, and CPU-cycle
   timing. Do not propagate the incorrect diagnosis to sibling projects.
2. Fix L3 and validate real character consumption and reset command timing.
3. Reconcile parity, generated-source checks, and documentation (L4).
4. Address original video findings 3/4 and timing finding 6 with their
   focused tests and hardware checks.
5. Run an authorized fresh synthesis/full compile, inspect warnings and
   timing coverage, convert/restage the resulting image, and verify the
   staged bytes. Perform hardware typing/reset/video tests.

## Original review: historical evidence and recommendations

The remaining sections preserve the initial review for traceability. Their
claims about what is unfixed, source parity, artifact equality, resource
counts, and implementation order are historical; use the latest section
above for current status.

### Original evidence and validation limits

- Existing [fitter summary](src/fpga/output_files_apple2e/apple2e_core.fit.summary)
  reports success at 2026-10-19 01:05:04 for revision `apple2e_core`, top
  `apf_top`, device `5CEBA4F23C8`, Quartus 17.0.2 Lite.
- Existing [assembler report](src/fpga/output_files_apple2e/apple2e_core.asm.rpt)
  reports success at 01:05:14.
- Reported utilization: 3,364/18,480 ALMs (18%), 217/308 RAM blocks (70%),
  1,758,236 block-memory bits (56%), and one PLL.
- A read-only byte comparison verified that the staged
  `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r` is the exact per-byte
  bit reversal of `src/fpga/output_files_apple2e/apple2e_core.rbf`.
  This verifies conversion/staging, not that the image implements every
  current worktree edit.
- Local canonical machine RTL matched corresponding
  `../Apple-II_MiSTer/rtl` files. The local `apple2e.hex`, `keyboard.hex`, and
  `video2.hex` ROMs also matched. Generated Q17 variants were not included
  in that canonical byte comparison.
- Read-only Verilator lint of the local QSF's Verilog sources, top
  `core_top`, completed with exit 0 using `--lint-only --timing -sv -Wall
  -Wno-fatal`. APF `common.v` and `mf_datatable.v`, plus the existing PLL
  and RAM simulation stubs, were included as dependencies.
- Lint was NOT warning-clean. It reported width, undriven-net, reset-style,
  and other warnings. Multiple-driver warnings also occur in template
  bridge code and the RAM simulation stub; these were not established as
  new Pocket defects.
- No new Quartus compile, functional simulation, or hardware test was run.
  Do not describe the findings as hardware-reproduced failures.

## 1. High: documented build flow still builds the template

**Evidence:** [README](README.md) recommends [p0_build.bat](p0_build.bat),
but that script compiles `ap_core`, converts `output_files/ap_core.rbf`,
and stages `Cores/Developer.Core Template`. Root manifests are still
template manifests. The actual Apple IIe package is under
[sd_root/Cores/Newsdee.Apple2e](sd_root/Cores/Newsdee.Apple2e).
The script also hardcodes the owner's workspace path.

**Impact:** following the advertised build instructions does not rebuild
or update the Apple IIe package.

**Recommendation:**

- Retain the P0 script as a clearly labelled template regression path.
- Provide/document an Apple IIe flow using revision `apple2e_core`,
  `output_files_apple2e/apple2e_core.rbf`, and the Apple IIe destination.
- Choose one authoritative set of Apple IIe manifests and stage from it;
  do not accidentally copy the root template metadata over the real core.
- Derive paths from the script location and quote paths.
- Check each conversion/copy operation's result; avoid success messages
  after a failed staging step.

**Acceptance:** with permission for a build, demonstrate that the documented
command builds the correct revision, updates only the intended package,
includes the required manifests, and produces the exact bit-reversed RBF.
Retain a usable template regression path.

## 2. High: OSK reset feeds back into its own command controller

**Evidence:** in
[apple2e_core_top.v](src/fpga/core/apple2e/apple2e_core_top.v),
`machine_reset` includes `osk_cmd_reset`, and the OSK's `.reset` receives
`machine_reset`. In
[virtual_keyboard_controller.sv](machine/osk/virtual_keyboard_controller.sv),
`start_selected_command` loads a reset counter, but the controller's reset
branch clears that counter, the command, and Apple modifier state.
The default intended reset length is 1,024 clocks.

**Impact:** assertion of the command reset causes the controller to clear
itself on the next machine clock, reducing the intended reset pulse to one
clock and cancelling the subsequent modifier-hold sequence.

There is a second integration defect:
[apple2e_osk.v](src/fpga/core/apple2e/apple2e_osk.v) leaves the keyboard's
`open_apple` and `closed_apple` outputs disconnected, while the machine
`GAMEPORT` input is tied to zero. Cold Reset and Self Test cannot convey
their intended Apple-button combinations to the ROM.

**Recommendation:**

- Separate host/power-on reset of the OSK controller from an OSK-requested
  machine reset. Do not clear the pulse generator with its own output.
- Determine the appropriate reset policy separately for the keyboard
  translator, overlay, machine, and command controller.
- Wire Apple-button state into the correct machine `GAMEPORT` bits using
  the existing machine interface definition and MiSTer integration as
  reference. Do not guess the bit positions.
- Preserve the command's modifier-hold interval after machine reset.

**Acceptance:** test through the actual Pocket wrapper. Check reset pulse
length, command completion, held modifier values as observed by the
machine, and distinct Warm Reset/Cold Reset/Self Test behavior. Also test
host reset and power-on reset for regressions.

## 3. Medium: frame-switch CDC and display reset need hardware-safe treatment

**Evidence:** in [apf_video.v](src/fpga/core/apple2e/apf_video.v), the
nominal three-stage `wb_syn` chain detects a change with
`wb_syn[0] ^ wb_syn[1]`; its third stage is unused. Functional logic thus
consumes the first synchronizer stage. A separate `wbuf_s1/wbuf_s2` chain
supplies the buffer-select value.

**Impact:** this is a first-stage fanout/reconvergence reliability risk,
not proof that the previously reported duplicate-screen glitch remains.
Ordinary Verilator tests cannot reproduce metastability.

Display registers also use `machine_reset`, which is released in the
machine clock domain, as an asynchronous reset without a local
display-clock reset-release synchronizer.

**Recommendation:**

- Synchronize the buffer-toggle event through one appropriately staged
  chain; derive event detection and the corresponding buffer selection
  from consistent, fully synchronized state.
- Do not use the first synchronizer stage for functional decisions.
- Give the display domain an asynchronously asserted, locally
  synchronously released reset as appropriate for the design.
- Preserve the intended completed-frame ownership and frame-start timing;
  do not merely add arbitrary delays until one simulation passes.

**Acceptance:** assert buffer ownership during active reads, exercise
varying relative clock phase and host/OSK reset timing, inspect Quartus
synchronizer recognition and recovery/removal coverage, and perform
hardware resets and extended video testing.

## 4. Medium: capture does not flush the final partial pixel word

**Evidence:** the capture block in
[apf_video.v](src/fpga/core/apple2e/apf_video.v) uses the HBL-falling clock
to initialize state instead of capturing a sample. With the documented
560-clock active interval, that leaves 559 captured samples. Pixel RAM
writes occur only on complete eight-pixel words; line end does not flush
the remaining seven samples. `cap_ram` still advertises the captured
sample count.

**Impact:** the scaler can address unwritten/stale pixels at the right
edge. The exact displayed symptom has not been hardware-verified.

**Recommendation:** define explicitly whether the first active sample is
included, and make the advertised line length agree with pixels actually
written. Capture the full intended line and/or correctly flush partial
words. Preserve synchronous RAM inference and bit ordering.

**Acceptance:** drive known patterns into the first and last eight
samples, check capture count and every readable sample, and exercise both
frame buffers. Include partial-word cases if variable lengths remain
supported. Recheck inferred memory resources after synthesis.

## 5. Medium: disk manifest advertises an unimplemented loader

**Evidence:** the staged [data.json](sd_root/Cores/Newsdee.Apple2e/data.json)
offers `.nib` at `0x02000000` with `size_exact: 143360`.
That is the usual sector-image size; a conventional 35-track NIB image
is 232,960 bytes (35 x 6,656).

The bridge decoder in
[apple2e_core_top.v](src/fpga/core/apple2e/apple2e_core_top.v) implements
no loader at that address. Slot requests are acknowledged as successful
without corresponding disk loading/controller integration.

**Impact:** a valid NIB can be rejected by the metadata, or loading can
appear successful while having no effect.

**Recommendation:** for the current bring-up milestone, stop advertising
a usable disk slot unless intentionally exposed as an explicitly labelled
development placeholder. If implementing floppy support is authorized,
agree on the image contract and implement the data path and meaningful
request acknowledgements before exposing it as working.

**Acceptance:** verify the size contract with representative files,
observe data reaching the intended memory, and boot a disk. Test invalid
sizes and failed transfers. Floppy support being absent is documented;
do not expand this review fix into an unsolicited floppy implementation.

## 6. Medium: timing success has significant coverage gaps

**Evidence:** the existing
[TimeQuest report](src/fpga/output_files_apple2e/apple2e_core.sta.rpt)
lists two unconstrained clocks (`audgen_mclk` and
`aud_mclk_divider[1]`), four unconstrained input ports, and 22
unconstrained output ports, including the scaler video interface.

[apf_constraints.sdc](src/fpga/apf/apf_constraints.sdc) still reads the
template [core_constraints.sdc](src/fpga/core/core_constraints.sdc).
The Apple IIe QSF additionally loads
[apple2e_core_constraints.sdc](src/fpga/core/apple2e/apple2e_core_constraints.sdc).
TimeQuest reports unmatched template PLL paths. The unused fourth
Apple IIe PLL output also has an unmatched clock filter.

**Recommendation:**

- Separate the template and Apple IIe constraint-loading paths without
  breaking P0 or blindly editing vendor/template APF files.
- Review each asynchronous group against the actual clock relationship
  and CDC implementation. The video 0-degree and 90-degree clocks are
  intentionally related; do not assume every PLL output is asynchronous.
- Address the fabric-generated audio clock strategy/constraints.
- Establish external interface timing requirements from the APF contract;
  do not invent delay values or suppress paths just to remove warnings.
- Document intentional exclusions separately from missing constraints.

**Acceptance:** inspect clocks, ignored SDC commands, unconstrained-path
reports, external I/O timing, and reset recovery/removal after an
authorized compile. Positive slack on constrained paths alone is not
complete timing closure. Some gaps are inherited from the template, not
new defects introduced by P2b.

## 7. Medium: test coverage does not match the claimed integration scope

**Evidence:** [tb_apf_video.sv](verilog/tb/tb_apf_video.sv) instantiates the
machine, OSK, RAM, and adapter separately. Its `k_cmd_rst` is not connected
to machine reset, so it cannot catch finding 2. The P2b description in
[verilog/README.md](verilog/README.md) overstates this as testing the full
`apple2e_core_top`.

[verilate_p2a.sh](verilog/verilate_p2a.sh) and
[verilate_apple2e.sh](verilog/verilate_apple2e.sh) use sibling MiSTer RTL
and canonical OSK files. Quartus uses local machine copies and generated
Q17 OSK variants. Current canonical parity does not guarantee future
parity or establish Q17 behavioral equivalence.

**Recommendation:**

- Keep focused component tests, but identify them accurately.
- Exercise reset and Apple-button integration through the actual wrapper.
- Test local sources and local ROMs for the self-contained Pocket build.
- Validate generated Q17 variants with the same functional checks as their
  canonical counterparts, or add a focused equivalence check.
- Run the existing sync/generated-file freshness checks as explicit gates.
- Review blanket suppression of undriven, width, and latch warnings;
  classify known warnings rather than hiding correctness-sensitive ones.

**Acceptance:** demonstrate that a deliberate reset-wiring regression
would fail a test, that a stale generated variant is rejected, and that
the Pocket validation path does not silently depend on different sibling
sources or ROMs.

## 8. Lower priority: keyboard read-strobe direction is incorrect

**Evidence:** [apple2e_osk.v](src/fpga/core/apple2e/apple2e_osk.v) declares
`reads` as an output, although the machine drives it and the internal
keyboard consumes it as an input. Verilator reports it as undriven.

**Recommendation:** correct the port contract to an input and inspect
all instances and tests.

**Acceptance:** confirm that the CPU's keyboard-read strobe clears the
key latch, ordinary typing remains correct, and the specific undriven
warning disappears. Do not claim this declaration alone explains an
observed hardware typing failure: net collapsing may allow the current
wiring to function.

## Original implementation order (superseded by latest status above)

1. Correct/document the Apple IIe build and staging path.
2. Fix the keyboard port contract and OSK reset/Apple-button integration,
   with wrapper-level regression tests.
3. Fix capture completeness and strengthen video CDC/reset handling with
   focused pattern and phase/reset tests.
4. Reconcile the staged disk metadata with the current milestone.
5. Align simulation sources, Q17 validation, and documentation.
6. Review constraints and run an owner-authorized Quartus compile, then
   hardware validation.

Do not bundle unrelated cleanup into these changes. For each fix, record
the owning clock domain, reset semantics, intended cycle behavior, exact
test result, known/new warnings, and remaining hardware-only checks.
RAM-block use is already 70%; check memory inference and packing when
altering video storage or adding peripherals.
