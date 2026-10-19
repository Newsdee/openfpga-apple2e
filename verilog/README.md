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

## P2b: OSK keyboard (tb/tb_apf_video.sv + tb/tb_p2b_shots.sv)

P2b extends the P2a harness with the OSK (on-screen keyboard): the DUT is
now the full `apple2e_core_top` (machine + `apple2e_osk` + `apf_video`).
Button map (APF cont1, remapped 2026-10-17 per owner): D-pad = cursor,
face-A = fire, **start[15] = OSK on/off**, face-X = space, face-Y =
enter, **face-select[14] = transparency cycle**, **trig-L1[8] = panel
position**. NOTE (2026-10-18): the OSK controller's `joystick[3:0]`
dpad convention is [0]=right [1]=left [2]=down [3]=up, while the APF
`cont1` dpad bits are [0]=up [1]=down [2]=left [3]=right, so the dpad
nibble is **bit-reversed** in `apple2e_osk.v` (a straight passthrough
rotated the cursor movement). Buttons go through a two-stage input
cleanup in `apple2e_osk.v`: (1) a **debounce** (~1.4 ms stable-to-
accept) and (2) a **press-latch with release confirmation** (~30 ms)
so one physical press = exactly one 0->1 / one 1->0 - the OSK
controller is edge-triggered and re-arms on every falling edge, so
without the latch an oscillating delivered signal would type the same
key many times (the on-hardware "whole rows of the same key" report).
`tb_apf_video.sv` presses start (bit 15) to open the OSK, does a CLEAN
fire press plus a 15-cycle @5 ms fire WOBBLE, presses enter, and taps
dpad UP + LEFT, and checks:

- **G6a** — the single CLEAN fire press AND the 15-cycle fire WOBBLE
  each issue exactly one virtual key-press (counted on `kb_v_event`/
  `kb_v_pressed`) - proving the press-latch swallows the wobble that
  would otherwise re-fire the key on every 0->1.
- **G6b** — the OSK panel appears in >= 75% of the monitored APF display
  frames (white > 1000 px in the panel line range; >= 20 observed frames).
- **G6c** — the APF dpad UP then LEFT taps move the cursor (1,1)->(0,0)
  (verifies the dpad bit-reversal fix).

`apple2e_osk.v` also draws a **debug button-indicator strip** while the
OSK is open: 16 2-px blocks (1-px gap) in the panel's empty bottom
margin (panel lines 92..93), block N lit while cont1 bit N reads
pressed — the on-hardware polarity/bit-map diagnostic (see
PLAN_POCKET_CORE.md, P2b entry). `tb_p2b_shots.sv` is the image-rendering
harness: it writes 1-bit text grids (rows of 0/1) for one APF output
frame, the machine-domain OSK-composited frame, and both ping-pong
capture buffers to `shots/*.txt` (the machine frame is captured
~1.802-1.819 s and includes a fire press at 1.81 s so the strip shows
lit in `machine.png`); `shots_txt2png.py` (pure-stdlib PNG writer, no PIL
needed) converts them to `shots/*.png`. Run from the Apple-II_MiSTer
root (the machine ROMs are CWD-relative), then
`python apple2e-pocket/verilog/shots_txt2png.py` from the pocket repo
root.

**Status 2026-10-18: PASS** (frames=198, G5 racy_cycles=591 bounded,
G6a clean+wobble each = 1 press, G6b panel 70/70 display frames, G6c
dpad UP+LEFT -> (0,0)). The APF "panel missing from one buffer" sim bug
was a `pix_ram` sizing error (see PLAN_POCKET_CORE.md, P2b entry) —
fixed, both buffers now hold the panel. The dpad-rotation + "many same
key" hardware reports were fixed by the dpad bit-reversal + press-latch
with release confirmation (2026-10-18). Hardware re-test pending (owner
compiles + restages).
