# joystick_input.sv - donor import from the MiSTer Apple II core

**Byte-identical** port of the MiSTer Apple II core's joystick handler.
No modifications: the Pocket-side integrations (OSK gate, face-button
centering, paddle timer) live in `apf_stream_video_top.v` around this
module, so the donor file stays diff-able against the upstream tree.

```
source: E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/joystick_input.sv
donor head at import (2026-10-25): 7ed980d
```

## SHA-256 pin (verified 2026-10-25)

| File                 | SHA-256 | Status |
|----------------------|---------|--------|
| `joystick_input.sv`  | `f5576c8936eedb736ad84ca97ca839bcb1b25e2fe42807a3e6e3229892695591` | byte-identical |

Re-verify:

```bash
sha256sum src/fpga/core/apple2e/joystick_input.sv
# expect f5576c8936eedb736ad84ca97ca839bcb1b25e2fe42807a3e6e3229892695591
cmp src/fpga/core/apple2e/joystick_input.sv \
    E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/joystick_input.sv
```

Line endings: CRLF throughout (as in the donor file) - do not normalize.

## Integration notes (Pocket side, in `apf_stream_video_top.v`)

- Runs in the machine domain on a GATED slice of `clk_core_14318`
  (143.18 MHz): 100% / 50% / 25% clock pass-through implements the
  Relative fast / normal / slow steps (0.5 / 1 / 2 ms per update at
  `RELATIVE_UPDATE_CYCLES = 71591`), and the gate closes while the
  OSK is visible (`osk_visible`) - freeze, not zero.
- `joystick_analog` / `paddle` / `swap_axes` / `paddle_as_*` /
  `x_center` are tied off (Pocket pad has no analog sticks, v1);
  `relative_mode` comes from the "Joystick" Core Settings option.
- `joy[6]` (face X) is the "centre paddles" override applied in the top
  before the `pdl_timer`; `joy[4]/[5]/[7]` are PB0/PB1/PB2, merged with
  the OSK apple buttons into `GAMEPORT` (OSK-visible = gated to OSK).

# savestate_manager.sv - donor import from the MiSTer Apple II core

**Byte-identical** import of the MiSTer Apple II core savestate FSM
(`Apple-II_MiSTer/rtl/savestates/savestate_manager.sv`). No modifications:
the Pocket-side integration (slot <-> SDRAM owner bridge, handshake
contract, word-0 preload) lives in `savestate_slot.v`, so the donor file
stays diff-able against the upstream tree.

```
source: E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/savestates/savestate_manager.sv
donor head at import (2026-11-11): 96881ff-era (Apple-II_MiSTer working tree)
```

## SHA-256 pin (verified 2026-11-11)

| File                   | SHA-256                                                        | Status          |
|------------------------|----------------------------------------------------------------|-----------------|
| `savestate_manager.sv` | `b03fde24fbf64342d293afcbf1dc4a2f1cc8e68ffe4a6a68a0e189ca8d3cb52f` | byte-identical |

Re-verify:

```bash
sha256sum src/fpga/core/apple2e/savestate_manager.sv
# expect b03fde24fbf64342d293afcbf1dc4a2f1cc8e68ffe4a6a68a0e189ca8d3cb52f
cmp src/fpga/core/apple2e/savestate_manager.sv \r
    E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer/rtl/savestates/savestate_manager.sv
```

Line endings: CRLF throughout (as in the donor file) - do not normalize.

## Integration notes (Pocket side)

- Instantiated in `savestate_slot.v` (machine domain). Its `ss_*` ports
  match the pinned `machine/apple2.v` exactly; `ram_*` connect to the
  top-level `ram_main`/`ram_aux` arrays.
- The `slot_*` port is re-targeted from the donor `savestate_ddr` to the
  SDRAM blob (word base 0x400000) via the `sdram_word_owner` clients
  `ss_rd`/`ss_wr`. See `docs/EXPERT_BRIEF_SAVESTATE_MANAGER_2026-11-11.md`.
