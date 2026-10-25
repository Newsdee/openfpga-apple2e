# Build 2026-10-25_1937_phaseb_fileinit

## Identity
- **Logic:** identical to the 17:24 J12 build (0.2.2: disk-proven base + J8
  Y-flip + J10 hardwired Absolute + J11 OSK-gated overlay + J12 drive LEDs,
  OVL_DEBUG=1). The ONLY change: **Phase B** of TASK_RAM_FILE_INITIALIZATION
  - the nested 256x256 procedural RAM zero loops in
  apf_stream_video_top.v replaced by two $readmemh of the canonical
  src/fpga/rtl/roms/ram_zero_64k.hex (65,536 x "00"); ram_init_i/j removed;
  runtime clearing sweep untouched. pocket_boot build.sh stages the image
  + preflight.
- **Purpose:** Phase C full-core measurement of the file-init optimization.

## Artifacts
| File | SHA-256 | Size |
|---|---|---|
| `apf_stream_video.rbf` | `990086736e621c498d03ff01087508f93d139e5b36491f9e2bae5fb66074237b` | 1,620,504 |
| `bitstream.rbf_r` | `c10f49eb6ba781e497935b860d3cc7353850890154f4ebf26c77cc4b6a520c8f` | 1,620,504 |

## Quartus (flow complete ~19:37, 0 errors)
| Stage | 17:23 (loop init) | this build (file init) |
|---|---|---|
| A&S | 25:55 (CPU 26:40) | **2:14 (CPU 3:16)** |
| Fitter | 3:53 | 4:40 |
| **Total flow** | 30:15 | **7:24** |

- A&S **11.7x faster**; total flow 4.1x faster.
- ram_main/ram_aux both inferred altsyncram 65,536x8 with generated MIF
  init files (db/apf_stream_video.ram0/ram1_stream_video_core_top_8d2d0ebd.hdl.mif).
- Resources BIT-IDENTICAL to the 17:23 snapshot: 8,060/18,480 ALM, 6,696
  regs, 1,527,836 mem bits (the gate), 4 DSP.
- Timing identical: 80/80 TNS 0.000, mp2 worst 0.978 ns @85C.
- OVL_DBG = 1 confirmed in map.rpt.
- Synthesis provably processed the changed RTL (fresh A&S + MIF generation).

## Hardware test (pending at archive time)
Owner checklist: first power-on boot + "Reboot on load" with DOS 3.3 /
Jungle Hunt; disk boot; LEDs; joystick. If all hold, the file-init change
is released (Phase C complete). Sim smoke/matrix run still pending the
host AV block at compile time (re-run `phase_a_run.bat sim` +
`verilog/pocket_boot/obj_dir/Vtb_pocket_boot.exe --smoke +PDLPROBE=1`).
