#!/bin/sh
# run_tb_ss_cmdrace.sh - build + run the L0 stale-ack race repro TB.
#
# EXPERT_BRIEF_SAVESTATE_WEDGE_MACH_SIDE_2026-11-16.md §9 Step 1:
# real core_bridge_cmd + real savestate_slot, mach-clock phase-swept
# (+PH0..+PH5, one run each). Aggregates cmd1/cmd2 acceptances.
#
# Run from MSYS2:
#   cd apple2e-pocket/verilog && bash run_tb_ss_cmdrace.sh
#
# Verdict: "CMDRACE: cmd1=<n>/6 cmd2=<n>/6 accepted".
# UNFIXED RTL expects cmd2 < 6 (phase-dependent loss); FIXED RTL expects 6/6.
# The runner exits 0 when all 6 runs produced a verdict (the acceptance
# counts are the data - a LOST cmd2 is a SUCCESS of the repro goal).
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

MD=obj_dir_tb_ss_cmdrace
mkdir -p "$MD"
EX="$MD/obj_dir/Vtb_ss_cmdrace.exe"

rm -f "$EX"
if ! verilator_bin --binary --timing -j 4 \
    --top tb_ss_cmdrace \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir "$MD/obj_dir" \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/src/fpga/apf/mf_datatable.v" \
    stubs/altsyncram_sim.v \
    "$ROOT/src/fpga/core/core_bridge_cmd.v" \
    "$ROOT/src/fpga/core/apple2e/savestate_manager.sv" \
    "$ROOT/src/fpga/core/apple2e/savestate_slot.v" \
    tb/tb_ss_cmdrace.sv > "$MD/build.log" 2>&1; then
    echo "## BUILD FAILED (see $MD/build.log)"
    tail -30 "$MD/build.log"
    exit 1
fi

if [ ! -f "$EX" ]; then
    echo "## LINK FAILED (no exe; check $MD/build.log)"
    tail -10 "$MD/build.log"
    exit 1
fi

# ---------------------------------------------------------------- phases
# one run per phase; each run is a cold power-up + two saves.
# verdict codes: c1/c2 00=OK 01=ERR 10=TIMEOUT 11=LOST; replay_ok=1 means
# exactly two manager acceptances (ghost-save guard, EXPERT_BRIEF §10).
cmd1_ok=0; cmd2_ok=0; replay_ok=0; runs=0
for P in 0 1 2 3 4 5; do
    if [ "$P" = "0" ]; then FL=""; else FL="+PH$P"; fi
    "$EX" $FL > "$MD/run_ph$P.log" 2>&1
    rc=$?
    line=$(grep "^PHASE=" "$MD/run_ph$P.log" | tail -1)
    if [ -z "$line" ]; then
        echo "PH$P: NO VERDICT (rc=$rc) - see $MD/run_ph$P.log"
        tail -5 "$MD/run_ph$P.log"
        continue
    fi
    runs=$((runs+1))
    echo "$line"
    case "$line" in *" c1=00"*) cmd1_ok=$((cmd1_ok+1));; esac
    case "$line" in *" c2=00"*) cmd2_ok=$((cmd2_ok+1));; esac
    case "$line" in *"replay_ok=1"*) replay_ok=$((replay_ok+1));; esac
done

echo "CMDRACE: runs=$runs/6 cmd1_ok=$cmd1_ok cmd2_ok=$cmd2_ok replay_ok=$replay_ok"
if [ "$runs" -eq 6 ]; then
    echo "## RUN PASS (exit 0) - acceptance counts above are the data"
    exit 0
fi
echo "## RUN FAIL (only $runs/6 verdicts)"
exit 1
