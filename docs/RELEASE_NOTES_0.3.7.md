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
  DC-removed level: 1x = ×16, 2x = ×24, 3x = ×32.
- **No clipping, verified to the card's maximum:** the card's audio
  output is the sum of three 8-bit YM levels per side (max 765), so at
  3x the MB word reaches ±24,480; added to the speaker's ±8,192 that's
  ±32,672 — inside the 16-bit range even at absolute card max plus
  full speaker.
- The card RTL is **vendored byte-identical** from the MiSTer Apple II
  core's Mockingboard implementation (donor files SHA-256-pinned with
  provenance in `src/fpga/core/mockingboard/NOTICE.md`). Two donor
  quirks are documented, not "fixed": the YM2149 channel formula gates
  a pure tone on the channel's noise-select bit (mixer reg 7 = 0x00 is
  silent, 0x08 is audible), and VIA IER bit 7 selects OR-set vs
  AND-clear mode.

## What else

- Everything from 0.3.6 (savestate save/load) is unchanged.
- Platform metadata correction: the core's platform **year is now
  1983** (Apple IIe, with expansion) instead of 1979.
- Floppy (WOZ) and HDV behavior is as in 0.3.6: no storage RTL changes
  in this release. (0.3.6→0.3.7 development included a hardware
  placement investigation of a transient WOZ-load issue; the storage
  RTL is untouched by this release.)

## Release candidate note

Cut from the tree immediately after the Mockingboard audio sign-off
(sim-validated: card unit TB 22/22 checks, machine TB with a real
6502 programming the card, audio TB 11/11 checks including gain
ratios, mono harness `-Werror`-clean). Final hardware floppy/audio
pass is the release gate before the zip is re-cut.
