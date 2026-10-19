#!/usr/bin/env python3
# ppm2png.py - convert P6 PPM -> PNG using only the Python stdlib (zlib).
# Usage: python ppm2png.py <file.ppm> [more.ppm ...]
# Writes <file>.png next to each input.
import struct, sys, zlib

def chunk(tag, payload):
    c = struct.pack('>I', len(payload)) + tag + payload
    return c + struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF)

def ppm_to_png(src, dst):
    data = open(src, 'rb').read()
    if data[:2] != b'P6':
        raise SystemExit(f"{src}: not a P6 PPM")
    idx = 2
    def tok():
        nonlocal idx
        while idx < len(data) and data[idx] in b' \t\r\n':
            idx += 1
        start = idx
        while idx < len(data) and data[idx] not in b' \t\r\n':
            idx += 1
        return data[start:idx]
    w = int(tok()); h = int(tok()); maxv = int(tok())
    if maxv != 255:
        raise SystemExit(f"{src}: unsupported maxval {maxv}")
    idx += 1  # single whitespace byte after header
    px = data[idx:]
    if len(px) != w * h * 3:
        raise SystemExit(f"{src}: pixel size {len(px)} != {w}*{h}*3")
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += px[y * w * 3:(y + 1) * w * 3]
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', ihdr)
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    open(dst, 'wb').write(png)
    print(f"{src} -> {dst} ({w}x{h}, {len(png)} bytes)")

for a in sys.argv[1:]:
    ppm_to_png(a, a[:-4] + '.png' if a.endswith('.ppm') else a + '.png')
