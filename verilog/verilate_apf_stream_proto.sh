#!/usr/bin/env bash
# verilate_apf_stream_proto.sh - build the Phase 1 streaming-pattern prototype
# harness (tb_apf_stream_proto) with Verilator (MSYS2 UCRT64).
#
# Self-contained: the prototype (apf_stream_proto.v) generates the test
# patterns and forms the APF video contract; the testbench checks it. No
# machine sources, no ROMs, no apf_top - just the two files.
#
# Pure self-driving testbench (no C++ main): build with `verilator --binary`
# (provides the sc_time_stamp() stub --timing links need).
#
# Usage:  verilate_apf_stream_proto.sh [clean]
set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
ROOT=..

# make.exe shim (AGENTS.md: verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_dir_streamproto
    exit 0
fi

verilator_bin --binary --timing -j 4 \
    --top tb_apf_stream_proto \
    -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
    -CFLAGS "-O2" \
    --Mdir obj_dir_streamproto \
    $ROOT/src/fpga/core/apple2e/apf_stream_proto.v \
    tb/tb_apf_stream_proto.sv

echo "build ok: obj_dir_streamproto/Vtb_apf_stream_proto (self-contained, no ROMs)"
