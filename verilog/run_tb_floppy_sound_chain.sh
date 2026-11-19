#!/bin/sh
# run_tb_floppy_sound_chain.sh - build + run the floppy-sound PORT gate
# (tb_floppy_sound_chain.sv, PLAN_FLOPPY_SOUND_PORT_2026-11-19.md).
#
# DUT: the real floppy_sound donor + the real speaker_i2s mixer (I2S word
# decoder in the TB). Proves the integration: zero-idle bit-identity,
# event->audible words, pan routing, saturating mix. Donor-level physics
# (hum/clunk/knock/gain/pan) are in run_tb_floppy_sound.sh.
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_floppy_sound_chain.sh
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

MD=obj_dir_tb_floppy_sound_chain
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_floppy_sound_chain.exe"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_floppy_sound_chain \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/core/sound/floppy_sound.sv" \
    "$ROOT/src/fpga/core/apple2e/speaker_i2s.v" \
    tb/tb_floppy_sound_chain.sv > "$MD/build.log" 2>&1; then
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
if [ "$rc" -eq 0 ] && grep -q "FLOPPY SOUND CHAIN TB ALL CHECKS PASSED" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
