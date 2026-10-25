#!/usr/bin/env bash
# run_tb_speaker_i2s.sh - build + run the 555-speaker->I2S unit test
# (pure self-driving TB: verilator --binary --timing; CWD must be the
# apple2e-pocket repo root). Exits 0 iff the TB prints SPEAKER-I2S PASS.
set -u
cd "$(dirname "$0")/../.."     # repo root
Q=/c/msys64/ucrt64/bin
export PATH=/c/msys64/tmp/makeshim:$Q:/c/msys64/usr/bin:/ucrt64/bin:/usr/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
export SHELL=/c/msys64/usr/bin/sh
mkdir -p /c/msys64/tmp/makeshim
cp -f "$Q/mingw32-make.exe" /c/msys64/tmp/makeshim/make.exe

"$Q/verilator_bin.exe" --version 2>&1 | head -1
rm -rf obj_tb_speaker_i2s
"$Q/verilator_bin.exe" --binary --timing --sched-zero-delay -j 4 \
    --top tb_speaker_i2s \
    src/fpga/core/apple2e/speaker_i2s.v verilog/tb/tb_speaker_i2s.sv \
    -Mdir obj_tb_speaker_i2s > obj_tb_speaker_i2s.build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then
    echo "BUILD-FAIL rc=$rc"
    grep -iE "error|warning" obj_tb_speaker_i2s.build.log | head -10
    exit 1
fi
echo "build ok"
./obj_tb_speaker_i2s/Vtb_speaker_i2s.exe > obj_tb_speaker_i2s.run.log 2>&1
rc=$?
grep -E "TB:" obj_tb_speaker_i2s.run.log
if [ "$rc" = 0 ] && grep -q "TB: SPEAKER-I2S PASS" obj_tb_speaker_i2s.run.log; then
    echo "TB-RESULT: PASS"
    exit 0
fi
echo "TB-RESULT: FAIL rc=$rc"
exit 1
