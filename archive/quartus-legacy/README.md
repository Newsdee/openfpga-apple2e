# Retired Quartus projects (2026-10-20)

Kept for reference only - do NOT compile these. The single active Quartus
project is `src/fpga/apf_stream_video` (top `apf_top_st`): it contains the
streaming video path, OSK, M0 SDRAM storage, and the status overlay. Every
feature that ever shipped on hardware landed there; the projects below are
superseded earlier generations.

| Project | Top | Was |
|---|---|---|
| `ap_core` | `apf_top` | P0 basicassets toolchain skeleton (reference core, not Apple IIe) |
| `apple2e_core` | `apf_top` | P2a non-streaming core (superseded by the streaming architecture) |
| `apf_stream_proto` | `apf_top_p` | Phase-1 streaming pattern/PLL prototype (absorbed into `apf_stream_video.v`) |

They were retired because all of them (except `ap_core`) wrote to the same
`output_files_apple2e` directory as the active project - stale RBFs/reports
from a legacy compile could be mistaken for the current build (the M0
bitstream-provenance hazard). One project = one RBF path.

The legacy tops/RTL remain in-tree under `src/fpga/` and are still used by
the Verilator harnesses (`verilog/verilate_apf_stream_proto.sh`,
`verilog/verilate_apple2e.sh`, `verilog/verilate_wrapper.sh`).

Future build variants belong in as parameters of `apf_stream_video`
(see the `DEC2X` pattern), not new Quartus projects.

Also retired (2026-10-20):
- `scripts/` - the build bats for the retired projects (`apple2e_build.bat`,
  `apf_stream_proto_build.bat`, `p0_build.bat`); they point at the moved QSFs.
  The current build entry point stays at the repo root:
  `apf_stream_video_build.bat`.
- `../sd-legacy/` - stale SD core packages `Newsdee.Apple2e` (P2a, stale
  1.5 MB RBF) and `Newsdee.Apple2eStreamProto` (Phase 1, stale RBF). They
  were moved out of `sd_root/Cores/` so a full sd_root copy to the Pocket SD
  card cannot stage obsolete bitstreams. The live package is
  `sd_root/Cores/Newsdee.Apple2eStreamVideo/`.
