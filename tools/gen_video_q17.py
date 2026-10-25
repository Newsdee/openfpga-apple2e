#!/usr/bin/env python
# -*- coding: utf-8 -*-
# gen_video_q17.py - generate Quartus 17-compatible copies of the imported
# donor NTSC video sources, with module names suffixed `_q17` so the canonical
# donor and the candidate can be elaborated side by side in ONE Verilator build
# for the N1 differential parity test.
#
#   machine/video/composite_decoder.sv  -> composite_decoder_q17.sv
#   machine/video/apple_composite.sv    -> apple_composite_q17.sv
#   machine/video/video_pipeline.sv     -> video_pipeline_q17.sv
#   machine/video/vga_controller.v      -> NOT copied (no casts; shared as-is)
#
# Why: Quartus Prime 17.0.2's SystemVerilog parser rejects the `N'(expr)` size
# cast with Error 10170 ("near text: '.'") - the same construct that forced
# tools/gen_osk_q17.py for the OSK overlay. The canonical machine/video/ copies
# must stay byte-identical with Apple-II_MiSTer/rtl/video (checked by
# check_machine_sync.sh), so the QSF will compile these generated variants.
# Verilator's differential test compiles BOTH: canonical as golden reference,
# q17 as candidate.
#
# IMPORTANT - the OSK tool's blanket "drop the cast" transform is NOT valid
# here. It is exact only where the cast sits on the RHS of an assignment whose
# LHS is exactly N bits wide (the assignment already truncates). Several donor
# sites are inside *expressions*, where the cast sets the self-determined width
# and dropping it would widen the arithmetic. Each site below is therefore
# rewritten individually, with the justification recorded, and the generator
# VERIFIES that every expected source pattern occurs exactly once - so a donor
# change silently invalidating a rewrite is a hard error, not a wrong build.
#
# Rewrite classes used:
#   DROP   - remove `N'(...)`, leaving the expression. Exact because the
#            assignment LHS is declared exactly N bits wide (truncation already
#            happens on assignment). Verified against the declaration.
#   HOIST  - introduce an explicitly N-bit `localparam` and substitute it.
#            Exact unconditionally: a declared [N-1:0] localparam truncates its
#            RHS mod 2^N, which is precisely what the cast did, independent of
#            parameter values. Used where the cast sits inside a comparison or
#            a bit-mask expression.
#   SIGNED - replace the `signed'(x)` *signing* cast with `$signed(x)`, which
#            Quartus 17 accepts and which is semantically identical.
#
# Usage:
#   python gen_video_q17.py            # (re)generate the q17 variants
#   python gen_video_q17.py --check    # regenerate, compare, exit 1 on drift
#
# Pure stdlib; byte-safe (reads/writes with newline="" so the donor's CRLF /
# mixed EOLs are preserved exactly - never let an editor re-save these).

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
VID = os.path.join(REPO, "machine", "video")

# --------------------------------------------------------------------------
# Per-site rewrite tables. Each entry is (old, new, justification).
# `old` must appear EXACTLY ONCE in the source or generation fails.
# --------------------------------------------------------------------------

