#!/bin/sh
# run_tb_savestate_manager.sh - build + run the savestate_manager unit gate.
#
# Environment facts (Apple-II_FPGAdev AGENTS.md, "Verilator harness builds"
# + apple2e-pocket/AGENTS.md): native mingw32-make via the make.exe shim,
# TMP/TEMP/TMPDIR exported inside the shell, VERILATOR_ROOT exported,
# C:/msys64/usr/bin on PATH + SHELL=sh (verilated.mk POSIX recipes),
# pure self-driving TB -> --binary --timing (not --exe).
#
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_savestate_manager.sh
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

MD=obj_dir_tb_savestate_manager
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_savestate_manager.exe"

rm -f "$EX"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_savestate_manager \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/core/apple2e/savestate_manager.sv" \
    tb/tb_savestate_manager.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    tail -5 "$MD/build.log"
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe; check $MD/build.log)"
    tail -5 "$MD/build.log"
    exit 1
fi

# AV note: a freshly linked PE can be killed mid-session (exit 127, no
# output); relinking once usually buys a fresh window.
"$EX" > "$MD/run.log" 2>&1
rc=$?
tail -25 "$MD/run.log"
if grep -q "SAVESTATE MANAGER TB: PASS" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
