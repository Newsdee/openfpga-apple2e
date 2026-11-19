#!/bin/sh
# run_tb_mb_machine.sh - build + run the Mockingboard machine-level gate
# (tb_mb_machine.sv, PLAN_MOCKINGBOARD_PORT section 6.3).
#
# Real apple2 machine + RAM + MOCKINGBOARD card in slot 4, wired exactly
# as apf_stream_video_top.v. No WOZ/HDD/savestate paths in this harness.
#
# Run CWD must be verilog/mbm/ (the machine hardcodes rtl/roms/... for
# $readmemh); the runner stages the ROMs there, like verilate_u6.sh.
#
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_mb_machine.sh
set -u
export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")" || exit 1
ROOT=..
MACHINE=$ROOT/machine

# make.exe shim (verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

# stage the machine ROMs for the run CWD (gitignored mbm/)
mkdir -p mbm/rtl/roms
cp -f $ROOT/src/fpga/rtl/roms/apple2e.hex mbm/rtl/roms/apple2e.hex
cp -f $ROOT/src/fpga/rtl/roms/video2.hex  mbm/rtl/roms/video2.hex

MD=obj_dir_mb_machine
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_mb_machine.exe"

if ! verilator_bin --binary --timing -j 4 \
    --top tb_mb_machine \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    $MACHINE/apple2.v \
    $MACHINE/apple2_font_rom.v \
    $MACHINE/ramcard.v \
    $MACHINE/rom.v \
    $MACHINE/timing_generator.v \
    $MACHINE/video_generator.v \
    $MACHINE/cpu/nmos6502/cpu_65c02.sv \
    $MACHINE/cpu/nmos6502/cpu_alu.sv \
    $MACHINE/cpu/wdc65c02/cpu_65c02.sv \
    $MACHINE/cpu/wdc65c02/cpu_alu.sv \
    "$ROOT/src/fpga/core/mockingboard/mockingboard.v" \
    "$ROOT/src/fpga/core/mockingboard/via6522.v" \
    "$ROOT/src/fpga/core/mockingboard/YM2149.sv" \
    tb/tb_mb_machine.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    grep -E "%Error" "$MD/build.log" | head -15
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe)"
    tail -15 "$MD/build.log"
    exit 1
fi

# AV note: a freshly linked PE can be killed mid-session (exit 127, no
# output); relink once if the first run produces nothing.
( cd mbm && "$OLDPWD/$EX" ) > "$MD/run.log" 2>&1
rc=$?
tail -40 "$MD/run.log"
if [ "$rc" -eq 0 ] && grep -q "MB MACHINE TB ALL CHECKS PASSED" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
