#!/usr/bin/env python3
"""Convert a B&W logo PNG to the Analogue Pocket core icon.bin format.

Pocket icon spec (Analogue docs, packaging-a-core):
  - 36x36 monochrome canvas, 16-bit pixels, brightness in the upper byte.
  - fully on  = 0xFF00, fully off = 0x0000.
  - stored rotated 90 degrees counter-clockwise.
  - icon color may be inverted in the UI, so supply black-and-white only.

Conversion done here:
  1. composite RGBA over white (background => light => "off")
  2. grayscale, downscale to 36x36 (LANCZOS)
  3. threshold: dark = on, light = off
  4. rotate 90 CCW (the stored orientation)
  5. emit 16-bit words (default little-endian; --be for big-endian)

Usage:
  python make_icon.py <src.png> <out.bin> [le|be]
"""
import sys
from PIL import Image

CANVAS = 36


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    endian = sys.argv[3].lower() if len(sys.argv) > 3 else 'le'
    if endian not in ('le', 'be'):
        sys.exit('endian must be le or be')

    im = Image.open(src).convert('RGBA')
    bg = Image.new('RGBA', im.size, (255, 255, 255, 255))
    bg.alpha_composite(im)
    g = bg.convert('L').resize((CANVAS, CANVAS), Image.LANCZOS)
    g = g.point(lambda p: 0xFF if p < 128 else 0x00)  # dark=on, light=off

    up = g.load()
    print('upright 36x36 (what the logo reads as), #=on:')
    for y in range(CANVAS):
        print(''.join('#' if up[x, y] else '.' for x in range(CANVAS)))

    stored = g.rotate(90, expand=True)  # 90 CCW
    px = stored.load()
    data = bytearray()
    for y in range(CANVAS):
        for x in range(CANVAS):
            v = px[x, y]  # 0x00 or 0xFF
            hi, lo = v, 0x00  # brightness in the UPPER byte
            data += bytes([lo, hi]) if endian == 'le' else bytes([hi, lo])
    with open(out, 'wb') as f:
        f.write(data)
    print(f'\nwrote {out}: {len(data)} bytes (expect {CANVAS * CANVAS * 2}), endian={endian}')
    print('stored orientation (rotated 90 CCW), #=on:')
    for y in range(CANVAS):
        print(''.join('#' if px[x, y] else '.' for x in range(CANVAS)))


if __name__ == '__main__':
    main()
