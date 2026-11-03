# Build archive: 2026-11-03 11:31 — v0.3.1 Joystick Mode (relative mode)

Purpose: the Joystick Mode feature (`BRIEF_JOY_RELATIVE_MODE` §4) — a new
"Joystick Mode" OSD option (Absolute / Relative) that un-ties the donor
`joystick_input` module's relative ladder. Plus the Step-0 probe (JOY line)
kept as a fallback for an ambiguous feel-test. `OVL_DEBUG=1` (probe visible
in the boot window / OSK, NOT during gameplay — so a paddle game is clean).

## What changed (vs the 0.3.0 clean build)
- `apf_stream_video_top.v`: capture `cfg_joy_mode_word` (`0x01F00014`,
  write-only, same safe pattern as `cfg_media_word`); sync `joy_rel_m`
  (relative-mode enable — a **wire**) into the machine domain; rewire the
  `joystick_input` instance — `.joystick_analog` ← live left-stick bytes
  (donor `[15:8]=X [7:0]=Y`), `.relative_mode` ← `joy_rel_m`. The existing
  `joy_clk` (`~osk_visible`) gate already freezes the paddle/accumulator
  while the OSK is open, so relative mode can't drift a running game.
- `interact.json`: new "Joystick Mode" list (id 7, `0x01F00014`, writeonly,
  persist, default Absolute): 0=Absolute 1=Relative.
- `core.json`: version 0.3.0 -> 0.3.1.
- (probe, from `582b3cc`) `OVL_DEBUG=1` + the JOY line stay as the fallback.

## Compile (Quartus 17.0.2 Lite)
- Fit: Successful. ALM 13,306 / 18,480 (72%).
- STA: TNS 0.000 (all constraints met; tightest setup slack 0.492 ns, Slow 1100mV 85C).
- ASM: Successful. `.rbf` 1,769,488 bytes.
- A&S note: the first compile hit **Error 10663** (`joy_rel_m` declared `reg`;
  the `synch_3 .o` must be a structural net) — fixed to `wire` (`5d35598`).
  Pre-existing **Warning 10762** at line 379 (the 32-bit `bridge_addr` case)
  is benign (Quartus can't enumerate 2^32 states).

## SHA-256
- source `.rbf`:       `85cb5ae3aad5283d144eb055e0083833e80d330804b36d1f0b93c5a5175ae3fd`
- `bitstream.rbf_r`:   `604f23ccd111fd4884d884128ce3a86acc55bd1dbed4b3a64e43cccd1e4f4495`

## Hardware test (the feel-test in a paddle game)
1. Copy `sd_root/Cores/Newsdee.Apple2e/` -> the card. `core.json` (0.3.1),
   `interact.json` (new option) and `bitstream.rbf_r` all changed; `data.json`
   / `video.json` unchanged. Copy the whole dir (safest) or at minimum those
   three files.
2. Power on. Set **Joystick Mode = Relative** in the menu.
3. Load **Sneakers** or **Alien Downpour** and feel the paddle:
   - **Feels good** (smooth stick tracking, correct Y direction, no drift at
     rest) => 0.3.1 is done.
   - **Y inverted** (stick-up moves the paddle down) => flip `joy_y_pdl`
     (one-line glue).
   - **Paddle drifts at rest** (stick idling off-centre) => add a centre trim.
   - **Only the d-pad works** (steppy, no analog) => the sticks aren't feeding
     live bytes on this board => re-scope to d-pad-only relative.

## Revert / shipping note
`OVL_DEBUG=1` here (probe visible in the boot window / OSK only). For the
shipping build, revert `OVL_DEBUG` to 0 (the JOY line disappears; the joystick
feature is unaffected — it's not gated by `OVL_DEBUG`). The 0.3.1 release
snapshot (`sd_root_release/`) is still 0.3.0 — sync it when 0.3.1 ships.
