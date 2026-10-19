# MiSTer versus Pocket colour pipeline: findings and recommendations

Date: 2026-10-19  
Scope: explain the actual MiSTer video path and inform the Pocket colour
architecture decision. Read-only source/report review; no RTL was changed,
and no new synthesis, simulation, or hardware test was run.

Companion: [Pocket colour decision request](COLOR_PIPELINE_DECISION_2026-10-19.md).
This summary corrects that document's framebuffer arithmetic and its claim
that MiSTer has no framebuffer or scaling.

## Executive conclusion

MiSTer does not need a native RGB frame stored in the Apple II core's M10Ks
to produce coloured video and a transparent OSK. It generates and composites
RGB as a stream. Its common HDMI framework then performs scaling/frame
buffering using external DDR3.

Pocket currently converts the native stream through a core-local,
double-buffered M10K adapter before delivering video to APF. Expanding that
buffer to RGB888 is the expensive part, not generating RGB or blending the
OSK itself.

**Do not implement option B as costed in the decision request.** Its memory
calculation treats a packed eight-pixel word as though it were one pixel.
First verify whether Pocket can use a supported streaming raster that avoids
this particular full-frame adapter. If a full RGB framebuffer remains a
requirement, plan external memory rather than assuming it fits in M10K.

## 1. What MiSTer actually does

The inspected source-of-truth is `Apple-II_MiSTer`, not the deprecated sibling.
Paths below are relative to this document.

```text
Apple II native video and timing
    |
    v
video_pipeline
  native RGB renderer OR composite encode/decode
  selects matching RGB, sync and blanking
    |
    v
drive-status overlay
    |
    v
virtual-keyboard overlay
  RGB888 foreground/background blending
    |
    v
video_mixer
  gamma and optional scandoubling/HQ2x
    |
    +--> direct analogue-video path where configured
    |
    v
MiSTer common HDMI scaler (ascal)
  external DDR3 framebuffer
    |
    v
configured HDMI raster
```

### Native colour generation and OSK are streaming stages

- [apple2_top.v](../../Apple-II_MiSTer/rtl/apple2_top.v) instantiates
  `video_pipeline` and passes its RGB and matching timing to the wrapper.
- [video_pipeline.sv](../../Apple-II_MiSTer/rtl/video/video_pipeline.sv)
  processes native or composite-decoded video in the machine-video clock
  domain. It outputs three 8-bit colour channels plus sync/blanking.
- [Apple-II.sv](../../Apple-II_MiSTer/Apple-II.sv) connects core RGB through
  `drive_status_overlay`, then `virtual_keyboard_overlay`, whose RGB output
  goes into `video_mixer`.
- The OSK and its font ROM run from `clk_sys`, the machine clock. The mixer
  runs from `CLK_VIDEO` with pixel-enable timing. This is not one arbitrary
  asynchronous clock shared by every stage.
- [video_mixer.sv](../../Apple-II_MiSTer/sys/video_mixer.sv) accepts full
  8-bit channels with the default `HALF_DEPTH=0`. It supports gamma and
  optional scan doubling/HQ2x; it does not allocate the Pocket-style native
  double RGB framebuffer.

RGB888 here is a pixel-bus format, not a declaration that every frame must
reside in on-chip RAM. Filters and scan doubling may require local history
or line storage; that is different from two complete RGB frames.

### The HDMI framebuffer exists outside the Apple II machine renderer

In [sys_top.v](../../Apple-II_MiSTer/sys/sys_top.v):

- `ascal` receives RGB, pixel enable, sync and data enable on its input side.
- It produces the separately configured HDMI timing on `clk_hdmi`.
- Its Avalon memory port is 128 bits wide and connects to `vbuf_*`.
- `sysmem_lite` connects those signals to the interface explicitly labelled
  "128-bit DDR3 RAM access / HDMI frame buffer".
- The scaler configuration reserves 8 MiB by default, or 2 MiB when
  `MISTER_SMALL_VBUF` is selected.

Thus "MiSTer has no framebuffer because it does no scaling" is incorrect
for the overall HDMI path. The useful distinction is **streaming core
rendering plus shared external-memory scaling**, versus **Pocket's current
core-local M10K frame adaptation**.

Do not copy MiSTer's scaler or memory subsystem as if it were a Pocket
drop-in. The platform interfaces and infrastructure differ.

## 2. Why the current Pocket path costs more M10K

[apf_video.v](../src/fpga/core/apple2e/apf_video.v) captures native samples
in the machine domain, then reads a completed buffer from the APF video
clock domain. It maps 560 samples to 320 output columns and centres 192
lines within the current 240-line active window.

The adapter therefore owns storage and scheduling that MiSTer largely
delegates to its common display framework.

Today the Pocket OSK already computes RGB888, but
[apple2e_osk.v](../src/fpga/core/apple2e/apple2e_osk.v) collapses it to one
bit before this buffer. Colour is lost at that explicit conversion, not
because the OSK renderer cannot generate colour.

## 3. Correct memory budget

The current `pix_ram[0:65535]` has eight bits per word. Each word contains
**eight separate monochrome pixels**.

The inspected 15:28 fitter report allocates the entire pixel RAM:

