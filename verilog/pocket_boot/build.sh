#!/usr/bin/env bash
# build.sh - build the interactive Pocket boot-debug harness (Verilator --exe, SDL2).
#
# Environment facts (AGENTS.md "Verilator harness builds" + MiSTer repo recipe):
#  - native mingw32-make via make.exe shim (MSYS make strips TMP)
#  - TMP/TEMP/TMPDIR exported inside the shell
#  - VERILATOR_ROOT exported (verilator_bin needs verilated_std.sv)
#  - C:/msys64/usr/bin on PATH + SHELL=sh for verilated.mk POSIX recipes
#  - --exe with user C++ main needs the sc_time_stamp() stub (in pocket_main.cpp)
#
# Usage:  build.sh [clean]
set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
VERILOG=..                       # verilog/
ROOT=../..                       # apple2e-pocket/

# make.exe shim (verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir
    exit 0
fi

# stage machine ROMs (CWD-relative $readmemh paths: rtl/roms/*.hex)
mkdir -p rtl/roms
cp -f "$VERILOG/u6/rtl/roms/apple2e.hex" rtl/roms/ 2>/dev/null \
    || cp -f "$ROOT/../Apple-II-Verilog_MiSTer/verilator/rtl/roms/apple2e.hex" rtl/roms/
cp -f "$VERILOG/u6/rtl/roms/video2.hex"  rtl/roms/ 2>/dev/null \
    || cp -f "$ROOT/../Apple-II-Verilog_MiSTer/verilator/rtl/roms/video2.hex"  rtl/roms/

# APF templates mf_pllbase.v (core/) and mf_datatable.v (apf/) declare
# `timescale 1ps/1ps`; a ps-timescale file poisons Verilator's
# mixed-timescale delay handling for the whole model (ns delays in the other
# files get reinterpreted as ps -> clocks run 1000x slow). Both templates
# contain no `#` delays, so re-declaring their timescale in ns units is
# behavior-neutral. Regenerated each build.
perl -pe 's/`timescale\s*1\s*ps\s*\/\s*1\s*ps/`timescale 1ns\/1ps/' \
    "$ROOT/src/fpga/core/mf_pllbase.v" > mf_pllbase_sim.v
grep -q "timescale 1ns/1ps" mf_pllbase_sim.v || { echo "mf_pllbase patch failed"; exit 1; }
perl -pe 's/`timescale\s*1\s*ps\s*\/\s*1\s*ps/`timescale 1ns\/1ps/' \
    "$ROOT/src/fpga/apf/mf_datatable.v" > mf_datatable_sim.v
grep -q "timescale 1ns/1ps" mf_datatable_sim.v || { echo "mf_datatable patch failed"; exit 1; }

SDL_INC="$(/c/msys64/ucrt64/bin/sdl2-config --prefix 2>/dev/null || echo /c/msys64/ucrt64)/include/SDL2"

# NOTE: CWD must stay at pocket_boot/ (ROM paths + the .woz hex the C++ writes).
# Build with Mdir inside this dir.
# --cc: generate the model only; pocket_main.cpp provides main() and the
# sc_time_stamp() stub that --timing links against (Verilator 5: no --exe).
verilator_bin --cc --timing -j 4 \
    --top tb_pocket_boot \
    --Mdir obj_dir \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -Wno-DECLFILENAME \
    -CFLAGS "-std=c++17 -O2 -I$SDL_INC -DSDL_MAIN_HANDLED" \
    -LDFLAGS "-lSDL2 -lopengl32 -lgdi32 -limm32" \
    pocket_main.cpp \
    tb_pocket_boot.sv \
    "$VERILOG/tb/tb_dram_model.sv" \
    "$ROOT/src/fpga/core/apple2e/apf_stream_video_top.v" \
    "$ROOT/src/fpga/core/apple2e/apf_stream_video.v" \
    "$ROOT/src/fpga/core/apple2e/apple2e_osk.v" \
    "$ROOT/src/fpga/core/apple2e/apf_stream_proto_pll.v" \
    "$ROOT/src/fpga/core/apple2e/apple2e_sdram_pll.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_storage.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_word_owner.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_sector_fetch.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_woz_transport.v" \
    "$ROOT/src/fpga/core/apple2e/woz_mount_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/slot_fifo.v" \
    "$ROOT/src/fpga/core/apple2e/disk_store.v" \
    "$ROOT/src/fpga/core/apple2e/disk_verifier.v" \
    "$ROOT/src/fpga/core/apple2e/reboot_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/ram_sweep_ctl.v" \
    "$ROOT/src/fpga/core/apple2e/io_sdram_pocket.v" \
    "$ROOT/src/fpga/core/apple2e/sdram_status_overlay.v" \
    "$ROOT/src/fpga/core/woz/disk_ii_rom.v" \
    "$ROOT/src/fpga/core/woz/disk_ii_woz.sv" \
    "$ROOT/src/fpga/core/woz/flux_drive.v" \
    "$ROOT/src/fpga/core/woz/woz_bram.sv" \
    "$ROOT/src/fpga/core/woz/woz_cell525.sv" \
    "$ROOT/src/fpga/core/woz/woz_floppy_controller.sv" \
    "$ROOT/src/fpga/core/core_bridge_cmd.v" \
    mf_pllbase_sim.v \
    "$ROOT/src/fpga/core/mf_pllbase/mf_pllbase_0002.v" \
    mf_datatable_sim.v \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/machine/apple2.v" \
    "$ROOT/machine/apple2_font_rom.v" \
    "$ROOT/machine/ramcard.v" \
    "$ROOT/machine/rom.v" \
    "$ROOT/machine/timing_generator.v" \
    "$ROOT/machine/keyboard.v" \
    "$ROOT/machine/video_generator.v" \
    "$ROOT/machine/cpu/nmos6502/cpu_65c02.sv" \
    "$ROOT/machine/cpu/nmos6502/cpu_alu.sv" \
    "$ROOT/machine/cpu/wdc65c02/cpu_65c02.sv" \
    "$ROOT/machine/cpu/wdc65c02/cpu_alu.sv" \
    "$ROOT/machine/osk/virtual_keyboard_controller.sv" \
    "$ROOT/machine/osk/virtual_keyboard_overlay.sv" \
    "$VERILOG/stubs/altera_pll_sim.v" \
    "$VERILOG/stubs/altsyncram_sim.v"

# --cc generates the model only; build the model libs, then link the exe
# with the user main (pocket_main.cpp provides main() + sc_time_stamp()).
make -C obj_dir -f Vtb_pocket_boot.mk -j 4
g++ -O2 -o obj_dir/Vtb_pocket_boot.exe \
    obj_dir/pocket_main.o \
    obj_dir/libVtb_pocket_boot.a obj_dir/libverilated.a \
    obj_dir/Vtb_pocket_boot__ALL.a \
    -lSDL2 -lopengl32 -lgdi32 -limm32

ls -la obj_dir/Vtb_pocket_boot.exe
echo "build ok: obj_dir/Vtb_pocket_boot"
