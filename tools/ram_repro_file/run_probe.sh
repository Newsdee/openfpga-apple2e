#!/usr/bin/env bash
# run_probe.sh - Phase A3: A&S measurement for one isolated probe revision.
# Run from ANYWHERE: `bash tools/ram_repro_file/run_probe.sh <rev>` with the
# probe dir as <this_dir>/<rev>. Sequential runs only - no competing builds.
set -u
REV=$1
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/$REV"
QM='C:\intelFPGA_lite\17.0\quartus\bin64\quartus_map.exe'
PY=/c/msys64/ucrt64/bin/python.exe
TS=$(date +%Y%m%d_%H%M%S)
LOG=run_${REV}_${TS}.log

{
    echo "probe: $REV   start: $(date)"
    echo "quartus: $("$QM" --version 2>&1 | head -2 | tr '\n' ' ')"
    echo "sources:"; sha256sum *.v *.qsf 2>/dev/null
    if grep -q readmemh *.v 2>/dev/null; then
        echo "preflight:"
        "$PY" validate_ram_image.py ../../src/fpga/rtl/roms/ram_zero_64k.hex --zeros || {
            echo "PREFLIGHT FAIL - not launching Quartus"; exit 1; }
    fi
    echo "--- launching A&S (quartus_map, write_settings_files=off) ---"
} > "$LOG"
"$QM" "$REV" --read_settings_files=on --write_settings_files=off >> "$LOG" 2>&1
RC=$?
{
    echo "--- A&S exit=$RC   end: $(date) ---"
    echo "map.summary: $(grep -E 'Analysis & Synthesis Status' $REV.map.summary 2>/dev/null | head -1)"
    grep -E "Elapsed time|Total CPU time" $REV.map.rpt 2>/dev/null | tail -2
    echo "full log: $HERE/$REV/$LOG"
}
echo "A&S done rc=$RC log=$HERE/$REV/$LOG"
[ "$RC" = 0 ]
