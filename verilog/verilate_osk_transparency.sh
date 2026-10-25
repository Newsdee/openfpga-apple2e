#!/usr/bin/env bash
# verilate_osk_transparency.sh - NTSC colour-path glue test
#
# Builds and runs tb_osk_rgb_transparency: proves that apple2e_osk with the new
# RGB_IN=1 parameter passes a CHROMATIC background through bit-exactly (colour
# is not collapsed to luma by the overlay), and that RGB_IN=0 - the default every
# pre-existing caller relies on - still produces the original 1-bit expansion
# video_in ? 24'hFFFFFF : 24'h000000.
#
# This exists because the boot harness cannot answer the question: DOS 3.3 boots
# to 40-column TEXT, which is monochrome on a real Apple II, so the integrated
# run measures max channel spread 0 whether or not the decoder works.
#
# Uses the CANONICAL machine/osk/ sources (Verilator handles the SystemVerilog
# casts); the _q17 variants are Quartus-only, per verilate_wrapper.sh.
#
# Usage:  verilate_osk_transparency.sh [clean]
# Exit:   0 = PASS, nonzero = FAIL / build error / non-vacuity gate tripped
set -uo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"          # verilog/
ROOT=..                        # repo root
OBJ=obj_dir_osk_transparency
TB=tb_osk_rgb_transparency

mkdir -p /c/msys64/tmp/makeshim
cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe 2>/dev/null || true

if [ "${1:-}" = "clean" ]; then
    rm -rf $OBJ osk_transparency_build.log osk_transparency_mk.log
    exit 0
fi

# --binary (not --exe): self-driving SV testbench with no C++ main, and --binary
# supplies the sc_time_stamp() stub that a --timing link needs.
verilator_bin --binary --timing -j 4 \
    --top $TB \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    --Mdir $OBJ \
    $ROOT/machine/keyboard.v \
    $ROOT/machine/apple2_font_rom.v \
    $ROOT/machine/rom.v \
    $ROOT/machine/osk/virtual_keyboard_controller.sv \
    $ROOT/machine/osk/virtual_keyboard_overlay.sv \
    $ROOT/src/fpga/core/apple2e/apple2e_osk.v \
    tb/$TB.sv \
    > osk_transparency_build.log 2>&1
vrc=$?
if [ $vrc -ne 0 ]; then
    echo "verilator build FAILED (see osk_transparency_build.log)"; tail -30 osk_transparency_build.log; exit 1
fi

# relink and launch in ONE command: the host AV layer deletes freshly linked PEs
# after a short grace window (workspace AGENTS.md, unit-test ladder facts).
( cd $OBJ && rm -f V$TB V$TB.exe && \
  /c/msys64/ucrt64/bin/mingw32-make.exe -f V$TB.mk V$TB > ../osk_transparency_mk.log 2>&1 && \
  ./V$TB.exe )
rc=$?
if [ $rc -ne 0 ]; then
    if [ -s osk_transparency_mk.log ]; then tail -20 osk_transparency_mk.log; fi
    echo "run FAILED (exit $rc). If there was no output at all, suspect the host"
    echo "AV grace window: re-run this script (it relinks and launches together)."
fi
exit $rc
