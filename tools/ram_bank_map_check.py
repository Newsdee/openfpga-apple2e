#!/usr/bin/env python3
# ram_bank_map_check.py - post-A&S gate for the apf_apple2 map report.
#
# Permanent gate added 2026-11-14 (see docs/EXPERT_BRIEF_RAM_BANK_INFERENCE_
# 2026-11-14.md): apple2e_ram_bank:u_ram_bank must infer as EXACTLY two
# 64KiB (524,288-bit) M10Ks. Two silent failure classes were caught by
# hand in one day:
#   (a) DUPLICATION - a second read port with a distinct address made
#       Quartus duplicate each bank (4 RAMs, +128KiB, A&S "successful",
#       fitter 11802);
#   (b) UNINFERRED - a shared-destination bank-mux read made both banks
#       "uninferred due to asynchronous read logic" (276007) -> A&S 276003.
# This check fails the build on either class BEFORE a fit cycle is spent.
#
# Usage: python ram_bank_map_check.py <apf_apple2.map.rpt>
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ram_bank_map_check.py <apf_apple2.map.rpt>")
        return 2
    with open(sys.argv[1], errors="replace") as f:
        lines = f.read().splitlines()

    # (b) any 276007 uninferred-RAM info naming the module
    uninf = [l.strip() for l in lines
             if "276007" in l and "apple2e_ram_bank" in l]

    # per-hierarchy memory table rows (columns ';'-delimited; field 4 =
    # block memory bits, field 8 = full hierarchy name). Count the depth-1
    # altsyncram instances under u_ram_bank (NOT the deeper auto_generated
    # sub-rows, which repeat the same bit count).
    rows = []
    for l in lines:
        if l.count(";") < 9 or "apple2e_ram_bank:u_ram_bank|altsyncram" not in l:
            continue
        f_ = [x.strip() for x in l.split(";")]
        if not re.fullmatch(r"\d+", f_[4]):
            continue
        if not re.search(r"apple2e_ram_bank:u_ram_bank\|altsyncram:[A-Za-z0-9_]+$",
                         f_[8]):
            continue
        rows.append((f_[4], f_[8]))

    ok = True
    if uninf:
        ok = False
        print("RAM-BANK MAP CHECK FAIL: uninferred RAM in apple2e_ram_bank:")
        for l in uninf:
            print("   " + l)
    n64k = [r for r in rows if r[0] == "524288"]
    if len(n64k) != 2:
        ok = False
        print("RAM-BANK MAP CHECK FAIL: expected exactly 2 x 524288-bit "
              "(64KiB) RAMs under u_ram_bank, found %d:" % len(n64k))
        for bits, name in rows:
            print("   %s bits | %s" % (bits, name))
    if ok:
        print("RAM-BANK MAP CHECK PASS: u_ram_bank = 2 x 64KiB M10Ks, no 276007")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
