# Coding-agent recommendation: prototype native RGB streaming to Pocket

Date: 2026-10-19, approximately 16:14 +08:00  
Project: `apple2e-pocket`  
Reference: `agg23/openfpga-NES`, commit
`be5f1303a0df15d012155cb248b6174bb81e64b6`

## Decision summary

**Prototype direct RGB streaming before implementing PSRAM or a larger
framebuffer.**

The inspected NES Pocket core sends native-style RGB video through a small
APF adapter without a full-frame pixel buffer in that path. It demonstrates
that the current Apple IIe adapter's 320x240 active / 400x512 total raster
at 12.288 MHz is not a universal Pocket requirement.

It does **not** establish that the proposed Apple II 560x192 active raster
at approximately 14.312 MHz is supported. Verify the APF contract and test
that raster before committing to the architecture.

This document is a recommendation, not implementation authorization.
The owner requested the handoff; no RTL changes or hardware tests were
performed by the reviewing agent. Obtain approval before implementation
and before a full Quartus compile.

## 1. Read these local documents first

- [Colour decision request](COLOR_PIPELINE_DECISION_2026-10-19.md).
- [MiSTer/Pocket colour handover](MISTER_POCKET_COLOR_HANDOVER_2026-10-19.md).
- The project [README](../README.md) and workspace `AGENTS.md`.

The memory arithmetic corrections in the MiSTer/Pocket handover remain
valid. This NES evidence changes the next action: investigate streaming
first, rather than assuming a full RGB framebuffer is necessary.

Keep keyboard behaviour and unrelated MiSTer video RTL untouched.
Preserve the current working Pocket adapter, canonical OSK sources, user
changes, generated images, and mixed line endings.

## 2. Verified NES evidence

All links below are pinned to the inspected commit.