DECODER_SITES = [
    # ---- DROP: localparam declared [10:0], cast is 11 bits -> identical ----
    ("localparam [10:0] HS_WIDTH    = 11'(tenths_us(47));",
     "localparam [10:0] HS_WIDTH    = tenths_us(47);",
     "DROP: LHS declared [10:0] = 11 bits = cast width; assignment truncates"),
    ("localparam [10:0] CLAMP_GATE  = 11'(tenths_us(99));",
     "localparam [10:0] CLAMP_GATE  = tenths_us(99);",
     "DROP: LHS declared [10:0] = cast width 11"),
    ("localparam [10:0] HB_END      = 11'(tenths_us(154));",
     "localparam [10:0] HB_END      = tenths_us(154);",
     "DROP: LHS declared [10:0] = cast width 11"),
    # ---- DROP: parameterized width, LHS declared [HCNT_W-1:0] ----
    ("localparam [HCNT_W-1:0] FRONT_PORCH = HCNT_W'(132);",
     "localparam [HCNT_W-1:0] FRONT_PORCH = 132;",
     "DROP: LHS declared [HCNT_W-1:0] = cast width HCNT_W"),
    # ---- DROP: LHS declared [7:0] = cast width 8 ----
    ("localparam [7:0]         BURST_CONV  = 8'(AXIS);",
     "localparam [7:0]         BURST_CONV  = AXIS;",
     "DROP: LHS declared [7:0] = cast width 8"),
    # ---- HOIST: cast is inside a comparison, so it sets the arithmetic
    #      width. Dropping it would widen the sum to 32 bits (BURST_ACC and
    #      CLAMP_ACC are unsized integer localparams). An 11-bit localparam
    #      truncates mod 2048 exactly as the cast did. ----
    ("wire in_burst  = ({1'b0, hpos} >= BURST_GATE) && ({1'b0, hpos} < BURST_GATE + 11'(BURST_ACC));",
     "wire in_burst  = ({1'b0, hpos} >= BURST_GATE) && ({1'b0, hpos} < BURST_END);",
     "HOIST: see BURST_END localparam (cast set the add width in a compare)"),
    ("wire in_clamp  = ({1'b0, hpos} >= CLAMP_GATE) && ({1'b0, hpos} < CLAMP_GATE + 11'(CLAMP_ACC));",
     "wire in_clamp  = ({1'b0, hpos} >= CLAMP_GATE) && ({1'b0, hpos} < CLAMP_END);",
     "HOIST: see CLAMP_END localparam"),
    ("wire burst_fin = ({1'b0, hpos} == BURST_GATE + 11'(BURST_ACC));",
     "wire burst_fin = ({1'b0, hpos} == BURST_END);",
     "HOIST: see BURST_END localparam"),
    ("wire clamp_fin = ({1'b0, hpos} == CLAMP_GATE + 11'(CLAMP_ACC));",
     "wire clamp_fin = ({1'b0, hpos} == CLAMP_END);",
     "HOIST: see CLAMP_END localparam"),
    # ---- DROP: LHS v_abs declared [15:0] = cast width 16; the ternary's
    #      other branch is already v_err[15:0], so both are 16 bits. ----
    ("wire [15:0] v_abs = v_err[16] ? 16'(-v_err) : v_err[15:0];",
     "wire [15:0] v_abs = v_err[16] ? -v_err : v_err[15:0];",
     "DROP: LHS declared [15:0] = cast width 16; assignment truncates"),
    # ---- DROP: LHS phase_rem declared [PHASE_REM_W-1:0] = cast width ----
    ("phase_rem <= PHASE_REM_W'(phase_rem_next - SPC[PHASE_REM_W:0]);",
     "phase_rem <= phase_rem_next - SPC[PHASE_REM_W:0];",
     "DROP: LHS phase_rem declared [PHASE_REM_W-1:0] = cast width"),
    # ---- DROP: LHS luma_delay declared [3:0] = cast width 4 ----
    ("wire [3:0] luma_delay = (chroma_trail == 4'd0) ? 4'd0 : (chroma_trail >= 4'd4) ? 4'd15 : 4'((1 << chroma_trail) - 1);",
     "wire [3:0] luma_delay = (chroma_trail == 4'd0) ? 4'd0 : (chroma_trail >= 4'd4) ? 4'd15 : ((1 << chroma_trail) - 1);",
     "DROP: LHS declared [3:0] = cast width 4; assignment truncates"),
    # ---- HOIST: both casts are inside a bit-mask compare. pix_cnt is [7:0],
    #      PIX_DIV is an unsized (32-bit) parameter, so dropping the cast would
    #      widen the AND to 32 bits. An 8-bit localparam truncates mod 256. ----
    ("pix_out <= (pix_cnt & 8'(PIX_DIV - 1)) == 8'(PIX_DIV - 1);",
     "pix_out <= (pix_cnt & PIX_MASK) == PIX_MASK;",
     "HOIST: see PIX_MASK localparam (cast set the AND width in a compare)"),
]

# Inserted immediately after the anchor line, preserving the anchor's EOL.
DECODER_INSERTS = [
    ("localparam [7:0]         BURST_CONV  = AXIS;",
     ["// q17: HOIST rewrites for the 11'(BURST_ACC)/11'(CLAMP_ACC) casts that sat",
      "// inside comparisons. Declared 11-bit, so each truncates mod 2048 exactly",
      "// as the donor cast did, independent of the unsized integer localparams.",
      "localparam [10:0] BURST_END = BURST_GATE + BURST_ACC;",
      "localparam [10:0] CLAMP_END = CLAMP_GATE + CLAMP_ACC;"]),
    ("localparam [7:0]         BURST_CONV  = AXIS;",
     ["// q17: HOIST rewrite for the two 8'(PIX_DIV - 1) casts inside the pix_out",
      "// mask compare. Declared 8-bit, so it truncates mod 256 exactly as the",
      "// donor cast did; pix_cnt is [7:0] so the AND width is unchanged.",
      "localparam [7:0] PIX_MASK = PIX_DIV - 1;"]),
]

COMPOSITE_SITES = [
    # ---- SIGNED + DROP: `signed'(bright)` is a *signing* cast -> $signed().
    #      Outer 16'() drops because LHS comp_brightness is signed [15:0]. ----
    ("wire signed [15:0] comp_brightness = 16'(signed'(bright) * 32'sd32);",
     "wire signed [15:0] comp_brightness = $signed(bright) * 32'sd32;",
     "SIGNED+DROP: signed'(x)->$signed(x); outer 16' drops (LHS signed [15:0])"),
    # ---- DROP: LHS comp_contrast_prod declared [33:0] = 34 bits = cast width,
    #      so the multiply is already evaluated in a 34-bit context. ----
    ("wire [33:0] comp_contrast_prod = 34'(contrast) * 34'd2857;",
     "wire [33:0] comp_contrast_prod = contrast * 34'd2857;",
     "DROP: LHS declared [33:0] = 34 bits = cast width; context already 34"),
]

