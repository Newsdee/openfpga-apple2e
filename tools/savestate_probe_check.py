#!/usr/bin/env python3
# savestate_probe_check.py — verify the WORK ITEM 0 transport probe.
#
# The probe backs the savestate "blob" (at BRIDGE address 0x40000000) with a
# pure address-derived ramp: each 32-bit word returns its own address, so
# word i == 0x40000000 + 4*i. Triggering Memories makes the host read that
# region and write it to a Saves/ file. This script checks that file for the
# ramp, and reports:
#   * the file size        -> the savestate_size UNITS (bytes vs words)
#   * the byte order        -> little-endian vs big-endian (the BRIDGE convention)
#   * the base + ramp length -> proves the transport base is correct
#
# Usage:
#   python savestate_probe_check.py <path-to-Saves-file>
#   python savestate_probe_check.py <Saves-dir>        # picks the most recent file
#
# Exit 0 = a valid ramp was found (transport verified), 1 = no ramp.
#
# This is a THROWAWAY diagnostic for the work-item-0 probe (see
# docs/PLAN_SAVESTATES_2026-11-09.md); delete it with the probe.

import sys
import os
import struct

BASE = 0x40000000        # savestate_addr (the probe's blob base)
SIZE_BYTES = 131328      # donor blob size in bytes (USED_WORDS 16416 x 8)


def find_ramp(data, little_endian, max_scan_words=128):
    """Scan 4-byte-aligned offsets for the ramp; return (word_offset, run_length)."""
    fmt = '<I' if little_endian else '>I'
    n = len(data) // 4
    best_off, best_len = -1, 0
    for start in range(0, min(n, max_scan_words)):
        w0 = struct.unpack_from(fmt, data, start * 4)[0]
        if w0 != BASE:
            continue
        length = 0
        for i in range(n - start):
            w = struct.unpack_from(fmt, data, (start + i) * 4)[0]
            if w == BASE + 4 * i:
                length += 1
            else:
                break
        if length > best_len:
            best_off, best_len = start, length
    return best_off, best_len


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)

    target = sys.argv[1]
    if os.path.isdir(target):
        # pick the most recently modified file in the Saves dir
        files = [os.path.join(target, f) for f in os.listdir(target)
                 if os.path.isfile(os.path.join(target, f))]
        if not files:
            print(f"no files in {target}")
            sys.exit(2)
        target = max(files, key=os.path.getmtime)

    with open(target, 'rb') as f:
        data = f.read()

    n_bytes = len(data)
    n_words = n_bytes // 4
    print(f"file        : {target}")
    print(f"size        : {n_bytes} bytes = {n_words} x 32-bit words")
    print(f"  units     : {'BYTES' if n_bytes == SIZE_BYTES else ('WORDS' if n_bytes == SIZE_BYTES * 4 else 'UNEXPECTED')} "
          f"(expected {SIZE_BYTES} B if size=bytes, {SIZE_BYTES*4} B if size=words)")
    print()

    results = {}
    for le in (True, False):
        off, ln = find_ramp(data, le)
        bo = "little-endian" if le else "big-endian"
        results[bo] = (off, ln)
        if ln > 0:
            print(f"  {bo:15s}: ramp of {ln} words at word offset {off} (file 0x{off*4:X})")
        else:
            print(f"  {bo:15s}: no ramp found")

    le_off, le_ln = results["little-endian"]
    be_off, be_ln = results["big-endian"]
    best_ln = max(le_ln, be_ln)

    print()
    if best_ln >= 100:
        if le_ln >= be_ln:
            bo, off = "little-endian", le_off
        else:
            bo, off = "big-endian", be_off
        print(f"PASS: {best_ln} consecutive ramp words, {bo}, base {hex(BASE)} at word {off}.")
        print(f"Transport verified: base + byte-order ({bo}) + size units (see above).")
        print("Next: build the real SDRAM blob + savestate_manager (this probe is throwaway).")
        sys.exit(0)
    else:
        print(f"FAIL: best ramp run = {best_ln} words (need >= 100).")
        print("Check: did the host read at 0x40000000? is the base/byte-order/size as assumed?")
        sys.exit(1)


if __name__ == '__main__':
    main()
