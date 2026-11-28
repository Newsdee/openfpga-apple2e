# Release 0.4.7 — 2026-11-28

**Procedural HDV seek sound — a synthesized voice for hard-drive seeks,
off by default.**

0.4.6 (video window alignment, unchanged here) plus one new opt-in audio
feature: the HDV now "grinds" softly when the guest seeks, like a real
ST-225-class drive, entirely synthesized in fabric — no samples, no ROM,
no card assets, ~500 ALMs.

## What's new over 0.4.6

### HDV seek sound (`hdv_seek_sound.sv`)

- **Trigger**: observes the ACCEPTED guest command pulses `hdd.v` already
  emits (`hdd_read`/`hdd_write` + `sector`) — never the DMA path, so status
  polls, rejected writes, protected writes and unmounted requests can't
  trigger it. Distance = unsigned absolute difference of 16-bit block
  numbers (no wraparound: `0xFFFF -> 0x0000` is a LONG seek, not adjacent).
  - distance 0..1: silent (sequential access stays silent by design)
  - distance 2..63: short seek, 52 ms
  - distance >= 64: long seek, 134 ms
  - history updates on EVERY accepted command, including mid-playback;
    triggers during a sound are dropped (never queued or restarted)
- **Voice** (owner-tuned "preset Q"): flat 3040 Hz triangle body, light
  LFSR grit through a two-pole shift/add lowpass, slow amplitude swells
  (70 Hz short / 55 Hz long) with deterministic jitter, shallow envelope
  (1500/900) so peaks never mute, 16 ms attack / 30 ms release inside the
  duration, exact digital zero at idle and at the end. Signed bounded
  arithmetic, no lookup tables. Peak ~1550 signed (4.7% FS) after the
  owner's "a bit less loud" hardware pass (OUT_SHIFT -5 -> -4).
- **Tuning method**: the timbre was found by ear in `verilog/hdv_snd/
  tone_lab.html`, a browser parameter lab that mirrors the RTL integer-
  exact (verified: peak within 1%, onsets within the trigger latency),
  against a real Seagate ST-225 recording (dominant 2616 Hz tonal peak
  + 200-720 Hz mechanical cluster informed the first candidates; the
  shipped voice is the owner's sweet spot, not a copy).

### Option: Interact -> HDV Sound (default OFF)

- `interact.json` id 15, persist, writeonly, bridge `0x01F00030`
  (next free slot; map documented in `apf_stream_video_top.v`).
- **Off is bit-identical to 0.4.6 audio**: the voice outputs exact zeros,
  and `tb_speaker_i2s` proves the I2S words unchanged with the term tied
  to zero. The signed mono term enters the existing 19-bit saturating sum
  equally on L/R (sign-extended by bit replication — not the zero-prefix
  that caused the 2026-11-19 negative-flip bug); worst-case headroom
  keeps the saturator's bit18 sign test valid.
- CDC follows the mixer's proven held-sample valid/ack pattern (complete
  samples cross coherently; disable/reset propagates a zero, never a
  stale sample).

## Validation

- `hdv_seek_sound` events TB: ALL PASS (12 checks: silent seed/dist-0/1,
  fwd+rev dist 2/63/64, 0xFFFF->0x0000 long, 200-step sequential silence,
  mid-play drop (no queue), eject silence, remount re-seed, reset to exact
  zero, disabled silence).
- Audio regressions: `tb_speaker_i2s` PASS (bit-identical baseline),
  `tb_floppy_sound_chain` PASS, `tb_mb_audio` PASS, `tb_floppy_sound` PASS.
- Full stack: `pocket_boot` SMOKE BOOT OK (frames=10, fb=560x191).
- Quartus: Fitter Successful, TNS 0.000, worst slack 1.315; RAM-bank gate
  PASS (2 x 64KiB M10K); 11,771 ALM / 64% (+~500 for voice+mixer),
  13,220 registers, memory bits unchanged at 50%.
- Hardware (owner, Pocket): two listening rounds — round 1 exposed the
  rising-sweep "bird chirp" (the approved lab sound was actually a flat
  tone; fixed to flat 3040), round 2 halved the level. Final build
  accepted 2026-11-28. Deployed bitstream sha256
  `96bf16970c944445a651e3d4d56c838a7c39d23c581cca16d0f85511c840eff9`.

## Known boundaries

- The seek voice reacts to guest COMMANDS, not to successful transfers —
  a failing/faulted transfer still "seeks" audibly. This matches the plan
  (the pulses are accepted-command indications) and real drives, which
  make noise on the physical seek regardless of the data outcome.
- Level granularity: OUT_SHIFT is integer steps (~x2 each). Finer trim,
  if ever wanted, needs a small multiplier (deferred).
