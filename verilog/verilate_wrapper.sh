#!/usr/bin/env bash
# verilate_wrapper.sh - build the wrapper-level keyboard/reset integration
# harness (tb_wrapper_kbd) with Verilator (MSYS2 UCRT64).
#
# Like verilate_apple2e.sh, but:
#   * top = tb_wrapper_kbd (the keyboard/reset integration test)
#   * machine sources come from the LOCAL ../machine/ folder (the
#     self-contained Pocket build, finding 7) - NOT the sibling MiSTer rtl/.
#     This is what Quartus compiles, so the sim validates the built code
#     (including the $C000 read-ack flood fix in machine/apple2.v).
#   * OSK uses the canonical machine/osk/ files (Verilator handles the
#     SystemVerilog casts; the Q17 variants are Quartus-only).
#
# The built exe must RUN with CWD = Apple-II_MiSTer/ repo root (the DUT's
# $readmemh paths "rtl/roms/*.hex" are CWD-relative).
#
# Usage:  verilate_wrapper.sh [clean]
set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
ROOT=..

# make.exe shim (AGENTS.md: verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir_wrapper apf_top_wrapper_sim.v
    exit 0
fi

# sim-only copy of apf_top.v: widen the two nets Verilator rejects on inout
# width (same transform as verilate_apple2e.sh).
perl -pe '
  s/^wire    \[3:0\]   scal_ddio_ctrl;\r?$/wire    [11:0]   scal_ddio_ctrl;\r/;
  s/^mf_ddio_bidir_12 isclk\(\r?$/wire    [11:0]  scal_clk_padio;\r\nassign scal_clk = scal_clk_padio[0]; \/\/ sim: bit0 carries the DDR clock pattern (datain_h=1 -> 0x001)\r\nmf_ddio_bidir_12 isclk(\r/;
  s/^    \.padio \( scal_clk \)\r?$/    .padio ( scal_clk_padio )\r/;
' $ROOT/src/fpga/apf/apf_top.v > apf_top_wrapper_sim.v
grep -q scal_clk_padio apf_top_wrapper_sim.v || { echo "apf_top_wrapper_sim.v patch failed"; exit 1; }

verilator_bin --binary --timing -j 4 \
    --top tb_wrapper_kbd \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir obj_dir_wrapper \
    ../machine/apple2.v \
    ../machine/timing_generator.v \
    ../machine/video_generator.v \
    ../machine/rom.v \
    ../machine/ramcard.v \
    ../machine/apple2_font_rom.v \
    ../machine/keyboard.v \
    ../machine/osk/virtual_keyboard_controller.sv \
    ../machine/osk/virtual_keyboard_overlay.sv \
    ../machine/cpu/nmos6502/cpu_65c02.sv \
    ../machine/cpu/nmos6502/cpu_alu.sv \
    ../machine/cpu/wdc65c02/cpu_65c02.sv \
    ../machine/cpu/wdc65c02/cpu_alu.sv \
    $ROOT/src/fpga/core/apple2e/apf_video.v \
    $ROOT/src/fpga/core/apple2e/apple2e_osk.v \
    apf_top_wrapper_sim.v \
    $ROOT/src/fpga/apf/common.v \
    $ROOT/src/fpga/apf/io_bridge_peripheral.v \
    $ROOT/src/fpga/apf/io_pad_controller.v \
    $ROOT/src/fpga/apf/mf_datatable.v \
    $ROOT/src/fpga/apf/mf_ddio_bidir_12.v \
    $ROOT/src/fpga/core/apple2e/apple2e_core_top.v \
    $ROOT/src/fpga/core/apple2e/apple2e_pll.v \
    $ROOT/src/fpga/core/core_bridge_cmd.v \
    stubs/altera_pll_sim.v \
    stubs/altsyncram_sim.v \
    stubs/altddio_bidir_sim.v \
    tb/tb_wrapper_kbd.sv

echo "build ok: obj_dir_wrapper/Vtb_wrapper_kbd (run with CWD = Apple-II_MiSTer root)"
