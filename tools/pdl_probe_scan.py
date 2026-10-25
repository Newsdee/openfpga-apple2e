#!/usr/bin/env python
# Scan a raw WOZ v1 image for 6502 instructions that reveal the PDL
# protocol a title uses: standard ($C070/$C071 bit-7 poll, $C030 arm)
# vs the Pocket-core convention ($C07x arm, $C064/$C065 bit-7 poll).
import sys

data = open(sys.argv[1], "rb").read()

pats = [
    (b"\xAD\x70\xC0", "LDA $C070  (standard X poll)"),
    (b"\xAD\x71\xC0", "LDA $C071  (standard Y poll)"),
    (b"\xAD\x30\xC0", "LDA $C030  (standard arm)"),
    (b"\xAD\x64\xC0", "LDA $C064  (core-convention X poll)"),
    (b"\xAD\x65\xC0", "LDA $C065  (core-convention Y poll)"),
    (b"\xAD\x60\xC0", "LDA $C060  (gameport instant read)"),
    (b"\x8D\x30\xC0", "STA $C030"),
    (b"\x2D\x70\xC0", "BIT $C070"),
    (b"\x2D\x71\xC0", "BIT $C071"),
    (b"\xA9\x70\xC0", "LDY $C070"),
    (b"\xB9\x70\xC0", "LDA $C070,X"),
    (b"\xB9\x71\xC0", "LDA $C071,X"),
    (b"\xB9\x64\xC0", "LDA $C064,X"),
    (b"\xB9\x65\xC0", "LDA $C065,X"),
    (b"\xA5\x70",     "LDA $70,ZP  (zero-page, listed for context)"),
    (b"\xA5\x30",     "LDA $30,ZP  (zero-page, listed for context)"),
]

print("file: %s (%d bytes)" % (sys.argv[1], len(data)))
for pat, name in pats:
    n = 0
    idx = 0
    while True:
        i = data.find(pat, idx)
        if i < 0:
            break
        n += 1
        idx = i + 1
    print("%-34s %d" % (name, n))
