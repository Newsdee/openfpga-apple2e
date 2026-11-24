#!/usr/bin/env python3
# gen_mb_image2.py - deterministic WOZ2 5.25" image for the multi-block
# control harness (tb_woz_mb_control):
#
#   blocks 0-2  : meta (1536 B): WOZ2 hdr + INFO(60) + TMAP(160) + TRKS(1280)
#   blocks 3-15 : track 0 data, 13 blocks, 51200 bits   (the donor's shape)
#   blocks 16-19: track 1 data,  4 blocks, 20480 bits   (seek-target track)
#   total       : 20 blocks = 10240 bytes
#
# TMAP: [0]=0, [1]=1, rest 0xFF (two legal tracks, the rest unmapped).
# Pattern is per-track so cross-track contamination is detectable:
#   track 0 block b byte i: (( (3+b)*7 + i + 3 ) ^ ((3+b)+i) >> 5 ) & 0xFF
#   track 1 block b byte i: (( (16+b)*11 + i + 5 ) ^ ((16+b)+i) >> 4 ) & 0xFF
#
# Outputs mb_image2.hex (byte-wide $readmemh, one "xx" per line) and prints
# the layout facts the harness asserts.
import struct, zlib, sys

BLK = 512
T0_START, T0_CNT, T0_BITS = 3, 13, 51200
T1_START, T1_CNT, T1_BITS = 16, 4, 20480
T2_START, T2_CNT, T2_BITS = 20, 2, 8192
NBLK = T2_START + T2_CNT          # 22 (qtr tracks 0,1 = physical pair 0; qtr 2 = pair 1)

def t0_byte(i):
    return (((i * 7 + 3) ^ (i >> 5)) & 0xFF)
def t1_byte(i):
    return (((i * 11 + 5) ^ (i >> 4)) & 0xFF)
def t2_byte(i):
    return (((i * 13 + 7) ^ (i >> 6)) & 0xFF)

meta = bytearray()
meta += b'WOZ2' + b'\xff\x0a\x0d\x0a' + b'\x00\x00\x00\x00'   # CRC placeholder
info = bytearray(60)
info[0] = 2      # INFO version 2 (no FLUX required)
info[1] = 1      # 5.25"
info[2] = 0      # not write protected
info[39] = 32    # optimal bit timing = standard
meta += b'INFO' + struct.pack('<I', 60) + info
tmap = bytearray([0xFF] * 160)
tmap[0] = 0
tmap[1] = 1
tmap[2] = 2
meta += b'TMAP' + struct.pack('<I', 160) + tmap
trks = bytearray(160 * 8)
trks[0:8]   = struct.pack('<HHI', T0_START, T0_CNT, T0_BITS)
trks[8:16]  = struct.pack('<HHI', T1_START, T1_CNT, T1_BITS)
trks[16:24] = struct.pack('<HHI', T2_START, T2_CNT, T2_BITS)
meta += b'TRKS' + struct.pack('<I', len(trks)) + trks
assert len(meta) == 1536, len(meta)
crc = zlib.crc32(bytes(meta[12:])) & 0xFFFFFFFF
meta[8:12] = struct.pack('<I', crc)

data = bytearray()
for b in range(T0_START, T0_START + T0_CNT):
    for i in range(BLK):
        data.append(t0_byte(b * BLK + i))
for b in range(T1_START, T1_START + T1_CNT):
    for i in range(BLK):
        data.append(t1_byte(b * BLK + i))
for b in range(T2_START, T2_START + T2_CNT):
    for i in range(BLK):
        data.append(t2_byte(b * BLK + i))

img = bytes(meta) + bytes(data)
assert len(img) == NBLK * BLK
out = sys.argv[1] if len(sys.argv) > 1 else 'mb_image2.hex'
with open(out, 'w') as f:
    for b in img:
        f.write('%02x\n' % b)
print('image: %d bytes (%d blocks), meta=3, t0 start=%d cnt=%d bits=%d, t1 start=%d cnt=%d bits=%d, t2 start=%d cnt=%d bits=%d, crc=%08x'
      % (len(img), NBLK, T0_START, T0_CNT, T0_BITS, T1_START, T1_CNT, T1_BITS, T2_START, T2_CNT, T2_BITS, crc))
