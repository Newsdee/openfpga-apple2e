# Verilator boot-debug harness (`verilog/pocket_boot/`) — 2026-10-21

Built after the "still not booting" hardware report: a full-DUT Verilator
simulation of `stream_video_core_top` (the exact Pocket core) with an APF
host-bridge model, SDRAM model, frame grabber, and SDL2 video output, so the
WOZ boot sequence can be watched and debugged in simulation before
hardware.

## Layout

| file | role |
|---|---|
| `tb_pocket_boot.sv` | DUT (`stream_video_core_top`) + 5 clocks + host-bridge protocol (0x0010/0x0011 reset, 0x0082/0x008F WOZ load) + frame grabber + diagnostic taps (`machine_reset`, `pll_core_locked`, `stor_init_done`, `mc_img_mounted`→`d_mt`, `d_ac`, `d_mo`, `d_reads`…) |
| `pocket_main.cpp` | C++ main: WOZ→hex conversion (+`WOZSIZE` plusarg), SDL2 window (nearest-neighbor), `--smoke` headless mode (PPM frames in `pocket_boot_shots/`), keys F7 shot / F8 host reset / F9 re-run cycle / F10 cycle seq mode |
| `build.sh` | verilator `--cc --timing` build. Also regenerates `mf_pllbase_sim.v` / `mf_datatable_sim.v` (timescale patches, see below) |
| `run_pocket_boot.bat` | convenience launcher |
| `../tb/tb_dram_model.sv` | shared 4-bank mobile-SDRAM model (also used by the M0 storage TBs) |
| `../stubs/altera_pll_sim.v` | NCO PLL stub — now with an SDRAM-PLL mode (see below) |

## Build / run

```bash
# from apple2e-pocket/verilog/pocket_boot (MSYS2 ucrt64, same env as the
# unit-test ladder: makeshim make, VERILATOR_ROOT, sh as make SHELL)
bash build.sh
g++ -O2 -o obj_dir/Vtb_pocket_boot.exe obj_dir/pocket_main.o \
    obj_dir/libVtb_pocket_boot.a obj_dir/libverilated.a \
    obj_dir/Vtb_pocket_boot__ALL.a -lSDL2 -lopengl32 -lgdi32 -limm32

./obj_dir/Vtb_pocket_boot.exe                 # interactive SDL window
./obj_dir/Vtb_pocket_boot.exe --smoke         # headless: frames + diagnostics
./obj_dir/Vtb_pocket_boot.exe --smoke --budget-ms 2000   # longer sim budget
./obj_dir/Vtb_pocket_boot.exe --seq after --smoke       # reset-ordering variant
./obj_dir/Vtb_pocket_boot.exe --dramtrace --smoke       # SDRAM command trace
```

Notes: `disk.woz` in the folder is the image (copied from
`sd_root/Assets/apple2e/common/DOSMaster.woz`); `rtl/roms/*.hex` must exist
in the CWD (staged). First launch of a freshly linked exe can be AV-killed —
relaunch.

## What the boot sequence does in sim

1. t=2 ms: host issues Reset Enter (seq `around`), then the WOZ 0082 begin,
   58624 words via the bridge slot ports, 008F complete.
2. Reset released (~9 ms sim at default pace): `mrs` drops, machine runs ROM.
3. First video frame ~12 ms; frames keep coming (~250 fps counter rate).
4. Load+verify: coordinator runs load → drain → readback verify; the result
   (`res_valid`/`res_code`, host domain) syncs to the machine domain and
   `woz_mount_ctl` mounts on the OK rising edge (state ST_UNMOUNTED→
   ST_MOUNTED, `mc_img_mounted`=1). At default host pace this completes
   ~89 ms (verify reads the whole image back at ~1.2M words/s).
5. The WOZ engine sees the mount, scans the image, starts serving transport
   reads (`d_reads` counts `sd_buff_wr` bytes).
6. ROM logo animation (~0.18 s machine time at the 14.318 MHz machine clock),
   then the monitor boots from the mounted image: more `d_reads`, DOS 3.3
   text screen in the video output.

### Host pacing (required — sim artifact otherwise)

The TB host must pace word writes below the store's drain rate:
`load_pace` (public reg, default 40 idle 74a cycles/word → 48 cycles ≈
3.7M words/s). `disk_store` consumes one word per ~22 ctrl cycles (~6M
words/s, incl. ACT/2×WRITE/PRECHG + refresh pauses — inherent to the
pinned io_sdram word port, same in hardware). The unpaced TB wrote at
9.3M words/s, outran the store, overflowed the 256-deep slot FIFO and the
coordinator latched FAIL-OV — the mount ctl then correctly refused to
mount (it only mounts on `res_code==0`) and the machine never saw the
floppy. That failure mode is a sim artifact (the real APF host paces below
drain rate; M0 loads succeed on hardware), so the harness paces by
default. If a run shows `HOST rv 0->1 rc 01` (FAIL) early in a load, the
pace is too fast — raise `load_pace`.

