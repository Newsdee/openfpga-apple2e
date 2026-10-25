#!/bin/sh
# One-shot pocket_boot rebuild + headless smoke for the joystick
# integration (2026-10-25). Mirrors run_pocket_boot.bat "build smoke"
# in a single MSYS chain (the AV-safe pattern on this host).
set -x
cd "$(dirname "$0")"
export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh
bash build.sh clean
bash build.sh
./obj_dir/Vtb_pocket_boot.exe --smoke --budget-ms 300000
echo "SMOKE_RC=$?"
