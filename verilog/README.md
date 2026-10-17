# Verilator harness for the APF Pocket core

Local simulation/debug environment for `apple2e-pocket`. Follows the same
conventions as `Apple-II-Verilog_MiSTer/verilator` (MSYS2 UCRT64,
`build_verilator.bat` / `run_verilator.bat`, AGENTS.md build facts).

## Scope

Two harnesses, both instantiating the real `apf_top` (bridge + PAD +
video/audio PHY) with the two async 74.25 MHz clocks and tied-off external
inputs, verifying after 3 s of simulated time (exit code 0 = PASS):

**P0 — template** (`tb/tb_apf_smoke.sv`, `build_verilator.bat`):
the unmodified template `core_top` test-pattern core. Checks video sync
(VS/HS), DE activity, pixels not stuck (>=2 colors), I2S MCLK/LRCK.
Proves the template tree builds and simulates under Verilator.

**P1 — apple2e** (`tb/tb_apple2e_smoke.sv`, `build_apple2e_verilator.bat`):
the Apple IIe `core_top` (`core/apple2e/apple2e_core_top.v`) with the
`apple2e_pll` tree (14.318 / 12.288 / 12.288-90 / 3.072 MHz). The host
issues Reset Exit (0x0011) over the real bridge SPI, then checks video sync,
DE, pixels, a `scal_clk` frequency sanity check (12.288 MHz family, not the
74.25 MHz reference), and I2S MCLK/LRCK. Both builds share the same stubs;
they use separate `obj_dir` / `obj_dir_apple2e` so they don't clobber each
other.

## Build & run

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\verilog
build_verilator.bat            rem clean rebuild: build_verilator.bat clean
run_verilator.bat
```

## DUT sources

Template RTL is referenced **in place** (`../src/fpga/...`), not copied:
the sim always tracks the exact tree Quartus compiles. Only additions:

- `stubs/altsyncram_sim.v` — behavioral 256x32 dual-port RAM standing in for
  the Quartus `altsyncram` IP used by `apf/mf_datatable.v` (build-ID table;
  zero-initialized in sim — cosmetic content only).
- `stubs/altddio_bidir_sim.v` — behavioral 12-bit DDR bidir pad standing in
  for the Quartus `altddio_bidir` IP (drives `datain_l` on the rising
  `outclock` edge, `datain_h` on the falling edge).
- `stubs/altera_pll_sim.v` — behavioral `altera_pll` standing in for the
  Quartus PLL IP. The vendor model's lnsim chain doesn't resolve in
  Verilator, so this generates the four apple2e clocks (14.318 / 12.288 /
  12.288-90 / 3.072 MHz) via 24-bit NCOs. **Note:** the stub hardcodes the
  apple2e frequencies and ignores the instance's `output_clock_frequencyN`
  params, so the template build's video clock is the stub's 14.318 MHz (not
  its 12.288 MHz intent) — harmless for the threshold-based template checks,
  and the real Quartus template build uses the real 12.288 MHz PLL.
- `tb/tb_apf_smoke.sv` — P0 template smoke testbench (pure SV, `--binary
  --timing`).
- `tb/tb_apple2e_smoke.sv` — P1 apple2e smoke testbench.

Cartridge/link/IR/UART/memory buses are left unconnected (DUT-side only).

## Build & run (apple2e)

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\verilog
build_apple2e_verilator.bat     rem clean: build_apple2e_verilator.bat clean
run_apple2e_verilator.bat
```

The apple2e build references `core/apple2e/apple2e_core_top.v` +
`core/apple2e/apple2e_pll.v` (NOT the template `core_top` / `mf_pllbase` —
module-name collision on `core_top`). `apf_top`'s `core_top ic` binds to the
apple2e core.

## Roadmap (per docs/porting/PLAN_POCKET_CORE.md §7)

- **P1 (done):** apple2e `core_top` + `apple2e_pll` tree (14.318/12.288/
  12.288-90/3.072 MHz), Reset Exit (0x0011) over the real bridge SPI, video
  test pattern + `scal_clk` frequency check. See `tb_apple2e_smoke.sv`.
- **P2:** full `apf_shell_sim` — bridge writes for interact params, PAD
  type-4 keyboard packet generator, data-slot load FSM — with the Apple II
  RTL dropped in; boot-from-baked-`.nib`, keyboard, audio checks.

## P2a: native-video probe (tb/tb_native_probe.sv)

Builds the unmodified machine core (Apple-II_MiSTer/rtl, referenced in place)
with a geometry-measuring TB: line-length/active-length/white-pixel
histograms, frame structure, TEXT_MODE/HGR_MODE flags; boots the real BIOS
(90 frames), pokes $C010=$80, measures the HGR phase (30 frames).

    build_probe_verilator.bat        rem clean: +clean
    run_probe_verilator.bat          rem builds if needed, runs (+cpu=0/+cpu=1)

**2026-10-17 AV incident (resolved):** freshly linked harness PEs (this
probe AND the P1 `Vtb_apple2e_smoke.exe`) were killed at startup with
0xC0000409 fastfail / exit 127 and zero output — including copies to
C:\Temp (hash-based kill; small C++ PEs still ran). Per AGENTS.md, stopped
fighting it. The block flaps and lifted on its own; `run_probe_verilator.bat`
now runs clean from bare cmd (the bats put `C:\msys64\ucrt64\bin` on PATH
for the ucrt64 DLLs, e.g. libwinpthread-1.dll).

## P2a: machine + APF video adapter (tb/tb_apf_video.sv)

End-to-end P2a harness: unmodified machine core + `apf_video` adapter +
output monitor. Checks: vs/hs geometry (512 hs/frame; upper bound allows
the sim-only hold lines, since in sim the machine frame slightly exceeds
the display grid — see PLAN_POCKET_CORE.md), KB-014 (rgb=0 outside DE),
BIOS boots to the Apple logo (peak white) then settles to a stable
sparse-white prompt screen, and **G5 (ping-pong race invariant)**: the
display buffer must never equal the machine write buffer for more than a
few cycles per frame (the ~3-4 cycle synchronizer settling window;
pre-boot idle is not counted). ~2 s machine time, PASS = exit 0.

    build_p2a_verilator.bat        rem clean: +clean
    run_p2a_verilator.bat          rem builds if needed, then runs

**Status 2026-10-17: PASS.** ~102 output frames, 512 hs/frame (+ sim hold
lines), 0 KB-014 violations, peak white 38,667 (logo), stable ~135-px
prompt screen, **G5 racy_cycles=303 over 102 frames (~3/frame = only the
settling window)** — the ping-pong buffer race is closed: the display
frame start and buffer re-select are locked to the machine's wbuf change
(3-stage sync + 1-cycle delay), so the display always reads the buffer the
machine just finished (see PLAN_POCKET_CORE.md, "Hardware video glitch"
entry, for the root cause and the failed VBL-pulse fix attempt).
Measured native geometry (from adapter debug + probe): line = 910 masters
(65 H-slots), active = 560 (HBL low, 40 slots), blank = 351 (HBL high,
25 slots at line start); frame = 262 lines, 70 VBL (6 top + 64 bottom),
192 visible lines (24 rows x 8), 60.15 Hz.
