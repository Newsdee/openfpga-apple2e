#!/bin/sh
# run_tb_floppy_sound.sh - build + run the donor-level floppy sound TB
# (tb_floppy_sound.sv, PLAN_FLOPPY_SOUND_PORT section 4.2 items a-c).
#
# Pure donor-level TB: src/fpga/core/sound/floppy_sound.sv + TB, no
# engine, no speaker_i2s. Same environment facts as the other
# verilog/ runners (native make shim, TMP export, VERILATOR_ROOT,
# --binary --timing for the pure self-driving TB).
#
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_floppy_sound.sh
set -u
export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")" || exit 1
ROOT=..

# make.exe shim (verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

MD=obj_dir_tb_floppy_sound
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_floppy_sound.exe"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_floppy_sound \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/core/sound/floppy_sound.sv" \
    tb/tb_floppy_sound.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    tail -25 "$MD/build.log"
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe; check $MD/build.log)"
    tail -25 "$MD/build.log"
    exit 1
fi

# AV note: a freshly linked PE can be killed mid-session (exit 127, no
# output); relinking once usually buys a fresh window.
"$EX" > "$MD/run.log" 2>&1
rc=$?
tail -40 "$MD/run.log"
if [ "$rc" -eq 0 ] && grep -q "FLOPPY SOUND TB ALL CHECKS PASSED" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
