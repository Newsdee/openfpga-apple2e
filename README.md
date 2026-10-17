# Apple IIe for Analogue Pocket (openFPGA)

Analogue Pocket (openFPGA/APF) core for the Apple IIe, built on
`open-fpga/core-template` v1.3.0 (commit `da3a021`). Machine RTL is a
byte-identical copy of the `Apple-II_MiSTer` project (see
`check_machine_sync.sh`); the machine + APF bridge + video adapter live in
this repo so the Quartus project is self-contained.

## Status (2026-10-17)

- **P0 toolchain** — template compiles on Quartus 17.0.2 Lite
  (Cyclone V `5CEBA4F23C8`), `.rbf` -> `.rbf_r` conversion, SD staging. Done.
- **P1 shell** — PLL tree (74.25 MHz x2, 12.288 MHz video, 14.312 MHz
  machine), I2S, bridge, KB-014-clean test-pattern video. Hardware-verified.
- **P2a machine** — real Apple IIe boots: 65C02 + BIOS + 64K RAM +
  `apf_video` adapter (native 1-bit video -> APF 400x512 @ 12.288 MHz).
  Boots to the Apple logo, then the `Ready.` prompt. Hardware-verified,
  including the fix for the intermittent duplicate-screen (ping-pong
  buffer-race) glitch.

Next: floppy (disk_ii, single drive, 16 KiB track RAM), keyboard (OSK),
speaker. Plan: `docs/porting/PLAN_POCKET_CORE.md` in the parent FPGA
workspace (not in this repo).

## Layout

```
src/fpga/            Quartus project (apple2e_core.qsf; template ap_core.qsf
                     retained for P0 regression)
  apf/               APF shell (template, unmodified)
  core/apple2e/      apple2e_core_top.v, apple2e_pll.v, apf_video.v (+ SDC)
  rtl/roms/          ROM hexes (apple2e.hex, video2.hex) for Quartus CWD
machine/             byte-identical machine RTL (Apple-II_MiSTer/rtl)
verilog/             Verilator harnesses (tb/, stubs/, build+run bats)
sd_root/             SD-card staging (Cores/Newsdee.Apple2e, Platforms)
output/              generated bitstream.rbf_r (gitignored)
tools/rbf2rbf_r.py   .rbf -> .rbf_r (bit-reversal) converter
p0_build.bat         compile -> convert -> stage (full flow)
```

## Build (Windows, Quartus 17.0.2 on PATH)

```bat
:: full flow: Quartus compile + .rbf_r conversion + SD staging
p0_build.bat

:: or, open in the Quartus UI:
src/fpga/apple2e_core.qsf
```

## Sim (MSYS2 UCRT64)

```sh
cd verilog
bash verilate_p2a.sh          # machine + apf_video harness (tb_apf_video.sv)
cmd //c run_p2a_verilator.bat # run (CWD = Apple-II_MiSTer root for ROMs)
bash verilate_apple2e.sh && cmd //c run_apple2e_verilator.bat  # P1 smoke
```

See `verilog/README.md` for the full harness list (P0/P1/P2a, geometry
probe, RAM-inference minimal repro in `ramtest/`).

## Provenance / licensing

- APF shell: `open-fpga/core-template` (Analogue openFPGA program).
- Machine RTL: `Apple-II_MiSTer` project (Newsdee).
- ROMs: `apple2e.hex` (Apple IIe BIOS), `video2.hex` (video ROM).
