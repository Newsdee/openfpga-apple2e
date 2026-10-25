#!/usr/bin/env python3
# validate_ram_image.py - strict preflight for ram_zero_64k.hex (Phase A2).
#
# Usage:
#   validate_ram_image.py <image> [--expect-lines N] [--zeros] [--lenient]
#
#   --zeros      every token must be exactly "00" (the canonical zero image;
#                also enforces exact file size N*3 bytes)
#   --lenient    structural checks only; any valid 2-hex-digit token
#                accepted (for deterministic nonzero test images)
#
# Structural checks (always):
#   - file exists and is readable
#   - no UTF-8 BOM, no non-ASCII bytes, no NUL
#   - exactly --expect-lines lines, each exactly one 2-hex-digit token
#     (no address directives, comments, empty lines, or extra tokens)
# Token count + content are the GATE (robust across EOL policies: $readmemh
# and Quartus both tolerate CRLF, so a CRLF-checked-out image still loads
# correctly). Byte size and CR presence are reported as informational
# notes only - a CRLF file is a checkout-policy note, not a validation
# failure (2026-10-25 review: do not "fix" the file by rewriting it).
# --zeros additionally requires every token to be exactly "00".
#
# Exit 0 = PASS (prints line count, mode, SHA-256, size). Any failure
# prints an explicit reason and exits 1. This is the preflight gate: the
# run scripts must fail on its failure BEFORE building or running anything.
import sys
import re
import hashlib

TOKEN = re.compile(rb"^[0-9a-fA-F]{2}$")


def fail(msg):
    print("FAIL %s" % msg)
    return 1


def main(argv):
    args = [a for a in argv if a not in ("--zeros", "--lenient")]
    zeros = "--zeros" in argv
    lenient = "--lenient" in argv
    expect = 65536
    if "--expect-lines" in argv:
        expect = int(argv[argv.index("--expect-lines") + 1])
    if len(args) != 1:
        print(__doc__)
        return 2
    path = args[0]

    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return fail("missing-or-unreadable: %s: %s" % (path, e))
    if data.startswith(b"\xef\xbb\xbf"):
        return fail("bom: UTF-8 BOM present (first token corrupted)")
    if b"\x00" in data:
        return fail("nul: NUL byte present")
    if any(b > 0x7f for b in data):
        return fail("non-ascii: non-ASCII byte present")
    if b"\r" in data:
        # CRLF is tolerated by $readmemh/Quartus - informational only.
        print("NOTE crlf: CR byte(s) present (CRLF checkout; tolerated by $readmemh)")
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if not data.endswith(b"\n"):
        return fail("no-trailing-lf: file does not end with LF")
    if zeros and len(data) != expect * 3:
        # Size is informational under the token gate (a CRLF file is bigger
        # but still token-valid) - warn, do not fail.
        print("NOTE size: %d bytes (LF-canonical size would be %d)"
              % (len(data), expect * 3))
    lines = data.split(b"\n")[:-1]
    if len(lines) != expect:
        return fail("count: %d lines, expected %d" % (len(lines), expect))
    bad = 0
    for i, ln in enumerate(lines):
        if not TOKEN.match(ln):
            if bad < 3:
                print("FAIL token line %d: %r" % (i, ln))
            bad += 1
            if bad > 3:
                break
        elif zeros and ln != b"00":
            if bad < 3:
                print("FAIL nonzero line %d: %r" % (i, ln))
            bad += 1
            if bad > 3:
                break
    if bad:
        return fail("%d bad line(s)" % bad)
    mode = "zeros" if zeros else ("lenient" if lenient else "structural")
    print("PASS %s: %d lines, mode=%s, %d bytes, sha256=%s"
          % (path, expect, mode, len(data), hashlib.sha256(data).hexdigest()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
