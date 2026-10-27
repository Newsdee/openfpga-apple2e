#!/usr/bin/env bash
# run_hdv_bridge.sh - build + run the HDV bridge harness (Verilator --binary).
#
# Environment facts (AGENTS.md "Verilator harness builds"):
#  - native mingw32-make via make.exe shim (MSYS make strips TMP)
#  - TMP/TEMP/TMPDIR exported inside the shell
#  - VERILATOR_ROOT exported (verilator_bin needs verilated_std.sv)
#  - C:/msys64/usr/bin on PATH + SHELL=sh for verilated.mk POSIX recipes
#  - pure self-driving TB: --binary (not --exe) provides main + sc_time_stamp
#
# Usage:  run_hdv_bridge.sh [clean]
set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
ROOT=../..                     # apple2e-pocket/

# make.exe shim (verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir
    exit 0
fi

/c/msys64/ucrt64/bin/verilator_bin.exe \
    --binary --timing -Wno-fatal \
    --Mdir obj_dir \
    -sv \
    tb_hdv_bridge.sv \
    "$ROOT/src/fpga/core/hdv_bridge.sv" \
    "$ROOT/src/fpga/core/hdd.v" \
    "$ROOT/src/fpga/core/hdd_rom.v"

# a zero-byte _ALL.cpp from an interrupted run breaks the link
f=obj_dir/Vtb_hdv_bridge__ALL.cpp
[ -f "$f" ] && [ ! -s "$f" ] && rm -f "$f"

make -C obj_dir -f Vtb_hdv_bridge.mk -j4 Vtb_hdv_bridge

# run (CWD-relative $readmemh paths: hdd_rom reads rtl/roms/hddrom.hex)
mkdir -p rtl/roms
cp -f "$ROOT/src/fpga/rtl/roms/hddrom.hex" rtl/roms/hddrom.hex
./obj_dir/Vtb_hdv_bridge.exe
