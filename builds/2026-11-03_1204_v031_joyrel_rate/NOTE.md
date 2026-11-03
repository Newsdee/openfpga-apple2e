# Build archive: 2026-11-03 12:04 — v0.3.1 joystick relative mode (rate-tuned)

Purpose: 0.3.1 joystick relative mode with two follow-ups from hardware feel:
1. **Rate fix** — relative-mode step period `RELATIVE_UPDATE_CYCLES` 71591
   (0.5 ms) → 143182 (1 ms, the donor default). The 0.5 ms felt "floaty" on
   hardware (paddle overshoots before release, reads as inertia — it is NOT
   actual coasting; the accumulator already holds the moment the step-delta
   hits 0). Halving the step rate cuts the overshoot ~2×. Tunable: raise toward
   71591 if now too sluggish.
2. **Menu reorder** — settings block now: Reboot on load, Boot Media,
   Joystick Mode, Color Preset, DPad Keys, Fire Keys (interact.json-only, no
   recompile needed to take effect).

Plus the Step-0 probe (JOY line) retained as a fallback. `OVL_DEBUG=1`
(probe visible in boot window / OSK only, not during gameplay).

## What changed (vs the 0.3.1 first joystick build 604f23cc)
- `apf_stream_video_top.v`: `.RELATIVE_UPDATE_CYCLES(71591)` → `143182`.
- `interact.json`: variables reordered (Boot Media + Joystick Mode moved up).

## Compile (Quartus 17.0.2 Lite)
- Fit: Successful. ALM 13,271 / 18,480 (72%).
- STA: TNS 0.000 (all constraints met; tightest setup slack 1.006 ns, Slow 1100mV 85C).
- ASM: Successful. `.rbf` 1,759,708 bytes. 0 A&S errors.

## SHA-256
- source `.rbf`:        `7bb2b24c2498576ed3e1705872404ea663279858053aad2eacf0ef54637a6eb4`
- `bitstream.rbf_r`:    `f5105e2f7652d59519e27bb68ac21e4a6b5186c481d062f0b800c7b96b4f9716`

## Hardware test
1. Copy `sd_root/Cores/Newsdee.Apple2e/` -> card (bitstream.rbf_r +
   interact.json changed).
2. Reboot. Set Joystick Mode = Relative. Load Sneakers / Alien Downpour.
   - Feel: paddle should now stop where you release it (less overshoot).
   - If too sluggish: I nudge RELATIVE_UPDATE_CYCLES back up (~100000).
   - If still floaty: I go lower.

## Pending (deferred, separate pass)
- Warning triage (owner asked "is it worth cleaning up?"): ~95% of the ~370
  A&S warnings are inherent noise (14320 synthesized-away, 13410 stuck-CRAM
  bits, DDIO pins, 32-bit case-completeness, build hint). ~5% worth a look:
  10230 truncation in our files (apf_stream_video.v:122, sdram_storage.v:474/623,
  reboot_ctl.v:56/57), 10030 undriven rom.v write ports, 276027 dual-clock
  RAM read-during-write (sdram FIFO — the one real correctness question),
  10858 "host_4C used but never assigned" (core_bridge_cmd.v:144). Not done
  yet — a focused pass, not a drive-by cleanup.

## Shipping note
`OVL_DEBUG=1` here. Shipping build reverts to 0. `sd_root_release/` still 0.3.0
— sync when 0.3.1 ships.
