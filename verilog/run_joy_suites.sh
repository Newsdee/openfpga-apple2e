#!/bin/sh
# Run the joystick/paddle unit suites (J1/J2, 2026-10-25) with the same
# Verilator --binary --timing recipe as run_ovl_suites.sh.
#
#   tb_joystick_input    - donor-parity probe of the byte-pinned import
#   tb_paddle_gameport   - Apple II $C07x one-shot contract (pdl_timer)
#
# Usage:  run_joy_suites.sh   (from verilog/, MSYS2 shell)
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH"
export SHELL=/c/msys64/usr/bin/sh
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../src/fpga/core/apple2e"
M="$HERE/../machine"
MISROOT="$HERE/../../Apple-II_MiSTer"
VERILATOR=/c/msys64/ucrt64/bin/verilator_bin
MAKE=/c/msys64/ucrt64/bin/mingw32-make.exe
WARN_FLAGS="-Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch"

overall=0
build_run() {
    t="$1"; shift
    obj="obj_dir_joy_$t"
    log="$obj.log"
    rm -rf "$obj"
    ( "$VERILATOR" --binary --timing -j 4 --top "$t" $WARN_FLAGS \
        --Mdir "$obj" "$@" ) >"$log" 2>&1
    vr=$?
    if [ $vr -ne 0 ] || grep -qE "%Error" "$log"; then
        echo "BUILD-FAIL $t (rc=$vr)"; grep -E "%Error" "$log" | head -5; overall=1; return
    fi
    ( cd "$obj" && "$MAKE" -f "V$t.mk" "V$t" ) >>"$log" 2>&1
    if [ $? -ne 0 ] || [ ! -x "$obj/V$t.exe" ]; then
        echo "LINK-FAIL $t"; tail -5 "$log"; overall=1; return
    fi
    out="$( "$obj/V$t.exe" 2>&1 )"; runrc=$?
    echo "$out" | grep -E "PASS|FAIL" | tail -4
    if [ $runrc -eq 0 ] && ! echo "$out" | grep -qE "FAIL"; then
        echo "=== $t: OK"
    else
        echo "=== $t: FAIL (rc=$runrc)"; overall=1
    fi
}

for t in tb_joystick_input tb_paddle_gameport; do
    build_run "$t" "$S/joystick_input.sv" "$S/pdl_timer.v" "tb/$t.sv"
done

# gate TB: needs the OSK + machine osk + font ROM; run with CWD at the
# Apple-II_MiSTer root (font ROM $readmemh is CWD-relative)
obj="obj_dir_joy_tb_joy_gate"
log="$obj.log"
rm -rf "$obj"
( "$VERILATOR" --binary --timing -j 4 --top tb_joy_gate $WARN_FLAGS \
    --Mdir "$obj" \
    "$S/apple2e_osk.v" \
    "$M/osk/virtual_keyboard_controller.sv" \
    "$M/osk/virtual_keyboard_overlay.sv" \
    "$M/keyboard.v" \
    "$M/rom.v" \
    "$M/apple2_font_rom.v" \
    "$S/joystick_input.sv" \
    "tb/tb_joy_gate.sv" ) >"$log" 2>&1
vr=$?
if [ $vr -ne 0 ] || grep -qE "%Error" "$log"; then
    echo "BUILD-FAIL tb_joy_gate (rc=$vr)"; grep -E "%Error" "$log" | head -5; overall=1
else
    ( cd "$obj" && "$MAKE" -f "Vtb_joy_gate.mk" "Vtb_joy_gate" ) >>"$log" 2>&1
    if [ $? -ne 0 ] || [ ! -x "$obj/Vtb_joy_gate.exe" ]; then
        echo "LINK-FAIL tb_joy_gate"; tail -5 "$log"; overall=1
    else
        out="$( cd "$MISROOT" && "$HERE/$obj/Vtb_joy_gate.exe" 2>&1 )"; runrc=$?
        echo "$out" | grep -E "PASS|FAIL|T[1-5]" | tail -8
        if [ $runrc -eq 0 ] && ! echo "$out" | grep -qE "FAIL"; then
            echo "=== tb_joy_gate: OK"
        else
            echo "=== tb_joy_gate: FAIL (rc=$runrc)"; overall=1
        fi
    fi
fi
exit $overall
