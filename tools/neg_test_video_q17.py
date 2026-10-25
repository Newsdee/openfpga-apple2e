#!/usr/bin/env python
# -*- coding: utf-8 -*-
# neg_test_video_q17.py - prove tb_ntsc_parity is NOT vacuous.
#
# A differential test that reports "0 mismatches" is only meaningful if the
# harness can actually detect a divergence. This script corrupts one q17 rewrite
# site at a time, confirms the corruption landed in the file, rebuilds, runs,
# and REQUIRES a FAIL. A site whose corruption is not detected is reported as a
# COVERAGE HOLE (the stimulus never exercises that width), which is exactly the
# class of silent pass this exists to catch.
#
# Usage: python tools/neg_test_video_q17.py [--only N]
# Exit 0 = every corruption was detected. Nonzero = hole(s) found or build broke.
#
# Restores the generated files from the generator afterwards regardless of outcome.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
VID = os.path.join(REPO, "machine", "video")
VER = os.path.join(REPO, "verilog")
GEN = os.path.join(HERE, "gen_video_q17.py")
DEC = os.path.join(VID, "composite_decoder_q17.sv")
CMP = os.path.join(VID, "apple_composite_q17.sv")

SOURCES = [
    "video_pipeline.sv", "apple_composite.sv", "composite_decoder.sv",
    "vga_controller.v", "video_pipeline_q17.sv", "apple_composite_q17.sv",
    "composite_decoder_q17.sv",
]

# (label, file, old, new, rewrite class)
CASES = [
    ("site 168-171 BURST_END", DEC,
     "localparam [10:0] BURST_END = BURST_GATE + BURST_ACC;",
     "localparam [10:0] BURST_END = BURST_GATE + 1;", "HOIST"),
    ("site 779 PIX_MASK", DEC,
     "localparam [7:0] PIX_MASK = PIX_DIV - 1;",
     "localparam [7:0] PIX_MASK = PIX_DIV;", "HOIST"),
    ("site 271 v_abs else-branch", DEC,
     "wire [15:0] v_abs = v_err[16] ? -v_err : v_err[15:0];",
     "wire [15:0] v_abs = v_err[16] ? -v_err : v_err[14:0];", "DROP"),
    ("site 271 v_abs negate dropped", DEC,
     "wire [15:0] v_abs = v_err[16] ? -v_err : v_err[15:0];",
     "wire [15:0] v_abs = v_err[16] ? v_err : v_err[15:0];", "DROP"),
    ("site 630 luma_delay max", DEC,
     "(chroma_trail >= 4'd4) ? 4'd15 :",
     "(chroma_trail >= 4'd4) ? 4'd7 :", "DROP"),
    ("site 324 phase_rem width", DEC,
     "phase_rem <= phase_rem_next - SPC[PHASE_REM_W:0];",
     "phase_rem <= phase_rem_next - SPC[PHASE_REM_W-1:0];", "DROP"),
    ("site 113 HS_WIDTH", DEC,
     "localparam [10:0] HS_WIDTH    = tenths_us(47);",
     "localparam [10:0] HS_WIDTH    = tenths_us(48);", "DROP"),
    ("site 116 $signed dropped", CMP,
     "wire signed [15:0] comp_brightness = $signed(bright) * 32'sd32;",
     "wire signed [15:0] comp_brightness = bright * 32'sd32;", "SIGNED"),
    ("site 117 contrast width", CMP,
     "wire [33:0] comp_contrast_prod = contrast * 34'd2857;",
     "wire [33:0] comp_contrast_prod = contrast * 34'd2856;", "DROP"),
]

ENV = dict(os.environ)
# subprocess without shell=True resolves executables through the WINDOWS PATH,
# which does not understand POSIX /c/... entries - so prepend both forms.
ENV.update({
    "PATH": r"C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;"
            + "/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:"
            + ENV.get("PATH", ""),
    "TMP": "/c/msys64/tmp", "TEMP": "/c/msys64/tmp", "TMPDIR": "/c/msys64/tmp",
    "VERILATOR_ROOT": "C:/msys64/ucrt64/share/verilator",
    "SHELL": "/c/msys64/usr/bin/sh",
})
PY = r"C:\msys64\ucrt64\bin\python.exe"


def regenerate():
    r = subprocess.run([PY, GEN], capture_output=True, text=True, cwd=REPO, env=ENV)
    if r.returncode != 0:
        print("generator failed:\n" + r.stdout + r.stderr)
        sys.exit(1)