| Source | Relevant evidence |
|---|---|
| [Pocket core wrapper](https://github.com/agg23/openfpga-NES/blob/be5f1303a0df15d012155cb248b6174bb81e64b6/target/pocket/core_top.v) | Receives RGB888 and native blanking/sync from the NES implementation, registers pixels on the video clock, derives DE from blanking, and creates APF sync pulses. |
| [Video PLL](https://github.com/agg23/openfpga-NES/blob/be5f1303a0df15d012155cb248b6174bb81e64b6/target/pocket/mf_pllbase/mf_pllbase_0002.v) | Produces 5.369312 MHz video clocks with normal and approximately 90-degree phase; PPU clock is 21.477248 MHz. |
| [NES integration](https://github.com/agg23/openfpga-NES/blob/be5f1303a0df15d012155cb248b6174bb81e64b6/rtl/nes_top.sv) | Connects NES colour/timing to the RGB renderer and exposes RGB plus sync/blanking to the wrapper. |
| [Video renderer](https://github.com/agg23/openfpga-NES/blob/be5f1303a0df15d012155cb248b6174bb81e64b6/rtl/upstream/video.sv) | Generates RGB from palette/emphasis and native-style counters with pipeline registers, rather than storing a full rendered frame. |
| [Video manifest](https://github.com/agg23/openfpga-NES/blob/be5f1303a0df15d012155cb248b6174bb81e64b6/pkg/pocket/Cores/agg23.NES/video.json) | Advertises 256x240 and 256x224 input modes with different aspect ratios. |
| [Timing constraints](https://github.com/agg23/openfpga-NES/blob/be5f1303a0df15d012155cb248b6174bb81e64b6/target/pocket/core_constraints.sdc) | Shows NES-specific clock-group and timing treatment; it is reference material, not a drop-in constraint set. |

The traced path is:

```text
NES colour + native timing
  -> palette/emphasis RGB conversion
  -> RGB registers
  -> APF sync/blanking adapter
  -> Pocket scaler
```

External memory elsewhere in the NES core is not evidence of a video
framebuffer. No full-frame pixel store was found in the traced rendering
and output path.

## 3. Proposed Apple II path

```text
Apple II native video/timing
  -> monochrome RGB initially; native/composite colour decoder later
  -> full-colour OSK compositing at native coordinates
  -> thin APF timing/output adapter
  -> Pocket scaler
```

Potential benefits:

- No two-frame RGB888 allocation in M10K.
- No PSRAM video controller if direct streaming is supported.
- OSK retains its native-width geometry rather than being moved to a
  320-pixel coordinate system.
- Existing integer transparency blending can remain RGB888 end to end.
- Future composite RGB need not be quantized into an interim palette.

These are architectural opportunities, not yet measured results.
Composite decoding may still need line history, logic, and DSP resources.
Removing a frame adapter does not mean all video buffering disappears.

## 4. Phase 0: verify the platform contract

Before changing the working pipeline, establish from official APF
documentation and suitable references:

1. Supported active dimensions, total raster constraints, frame rate, and
   pixel-clock range for a proposed 560x192 Apple II stream.
2. Forwarded-clock phase and DDR interface requirements, including legal
   Quartus PLL settings for the chosen clock.
3. Required HS/VS pulse widths, separation, DE relationship and blanking.
4. Manifest scaler dimensions and aspect-ratio configuration.
5. Whether Pocket and dock impose relevant differences.

Distinguish active pixels from total clocks/lines and aspect ratio.
Do not resize or retime the Apple II machine itself just to fit an assumed
APF raster without explicit agreement and behavioural validation.

**Exit gate:** a documented candidate raster/clock/manifest contract, with
unresolved limits called out rather than assumed.

## 5. Phase 1: isolated streaming pattern prototype

With owner approval, create a separately selectable experimental build
using the project's existing conventions. Do not replace the working path
or silently overwrite its known-good package.

- Produce RGB colour bars, black/white, single-pixel alternating patterns,
  edge markers, and line/frame identifiers at the proposed geometry.
- Use a valid video clock and phase-shifted forwarded clock.
- Implement only the required APF output formatting.
- Keep output pixel data and timing registered/aligned as required.
- Make reset assertion/release safe in every involved clock domain.
- Use one scaler mode initially unless additional modes are required.

Do not blindly copy the NES wrapper:

- It sends scaler-mode metadata in a blanking slot after DE.
- Its pulse scheduling and pipeline delays are NES-specific.
- Its SDC groups and multicycle constraints describe its own design.

Understand metadata rules before adopting them. For a simple no-metadata
prototype, follow the confirmed APF blanking-data contract; do not mistake
another core's defined metadata transfer for arbitrary blanking RGB.

**Simulation gate:** verify exact active dimensions, pixel count, colour
values, sync pulse behaviour, DE alignment, frame cadence and reset recovery.

**Hardware gate:** with an owner-run compile, verify stable capture, all
edges visible, correct aspect ratio, no colour-channel errors, fine-pattern
integrity, and stable operation on Pocket and dock where available.

## 6. Phase 2: native monochrome plus full-colour OSK

Only after the pattern transport works:

- Feed the actual machine video as RGB black/white.
- Retain the OSK's full RGB output instead of collapsing it to one bit.
- Preserve native OSK coordinates and font-ROM timing.
- Carry corresponding blanking/sync through the same pixel latency.
- Keep any retained diagnostic strips explicitly defined in RGB; do not
  silently discard or reinterpret them during the interface change.
- Preserve the canonical `machine/osk` source relationship and validate
  the actual source set used by Quartus, not only the simulation copies.

Test all transparency settings over both black and white, badges,
highlights, glyphs, top/bottom positions, and OSK open/close transitions.
Check that displayed key input remains functional without changing its
keyboard protocol.

An old buffer-ownership G5 check is not proof for a streaming architecture.
Keep it for the fallback path and add assertions appropriate to the new
timing/pixel contract.

## 7. Phase 3: composite colour

Once native streaming and OSK rendering are stable:

- Use MiSTer's [video_pipeline.sv](../../Apple-II_MiSTer/rtl/video/video_pipeline.sv)
  as the renderer reference. Its interface uses `CLK_14M`, `reset` and
  `machine_ce`, and outputs RGB888 plus `HS`, `VS`, `HBL_O` and `VBL_O`.
  Inspect its dependencies and drive every control input deliberately;
  the interface is not just a monochrome-to-RGB conversion.
- Integrate the selected native/composite RGB processing path.
- Preserve its sample phase, sync/blanking delays, colour controls, and
  any line-history requirements.
- Feed the selected RGB and its matching timing into OSK composition.
- Measure inference, RAM blocks, ALMs/DSPs and timing before widening scope.

Do not assume the MiSTer renderer fits or binds unchanged in Quartus 17.
Do not modify the MiSTer source merely to make the Pocket experiment compile.

## 8. Fallback decision

If APF cannot accept the proposed stream:

1. Identify the exact failing limit.
2. Determine whether a supported raster and small line-buffered conversion
   can meet it while preserving machine timing and image quality.
3. If complete arbitrary-RGB frame storage is genuinely required, prototype
   external memory with burst scheduling, display deadline guarantees,
   bounded line buffers, reset handling, CDC and interface constraints.

Do not return to option B's incorrect calculation. The current 8-bit RAM
word holds eight monochrome pixels. Two tightly packed native RGB888
frames require 5,160,960 bits, exceeding the device's entire block-memory
capacity before machine RAM/ROMs.

Exact indexed storage remains a possible OSK-over-monochrome interim
solution, not a general substitute for arbitrary composite RGB.

## 9. Completion and handover evidence

Record:

- Chosen APF contract and the evidence supporting it.
- Exact changed files and build/manifest selection.
- Clock/reset/domain relationships and pixel pipeline latency.
- Simulation checks and hardware observations, separately.
- Quartus version/revision, resource deltas and timing coverage.
- New warnings versus known warnings; no blanket suppression of functional
  issues.
- Source/ROM provenance and the hash of the exact staged image tested.
- Remaining platform limits and the preserved fallback procedure.

**Recommended next action:** verify the Apple II raster against the APF
contract, then run the isolated streaming-pattern experiment. Do not spend
the next implementation cycle on a PSRAM framebuffer before answering
whether that framebuffer is needed at all.
