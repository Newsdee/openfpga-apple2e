# Decision request — Apple IIe Pocket OSK color pipeline (2026-10-19)

> **SUPerseded 2026-10-19 16:30 +08:00 (correction + new leading path).**
> The **Option B** arithmetic in this doc was **wrong**: it counted the
> `pix_ram` *words* (65,536 × 24 = 1.57 Mbit), not the actual *pixels* it must
> hold. The machine-active frame is **560 × 192 = 107,520 px/frame**; two
> ping-pong frames at RGB888 = **215,040 × 24 = 5,160,960 bits ≈ 5.16 Mbit**,
> which **exceeds the entire 3.15 Mbit M10K** (before machine RAM/ROMs). So
> **24-bit-per-pixel does not fit in the M10K.** The **leading path is now
> native RGB streaming** (no full-frame buffer), per the NES reference — see
> [NES_REFERENCE_STREAMING_RECOMMENDATION_2026-10-19.md](NES_REFERENCE_STREAMING_RECOMMENDATION_2026-10-19.md).

**Owner:** Newsdee · **Repo:** `Newsdee/openfpga-apple2e` · **Device:** Cyclone V
`5CEBA4F23C8` (Analogue Pocket), Quartus 17.0.2 Lite.

## The decision
Choose the **frame-buffer color format** for the Apple IIe Pocket core's video
path so the on-screen keyboard (OSK) renders at **full MiSTer color, including
transparency**, and so the same pipeline scales into the planned **Apple IIe
composite-color** modes later.

## What we have
- The OSK overlay (`machine/osk/virtual_keyboard_overlay.sv`, byte-identical to
  the MiSTer core) **already produces the full 24-bit MiSTer color**: `rgb_out`
  (cream panel, colored text, the three Apple badges, the selected-key
  highlight, and transparency blending). It composites that 24-bit result over
  the machine's 1-bit video.
- Today `apple2e_osk.v` **discards** that color: it collapses to 1 bit
  (`video_out = osk_rgb[17]`) before the `apf_video` adapter, so the panel
  renders white-on-black.
- `apf_video` converts the machine's native video to the APF's **fixed** 400×512
  @ 12.288 MHz grid (the machine's 560-sample lines are nearest-neighbour-scaled
  to 320 APF columns; 192 machine lines are centered in the 240-line active
  window). It stores the **machine-active frame only** (2 ping-pong buffers ×
  192 lines × 70 words = **26,880 words used**; the `pix_ram[0:65535]`
  declaration is headroom, not the real size) and reads it back at the APF pixel
  rate.

## Why there is a buffer at all (vs. the MiSTer core)
The MiSTer core has **no** frame buffer because its output timing **is** the
machine timing (no scaling). The APF output timing is **fixed** (400×512 grid),
so we must scale the machine's 560-sample × 192-line frame into it. That scaling
is the only reason a buffer exists — and it is the **small machine-active
frame**, not a full-resolution APF frame.

## The M10K budget (fresh fit, 2026-10-19)
- Device M10K: **3,153,920 bits**.
- Current usage: **1,758,236 bits (56%)**, of which `pix_ram` is ~0.21 Mbit
  (1-bit).
- Free: ~1.4 Mbit.

## Options (frame-buffer color format)

| option | format | real storage | fits M10K? | OSK color | transparency | notes |
|---|---|---|---|---|---|---|
| **A** | 4-bit index (16 colors) + palette LUT | 215,040 px × 4 = ~0.86 Mbit | ✅ yes | ✅ panel/text/badges/selected + B&W | ❌ blends snap to nearest palette entry | smallest; parameterized `PIX_INDEX_WIDTH` keeps the door open; a possible *OSK-over-monochrome interim* only |
| **B** | ~~24-bit per word in the M10K~~ | **215,040 px × 24 = 5.16 Mbit** | ❌ **no** (exceeds the whole 3.15 Mbit M10K) | ✅ exact | ✅ exact | **INVALID — the original 1.57 Mbit figure counted words, not pixels. Do not return to this.** |
| **C** | 24-bit in PSRAM (C64-core pattern) | PSRAM (128 Mbit) | ✅ trivially | ✅ exact | ✅ exact | the `myc64-pocket` core proves the PSRAM controller + display-read pattern; larger architectural change — a **fallback**, not the first try |
| **D** | **native RGB streaming, no full-frame buffer** (NES pattern) | small line registers / no RGB store | ✅ (no RGB frame alloc) | ✅ exact | ✅ exact | **leading path** — stream native 560×192 @ ~14.312 MHz through a thin APF adapter; Pocket scaler handles the raster; see the NES recommendation doc |

