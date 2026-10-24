#!/bin/sh
# Launch ONLY the two long storage regression suites (2026-10-23):
#   rr_tb_top_storage, rr_tb_bridge_storage
# Fresh regen + relink from each obj dir's recorded verilator command, then
# setsid-detached background launch with per-suite logs. The pocket_boot
# interactive sims were killed first so these two get full CPU.
#
# AV note (see rerun_m1_regress.sh header): each launch is chained right
# after its relink; if a just-linked PE is AV-killed (exit 127, no output)
# the mitigation is to relink again (new PE timestamp) and relaunch.
#
# Verdict: each run log must end with a PASS/FAIL line. Check:
#   obj_dir_rr_tb_top_storage/run_long_*.log
#   obj_dir_rr_tb_bridge_storage/run_long_*.log
set -u
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
export SHELL=/c/msys64/usr/bin/sh
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
cd "$(dirname "$0")" || exit 1

for d in rr_tb_top_storage rr_tb_bridge_storage; do
    f=$(ls obj_dir_$d/*verFiles.dat 2>/dev/null | head -1)
    [ -z "$f" ] && { echo "## $d :: NO verFiles.dat"; continue; }
    cmd=$(grep -m1 '^C ' "$f" | sed 's/^C "//;s/"$//')
    mkdir=$(ls obj_dir_$d/*.mk 2>/dev/null | head -1)
    mkbase=$(basename "$mkdir" .mk).mk
    ex=$(ls obj_dir_$d/V*.exe 2>/dev/null | head -1)
    rm -f "$ex" 2>/dev/null
    if ! verilator_bin.exe $cmd > "obj_dir_$d/regen_$d.log" 2>&1; then
        echo "## $d :: VERILATOR FAILED"; tail -3 "obj_dir_$d/regen_$d.log"; continue
    fi
    if ! make -C obj_dir_$d -f "$mkbase" -j 4 > "obj_dir_$d/relink_$d.log" 2>&1; then
        echo "## $d :: MAKE FAILED"; tail -3 "obj_dir_$d/relink_$d.log"; continue
    fi
    log="obj_dir_$d/run_long_$(date +%Y%m%d_%H%M).log"
    /c/msys64/usr/bin/setsid nohup "./$ex" > "$log" 2>&1 < /dev/null &
    echo "## $d :: launched (pid $!), log $log"
done
echo "## launcher done (both suites running detached)"
