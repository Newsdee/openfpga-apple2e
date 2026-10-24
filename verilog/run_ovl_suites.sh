#!/bin/sh
# Run just the two overlay suites with the same build recipe as run_m0m1_regress.sh
# (which would otherwise also re-run the 30+ min storage suites).
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
export SHELL=/c/msys64/usr/bin/sh
export TMP=/c/msys64/tmp
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S=../src/fpga/core/apple2e
W=../src/fpga/core/woz
APF=../src/fpga/apf/common.v
APFDAT=../src/fpga/apf/mf_datatable.v
CBR=../src/fpga/core/core_bridge_cmd.v
DRAM=tb/tb_dram_model.sv
SYNC=stubs/altsyncram_sim.v
SUP="$S/sdram_storage.v $S/sdram_word_owner.v $S/sdram_sector_fetch.v $S/sdram_woz_transport.v $S/woz_mount_ctl.v $S/slot_fifo.v $S/disk_store.v $S/disk_verifier.v $S/io_sdram_pocket.v $S/sdram_status_overlay.v $W/disk_ii_rom.v $W/disk_ii_woz.sv $W/flux_drive.v $W/woz_bram.v $W/woz_cell525.sv $W/woz_floppy_controller.sv $CBR $APF $APFDAT $DRAM $SYNC"
VERILATOR=/c/msys64/ucrt64/bin/verilator_bin
MAKE=/c/msys64/ucrt64/bin/mingw32-make.exe
WARN_FLAGS="-Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch"

overall=0
for t in tb_ovl_status tb_ovl_dbgrect; do
    marker="PASS"
    obj="obj_dir_rr_$t"
    log="$obj.log"
    rm -rf "$obj"
    ( "$VERILATOR" --binary --timing -j 4 --top "$t" $WARN_FLAGS --Mdir "$obj" $SUP tb/$t.sv ) >"$log" 2>&1
    vr=$?
    if [ $vr -ne 0 ] || grep -qE "%Error" "$log"; then
        echo "BUILD-FAIL $t (rc=$vr)"; grep -E "%Error" "$log" | head -5; overall=1; continue
    fi
    ( cd "$obj" && "$MAKE" -f "V$t.mk" "V$t" ) >>"$log" 2>&1
    if [ $? -ne 0 ] || [ ! -x "$obj/V$t.exe" ]; then
        echo "LINK-FAIL $t"; tail -5 "$log"; overall=1; continue
    fi
    out="$( "$obj/V$t.exe" 2>&1 )"; runrc=$?
    echo "$out" | grep -E "PASS|FAIL" | tail -4
    if [ $runrc -eq 0 ] && ! echo "$out" | grep -qE "FAIL"; then
        echo "=== $t: OK"
    else
        echo "=== $t: PROBLEM (rc=$runrc)"; overall=1
    fi
done
exit $overall