- 524,288 logical bits.
- 64 RAM blocks.
- Whole design: 217 of 308 blocks, 1,758,236 logical memory bits.
- Non-pixel allocation: 153 blocks.
- Replacement pixel-store budget: at most 155 blocks before any additional
  features, line buffers, or controller overhead.

Two native active frames contain `2 * 560 * 192 = 215,040` pixels:

| Format | Tightly packed native active frames | Existing padded eight-pixel-word layout |
|---|---:|---:|
| 1 bit/pixel | 215,040 bits | 524,288 bits |
| 4 bits/pixel | 860,160 bits | 2,097,152 bits |
| 8 bits/pixel | 1,720,320 bits | 4,194,304 bits |
| RGB888 | 5,160,960 bits | 12,582,912 bits |

Changing an eight-monochrome-pixel word to 24 bits does not store eight
RGB888 pixels. Those require 192 bits per word, or a different one-pixel
addressing scheme with correspondingly more addresses.

Even tightly packed native RGB888 exceeds the device's entire 3,153,920-bit
block-memory capacity. Double-buffered RGB888 at 320 x 192 still needs
2,949,120 bits before the rest of the machine, so pre-scaling alone does
not make RGB888 fit.

Use actual inferred RAM-block counts and legal port geometries for budgeting.
The currently unused address combinations were not optimized out.

## 4. Architecture decision order

### First investigate: can APF accept a suitable streaming raster?

The 400 x 512 total / 320 x 240 active raster is the current implementation,
not proof of an immutable APF platform requirement.

Before committing to an external framebuffer, verify the official APF
contract and suitable reference implementations for:

- Supported pixel-clock range and phase requirements.
- Active dimensions, sync/blanking and scaler configuration.
- Whether a native-width RGB stream at an appropriate clock can be accepted.
- Frame-rate requirements and tolerance of the chosen native raster.
- Pocket and dock behaviour.

If supported, a streaming native RGB + OSK path into the platform scaler
could avoid the current full-frame conversion. If only a line-buffered
conversion is needed, prove producer/consumer scheduling and reset recovery.
Neither approach is established by this review; do not assume support or
delete the working adapter without a focused prototype.

### If a full arbitrary-RGB framebuffer is required: external memory

Use RGB888 for rendering/compositing interfaces and prototype PSRAM (or
another supported external-memory path) for storage. This is conceptually
closer to MiSTer's external-memory scaling than enlarging on-chip RAM.

Validate sustained and worst-case service latency, burst efficiency,
line-buffer depth, concurrent read/write scheduling, frame ownership, reset,
CDC, and interface timing. A reference core proves feasibility of its own
configuration, not the deadline guarantees of this pipeline.

### If the immediate scope is only OSK colour over monochrome

An exact indexed representation may be a smaller interim solution:

- The canonical overlay selects from 24 foreground constants.
- Four transparency settings blend over two background values, black/white.
- An upper bound is `24 * 4 * 2 + 2 = 194` output RGB values.
- An 8-bit index can therefore preserve these colours and integer blend
  results exactly; this is not a nearest-colour 16-entry palette.
- Compact double-buffered 320 x 192 x 8-bit storage needs 983,040 bits before
  padding and overhead, subject to synthesis and future peripheral budgets.

This route requires scaling before frame storage, exact LUT/encoder
validation, and preserving native overlay geometry. It is not a general
solution for arbitrary composite-decoder RGB values.

Live OSK composition after storage is another possible memory-saving
architecture. However, the current overlay has a 552-pixel native layout
and many fixed coordinates. Merely moving it to a 320-pixel raster would
crop/distort it. It needs deliberate coordinate handling, font latency
alignment, and coherent transfer of OSK state.

## 5. Handover actions and acceptance criteria

1. Correct the colour decision document using the allocation and arithmetic
   above. Remove claims that option B fits and that MiSTer does not scale.
2. Separate RGB processing format, storage format, and display raster as
   three design decisions. Define the immediate and future requirements.
3. Verify whether APF supports a streaming/line-buffered route before
   committing to a full external framebuffer.
4. Prototype the selected transport independently of the full emulator:
   known RGB patterns, colour bars, line edges, and frame/reset transitions.
5. Preserve exact overlay blends with tests over both black and white,
   all transparency settings, glyphs, highlights, badges, and panel positions.
6. Keep RGB, DE, sync and font latency aligned; verify RGB is zero outside
   DE. Test both buffers if frame storage is retained.
7. Address directly coupled existing capture-edge and CDC/reset issues.
   Do not assume the old G5 invariant or unchanged SDC proves hardware safety.
8. Inspect inference and RAM-block counts with the smallest authorized
   synthesis check. The owner launches full fitting/timing/hardware builds.
9. Report measured resources, warnings, timing coverage, and the exact
   image tested. Keep keyboard behaviour and unrelated RTL untouched.

**Bottom line:** MiSTer succeeds by streaming RGB through colour/OSK stages
and using its platform's external-memory scaler, not by fitting two native
RGB888 frames into this Pocket-sized M10K budget. Borrow that separation
of responsibilities, not the incorrect assumption that widening one RAM
word is sufficient.
