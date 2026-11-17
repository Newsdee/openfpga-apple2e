#!/bin/sh
# run_tb_savestate_minirepro.sh - build + run the wedge mechanism-hunt TB.
#
# DUT cut: bare real stack (port + owner + bridge + slot+manager + fake RAM
# + DRAM model) with scripted machine/host per
# EXPERT_BRIEF_SAVESTATE_MINIREPRO_TB_2026-11-15.md (approved spec).
#
# Run from MSYS2:
#   cd apple2e-pocket/verilog && bash run_tb_savestate_minirepro.sh
#   bash run_tb_savestate_minirepro.sh +G0                # single gate
#   bash run_tb_savestate_minirepro.sh +FAST +G1          # fast-mode G1a
#   (flags: +FAST N_BLOB=4096; +G0..+G5 single gate; +FSEEDS G4 seeds=4)
#
# Verdicts (run.log): "MINIREPRO TB: PASS" | "... WEDGES REPRODUCED ..." |
# "FAIL (...)". A WEDGES REPRODUCED run is a SUCCESS of the reproduction
# goal (the ledger_sg*.csv files in this dir are the data) - the runner exits
# 0 for any verdict line; only a missing verdict (watchdog/hang) fails.
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

# apple2e_ram_bank's $readmemh is CWD-relative
if [ ! -f rtl/roms/ram_zero_64k.hex ]; then
    mkdir -p rtl/roms
    cp -f "$ROOT/src/fpga/rtl/roms/ram_zero_64k.hex" rtl/roms/ram_zero_64k.hex
fi

MD=obj_dir_tb_savestate_minirepro_storage
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_savestate_minirepro.exe"

rm -f "$EX"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_savestate_minirepro \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/src/fpga/core/apple2e/ram_sweep_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/apple2e_ram_bank.v" \
    "$ROOT/src/fpga/core/apple2e/savestate_manager.sv" \
    "$ROOT/src/fpga/core/apple2e/savestate_slot.v" \
    "$ROOT/src/fpga/core/apple2e/savestate_bridge.v" \
    "$ROOT/src/fpga/core/apple2e/slot_fifo.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_word_owner.v" \
    "$ROOT/src/fpga/core/apple2e/io_sdram_pocket.v" \
    stubs/altsyncram_sim.v \
    tb/tb_dram_model.sv \
    tb/ss_ledger.sv \
    tb/tb_savestate_minirepro_storage.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    tail -20 "$MD/build.log"
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe; check $MD/build.log)"
    tail -10 "$MD/build.log"
    exit 1
fi

# AV note: a freshly linked PE can be killed mid-session (exit 127, no
# output); relinking once usually buys a fresh window.
"$EX" "$@" > "$MD/run.log" 2>&1
rc=$?
tail -40 "$MD/run.log"
if grep -q "MINIREPRO TB:" "$MD/run.log"; then
    echo "## RUN COMPLETE (exit $rc; verdict above; ledgers: $(ls ledger_sg*.csv 2>/dev/null | tr '\n' ' '))"
    exit 0
else
    echo "## RUN FAILED (no verdict line; exit $rc)"
    exit 1
fi
