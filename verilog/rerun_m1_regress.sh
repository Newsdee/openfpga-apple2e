#!/bin/sh
# M1 regression re-run after the sdram_sector_fetch pipelined-geometry fix
# (2026-10-21). Rebuilds each suite from the original verilator command
# recorded in its obj dir's verFiles.dat, links, and runs. Fast suites run
# inline; the two long storage suites are backgrounded with per-dir logs.
# AV note: run each exe promptly after its relink (host AV kills fresh C++
# PEs outside a short grace window); launches are chained right after make.
set -u
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
export SHELL=/c/msys64/usr/bin/sh
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
cd "$(dirname "$0")" || exit 1

cmd_for() { grep -m1 '^C ' "$1" | sed 's/^C "//;s/"$//'; }

run_suite() {
    d="$1"; bg="$2"
    vf="obj_dir_$d/*verFiles.dat"
    f=$(ls $vf 2>/dev/null | head -1)
    [ -z "$f" ] && { echo "## $d :: NO verFiles.dat"; return 1; }
    cmd=$(cmd_for "$f")
    mkdir=$(ls obj_dir_$d/*.mk 2>/dev/null | head -1)
    mkbase=$(basename "$mkdir" .mk).mk
    b=${mkdir#*V}; b=${b%.mk}
    ex="obj_dir_$d/$b.exe"
    # 2026-10-22: fall back to the real linked name if the derived one is absent
    # (verFiles-derived name can miss the V prefix: tb_top_storage vs
    # Vtb_top_storage).
    [ -x "$ex" ] || ex=$(ls obj_dir_$d/V*.exe 2>/dev/null | head -1)
    [ -n "$ex" ] || ex="obj_dir_$d/$b.exe"
    rm -f "$ex" 2>/dev/null
    if ! verilator_bin.exe $cmd > "obj_dir_$d/regen_$d.log" 2>&1; then
        echo "## $d :: VERILATOR FAILED"; tail -3 "obj_dir_$d/regen_$d.log"; return 1
    fi
    if ! make -C obj_dir_$d -f "$mkbase" -j 4 > "obj_dir_$d/relink_$d.log" 2>&1; then
        echo "## $d :: MAKE FAILED"; tail -3 "obj_dir_$d/relink_$d.log"; return 1
    fi
    if [ "$bg" = "bg" ]; then
        nohup "./$ex" > "obj_dir_$d/run_$(date +%Y%m%d_%H%M).log" 2>&1 &
        echo "## $d :: launched (pid $!), log obj_dir_$d/run_*.log"
    else
        out=$("./$ex" 2>&1 | grep -iE "PASS|FAIL|%Error" | tail -2 | tr '\n' ' | ')
        echo "## $d :: ${out:-NO-VERDICT-LINE}"
    fi
    return 0
}

for d in rr_tb_sector_fetch rr_tb_slot_fifo rr_tb_woz_mount_ctl rr_tb_woz_transport rr_tb_disk_store u6; do
    run_suite "$d" fg
done
for d in rr_tb_top_storage rr_tb_bridge_storage; do
    run_suite "$d" bg
done
echo "## done (bg suites still running)"
