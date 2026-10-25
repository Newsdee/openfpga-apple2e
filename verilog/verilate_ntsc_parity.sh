#!/usr/bin/env bash
# verilate_ntsc_parity.sh - N1 differential parity test for the NTSC port
#
# Builds and runs tb_ntsc_parity: the pinned donor video tree (golden) versus
# the generated Quartus-17-compatible tree (candidate, machine/video/*_q17.sv),
# driven from identical stimulus and compared every cycle.
#
# Zero mismatches is the only pass. There is deliberately no acquisition window:
# both sides are the same design from the same reset state, so any divergence is
# a rewrite defect. Coverage gates make an empty run fail rather than pass.
#
# The canonical donor files are used UNMODIFIED as the reference; the q17 files
# are generated, so this script regenerates them first and fails if the
# generator reports drift or a stale output.
#
# Usage:  verilate_ntsc_parity.sh [clean]
# Exit:   0 = PASS, nonzero = FAIL / build error / coverage gate tripped
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
    rm -rf obj_dir_ntsc_parity ntsc_parity_build.log ntsc_parity_mk.log
    exit 0
fi

# ---- the candidate must be freshly generated from the pinned donor ----
echo "=== regenerating machine/video/*_q17.sv ==="
$PY $ROOT/tools/gen_video_q17.py || { echo "generator FAILED"; exit 1; }
$PY $ROOT/tools/gen_video_q17.py --check || { echo "q17 drift check FAILED"; exit 1; }

# ---- the canonical donor must still be byte-pinned ----
echo "=== verifying machine/ is still byte-identical to the donor ==="
( cd $ROOT && bash check_machine_sync.sh ) | tail -1
if ! ( cd $ROOT && bash check_machine_sync.sh >/dev/null 2>&1 ); then
    echo "machine/ OUT OF SYNC with the donor - the golden reference is not the"
    echo "pinned donor, so a PASS here would prove nothing. Re-copy and re-run."
    exit 1
fi

V=$ROOT/machine/video

# --binary (not --exe): these are self-driving SV testbenches with no C++ main,
# and --binary supplies the sc_time_stamp() stub that a --timing link needs.
verilator_bin --binary --timing -j 4 \
    --top tb_ntsc_parity \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    --Mdir obj_dir_ntsc_parity \
    $V/video_pipeline.sv \
    $V/apple_composite.sv \
    $V/composite_decoder.sv \
    $V/vga_controller.v \
    $V/video_pipeline_q17.sv \
    $V/apple_composite_q17.sv \
    $V/composite_decoder_q17.sv \
    tb/tb_ntsc_parity.sv \
    > ntsc_parity_build.log 2>&1
vrc=$?
if [ $vrc -ne 0 ]; then
    echo "verilator build FAILED (see ntsc_parity_build.log)"; tail -30 ntsc_parity_build.log; exit 1
fi

# relink and launch promptly: the host AV layer kills freshly linked PEs after a
# short grace window (documented in the workspace AGENTS.md unit-test ladder).
( cd obj_dir_ntsc_parity && rm -f Vtb_ntsc_parity Vtb_ntsc_parity.exe && \
  /c/msys64/ucrt64/bin/mingw32-make.exe -f Vtb_ntsc_parity.mk Vtb_ntsc_parity > ../ntsc_parity_mk.log 2>&1 && \
  ./Vtb_ntsc_parity.exe )
rc=$?
if [ $rc -ne 0 ]; then
    if [ -s ntsc_parity_mk.log ]; then tail -20 ntsc_parity_mk.log; fi
    echo "run FAILED (exit $rc). If there was no output at all, suspect the host"
    echo "AV grace window: re-run this script (it relinks and launches together)."
fi
exit $rc
