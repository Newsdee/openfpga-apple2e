#!/usr/bin/env bash
# run_hdv_ab.sh - A/B differential: hdv_bridge of b5a3881 (FF array) vs
# the CURRENT working tree (M10K lanes + the 2026-11-21 read-stage fix),
# through the SHIPPING HDV mux and the REAL io_bridge_peripheral (2026-11-21
# expert instruction).
#
#   Build A: tb_hdv_ab.sv + hdv_bridge extracted from b5a3881 (silicon-proven
#            flip-flop array, RD_PRIME_STAGE=1)
#   Build B: tb_hdv_ab.sv + hdv_bridge from the working tree (M10K lanes;
#            after the 2026-11-21 fix, expected to match A byte-for-byte)
#   Shared : hdd.v + hdd_rom.v + common.v (synch_3) + altsyncram_sim +
#            io_bridge_peripheral (port-split wrapper, body verbatim)
#
# The two trees differ ONLY in hdv_bridge.sv (+ the HDV instantiation in
# apf_stream_video_top, whose mux arm this TB replicates verbatim);
# hdd.v / io_bridge_peripheral / common.v / altsyncram_sim are
# byte-identical between b5a3881 and 87e05b7 (checked below).
#
# Usage:  run_hdv_ab.sh [clean]
# Env:    MSYS2 UCRT64 (same facts as run_hdv_bridge.sh).

set -euo pipefail

export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp
export TEMP=/c/msys64/tmp
export TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh

cd "$(dirname "$0")"
ROOT=../..                     # apple2e-pocket/

# make.exe shim (verilated.mk's link step calls bare `make`)
if [ ! -f /c/msys64/tmp/makeshim/make.exe ]; then
    mkdir -p /c/msys64/tmp/makeshim
    cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf obj_a obj_b build work rtl transcript_A.log transcript_B.log
    exit 0
fi

# ---- provenance: the two trees differ only in hdv_bridge (+ stream_top)
git -C "$ROOT" rev-parse --short HEAD
for f in src/fpga/core/hdd.v src/fpga/core/hdd_rom.v src/fpga/apf/common.v \
         src/fpga/apf/io_bridge_peripheral.v verilog/stubs/altsyncram_sim.v; do
    if ! git -C "$ROOT" diff --quiet b5a3881 87e05b7 -- "$f"; then
        echo "FATAL: $f differs between b5a3881 and 87e05b7 - A/B assumption broken"
        exit 1
    fi
done
echo "provenance OK: shared files identical between b5a3881 and 87e05b7"

# ---- work dir: build A's DUT, the shared wrapper, rom copy (CWD-relative
#      $readmemh: the exe runs from this dir, rom in ./rtl/roms/)
rm -rf work build rtl
mkdir -p work build rtl/roms
git -C "$ROOT" show b5a3881:src/fpga/core/hdv_bridge.sv > work/hdv_bridge_a.sv
cp -f "$ROOT/src/fpga/core/hdv_bridge.sv" work/hdv_bridge_b.sv
cp -f "$ROOT/src/fpga/rtl/roms/hddrom.hex" rtl/roms/hddrom.hex

# ---- generate the port-split PMP wrapper (body verbatim) ----
perl ibs_phy_gen.pl "$ROOT/src/fpga/apf/io_bridge_peripheral.v" work/ibs_phy_split.v
# verbatim check: strip the _in/_out/_q/_n suffixes and the comment
# lines; every remaining differing line must reference a phy_sp* port
# or the module name, or be a structural token of the two documented
# insert blocks (combinational next-value block / scaffolding).
perl -pe 's/(phy_sp(?:iclk|imosi|imiso))_(?:in|out|q|n)/$1/g' work/ibs_phy_split.v > work/norm_split.v
if diff "$ROOT/src/fpga/apf/io_bridge_peripheral.v" work/norm_split.v \
        | grep -E '^[<>]' \
        | grep -vE '^\s*[<>]\s*//' \
        | grep -vE 'phy_sp|io_bridge_peripheral' \
        | grep -vE '^\s*[<>]\s*(always @\(\*\) begin|case\(spis\)|endcase|ST_SEND_[A-Z0-9]+: begin|end|\s*)$' \
        | grep -q .; then
    echo "FATAL: ibs_phy_split.v differs from the original beyond the documented phy port split + TX line-driving restructure"
    diff "$ROOT/src/fpga/apf/io_bridge_peripheral.v" work/norm_split.v | head -40
    exit 1
