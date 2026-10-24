#!/bin/bash
# Build + run tb_woz_mount_race_fixed -- the SAME repro against a PATCHED engine
# (disk_ii_woz_patched.sv) carrying the one-line corner-case correction, to prove
# the fix resolves the collision. The pinned core/woz/disk_ii_woz.sv is untouched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POCKET="$(cd "$HERE/.." && pwd)"
VERILATOR="C:/msys64/ucrt64/bin/verilator_bin.exe"
export VERILATOR_ROOT="C:/msys64/ucrt64/share/verilator"
mkdir -p /c/msys64/tmp/makeshim
cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe 2>/dev/null || true
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
export SHELL="/c/msys64/usr/bin/sh"; export SHELL_IS_BASH=1
export TMP="/c/msys64/tmp"; export TEMP="/c/msys64/tmp"; export TMPDIR="/c/msys64/tmp"

WOZ="$POCKET/src/fpga/core/woz"
APPLE="$POCKET/src/fpga/core/apple2e"

BUILD="$HERE/u7_race_fixed"
rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

SRC=(
  "$HERE/u7_race/disk_ii_woz_patched.sv"   # the PATCHED engine (module disk_ii_woz_patched)
  "$WOZ/woz_floppy_controller.sv"
  "$WOZ/woz_cell525.sv"
  "$WOZ/woz_bram.sv"
  "$WOZ/flux_drive.v"
  "$WOZ/disk_ii_rom.v"
  "$APPLE/woz_mount_ctl.v"
  "$HERE/u7_race/tb_woz_mount_race_fixed.sv"
)

echo "=== verilate tb_woz_mount_race_fixed (patched engine) ==="
"$VERILATOR" --binary --timing -sv --top-module tb_woz_mount_race_fixed \
    -Wno-fatal -Wno-lint -Wno-NULLPORT -Wno-width \
    "${SRC[@]}" --Mdir obj_fix -o tb_woz_mount_race_fixed 2> verilator.log
if ! grep -qiE "error" verilator.log; then echo "verilate OK"; else
  echo "=== verilate errors ==="; grep -iE "error" verilator.log | head -20; exit 2
fi

echo "=== run (patched engine) ==="
./obj_fix/tb_woz_mount_race_fixed
