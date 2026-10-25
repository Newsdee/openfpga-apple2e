#!/usr/bin/env python3
# gen_pattern.py <out> - deterministic NONZERO 64 KiB hex image (Phase A2).
#
# byte(addr) = (addr + (addr // 256)) & 0xFF, one 2-hex token per line, LF.
# Exactly one address (0) is zero; all other 65,535 are nonzero, so a
# successful all-address readback against this formula proves the
# $readmemh path really loaded file contents (Verilator's default-zero
# memory cannot pass this).
import sys


def main():
    out = sys.argv[1]
    with open(out, "wb") as f:
        for a in range(65536):
            f.write(("%02x\n" % ((a + a // 256) & 0xFF)).encode("ascii"))
    print("generated %s (65536 tokens, byte = (a + a//256) & 0xFF)" % out)


if __name__ == "__main__":
    main()
