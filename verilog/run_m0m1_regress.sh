#!/usr/bin/env bash
# M0 + M1 regression suite (Unit 7 sim gate).
# Builds each TB fresh (superset source list) and runs it with the correct CWD.
#   CWD = verilog/          : storage / mount-ctl / overlay / fifo / store / bridge TBs
#   CWD = repo root         : tb_woz_machine (reads verilog/tb/golden/dosmaster_16k.hex)
# Run from an MSYS2 shell:  bash verilog/run_m0m1_regress.sh
# (or from verilog/: bash run_m0m1_regress.sh)

set -uo pipefail

# --- environment (MSYS2 UCRT64 + native make shim + Verilator) ---
export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh
mkdir -p /c/msys64/tmp/makeshim
cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe 2>/dev/null || true

VERILATOR=/c/msys64/ucrt64/bin/verilator_bin
MAKE=/c/msys64/ucrt64/bin/mingw32-make.exe

# resolve repo root + verilog dir (this script may be run from either)
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"   # verilog/ (default run CWD for most TBs)

# --- superset RTL (storage stack + WOZ engine + bridge + DRAM model) ---
S=../src/fpga/core/apple2e
W=../src/fpga/core/woz
APF=../src/fpga/apf/common.v
APFDAT=../src/fpga/apf/mf_datatable.v
CBR=../src/fpga/core/core_bridge_cmd.v
DRAM=tb/tb_dram_model.sv
SYNC=stubs/altsyncram_sim.v
SUP="$S/sdram_storage.v $S/sdram_word_owner.v $S/sdram_sector_fetch.v $S/sdram_woz_transport.v $S/woz_mount_ctl.v $S/slot_fifo.v $S/disk_store.v $S/disk_verifier.v $S/io_sdram_pocket.v $S/sdram_status_overlay.v $W/disk_ii_rom.v $W/disk_ii_woz.sv $W/flux_drive.v $W/woz_bram.sv $W/woz_cell525.sv $W/woz_floppy_controller.sv $CBR $APF $APFDAT $DRAM $SYNC"

WARN_FLAGS="-Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch"

# build_run <top> <objdir> <run_cwd>  : build into objdir, run from run_cwd, return 0 if the
# exe prints a PASS marker (or $finish cleanly) without a FAIL/fatal marker.
build_run() {
    local top="$1" obj="$2" runcwd="$3" marker="$4"
    rm -rf "$obj"
    local log="$obj.log"
    local obj_abs="$HERE/$obj"        # absolute (the run CWD may differ from $HERE)
    local exe_abs="$obj_abs/V${top}.exe"
    # build: gate on the verilator exit status AND no %Error
    ( "$VERILATOR" --binary --timing -j 4 --top "$top" $WARN_FLAGS --Mdir "$obj" $SUP tb/$top.sv ) >"$log" 2>&1
    local vr=$?
    if [ $vr -ne 0 ] || grep -qE "%Error" "$log"; then
        echo "BUILD-FAIL $top (verilator rc=$vr)"; grep -E "%Error" "$log" | head -5; return 2
    fi
    ( cd "$obj" && "$MAKE" -f "V${top}.mk" "V${top}" ) >>"$log" 2>&1
    local mr=$?
    if [ $mr -ne 0 ] || [ ! -x "$exe_abs" ]; then
        echo "LINK-FAIL $top (make rc=$mr)"; tail -5 "$log"; return 3
    fi
    # run: capture stdout+stderr INSIDE the substitution; absolute exe path.
    # Re-link once if the host AV kills the fresh PE (rc=127 / no output).
    local out runrc
    out="$( cd "$runcwd" && "$exe_abs" 2>&1 )"; runrc=$?
    if [ $runrc -eq 127 ] || [ -z "$out" ]; then
        rm -f "$exe_abs"
        ( cd "$obj" && "$MAKE" -f "V${top}.mk" "V${top}" ) >>"$log" 2>&1
        [ -x "$exe_abs" ] || { echo "RELINK-FAIL $top"; return 4; }
        out="$( cd "$runcwd" && "$exe_abs" 2>&1 )"; runrc=$?
    fi
    # hard failure diagnostics (fatal/compile/stop) never print the marker
    if echo "$out" | grep -qiE "fatal:|Assertion failed|%Error|Simulation halted|\$stop"; then
        echo "FAIL $top (hard)"; echo "$out" | grep -iE "fatal|Assertion|%Error|halted|stop" | head -4
        return 1
    fi
    # PASS = the marker is present AND the run exited 0
    if [ $runrc -eq 0 ] && echo "$out" | grep -qF "$marker"; then
        echo "PASS $top  [marker: $marker]"; return 0
    fi
    echo "FAIL $top (rc=$runrc, no '$marker' marker)"; echo "$out" | grep -iE "FAIL|nfail|watchdog|stuck" | head -6
    echo "$out" | tail -3 | sed 's/^/    /'
    return 1
}

pass=0; fail=0
for entry in \
    "tb_slot_fifo|$HERE|SLOT FIFO PASS" \
    "tb_disk_store|$HERE|DISK STORE PASS" \
    "tb_sector_fetch|$HERE|ALL PASS" \
    "tb_woz_mount_ctl|$HERE|ALL PASS" \
    "tb_woz_transport|$HERE|ALL PASS" \
    "tb_top_storage|$HERE|TOP STORAGE PASS" \
    "tb_bridge_storage|$HERE|BRIDGE STORAGE PASS" \
    "tb_ovl_status|$HERE|OVL STATUS PASS" \
    "tb_ovl_dbgrect|$HERE|DBGRECT PASS" \
    "tb_woz_machine|$ROOT|ALL PASS" \
; do
    top="${entry%%|*}"; rest="${entry#*|}"; runcwd="${rest%%|*}"; marker="${rest##*|}"
    echo "=== $top (CWD=$runcwd) ==="
    if build_run "$top" "obj_dir_rr_$top" "$runcwd" "$marker"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
done

echo
echo "===== REGRESSION SUMMARY: PASS=$pass FAIL=$fail ====="
[ $fail -eq 0 ]
