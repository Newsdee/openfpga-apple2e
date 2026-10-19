#!/usr/bin/env bash
# verilate_phase2_shots.sh - build the PHASE 2 video-path capture harness.
#
# Machine core + OSK + apf_stream_video (the no-buffer streaming adapter),
# driven by tb/tb_phase2_shots.sv. Dumps 24-bit color frames of the exact
# signals that go to the APF in the Phase 2 hardware build, plus APF
# contract checks (RGB=0 outside DE, 1-cycle HS/VS, HS>=3 after VS).
#
# Pure self-driving TB -> verilator --binary --timing (AGENTS.md build facts).
#
# The built exe must RUN with CWD = Apple-II_MiSTer/ repo root (the DUT's
# $readmemh paths "rtl/roms/*.hex" are CWD-relative).
#
# Usage:  verilate_phase2_shots.sh [clean]
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
    rm -rf obj_dir_phase2
    exit 0
fi

[ -d "$MISTER/rtl" ] || { echo "missing machine sources: $MISTER/rtl"; exit 1; }
[ -f "$CORE/apf_stream_video.v" ] || { echo "missing $CORE/apf_stream_video.v"; exit 1; }

verilator_bin --binary --timing -j 4 \
    --top tb_phase2_shots \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir obj_dir_phase2 \
    $MACHINE/apple2.v \
    $MISTER/rtl/timing_generator.v \
    $MISTER/rtl/video_generator.v \
    $MISTER/rtl/rom.v \
    $MISTER/rtl/ramcard.v \
    $MISTER/rtl/apple2_font_rom.v \
    $MISTER/rtl/keyboard.v \
    $MISTER/rtl/osk/virtual_keyboard_controller.sv \
    $MISTER/rtl/osk/virtual_keyboard_overlay.sv \
    $MISTER/rtl/cpu/nmos6502/cpu_65c02.sv \
    $MISTER/rtl/cpu/nmos6502/cpu_alu.sv \
    $MISTER/rtl/cpu/wdc65c02/cpu_65c02.sv \
    $MISTER/rtl/cpu/wdc65c02/cpu_alu.sv \
    $CORE/apf_stream_video.v \
    $CORE/apple2e_osk.v \
    tb/tb_phase2_shots.sv

echo "build ok: obj_dir_phase2/Vtb_phase2_shots (run with CWD = Apple-II_MiSTer root)"
