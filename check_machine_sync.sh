#!/usr/bin/env bash
# check_machine_sync.sh - verify machine/ is byte-identical to the source of
# truth (Apple-II_MiSTer/rtl). The Pocket core builds the unmodified machine
# core from machine/ (self-contained repo); after any machine RTL change in
# Apple-II_MiSTer, re-copy and re-run this. Exit 0 = in sync.
set -euo pipefail

cd "$(dirname "$0")"
SRC=../Apple-II_MiSTer/rtl
[ -d "$SRC" ] || { echo "missing source of truth: $SRC"; exit 1; }

rc=0
check() {
    local a="machine/$1" b="$SRC/$1"
    if [ ! -f "$a" ]; then echo "MISSING  $a"; rc=1; return; fi
    if cmp -s "$a" "$b"; then
        echo "OK       $a"
    else
        echo "DIFFERS  $a  (vs $b)"; rc=1
    fi
}

check apple2.v
check timing_generator.v
check video_generator.v
check rom.v
check ramcard.v
check cpu/nmos6502/cpu_65c02.sv
check cpu/nmos6502/cpu_alu.sv
check cpu/wdc65c02/cpu_65c02.sv
check cpu/wdc65c02/cpu_alu.sv

if [ $rc -eq 0 ]; then
    echo "machine/ in sync with $SRC"
else
    echo "machine/ OUT OF SYNC - re-copy from $SRC"
fi
exit $rc
