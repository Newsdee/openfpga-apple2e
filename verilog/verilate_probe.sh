#!/usr/bin/env bash
# verilate_probe.sh - build the P2a native-video geometry probe (MSYS2 UCRT64).
#
# Instantiates the unmodified machine core from Apple-II_MiSTer/rtl (in place,
# like the other harnesses reference their sources) with tb/tb_native_probe.sv.
# Pure self-driving TB -> verilator --binary --timing (AGENTS.md build facts).
#
# The built exe must RUN with CWD = Apple-II_MiSTer/ repo root (the DUT's
# $readmemh paths "rtl/roms/*.hex" are CWD-relative).
#
# Usage:  verilate_probe.sh [clean]
set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
MISTER=../../Apple-II_MiSTer

# make.exe shim (AGENTS.md: verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir_probe
    exit 0
fi

[ -d "$MISTER/rtl" ] || { echo "missing machine sources: $MISTER/rtl"; exit 1; }

verilator_bin --binary --timing -j 4 \
    --top tb_native_probe \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir obj_dir_probe \
    $MISTER/rtl/apple2.v \
    $MISTER/rtl/timing_generator.v \
    $MISTER/rtl/video_generator.v \
    $MISTER/rtl/rom.v \
    $MISTER/rtl/ramcard.v \
    $MISTER/rtl/cpu/nmos6502/cpu_65c02.sv \
    $MISTER/rtl/cpu/nmos6502/cpu_alu.sv \
    $MISTER/rtl/cpu/wdc65c02/cpu_65c02.sv \
    $MISTER/rtl/cpu/wdc65c02/cpu_alu.sv \
    tb/tb_native_probe.sv

echo "build ok: obj_dir_probe/Vtb_native_probe (run with CWD = Apple-II_MiSTer root)"