fi
echo "wrapper OK: body verbatim (phy port split + documented TX restructure)"

# ---- build A (FF-array DUT) ----
/c/msys64/ucrt64/bin/verilator_bin.exe \
    --binary --timing -Wno-fatal \
    --Mdir obj_a \
    -sv \
    tb_hdv_ab.sv \
    work/hdv_bridge_a.sv \
    work/ibs_phy_split.v \
    "$ROOT/src/fpga/core/hdd.v" \
    "$ROOT/src/fpga/core/hdd_rom.v" \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/verilog/stubs/altsyncram_sim.v"

f=obj_a/Vtb_hdv_ab__ALL.cpp
[ -f "$f" ] && [ ! -s "$f" ] && rm -f "$f"
make -C obj_a -f Vtb_hdv_ab.mk -j4 Vtb_hdv_ab

# ---- build B (M10K DUT, working tree) ----
/c/msys64/ucrt64/bin/verilator_bin.exe \
    --binary --timing -Wno-fatal \
    --Mdir obj_b \
    -sv \
    tb_hdv_ab.sv \
    work/hdv_bridge_b.sv \
    work/ibs_phy_split.v \
    "$ROOT/src/fpga/core/hdd.v" \
    "$ROOT/src/fpga/core/hdd_rom.v" \
    "$ROOT/src/fpga/apf/common.v" \
    "$ROOT/verilog/stubs/altsyncram_sim.v"

f=obj_b/Vtb_hdv_ab__ALL.cpp
[ -f "$f" ] && [ ! -s "$f" ] && rm -f "$f"
make -C obj_b -f Vtb_hdv_ab.mk -j4 Vtb_hdv_ab

# ---- run both (CWD = this dir; hddrom.hex in ./rtl/roms/) ----
./obj_a/Vtb_hdv_ab.exe > transcript_A.log 2>&1 \
    || { echo "A run failed"; tail -20 transcript_A.log; exit 1; }
./obj_b/Vtb_hdv_ab.exe > transcript_B.log 2>&1 \
    || { echo "B run failed"; tail -20 transcript_B.log; exit 1; }

echo "================ A (b5a3881 FF-array) ================"
cat transcript_A.log
echo "================ B (current M10K) ================"
cat transcript_B.log

# ---- verdict ----
ok=1
grep -q "BURST B0 COLD-88: PASS" transcript_A.log || ok=0
grep -q "BURST B1 WARM-88: PASS" transcript_A.log || ok=0
grep -q "BURST B2 WARM-32: PASS" transcript_A.log || ok=0
grep -q "BURST B3 WARM-16: PASS" transcript_A.log || ok=0
grep -q "BURST B0 COLD-88: PASS" transcript_B.log || ok=0
grep -q "BURST B1 WARM-88: PASS" transcript_B.log || ok=0
grep -q "BURST B2 WARM-32: PASS" transcript_B.log || ok=0
grep -q "BURST B3 WARM-16: PASS" transcript_B.log || ok=0
if [ "$ok" = 1 ]; then
    echo "ALL BURSTS PASS IN BOTH BUILDS"
else
    echo "AT LEAST ONE BURST FAILED IN A BUILD (see transcripts above)"
fi

# transcript diff (ignore the header line naming the tree + the Verilator
# sim-report walltime block, which always differs)
strip_v() { grep -vE '^HDV AB harness start$|: Verilog \$finish$|^ *S i m u l a t i o n|^- *Verilator:' "$1"; }
if diff <(strip_v transcript_A.log) <(strip_v transcript_B.log) > /dev/null; then
    echo "TRANSCRIPTS IDENTICAL: the fixed M10K tree and the FF tree are byte-identical in sim"
else
    echo "TRANSCRIPTS DIFFER:"
    diff transcript_A.log transcript_B.log || true
fi
echo "HDV AB COMPLETE (transcripts: transcript_A.log / transcript_B.log)"