### Main-loop time advance (Verilator 5 --timing)

When the event queue empties at the current time, `eventsPending()` is
false and time does not advance by itself: the loop must advance
`ctx->time(top->nextTimeSlot())` before the next `eval()`. Without that
the harness stalls (or, with the original loop, exited) the moment the
queue drained — which first happened exactly when the WOZ scan started.

## Infrastructure fixes made to get a truthful boot sim

All fixes are in **sim-only files**; pinned/production RTL untouched.

1. **Verilator context time is picoseconds.** With mixed `1ns/10ps`
   timescales the model unifies to 1 ps: generated delays are ps-scaled
   (`#4000` → `delay(4000000)`), and `VerilatedContext::time()` returns ps.
   The C++ originally treated it as ns, so the "20 ms" smoke window was 20 µs
   and the 2 ms auto-boot was never reached. `pocket_main.cpp` now treats
   time as ps (log/display/budget constants rescaled).

2. **`altera_pll_sim.v` only knew the machine-PLL frequencies.** The stub
   hardwired NCO steps for 14.318/12.288/12.288/3.072 MHz (the `apple2e_pll`
   instance) but is also elaborated for the SDRAM PLL (`apple2e_sdram_pll`,
   `number_of_clocks=3`), whose outputs must be three 133.12 MHz clocks
   (ctrl 0°, chip 180°, clk90 90°). The stub fed the SDRAM domain
   14.318/12.288 MHz instead — two *different* frequencies — so controller
   commands (e.g. the per-word PRECHG after a burst/word write) fell entirely
   between the model's sampling edges and vanished. Fix: `SD_MODE`
   (`number_of_clocks == 3`) generates free-running 2×refclk = 133.12 MHz
   clocks with exact 0/180/90° phases. The DUT and DRAM model are fully
   cycle-based, so cycle behavior is identical; only the sim-time↔wall-time
   ratio of that domain differs from hardware.
   (A 24-bit NCO can't exceed refclk/2, hence the free-running generation.)

3. **`tb_dram_model.sv` timing constants** (the model previously enforced a
   stricter window than the M0-proven pinned controller):
   - `T_RFC` 12→11: the controller clears a refresh with an 11-command-cycle
     gap (observed: ACT at `ref_cnt=1` with a 12-cycle window); 11 cycles =
     82.6 ns @133.12 MHz, inside mobile-SDRAM tRFC spec.
   - `T_RCD` 3→2: the burst-write path (`ST_BURSTWR_0..2`) spaces ACT→WRITE
     by 2 cycles (word paths provide 3). Hardware-proven, so the model
     follows.
   - All counter checks compare against `(T−1)`: commands are sampled 1
     cycle after the controller drives them (1.5 ns `TD_CMD`), so a counter
     zeroed on the sampling cycle reads `S−1` for a true spacing `S`;
     checking `< T−1` enforces exactly "next command ≥ T cycles later".

4. **Verilator plusargs are compile-time** in this flow (`$test$plusargs`
   and even `$value$plusargs` were constant-folded against the *verilator*
   command line). Runtime knobs therefore go through TB ports: e.g.
   `trace_req` (drives the SDRAM command trace, `--dramtrace`).

Also: `mf_pllbase.v` / `mf_datatable.v` (APF templates, `timescale 1ps/1ps`)
are copied to `*_sim.v` with a 1 ns timescale by `build.sh` — a ps-timescale
file poisons Verilator's mixed-timescale delay handling for the whole model
(delays reinterpret ×1000). Both templates contain no `#` delays, so the
patch is behavior-neutral.

## Diagnostics

- Console line every 1 ms sim: `t` (ms), `frames`, `host` state,
  `res82/res8f` (load results), `mrs` (machine reset), `rstn`, `pll`
  (NCO lock), `init` (SDRAM boot_done), `MT AC MO` (WOZ mount/access/motor),
  `RD` (transport read count), `e74a` (bridge-clock edge counter — a rate
  sanity check: must be 74.25 MHz).
- `pocket_boot_shots/f???_NNNNNN.ppm` — last 3 frames; `long_NNNN.ppm` —
  every 200 frames (boot-sequence review). Convert with the PPM header
  `P6\n<w> <h>\n255\n` (multi-line).
- `dram_cmd_trace.log` (`--dramtrace`) — every non-NOP SDRAM command with
  tick/bank/ref state, at chip posedges and negedges.

## Known limits

- Sim speed ≈ 0.9 ms machine-time per wall-second on this host (~1125×);
  a full 2 s machine-time boot run ≈ 35–40 min wall.
- Frame grabber captures the active region only (560×192 for NTSC here).
- The SDRAM-PLL sim clocks are free-running (not NCO-derived): absolute
  sim-time ratios differ from hardware; cycle relationships (2-phase, 90°)
  are exact.
