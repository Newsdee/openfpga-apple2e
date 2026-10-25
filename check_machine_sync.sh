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
check apple2_font_rom.v
check keyboard.v
check osk/virtual_keyboard_controller.sv
check osk/virtual_keyboard_overlay.sv
check cpu/nmos6502/cpu_65c02.sv
check cpu/nmos6502/cpu_alu.sv
check cpu/wdc65c02/cpu_65c02.sv
check cpu/wdc65c02/cpu_alu.sv
# NTSC color path (byte-pinned donor import; see machine/video/NOTICE.md).
# Source of truth for these is $SRC/video, and check() prepends machine/.
check video/video_pipeline.sv
check video/apple_composite.sv
check video/composite_decoder.sv
check video/vga_controller.v

# q17 variant: the QSF compiles machine/osk/virtual_keyboard_overlay_q17.sv
# (generated: drops the 60 SystemVerilog N'(expr) casts Quartus 17 rejects).
# Regenerate it if the canonical overlay ever changes.
if [ -f machine/osk/virtual_keyboard_overlay_q17.sv ]; then
    if /c/msys64/ucrt64/bin/python.exe tools/gen_osk_q17.py --check; then
        :
    else
        rc=1
    fi
else
    echo "MISSING  machine/osk/virtual_keyboard_overlay_q17.sv (run: python tools/gen_osk_q17.py)"
    rc=1
fi

if [ $rc -eq 0 ]; then
    echo "machine/ in sync with $SRC"
else
    echo "machine/ OUT OF SYNC - re-copy from $SRC"
fi
exit $rc
