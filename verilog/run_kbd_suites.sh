#!/bin/sh
# Run the docked-USB-HID-keyboard unit suite (WP4, PLAN_USB_KEYBOARD_2026-11-02.md)
# with the same Verilator --binary --timing recipe as run_joy_suites.sh.
#
#   tb_pocket_kbd  - cont3 report -> apple2e_osk glue + hid_to_ps2 -> oskc ->
#                    keyboard.v -> K/reads/akd/apple buttons (the real chain)
#
# Usage:  run_kbd_suites.sh   (from verilog/, MSYS2 shell)
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH"
export SHELL=/c/msys64/usr/bin/sh
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../src/fpga/core/apple2e"
C="$HERE/../src/fpga/core"
M="$HERE/../machine"
MISROOT="$HERE/../../Apple-II_MiSTer"
VERILATOR=/c/msys64/ucrt64/bin/verilator_bin
MAKE=/c/msys64/ucrt64/bin/mingw32-make.exe
WARN_FLAGS="-Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch"

overall=0

# tb_pocket_kbd: needs apple2e_osk + the hid_to_ps2 converter + the machine
# osk/keyboard/font; run with CWD at the Apple-II_MiSTer root (the font ROM
# $readmemh("rtl/roms/video2.hex") is CWD-relative).
obj="obj_dir_kbd_tb_pocket_kbd"
log="$obj.log"
rm -rf "$obj"
( "$VERILATOR" --binary --timing -j 4 --top tb_pocket_kbd -DJOY_TO_KEY=1 -LDFLAGS "-mconsole" $WARN_FLAGS \
    --Mdir "$obj" \
    "$S/apple2e_osk.v" \
    "$C/hid_to_ps2.sv" \
    "$M/osk/virtual_keyboard_controller.sv" \
    "$M/osk/virtual_keyboard_overlay.sv" \
    "$M/keyboard.v" \
    "$M/rom.v" \
    "$M/apple2_font_rom.v" \
    "tb/tb_pocket_kbd.sv" ) >"$log" 2>&1
vr=$?
if [ $vr -ne 0 ] || grep -qE "%Error" "$log"; then
    echo "BUILD-FAIL tb_pocket_kbd (rc=$vr)"; grep -E "%Error" "$log" | head -5; overall=1
else
    ( cd "$obj" && "$MAKE" -f "Vtb_pocket_kbd.mk" "Vtb_pocket_kbd" ) >>"$log" 2>&1
    if [ $? -ne 0 ] || [ ! -x "$obj/Vtb_pocket_kbd.exe" ]; then
        echo "LINK-FAIL tb_pocket_kbd"; tail -5 "$log"; overall=1
    else
        out="$( cd "$MISROOT" && "$HERE/$obj/Vtb_pocket_kbd.exe" 2>&1 )"; runrc=$?
        echo "$out" | grep -E "PASS|FAIL|ok  :|T[0-9]" | tail -20
        if [ $runrc -eq 0 ] && ! echo "$out" | grep -qE "FAIL"; then
            echo "=== tb_pocket_kbd: OK"
        else
            echo "=== tb_pocket_kbd: FAIL (rc=$runrc)"; overall=1
        fi
    fi
fi
exit $overall
