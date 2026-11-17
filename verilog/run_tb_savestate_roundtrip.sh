#!/bin/sh
# run_tb_savestate_roundtrip.sh - build + run the W1 savestate round-trip gate.
#
# The gate (verilog/tb/tb_savestate_roundtrip.sv) instantiates the REAL
# shipping glue - apple2e_ram_bank.v (the extracted machine RAM),
# savestate_slot.v (with the byte-identical donor savestate_manager) and
# sdram_word_owner.v (W1 ssrd/sswr clients) - against a fake SDRAM word
# port and a fake machine side, at the real Pocket clock rates.
#
# Environment facts (Apple-II_FPGAdev AGENTS.md "Verilator harness builds"
# + apple2e-pocket/AGENTS.md): native mingw32-make via the make.exe shim,
# TMP/TEMP/TMPDIR exported inside the shell, VERILATOR_ROOT exported,
# C:/msys64/usr/bin on PATH + SHELL=sh (verilated.mk POSIX recipes),
# pure self-driving TB -> --binary --timing (not --exe).
#
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_savestate_roundtrip.sh
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

# apple2e_ram_bank's $readmemh is CWD-relative: stage the canonical zero
# image under rtl/roms/ (same contract as pocket_boot's build.sh)
if [ ! -f rtl/roms/ram_zero_64k.hex ]; then
    mkdir -p rtl/roms
    cp -f "$ROOT/src/fpga/rtl/roms/ram_zero_64k.hex" rtl/roms/ram_zero_64k.hex
fi

MD=obj_dir_tb_savestate_roundtrip
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_savestate_roundtrip.exe"

rm -f "$EX"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_savestate_roundtrip \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/src/fpga/core/apple2e/ram_sweep_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/apple2e_ram_bank.v" \
    "$ROOT/src/fpga/core/apple2e/savestate_manager.sv" \
    "$ROOT/src/fpga/core/apple2e/savestate_slot.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_word_owner.v" \
    "$ROOT/src/fpga/core/apple2e/io_sdram_pocket.v" \
    tb/tb_dram_model.sv \
    tb/tb_savestate_roundtrip.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    tail -10 "$MD/build.log"
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe; check $MD/build.log)"
    tail -10 "$MD/build.log"
    exit 1
fi

# AV note: a freshly linked PE can be killed mid-session (exit 127, no
# output); relinking once usually buys a fresh window.
"$EX" > "$MD/run.log" 2>&1
rc=$?
tail -25 "$MD/run.log"
if grep -q "SAVESTATE ROUNDTRIP TB: PASS" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
