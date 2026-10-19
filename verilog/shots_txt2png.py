#!/usr/bin/env python
# -*- coding: utf-8 -*-
# shots_txt2png.py - convert the tb_p2b_shots 1-bit text grids to PNG.
#
# Input:  E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/shots/*.txt
#         (each line = one pixel row, '1' = white, '0' = black)
# Output: same names with .png extension.
#
# Pure stdlib (struct + zlib); no PIL required.
#
# Usage:  python shots_txt2png.py [dir]
#   default dir = the shots folder next to this script.

import os
import re
import struct
import sys
import zlib


def png_chunk(tag, data):
    c = struct.pack(">I", len(data))
    c += tag + data
    c += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return c


def write_png(path, width, height, rows):
    # rows: list of strings of '0'/'1', len == width
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)  # 8-bit grayscale
    raw = b""
    for r in rows:
        raw += b"\x00"
        for ch in r:
            raw += b"\xff" if ch == "1" else b"\x00"
    png = b"\x89PNG\r\n\x1a\n"
    png += png_chunk(b"IHDR", ihdr)
    png += png_chunk(b"IDAT", zlib.compress(raw, 6))
    png += png_chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "shots")
    for name in sorted(os.listdir(d)):
        if not re.match(r"^.+\.txt$", name):
            continue
        p = os.path.join(d, name)
        with open(p, "r") as f:
            lines = [ln.rstrip("\r\n") for ln in f if ln.strip() != ""]
        if not lines:
            continue
        width = len(lines[0])
        height = len(lines)
        # trim ragged rows
        rows = [ln[:width] for ln in lines]
        out = os.path.join(d, name[:-4] + ".png")
        n = write_png(out, width, height, rows)
        print("%s  %dx%d  %d bytes" % (os.path.basename(out), width, height, n))


if __name__ == "__main__":
    main()
