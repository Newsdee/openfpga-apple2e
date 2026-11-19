# Apple IIe for Analogue Pocket — 0.3.7

**Mockingboard sound card.** The Apple IIe sound-card lineage gets its
most famous member: the core now emulates a **Mockingboard** (Model A
clone) in **slot 4** — two 6522 VIAs and two AY-3-8910 PSGs, six
stereo channels.

## Mockingboard

- New menu option **Mockingboard** in Core Settings: a **volume
  slider** with four positions — **Off, 1x, 2x, 3x**. Off is the
  default, and with it the audio output is **bit-identical** to the
  plain speaker path (the MB term is gated out and its DC tracker
  converges to zero).
- The card is a full IO-space device: the slot-4 window
  ($C400–$C7FF, VIA-mapped), IRQ/NMI lines, and both PSGs. Mockingboard
  software — the classic demo/music programs of the 1980s Apple scene —
  plays through the Pocket's headphone jack in stereo.
- **Audio chain** (why the sound is clean): the PSG's 10-bit channel
  sums are **point-sampled** in the machine clock domain and handed to
  the 12.288 MHz audio domain with a valid/ack handshake (one sample
  pair per handshake — glitch-free by construction). Each channel runs
  a slow DC tracker (τ ≈ 128 samples ≈ 2.7 ms) so notes keep their
  pitch and bass (50 Hz and below survives) while volume/DC shifts
  track in a few milliseconds. The selected gain scales the
  DC-removed level: 1x = ×24, 2x = ×32, 3x = ×48 (the first RC
  candidate's ×16 base was judged too quiet on hardware; the ladder
  shifted up one step and the top raised to ×48, 1.5x per step).
- **No digital clipping, verified to the card's maximum:** the card's
  audio output is the sum of three 8-bit YM levels per side (max 765).
  At 3x the MB word can reach ±36,720 at the absolute card corner, so
  the MB term and the final speaker+MB(+floppy) sum are **saturating**
  (clean limiting, never wraparound) - loud 3-channel material at 3x
  is limited, not distorted.
- The card RTL is **vendored byte-identical** from the MiSTer Apple II
  core's Mockingboard implementation (donor files SHA-256-pinned with
  provenance in `src/fpga/core/mockingboard/NOTICE.md`). Two donor
  quirks are documented, not "fixed": the YM2149 channel formula gates
  a pure tone on the channel's noise-select bit (mixer reg 7 = 0x00 is
  silent, 0x08 is audible), and VIA IER bit 7 selects OR-set vs
  AND-clear mode.

## Floppy drive sound

- New menu option **Floppy Sound** in Core Settings (default **on**):
  synthesized Disk II drive audio — motor hum on spin-up, head-step
  clunks, the track-0 knock, and read/write activity texture — mixed
  into the stereo output alongside the speaker and Mockingboard.
  Single-drive machine: the sounds sit on the **left** channel
  ("Drives" pan, MiSTer parity). Turning the option off returns the
  output to exactly the pre-feature stream (the sound engine is
  zero-idle and its mix term adds nothing when off — sim-proven
  bit-identity).
- The sound model is **vendored byte-identical** from the MiSTer Apple
  II core (donor file SHA-256-pinned with provenance in
  `src/fpga/core/sound/NOTICE.md`), driven by the WOZ engine's
  existing step/track-0/IO/motor event taps — no storage-RTL changes,
  so floppy/HDV behavior is untouched. The 10-bit amplitude samples
  cross to the audio domain with a valid/ack handshake (same pattern
  as the MB audio chain) and mix in at a fixed ×8 (hardwired, no
  knob — it is drive ambience, not music).

## What else

- The Mockingboard volume slider gained a **louder top end and
  saturating mix** (see the Mockingboard section above).
- Everything from 0.3.6 (savestate save/load) is unchanged.
- Platform metadata correction: the core's platform **year is now
  1983** (Apple IIe, with expansion) instead of 1979.
- Floppy (WOZ) and HDV behavior is as in 0.3.6: no storage RTL changes
  in this release. (0.3.6→0.3.7 development included a hardware
  placement investigation of a transient WOZ-load issue; the storage
  RTL is untouched by this release.)

## Release candidate note

Cut from the tree after the Mockingboard audio sign-off and the floppy-
sound landing (sim-validated: card unit TB 22/22 checks, machine TB
with a real 6502 programming the card, audio TB all checks including
the 24/32/48 gain ratios, floppy-sound donor TB 15/15 + full-chain TB
9/9, mono harness `-Werror`-clean). Final hardware floppy/audio/
drive-sound pass is the release gate before the zip is re-cut.
