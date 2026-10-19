#!/usr/bin/env bash
# verilate_p2a.sh - build the P2a machine + APF video adapter harness.
#
# Unmodified machine core (Apple-II_MiSTer/rtl, referenced in place) +
# src/fpga/core/apple2e/apf_video.v, driven by tb/tb_apf_video.sv.
# Pure self-driving TB -> verilator --binary --timing (AGENTS.md build facts).
#
# The built exe must RUN with CWD = Apple-II_MiSTer/ repo root (the DUT's
# $readmemh paths "rtl/roms/*.hex" are CWD-relative).
#
# Usage:  verilate_p2a.sh [clean]
set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
MISTER=../../Apple-II_MiSTer
MACHINE=../machine
CORE=../src/fpga/core/apple2e

# make.exe shim (AGENTS.md: verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir_p2a
    exit 0
fi

[ -d "$MISTER/rtl" ] || { echo "missing machine sources: $MISTER/rtl"; exit 1; }
[ -f "$CORE/apf_video.v" ] || { echo "missing $CORE/apf_video.v"; exit 1; }

verilator_bin --binary --timing -j 4 \
    --top tb_apf_video \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir obj_dir_p2a \
    $MACHINE/apple2.v \
    $MACHINE/timing_generator.v \
    $MACHINE/video_generator.v \
    $MACHINE/rom.v \
    $MACHINE/ramcard.v \
    $MACHINE/apple2_font_rom.v \
    $MACHINE/keyboard.v \
    $MACHINE/osk/virtual_keyboard_controller.sv \
    $MACHINE/osk/virtual_keyboard_overlay.sv \
    $MACHINE/cpu/nmos6502/cpu_65c02.sv \
    $MACHINE/cpu/nmos6502/cpu_alu.sv \
    $MACHINE/cpu/wdc65c02/cpu_65c02.sv \
    $MACHINE/cpu/wdc65c02/cpu_alu.sv \
    $CORE/apf_video.v \
    $CORE/apple2e_osk.v \
    tb/tb_apf_video.sv

echo "build ok: obj_dir_p2a/Vtb_apf_video (run with CWD = Apple-II_MiSTer root)"
