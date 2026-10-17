#!/usr/bin/env python3
"""Convert a Quartus raw .rbf bitstream to the APF .rbf_r form.

RBF_R = every byte of the .rbf bit-reversed (Analogue packaging format).
Usage:  rbf2rbf_r.py input.rbf [output.rbf_r]
(default output = input name with .rbf_r extension)
Prints SHA-256 of both files so a stale-card bitstream can be detected
(skill rule: rebuild => re-reverse; compare hashes).
"""
import hashlib, sys, os

def rev_byte(b: int) -> int:
    return int('{:08b}'.format(b)[::-1], 2)

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + '.rbf_r'
    data = open(src, 'rb').read()
    out = bytes(rev_byte(b) for b in data)
    with open(dst, 'wb') as f:
        f.write(out)
    print(f"{os.path.basename(src)} ({len(data)} B) -> {os.path.basename(dst)}")
    print(f"  sha256 in : {sha256(src)}")
    print(f"  sha256 out: {sha256(dst)}")

if __name__ == '__main__':
    main()
