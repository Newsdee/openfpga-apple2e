#!/usr/bin/env bash
# verilate_u6.sh - M1 Unit 6: full-machine WOZ floppy boot harness (Verilator)
#
# Builds tb_u6_boot (real apple2 machine + RAM + WOZ engine + transport +
# mount ctl + M0 sdram_storage + DRAM model) and runs it. Run CWD is
# verilog/u6/ so rtl/roms/{apple2e,video2}.hex + golden/dosmaster_full.hex
# resolve (the machine hardcodes rtl/roms/... for $readmemh).
#
# Prereq: verilog/u6/rtl/roms/*.hex (copied from src/fpga/rtl/roms) and
#         verilog/u6/golden/dosmaster_full.hex (from sd_root/Assets/.../DOSMaster.woz).
# Usage:  verilate_u6.sh [clean]
set -uo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"          # verilog/
ROOT=..                        # repo root
mkdir -p /c/msys64/tmp/makeshim
cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe 2>/dev/null || true

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir_u6
    exit 0
fi

# Self-generate the run-CWD assets (gitignored u6/): copy the ROMs and
# build the full golden image from the .woz.
mkdir -p u6/rtl/roms u6/golden
cp -f $ROOT/src/fpga/rtl/roms/apple2e.hex u6/rtl/roms/apple2e.hex
cp -f $ROOT/src/fpga/rtl/roms/video2.hex   u6/rtl/roms/video2.hex
if [ ! -f u6/golden/dosmaster_full.hex ]; then
    echo "building golden dosmaster_full.hex (234496 B) ..."
    /c/msys64/ucrt64/bin/python.exe -c "
import sys
d=open('$ROOT/sd_root/Assets/apple2e/common/DOSMaster.woz','rb').read()
hex='\n'.join('%02x'%b for b in d)
open('u6/golden/dosmaster_full.hex','w').write(hex+'\n')
print('golden:',len(d),'bytes')
"
fi
for f in u6/rtl/roms/apple2e.hex u6/rtl/roms/video2.hex u6/golden/dosmaster_full.hex; do
    if [ ! -f "$f" ]; then
        echo "failed to generate $f"; exit 1
    fi
done

# machine/ (byte-identical MiSTer reference) + storage + WOZ engine + TB
M=../machine
W=$ROOT/src/fpga/core/woz
S=$ROOT/src/fpga/core/apple2e

verilator_bin --binary --timing -j 4 \
    --top tb_u6_boot \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    --Mdir obj_dir_u6 \
    $M/apple2.v \
    $M/apple2_font_rom.v \
    $M/ramcard.v \
    $M/rom.v \
    $M/timing_generator.v \
    $M/video_generator.v \
    $M/cpu/nmos6502/cpu_65c02.sv \
    $M/cpu/nmos6502/cpu_alu.sv \
    $M/cpu/wdc65c02/cpu_65c02.sv \
    $M/cpu/wdc65c02/cpu_alu.sv \
    $S/sdram_storage.v \
    $S/sdram_word_owner.v \
    $S/sdram_sector_fetch.v \
    $S/sdram_woz_transport.v \
    $S/woz_mount_ctl.v \
    $S/slot_fifo.v \
    $S/disk_store.v \
    $S/disk_verifier.v \
    $S/io_sdram_pocket.v \
    $W/disk_ii_rom.v \
    $W/disk_ii_woz.sv \
    $W/flux_drive.v \
    $W/woz_bram.sv \
    $W/woz_cell525.sv \
    $W/woz_floppy_controller.sv \
    $ROOT/src/fpga/apf/common.v \
    tb/tb_dram_model.sv \
    stubs/altsyncram_sim.v \
    tb/tb_u6_boot.sv \
    > u6_build.log 2>&1
vrc=$?
if [ $vrc -ne 0 ]; then
    echo "verilator build FAILED (see u6_build.log)"; tail -30 u6_build.log; exit 1
fi

( cd obj_dir_u6 && rm -f Vtb_u6_boot && /c/msys64/ucrt64/bin/mingw32-make.exe -f Vtb_u6_boot.mk Vtb_u6_boot > ../u6_mk.log 2>&1 )
mrc=$?
if [ $mrc -ne 0 ]; then
    echo "make FAILED (see u6_mk.log)"; tail -30 u6_mk.log; exit 1
fi

echo "build ok: obj_dir_u6/Vtb_u6_boot.exe"
echo "=== running (CWD = u6/) ==="
cd u6
../obj_dir_u6/Vtb_u6_boot.exe
rc=$?
cd ..
exit $rc
