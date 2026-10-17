#!/usr/bin/env bash
# verilate_apple2e.sh - build the Apple IIe Pocket core smoke harness with
# Verilator (MSYS2 UCRT64). Same environment facts as verilate.sh (see
# Apple-II_FPGAdev AGENTS.md, "Verilator harness builds").
#
# Builds `apf_top` with the apple2e `core_top` (core/apple2e/apple2e_core_top.v)
# and the apple2e PLL tree (core/apple2e/apple2e_pll.v). The template core_top
# and mf_pllbase are NOT included (module-name collision on "core_top").
#
# Usage:  verilate_apple2e.sh [clean] [extra verilator args...]
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
    rm -rf obj_dir_apple2e apf_top_apple2e_sim.v
    exit 0
fi

# ---------------------------------------------------------------------------
# sim-only copy of apf_top.v: widen the two nets Verilator rejects on inout
# width (see verilate.sh). Regenerated from the template on every build.
# ---------------------------------------------------------------------------
perl -pe '
  s/^wire    \[3:0\]   scal_ddio_ctrl;\r?$/wire    [11:0]   scal_ddio_ctrl;\r/;
  s/^mf_ddio_bidir_12 isclk\(\r?$/wire    [11:0]  scal_clk_padio;\r\nassign scal_clk = scal_clk_padio[0]; \/\/ sim: bit0 carries the DDR clock pattern (datain_h=1 -> 0x001)\r\nmf_ddio_bidir_12 isclk(\r/;
  s/^    \.padio \( scal_clk \)\r?$/    .padio ( scal_clk_padio )\r/;
' $ROOT/src/fpga/apf/apf_top.v > apf_top_apple2e_sim.v
grep -q scal_clk_padio apf_top_apple2e_sim.v || { echo "apf_top_apple2e_sim.v patch failed"; exit 1; }

verilator_bin --binary --timing -j 4 \
    --top tb_apple2e_smoke \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir obj_dir_apple2e \
    apf_top_apple2e_sim.v \
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
    tb/tb_apple2e_smoke.sv

echo "build ok: obj_dir_apple2e/Vtb_apple2e_smoke"
