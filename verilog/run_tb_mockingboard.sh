#!/bin/sh
# run_tb_mockingboard.sh - build + run the Mockingboard card-level gate
# (tb_mockingboard.sv, PLAN_MOCKINGBOARD_PORT section 6.2).
#
# Pure card-level TB: donor trio + TB, no machine model.
# Environment facts (same as the other verilog/ runners): native
# mingw32-make via the make.exe shim, TMP exported inside the shell,
# VERILATOR_ROOT exported, C:/msys64/usr/bin on PATH + SHELL=sh,
# pure self-driving TB -> --binary --timing.
#
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_mockingboard.sh
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

MD=obj_dir_tb_mockingboard
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_mockingboard.exe"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_mockingboard \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/core/mockingboard/mockingboard.v" \
    "$ROOT/src/fpga/core/mockingboard/via6522.v" \
    "$ROOT/src/fpga/core/mockingboard/YM2149.sv" \
    tb/tb_mockingboard.sv > "$MD/build.log" 2>&1; then
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
if [ "$rc" -eq 0 ] && grep -q "MOCKINGBOARD TB ALL CHECKS PASSED" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
