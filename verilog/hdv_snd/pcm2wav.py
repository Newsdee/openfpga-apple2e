#!/usr/bin/env python3
# pcm2wav.py - wrap raw little-endian s16 PCM in a 48 kHz mono WAV header.
# Usage: python pcm2wav.py in.pcm out.wav
import struct, sys

def main():
    src, dst = sys.argv[1], sys.argv[2]
    pcm = open(src, "rb").read()
    n = len(pcm)
    assert n % 2 == 0, "PCM must be s16 little-endian (even byte count)"
    with open(dst, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + n))
        f.write(b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, 48000, 48000 * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", n))
        f.write(pcm)
    print(f"{dst}: {n//2} samples, {n/2/48000:.3f} s")

if __name__ == "__main__":
    main()
