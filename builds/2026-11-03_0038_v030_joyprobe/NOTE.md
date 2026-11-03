# Build archive: 2026-11-03 00:38 — v0.3.0 Step-0 stick-liveness probe

Purpose: hardware probe to falsify the "Pocket has no analog stick" assumption
(`BRIEF_JOY_RELATIVE_MODE_2026-11-02`, Step 0). Display-only — no functional
change to the paddle path. `OVL_DEBUG=1` (the debug text, incl. the new JOY
line, is visible).

## What changed (vs the 0.3.0 clean build)
- `apf_stream_video_top.v`: sync `cont1_joy` -> `cont1_joy_m` (3-FF, machine
  domain, mirrors `s_joy_key`); sticky "stick ever moved" OR-tree
  (`joy_ever_m`) on `cont1_joy_m[15:0]`; route raw left-stick bytes + the latch
  to the overlay. `OVL_DEBUG` 0 -> 1.
- `sdram_status_overlay.v`: new JOY line `"A=XX B=YY E=E"` (X0=424, rows 96..102):
  A=left-stick X byte, B=left-stick Y byte, E=stick-ever-moved (0/1). `pxjoy`
  OR'd into `ovl_px`.

## Compile (Quartus 17.0.2 Lite)
- Fit: Successful. ALM 13,158 / 18,480 (71%).
- STA: TNS 0.000 (all constraints met; tightest setup slack 1.139 ns, Slow 1100mV 85C).
- ASM: Successful. `.rbf` 1,755,740 bytes.

## SHA-256
- source `.rbf`:        `28dcb1761c1ee819037af18916de53a7a8c0a2dac6a8647685aea2c41702173d`
- `bitstream.rbf_r`:    `1056dcd28a0136ce4c1e7b21caee02c5ccfd414082be8eac9d897e8f1a0dcd32`

## Hardware test (the Step 0 verdict)
1. Copy `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r` -> card
   (`I:/Cores/Newsdee.Apple2e/`). JSONs are unchanged from 0.3.0 (only the
   `.rbf_r` changed), so this is the only file to copy.
2. Power on, open the OSK (makes the debug text show), wiggle the LEFT stick.
3. Read the JOY line (lower-right area, rows 96..102): `"A=XX B=YY E=E"`.
   - **Sticks live** -> A/B sweep `~0x00..0xFF` (signed -128..+127), rest ~0x00,
     E flips 0->1 on the first move. => proceed to the full relative-mode
     feature (BRIEF §4 change set).
   - **Sticks dead** -> A/B stay 0x00, E stuck 0. => re-scope to d-pad-only
     relative (the ladder's digital +/-3 branch still works).

## Revert / shipping note
`OVL_DEBUG` is 1 in this build (probe visible). For the shipping build, revert
`OVL_DEBUG` to 0 — the JOY line is gated by `ovl_px` (OVL_DBG-gated) so it
disappears, but the `cont1_joy_m` sync + `joy_ever_m` OR-tree stay compiled in
(a small resource cost; the sync is reused by the full feature's
`.joystick_analog` wiring, the OR-tree is probe-only and can be dropped later).