# Module / instance renaming so golden and candidate coexist in one build.
RENAMES = {
    "composite_decoder": "composite_decoder_q17",
    "apple_composite": "apple_composite_q17",
    "video_pipeline": "video_pipeline_q17",
    # vga_controller has no casts and is shared unmodified by both trees.
}


def apply_sites(text, sites, fname):
    for old, new, why in sites:
        n = text.count(old)
        if n != 1:
            raise SystemExit(
                "%s: rewrite anchor occurs %d times (expected exactly 1) - the "
                "donor changed, re-derive this site:\n  %s" % (fname, n, old))
        text = text.replace(old, new)
    return text


def apply_inserts(text, inserts, fname):
    for anchor, newlines in inserts:
        # match the anchor line plus its original EOL, insert after it
        m = re.search(re.escape(anchor) + r"(\r\n|\n|\r)", text)
        if not m:
            raise SystemExit("%s: insert anchor not found: %s" % (fname, anchor))
        eol = m.group(1)
        block = "".join(ln + eol for ln in newlines)
        text = text[:m.end()] + block + text[m.end():]
    return text


def rename_modules(text, fname):
    """Rename module declarations and instantiations of the copied subtree.

    Only whole-word occurrences are touched, and `vga_controller` is deliberately
    absent from RENAMES so both trees share the one unmodified copy (it has no
    casts). A negative lookahead stops `apple_composite` matching inside
    `apple_composite_q17` on a second pass.
    """
    for old, new in RENAMES.items():
        # module declaration: `module foo (` / `module foo #(`
        text = re.sub(r"\bmodule\s+%s\b(?!_)" % re.escape(old),
                      "module %s" % new, text)
        # instantiation: `foo #(` or `foo u_inst (`.
        # (?!_q17) is load-bearing: without it the pattern re-matches inside an
        # already-renamed `module foo_q17` (its `_q17\n(` satisfies the
        # `_\w+\s*\(` branch) and produces `foo_q17_q17`.
        text = re.sub(r"(?<![\w.])%s(?!_q17)(?=_\w+\s*\(|\s+#\s*\(|\s+[A-Za-z_]\w*\s*\()"
                      % re.escape(old), new, text)
    return text


def strip_comments(text):
    """Remove // and /* */ comments so gates only see real code."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


JOBS = [
    ("composite_decoder.sv", "composite_decoder_q17.sv", DECODER_SITES, DECODER_INSERTS),
    ("apple_composite.sv", "apple_composite_q17.sv", COMPOSITE_SITES, []),
    ("video_pipeline.sv", "video_pipeline_q17.sv", [], []),
]


def main():
    check = "--check" in sys.argv
    rc = 0
    total = 0
    for src_name, dst_name, sites, inserts in JOBS:
        src = os.path.join(VID, src_name)
        dst = os.path.join(VID, dst_name)
        if not os.path.exists(src):
            print("FAIL: missing source %s" % src_name)
            sys.exit(1)
        text = None
        try:
            # generate into memory first so --check never writes
            with open(src, "r", encoding="utf-8", newline="") as f:
                t = f.read()
            t = apply_sites(t, sites, src_name)
            if inserts:
                t = apply_inserts(t, inserts, src_name)
            t = rename_modules(t, src_name)
            # ---- hard gates: no Quartus-17-hostile construct may survive ----
            code = strip_comments(t)
            left = re.findall(r"\d+'\s*\(", code)
            if left:
                raise SystemExit("%s: %d size cast(s) left behind: %r"
                                 % (dst_name, len(left), left[:3]))
            if re.search(r"\bsigned'\s*\(", code):
                raise SystemExit("%s: signed'() cast left behind" % dst_name)
            # the rename must have taken effect, or the two trees collide
            base = src_name.rsplit(".", 1)[0]
            if base in RENAMES and not re.search(r"\bmodule\s+%s\b" % re.escape(RENAMES[base]), t):
                raise SystemExit("%s: module rename did not apply" % dst_name)
            text = t
        except SystemExit as e:
            print("FAIL: %s" % e)
            sys.exit(1)
        n = len(sites)
        total += n
        if check:
            if not os.path.exists(dst):
                print("FAIL: %s missing (run gen_video_q17.py)" % dst_name)
                rc = 1
                continue
            with open(dst, "r", encoding="utf-8", newline="") as f:
                cur = f.read()
            if cur != text:
                print("FAIL: %s is stale (regenerate: python gen_video_q17.py)"
                      % dst_name)
                rc = 1
            else:
                print("OK     %s in sync (%d rewrites)" % (dst_name, n))
        else:
            with open(dst, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            print("wrote %s (%d rewrites)" % (dst_name, n))
    if rc == 0:
        print("video q17: %d cast sites rewritten across %d files"
              % (total, len(JOBS)))
    sys.exit(rc)


if __name__ == "__main__":
    main()
