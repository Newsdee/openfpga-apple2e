# `machine/video/` - byte-pinned donor import (NTSC color path)

These four files are **byte-identical copies** from the pinned MiSTer donor.
They are imported unmodified so the donor remains the executable reference for
the differential test, and so any future donor fix can be re-copied and diffed.

| File | Donor path | sha256 (first 32 hex) | CR bytes |
|---|---|---|---|
| `video_pipeline.sv` | `Apple-II_MiSTer/rtl/video/video_pipeline.sv` | `1b4a7082d434e6153ba0cb063bbea351` | 325 |
| `apple_composite.sv` | `Apple-II_MiSTer/rtl/video/apple_composite.sv` | `816e9484e839387c21124281c24fd3e2` | 166 |
| `composite_decoder.sv` | `Apple-II_MiSTer/rtl/video/composite_decoder.sv` | `d769395fa43df1afe8927c4904d180e2` | 783 |
| `vga_controller.v` | `Apple-II_MiSTer/rtl/video/vga_controller.v` | `53ee53be5714c1e671c9a728b85bc503` | 905 |

Donor revision at import: **`7ed980d`** ("docs: correct vga_controller header -
it is a native-rate RGB renderer, not a line-doubler"), worktree clean apart
from three untracked non-RTL items. Import date: 2026-10-25.

All four files are **CRLF / mixed-EOL in the donor**. Preserve the byte layout:
copy with `cp -p`, never re-save through an editor or a PowerShell
`Get-Content | Set-Content` round trip, and verify with `tr -cd '\r' | wc -c`
(`gawk`/`sed`/`cat -A` silently drop `\r` under MSYS - see the workspace
`AGENTS.md` "MSYS byte-safety" section).

## Verification

`check_machine_sync.sh` at the repo root covers these four files against
`../Apple-II_MiSTer/rtl/video/`. Run it after any donor re-copy:

```sh
bash check_machine_sync.sh    # exit 0 = machine/ (including video/) in sync
```

## Notes on individual files

- **`vga_controller.v` is NOT a line-doubler**, despite its historical header
  comment (corrected in donor `7ed980d`). It is a native-rate RGB renderer and
  an *elaboration dependency* of the unmodified `video_pipeline`. With
  `use_composite=1` and `SCREEN_MODE=2'b00` constant it should be **unobserved
  and fold away in synthesis** - `apple_composite` is fed `.video(VIDEO)` (the
  raw one-bit machine signal), not `r_vga`. Verify its absence in the map/fit
  hierarchy; do not assume it. See `docs/PLAN_NTSC_PORT_2026-10-24.md` section 3.
- **`composite_decoder.sv`** contains `linebuf_mem[0:1023]` x 16 b = 16,384
  bits, which must infer **M10K, not a register array**. This is the same class
  of failure that produced the Q17 RAM blow-up (Error 276003/276007 -> ~500K
  logic registers -> Fitter 170011). Check the map report's inferred-RAM table.
- Do **not** retune the YIQ matrix, `SPC=4`, burst-window phase, or preset
  constants to save ALMs. The donor values are hardware-validated on MiSTer.

## Pocket-side deviations

None at import. Any deviation required for Pocket integration must be made in
Pocket glue (`src/fpga/core/apple2e/`), not by editing these files, and must be
recorded here with its reason.
