#!/usr/bin/env python
# -*- coding: utf-8 -*-
# gen_osk_q17.py - generate Quartus 17-compatible copies of the OSK sources
# (machine/osk/virtual_keyboard_overlay_q17.sv and
#  machine/osk/virtual_keyboard_controller_q17.sv).
#
# Why: Quartus Prime 17.0.2's SystemVerilog parser rejects two syntaxes the
# canonical OSK files use (the MiSTer core compiles them with a newer
# Quartus): the `N'(expr)` size cast (Error 10170 "near text: '.'") and the
# `bit` data type (Error 10161). The canonical machine/ copies must stay
# byte-identical with Apple-II_MiSTer/rtl/osk (checked by
# check_machine_sync.sh), so the QSF compiles these generated variants
# instead. Verilator keeps using the canonical files.
#
# Transforms (behavior-preserving):
#   overlay:    drop every `N'(EXPR)` cast, leaving `EXPR`. Exact because at
#               all 60 cast sites the assignment LHS is exactly N bits wide,
#               so the assignment already truncates to N bits - the same
#               result as the cast. (Verified per site at generation time.)
#   controller: `parameter bit NAME = V` -> `parameter NAME = V`. The three
#               affected parameters (SNAP_ENABLED, WRAP, DIAGONAL_LOCKED)
#               are only used in boolean conditions, so the default 32-bit
#               parameter type is behavior-identical. (The controller's
#               `function/task automatic` is accepted by Quartus 17.)
#
# Usage:
#   python gen_osk_q17.py            # (re)generate the q17 variants
#   python gen_osk_q17.py --check    # regenerate, compare, exit 1 on drift
#
# Pure stdlib; byte-safe (no EOL normalization - the sources' EOLs are kept).

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OSK = os.path.join(REPO, "machine", "osk")
JOBS = [
    # (source, destination, transform)
    (os.path.join(OSK, "virtual_keyboard_overlay.sv"),
     os.path.join(OSK, "virtual_keyboard_overlay_q17.sv"),
     "overlay"),
    (os.path.join(OSK, "virtual_keyboard_controller.sv"),
     os.path.join(OSK, "virtual_keyboard_controller_q17.sv"),
     "controller"),
]


def cast_sites(line):
    """Return list of (start, end, n, expr) for every N'(expr) in the line."""
    casts = []
    for m in re.finditer(r"(\d+)'\(", line):
        n = int(m.group(1))
        i = m.end()          # just after '('
        depth = 1
        j = i
        while j < len(line) and depth:
            if line[j] == "(":
                depth += 1
            elif line[j] == ")":
                depth -= 1
            j += 1
        if depth:
            raise SystemExit("unbalanced parens in cast at: %r" % line)
        casts.append((m.start(), j, n, line[i:j - 1]))
    return casts


def lhs_widths(text):
    widths = {}
    for m in re.finditer(r"(?:reg|wire)\s*\[(\d+)\s*:\s*(\d+)\]\s+(\w+)", text):
        lo, hi, name = int(m.group(2)), int(m.group(1)), m.group(3)
        if lo <= hi:
            widths[name] = hi - lo + 1
    return widths


def generate_overlay(src_text):
    widths = lhs_widths(src_text)
    lines = src_text.splitlines(keepends=True)
    out = []
    n_casts = 0
    for line in lines:
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        casts = cast_sites(line)
        if not casts:
            out.append(line)
            continue
        for (s, e, n, expr) in casts:
            # verify LHS width == cast width (the drop-cast invariant)
            # lhs = the identifier assigned on this statement
            am = re.search(r"(\w+)\s*=\s*$", line[:s].rsplit(";", 1)[-1])
            if not am:
                am = re.search(r"(\w+)\s*=\s*[^;]*$", line[:s])
            lhs = am.group(1) if am else None
            if lhs is None:
                raise SystemExit("cannot find LHS for cast: %r" % line)
            w = widths.get(lhs)
            if w != n:
                raise SystemExit(
                    "cast width %d != LHS %s width %r (drop-cast transform "
                    "would change behavior): %r" % (n, lhs, w, line))
        new = body
        for (s, e, n, expr) in reversed(casts):
            new = new[:s] + expr + new[e:]
        n_casts += len(casts)
        out.append(new + eol)
    text = "".join(out)
    if re.search(r"\d+'\(", text):
        raise SystemExit("cast left behind in generated overlay")
    return text, n_casts


def generate_controller(src_text):
    n = 0
    out_lines = []
    for line in src_text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        m = re.match(r"^(\s*)parameter\s+bit\s+(\w+)\s*=\s*(\d+)\s*(,)?\s*$", body)
        if m:
            n += 1
            out_lines.append("%sparameter %s = %s%s%s" %
                             (m.group(1), m.group(2), m.group(3),
                              m.group(4) or ",", "") + eol)
            continue
        out_lines.append(line)
    text = "".join(out_lines)
    if re.search(r"parameter\s+bit\b", text):
        raise SystemExit("'parameter bit' left behind in generated controller")
    return text, n


def main():
    check = "--check" in sys.argv
    rc = 0
    for src, dst, kind in JOBS:
        with open(src, "r", encoding="utf-8", newline="") as f:
            text = f.read()
        if kind == "overlay":
            text, n = generate_overlay(text)
        else:
            text, n = generate_controller(text)
        if check:
            if not os.path.exists(dst):
                print("FAIL: %s missing (run gen_osk_q17.py)" % os.path.basename(dst))
                rc = 1
                continue
            with open(dst, "r", encoding="utf-8", newline="") as f:
                cur = f.read()
            if cur != text:
                print("FAIL: %s is stale (regenerate: python gen_osk_q17.py)"
                      % os.path.basename(dst))
                rc = 1
            else:
                print("OK     %s in sync (%d rewrites)" % (os.path.basename(dst), n))
        else:
            with open(dst, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            print("wrote %s (%d rewrites)" % (os.path.basename(dst), n))
    sys.exit(rc)


if __name__ == "__main__":
    main()