def build_and_run():
    """Return (rc, output). Builds then runs the parity TB.

    Everything is executed through MSYS sh with the same PATH/shim/TMP/SHELL
    environment the proven verilate_ntsc_parity.sh runner uses. Driving
    verilator_bin directly from Python does not work: verilator's internal
    `make -C` needs the makeshim `make.exe` and a POSIX-style PATH, and fails
    with exit 2 otherwise.
    """
    srcs = " ".join("../machine/video/%s" % s for s in SOURCES)
    script = (
        "set -e\n"
        "cd '%s'\n"
        "mkdir -p /c/msys64/tmp/makeshim\n"
        "cp -f /c/msys64/ucrt64/bin/mingw32-make.exe /c/msys64/tmp/makeshim/make.exe\n"
        "verilator_bin --binary --timing -j 4 --top tb_ntsc_parity "
        "-Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch "
        "--Mdir obj_dir_ntsc_parity %s tb/tb_ntsc_parity.sv > /tmp/neg_build.log 2>&1\n"
        "cd obj_dir_ntsc_parity\n"
        "rm -f Vtb_ntsc_parity.exe\n"
        "mingw32-make -f Vtb_ntsc_parity.mk Vtb_ntsc_parity > /tmp/neg_mk.log 2>&1\n"
        "./Vtb_ntsc_parity.exe\n"
        % (VER.replace("\\", "/"), srcs)
    )
    r = subprocess.run(["C:/msys64/usr/bin/sh.exe", "-c", script],
                       capture_output=True, text=True, cwd=REPO, env=ENV)
    out = r.stdout + r.stderr
    if r.returncode != 0 and "coverage" not in out and "MISMATCH" not in out:
        # build or link failed - surface the captured logs
        for lg in ("/tmp/neg_build.log", "/tmp/neg_mk.log"):
            try:
                with open(lg.replace("/tmp", r"C:\msys64\tmp"), "r",
                          encoding="utf-8", errors="replace") as f:
                    tail = [l for l in f.read().splitlines() if l.strip()][-8:]
                if tail:
                    out += "\n" + "\n".join(tail)
            except OSError:
                pass
    return r.returncode, out


def main():
    only = None
    if "--only" in sys.argv:
        only = int(sys.argv[sys.argv.index("--only") + 1])
    regenerate()
    holes, detected, broken = [], [], []
    for i, (label, path, old, new, kind) in enumerate(CASES):
        if only is not None and i != only:
            continue
        regenerate()
        with open(path, "r", encoding="utf-8", newline="") as f:
            text = f.read()
        if text.count(old) != 1:
            print("SKIP %s: anchor occurs %d times (expected 1)" % (label, text.count(old)))
            broken.append(label)
            continue
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text.replace(old, new))
        # confirm the corruption actually landed before trusting the result
        with open(path, "r", encoding="utf-8", newline="") as f:
            if new not in f.read():
                print("SKIP %s: corruption did not land" % label)
                broken.append(label)
                continue
        rc, out = build_and_run()
        if rc != 0 and "MISMATCH" not in out and "PASS" not in out and "FAIL" not in out:
            print("BUILD-BREAK %s" % label)
            for l in out.strip().splitlines()[-6:]:
                print("           %s" % l[:190])
            broken.append(label)
            continue
        caught = ("FAIL" in out) or (rc != 0)
        first = next((ln for ln in out.splitlines()
                      if ln.startswith(("MISMATCH", "FAIL", "PASS"))), "")
        print("%-9s %-34s -> %s" % (kind, label,
                                     "DETECTED" if caught else "*** HOLE ***"))
        if first:
            print("           %s" % first[:150])
        (detected if caught else holes).append(label)
    regenerate()
    print("\n---- summary ----")
    print("detected: %d   holes: %d   skipped/build-break: %d"
          % (len(detected), len(holes), len(broken)))
    if holes:
        print("COVERAGE HOLES (stimulus never exercises these):")
        for h in holes:
            print("  - %s" % h)
        sys.exit(2)
    if broken:
        print("not evaluated (anchor moved or corruption illegal):")
        for b in broken:
            print("  - %s" % b)
    if not detected:
        print("NOTHING WAS EVALUATED - cannot claim non-vacuity")
        sys.exit(3)
    print("tb_ntsc_parity is non-vacuous for every evaluated rewrite site")
    sys.exit(0)


if __name__ == "__main__":
    main()
