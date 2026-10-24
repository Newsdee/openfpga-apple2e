#!/bin/bash
# Build + run tb_woz_mount_race (M1 no-boot corner-case repro).
# Real woz_mount_ctl + UNCHANGED disk_ii_woz + a simple sector-service model.
# Proves the reset-release collision: coincident mount edge + reset release
# loses the internal `mount`; a second reset recovers it.
#
# Run from apple2e-pocket/ (or anywhere; it resolves its own path).
#   bash verilog/verilate_woz_mount_race.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POCKET="$(cd "$HERE/.." && pwd)"
VERILATOR="C:/msys64/ucrt64/bin/verilator_bin.exe"
export VERILATOR_ROOT="C:/msys64/ucrt64/share/verilator"
# ucrt64 bin BEFORE usr/bin (else g++ resolves to the MSYS frontend and can't
# find cc1plus); makeshim gives bare `make` the mingw32-make the -binary step needs.
mkdir -p /c/msys64/tmp/makeshim
cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe 2>/dev/null || true
export PATH="/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
export SHELL="/c/msys64/usr/bin/sh"
export SHELL_IS_BASH=1
export TMP="/c/msys64/tmp"; export TEMP="/c/msys64/tmp"; export TMPDIR="/c/msys64/tmp"

WOZ="$POCKET/src/fpga/core/woz"
APPLE="$POCKET/src/fpga/core/apple2e"

BUILD="$HERE/u7_race"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

SRC=(
  "$WOZ/disk_ii_woz.sv"
  "$WOZ/woz_floppy_controller.sv"
  "$WOZ/woz_cell525.sv"
  "$WOZ/woz_bram.sv"
  "$WOZ/flux_drive.v"
  "$WOZ/disk_ii_rom.v"
  "$APPLE/woz_mount_ctl.v"
  "$POCKET/verilog/tb/tb_woz_mount_race.sv"
)

echo "=== verilate tb_woz_mount_race ==="
"$VERILATOR" --binary --timing -sv --top-module tb_woz_mount_race \
    -Wno-fatal -Wno-lint -Wno-NULLPORT -Wno-width \
    "${SRC[@]}" --Mdir obj_race -o tb_woz_mount_race 2> verilator.log
if ! grep -qiE "error" verilator.log; then
  echo "verilate OK"
else
  echo "=== verilate errors ==="; grep -iE "error" verilator.log | head -20
  exit 2
fi

echo "=== run ==="
./obj_race/tb_woz_mount_race
