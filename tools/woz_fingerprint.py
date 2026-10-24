#!/usr/bin/env python3
"""woz_fingerprint.py - expected on-screen fingerprint for the M1 storage overlay.

The Pocket core now latches, after every SDRAM readback-verify pass:
  F=  first 16 image bytes            (file bytes [0:16])
  L=  last 16 image bytes             (file bytes [n-16:n])
  W0  zlib-CRC32 of bytes [0:64K)
  W1  zlib-CRC32 of bytes [64K:128K)
  W2  zlib-CRC32 of bytes [128K:192K)
  W3  zlib-CRC32 of bytes [192K:n)     (independent CRCs; empty window = 0)

Run it on the EXACT file the card will serve:

    python tools/woz_fingerprint.py Assets/apple2e/common/disk.woz

and compare the printed values with the always-on overlay lines
(rows 65..95, right side of the Pocket screen):

    W0=XXXXXXXX W1=XXXXXXXX
    W2=XXXXXXXX W3=XXXXXXXX
    F=XXXXXXXXXXXXXXXX
    L=XXXXXXXXXXXXXXXX

A mismatch localizes a hardware-load corruption to a 64 KB region; F/L give
the exact head/tail bytes. Also print N= (length) and the full-file CRC= to
cross-check against the overlay's N=/OK-CRC lines.

--pattern N mode: compute the fingerprint of the synthetic byte pattern used
by verilog/tb/tb_verifier_fp.sv (byte i = (i + i>>8 + i>>16) & 0xFF), so the
TB output can be checked against a real zlib oracle:

    python tools/woz_fingerprint.py --pattern 200000
"""
import sys
import zlib


def pattern_bytes(n):
    return bytes(((i + (i >> 8) + (i >> 16)) & 0xFF) for i in range(n))


def window_crc(data, a, b):
    b = min(b, len(data))
    if a >= b:
        return "00000000"
    return format(zlib.crc32(data[a:b]) & 0xFFFFFFFF, "08X")


def fingerprint(data):
    n = len(data)
    # On-screen (8 bytes fit per line): F= = first 8 bytes, L= = last 8.
    f8 = data[:8].ljust(8, b"\x00")
    l8 = data[-8:].rjust(8, b"\x00") if n else b"\x00" * 8
    print(f"N={n:08X}  CRC={zlib.crc32(data) & 0xFFFFFFFF:08X}")
    print(f"W0={window_crc(data, 0, 65536)} W1={window_crc(data, 65536, 131072)}")
    print(f"W2={window_crc(data, 131072, 196608)} W3={window_crc(data, 196608, n)}")
    print("F=" + f8.hex().upper())
    print("L=" + l8.hex().upper())


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--pattern":
        fingerprint(pattern_bytes(int(sys.argv[2])))
    elif len(sys.argv) == 2:
        with open(sys.argv[1], "rb") as f:
            fingerprint(f.read())
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
