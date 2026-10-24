#!/bin/sh
# One-shot: rebuild + relink + detached-launch ONLY rr_tb_bridge_storage
# on the FINAL RTL (with the disk_verifier fingerprint extension added
# after the 10:44 long-suite run). Verifies storage behavior is unchanged
# by the additive fingerprint logic. ~17 min wall.
set -u
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
export SHELL=/c/msys64/usr/bin/sh
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
cd "$(dirname "$0")" || exit 1

d=rr_tb_bridge_storage
f=$(ls obj_dir_$d/*verFiles.dat 2>/dev/null | head -1)
[ -z "$f" ] && { echo "## $d :: NO verFiles.dat"; exit 1; }
cmd=$(grep -m1 '^C ' "$f" | sed 's/^C "//;s/"$//')
mkdir_=$(ls obj_dir_$d/*.mk 2>/dev/null | head -1)
mkbase=$(basename "$mkdir_" .mk).mk
ex=$(ls obj_dir_$d/V*.exe 2>/dev/null | head -1)
rm -f "$ex" 2>/dev/null
verilator_bin.exe $cmd > "obj_dir_$d/regen_final.log" 2>&1 || { echo "## VERILATOR FAILED"; tail -3 "obj_dir_$d/regen_final.log"; exit 1; }
make -C obj_dir_$d -f "$mkbase" -j 4 > "obj_dir_$d/relink_final.log" 2>&1 || { echo "## MAKE FAILED"; tail -5 "obj_dir_$d/relink_final.log"; exit 1; }
log="obj_dir_$d/run_final_$(date +%Y%m%d_%H%M).log"
/c/msys64/usr/bin/setsid nohup "./$ex" > "$log" 2>&1 < /dev/null &
echo "## $d :: launched (pid $!), log $log"
