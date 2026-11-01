#!/usr/bin/env bash
# run_hdv_variants.sh - HDV boot-observation matrix (expert review 2026-11-01
# suggested sequence). Runs each variant headless, keeps its log and frame
# shots separately. Run from verilog/pocket_boot/ (MSYS2 UCRT64 bash).
#
#   v1 healthy    0x008A mount at 0.5 ms, healthy host          (baseline)
#   v2 latemount  0x008A mount at 120 ms (after the ROM scan)
#   v3 failat3    fetch #3 answered 'ok' err=1
#   v4 stall3     fetch #3 answered 200 ms late (within FETCH_TO)
#   v5 dto        datatable-only mount (no 0x008A) - convergence
#   v6 gap50      healthy host with 50-cycle gaps between DMA words
#
# Usage: bash run_hdv_variants.sh [v1 v2 ...]   (default: all)
set -u
cd "$(dirname "$0")"
HDV="../../sd_root/Assets/apple2e/common/Total Replay v6.1.hdv"
EXE=obj_dir/Vtb_pocket_boot.exe
BUDGET_MS=10000

run_one() {
    local name=$1; shift
    local dir="hdvrun_${name}"
    rm -rf "$dir"; mkdir -p "$dir"
    rm -rf pocket_boot_shots
    # NOTE: the exe must run with CWD = this dir (relative ROM/hex paths)
    echo "=== ${name}: $* (budget ${BUDGET_MS} ms machine time) ==="
    "$EXE" --budget-ms "$BUDGET_MS" "$@" > "$dir/run.log" 2>&1
    local rc=$?
    mkdir -p "$dir/frames"
    cp -f pocket_boot_shots/*.ppm "$dir/frames/" 2>/dev/null
    echo "=== ${name} rc=$rc log tail: ==="
    tail -4 "$dir/run.log"
    echo "fetches: $(grep -c '^HDVFETCH' "$dir/run.log" 2>/dev/null || echo 0)  cmds: $(grep -c '^HDVTGT' "$dir/run.log" 2>/dev/null || echo 0)"
    grep -E "HDV RUN END|HDVFAIL|PAST-EOF|HDVTGT UNEXPECTED" "$dir/run.log" | tail -8
    echo
}

case "${1:-all}" in
    all)
        run_one v1_healthy  --hdv "$HDV"
        run_one v2_latemount --hdv "$HDV" --mount-ms 120
        run_one v3_failat3  --hdv "$HDV" --fail-at 3
        run_one v4_stall3   --hdv "$HDV" --stall-at 3 --stall-ms 200
        run_one v5_dtonly   --hdv "$HDV" --hdv-no008a --hdv-dt
        run_one v6_gap50    --hdv "$HDV" --gap 50
        ;;
    *)
        for v in "$@"; do
            case "$v" in
                v1_healthy)   run_one v1_healthy  --hdv "$HDV" ;;
                v2_latemount) run_one v2_latemount --hdv "$HDV" --mount-ms 120 ;;
                v3_failat3)   run_one v3_failat3  --hdv "$HDV" --fail-at 3 ;;
                v4_stall3)    run_one v4_stall3   --hdv "$HDV" --stall-at 3 --stall-ms 200 ;;
                v5_dtonly)    run_one v5_dtonly   --hdv "$HDV" --hdv-no008a --hdv-dt ;;
                v6_gap50)     run_one v6_gap50    --hdv "$HDV" --gap 50 ;;
                *) echo "unknown variant: $v" ;;
            esac
        done
        ;;
esac
echo "HDV variant runs complete."
