#!/bin/sh
# run_tb_savestate_integration.sh - build + run the W1 topological gate.
#
# The gate (verilog/tb/tb_savestate_integration.sv) instantiates the
# savestate word path EXACTLY as the shipping top wires it:
#   savestate_slot --ssrd/sswr--> sdram_storage --owner0--> io_sdram_pocket
#   savestate_bridge --hr/hwr--> sdram_storage --owner0--> io_sdram_pocket
#   sdram_storage.port_wr_idle -> slot + bridge
# plus a fake host (0x40xxxxxx window), a fake machine, and the real DRAM
# model. It exists because the round-trip TB (bare owner + port) masked a
# real integration gap: the storage owner's W1 clients were left dangling
# in the top, which would hang savestate save/load on hardware.
#
# Run from MSYS2:  cd apple2e-pocket/verilog && bash run_tb_savestate_integration.sh
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

MD=obj_dir_tb_savestate_integration
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_savestate_integration.exe"

rm -f "$EX"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_savestate_integration \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/src/fpga/apf/mf_datatable.v" \
    "$ROOT/src/fpga/core/apple2e/ram_sweep_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/apple2e_ram_bank.v" \
    "$ROOT/src/fpga/core/apple2e/savestate_manager.sv" \
    "$ROOT/src/fpga/core/apple2e/savestate_slot.v" \
    "$ROOT/src/fpga/core/apple2e/savestate_bridge.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_word_owner.v" \
    "$ROOT/src/fpga/core/apple2e/io_sdram_pocket.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_storage.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_sector_fetch.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_woz_transport.v" \
    "$ROOT/src/fpga/core/apple2e/woz_mount_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/slot_fifo.v" \
    "$ROOT/src/fpga/core/apple2e/disk_store.v" \
    "$ROOT/src/fpga/core/apple2e/disk_verifier.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_status_overlay.v" \
    "$ROOT/src/fpga/core/woz/disk_ii_rom.v" \
    "$ROOT/src/fpga/core/woz/disk_ii_woz.sv" \
    "$ROOT/src/fpga/core/woz/flux_drive.v" \
    "$ROOT/src/fpga/core/woz/woz_bram.sv" \
    "$ROOT/src/fpga/core/woz/woz_cell525.sv" \
    "$ROOT/src/fpga/core/woz/woz_floppy_controller.sv" \
    "$ROOT/src/fpga/core/core_bridge_cmd.v" \
    stubs/altsyncram_sim.v \
    tb/tb_dram_model.sv \
    tb/tb_savestate_integration.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    tail -10 "$MD/build.log"
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe; check $MD/build.log)"
    tail -10 "$MD/build.log"
    exit 1
fi

# Modes (first arg, optional):
#   (none)         paced-host full suite (T0, G1..G6) - the original gate
#   +UNPACED       R2 (2026-11-17) hardware-faithful gate: the real blob is
#                  written at the documented worst-case host rate
#                  (one posted write per 88 clk_74a, no backpressure); the
#                  16-deep host-write FIFO must NOT overflow and the load
#                  must be accepted. This is the shape of the real host
#                  (io_bridge_peripheral.v:49); the paced host hides it.
#   "+UNPACED +UPTAP"  same, with the per-op addr/data pipeline tap
# CWD contract: the exe reads real_1157_blob.hex and rtl/roms/*.hex
# CWD-RELATIVE - this script runs it from verilog/ (never from obj_dir).
MODE="${1:-}"

# AV note: a freshly linked PE can be killed mid-session (exit 127, no
# output); relinking once usually buys a fresh window.
"$EX" $MODE > "$MD/run.log" 2>&1
rc=$?
tail -30 "$MD/run.log"
case "$MODE" in
  +UNPACED*) MARKER="UNPACED-RESULT PASS" ;;
  *)         MARKER="SAVESTATE INTEGRATION TB: PASS" ;;
esac
if grep -q "$MARKER" "$MD/run.log"; then
    echo "## RUN PASS (exit $rc)"
else
    echo "## RUN FAIL (exit $rc)"
    exit 1
fi
