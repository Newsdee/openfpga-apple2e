#!/usr/bin/env bash
# verilate_ntsc_line0.sh - build+run tb_ntsc_line0 (first-line / left-edge probe)
#
# Same discipline as verilate_ntsc_parity.sh: regenerate the q17 tree from the
# pinned donor, verify the donor is still byte-pinned, build --binary --timing,
# relink+launch chained (host AV grace window).
#
# Usage:  bash verilog/verilate_ntsc_line0.sh [clean]
# Exit:   0 = build+run ok (check "TB: LINE0 PASS/FAIL" in the log)
set -uo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"          # verilog/
ROOT=..                        # repo root
PY=/c/msys64/ucrt64/bin/python.exe
mkdir -p /c/msys64/tmp/makeshim
cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe 2>/dev/null || true

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir_ntsc_line0 ntsc_line0_build.log ntsc_line0_run.log
    exit 0
fi

echo "=== regenerating machine/video/*_q17.sv ==="
$PY $ROOT/tools/gen_video_q17.py || { echo "generator FAILED"; exit 1; }
$PY $ROOT/tools/gen_video_q17.py --check || { echo "q17 drift check FAILED"; exit 1; }

echo "=== verifying machine/ is still byte-identical to the donor ==="
if ! ( cd $ROOT && bash check_machine_sync.sh >/dev/null 2>&1 ); then
    echo "machine/ OUT OF SYNC with the donor - a result here would prove nothing."
    exit 1
fi

V=$ROOT/machine/video

verilator_bin --binary --timing -j 4 \
    --top tb_ntsc_line0 \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    --Mdir obj_dir_ntsc_line0 \
    $V/video_pipeline_q17.sv \
    $V/apple_composite_q17.sv \
    $V/composite_decoder_q17.sv \
    $V/vga_controller.v \
    tb/tb_ntsc_line0.sv \
    > ntsc_line0_build.log 2>&1
vrc=$?
if [ $vrc -ne 0 ]; then
    echo "verilator build FAILED (see ntsc_line0_build.log)"; tail -30 ntsc_line0_build.log; exit 1
fi

( cd obj_dir_ntsc_line0 && rm -f Vtb_ntsc_line0 Vtb_ntsc_line0.exe && \
  /c/msys64/ucrt64/bin/mingw32-make.exe -f Vtb_ntsc_line0.mk Vtb_ntsc_line0 > ../ntsc_line0_mk.log 2>&1 && \
  ./Vtb_ntsc_line0.exe ) > ../ntsc_line0_run.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
    if [ -s ntsc_line0_mk.log ]; then tail -20 ntsc_line0_mk.log; fi
    echo "run FAILED (exit $rc). No output at all => suspect the host AV grace window; re-run."
    exit $rc
fi
grep -E "TB:|LINE0-DIFF|EDGE-COLOUR|FAIL" ntsc_line0_run.log | head -40
exit 0