Notes on the reference cores: `refs/myc64-pocket` is a **C64 emulator** (a
`picorv32` RISC-V soft-core running the C64 in C), **not** a hardware C64 core —
its 24-bit color is generated in software and stored in **PSRAM**. The
**`agg23/openfpga-NES`** core (pinned commit in the streaming doc) is the more
relevant reference: it **streams native RGB with no full-frame buffer**, proving
the APF accepts a non-400×512 raster.

## Working recommendation (D — native RGB streaming)
Per the NES reference, **prototype direct RGB streaming first** — no full-frame
buffer, no PSRAM. The Apple IIe core would stream its **native** 560-sample ×
192-line video (black/white now, composite RGB later) through a thin APF
timing/output adapter, and the **Pocket scaler** handles the raster conversion
(the NES core proves the APF accepts a non-400×512 raster).

This keeps the OSK's **native geometry** (not rescaled to 320 px) and its
**full RGB888 including transparency** end-to-end, with no M10K/PSRAM RGB frame
allocation.

**Sequence (from the NES recommendation doc — research/prototype, not yet
authorized implementation):**
1. **Phase 0 (no RTL):** verify from APF docs + the pinned NES reference that
   the Apple II **560×192 @ ~14.312 MHz** stream is a legal APF input (active
   dims, total raster, pixel-clock range, forwarded-clock phase/PLL, HS/VS/DE,
   manifest scaler dims, Pocket-vs-dock).
2. **Phase 1:** isolated streaming-pattern prototype (color bars/markers) in a
   separately selectable build — not replacing the working path.
3. **Phase 2:** real machine video + full-color OSK (the goal).
4. **Phase 3:** composite color via the MiSTer `video_pipeline.sv`.

**Fallback** only if Phase 0 shows the raster is illegal: small line-buffered
conversion (A), then PSRAM (C). Do **not** return to the invalid Option B.

`A` (indexed OSK-over-monochrome) remains a possible *interim* if streaming
proves infeasible; it is not a general substitute for arbitrary composite RGB.

## Questions for the experts
1. Is the **Apple II 560×192 @ ~14.312 MHz** native stream a **legal APF input**
   (the NES 256×240 @ 5.369 MHz is, per the reference)? What are the exact
   active-dim / total-raster / pixel-clock / forwarded-clock-phase limits?
2. For the **future Apple IIe composite-color** work, is **native streaming**
   the right base, or does the composite decoder (line history, DSP) make a
   **line-buffered** path preferable? Where should the RGB live — streamed
   live vs. a small line buffer?
3. Is there any reason **not** to stream the OSK's transparency blends **live**
   at the output (RGB888 end-to-end) rather than pre-blending into a store?
4. Should the **PSRAM path (C)** be kept warm as a documented escalation, or
   dropped for this core?

## What we will NOT do
- No consume-on-`$C000` or any keyboard-ack change (that work is closed and
  hardware-verified; see `KEYBOARD_FIX_HANDOFF_2026-10-19.md`).
- No change to the canonical `machine/osk/` files (they stay byte-identical to
  MiSTer); the color change is entirely in `apple2e_osk.v` + `apf_video.v`.

## Context docs
- `NES_REFERENCE_STREAMING_RECOMMENDATION_2026-10-19.md` — the streaming
  recommendation + pinned `agg23/openfpga-NES` evidence (the leading path).
- `KEYBOARD_FIX_HANDOFF_2026-10-19.md` — the closed keyboard-flood investigation.
- `OSK_KEYBOARD_FLOOD.md` — the OSK integration history.
- `refs/myc64-pocket/` — the PSRAM reference core (fallback C).
