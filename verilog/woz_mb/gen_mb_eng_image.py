#!/usr/bin/env python3
# gen_mb_eng_image.py - deterministic images for the engine-level
# multi-block controller TB (tb_woz_mb_eng):
#
# mb_eng2.hex (WOZ2, 82 blocks):
#   blocks 0-2  : meta (1536 B): WOZ2 hdr + INFO(60) + TMAP(160) + TRKS(1280)
#   T0 blocks 3-15  (13 blocks, 51200 bits)   - donor shape
#   T1 block  16    ( 1 block,  4000 bits)
#   T2 blocks 17-48 (32 blocks, 409600 bits)
#   T3 blocks 49-81 (33 blocks, 413696 bits)  - 32+1 split case
#   TMAP: [0..3]=0..3, rest 0xFF
#
# mb_eng_w1.hex (WOZ "v1", 14 blocks = 7168 B):
#   block 0: "WOZ1" hdr(12) + INFO(60, version=1) + TMAP(168) + TRKS header(8)
#            + first 256 data bytes  => TRKS data starts at absolute byte 256
#            (trks_base_block=0, trks_byte_offset=256 - the nonzero-offset case)
#   TRKS data: 6656 raw bytes for entry 0 (track 0); v1_bit_count = u16 LE at
#   data[6648..6649] = 0x1234
#
# Patterns are per-track so cross-track / cross-block contamination is
# detectable; the TB re-derives them (same expressions) as its byte oracle.
import struct, zlib, sys

BLK = 512

def pat(k, i):
    return (((i * (7 + 3 * (k % 5)) + 3 + k) ^ ((i + k) >> 5)) & 0xFF)

# ---------------------------------------------------------------- WOZ2
T0_START, T0_CNT, T0_BITS = 3, 13, 51200
T1_START, T1_CNT, T1_BITS = 16, 1, 4000
T2_START, T2_CNT, T2_BITS = 17, 32, 409600
T3_START, T3_CNT, T3_BITS = 49, 33, 413696
NBLK2 = T3_START + T3_CNT                     # 82

meta = bytearray()
meta += b'WOZ2' + b'\xff\x0a\x0d\x0a' + b'\x00\x00\x00\x00'   # CRC placeholder
info = bytearray(60)
info[0] = 2      # INFO version 2
info[1] = 1      # 5.25"
info[2] = 0      # not write protected
info[39] = 32    # optimal bit timing
meta += b'INFO' + struct.pack('<I', 60) + info
tmap = bytearray([0xFF] * 160)
tmap[0] = 0; tmap[1] = 1; tmap[2] = 2; tmap[3] = 3
meta += b'TMAP' + struct.pack('<I', 160) + tmap
trks = bytearray(160 * 8)
trks[0:8]   = struct.pack('<HHI', T0_START, T0_CNT, T0_BITS)
trks[8:16]  = struct.pack('<HHI', T1_START, T1_CNT, T1_BITS)
trks[16:24] = struct.pack('<HHI', T2_START, T2_CNT, T2_BITS)
trks[24:32] = struct.pack('<HHI', T3_START, T3_CNT, T3_BITS)
meta += b'TRKS' + struct.pack('<I', len(trks)) + trks
assert len(meta) == 1536, len(meta)
crc = zlib.crc32(bytes(meta[12:])) & 0xFFFFFFFF
meta[8:12] = struct.pack('<I', crc)

data = bytearray()
for k, (start, cnt, _bits) in enumerate([(T0_START, T0_CNT, 0),
                                         (T1_START, T1_CNT, 0),
                                         (T2_START, T2_CNT, 0),
                                         (T3_START, T3_CNT, 0)]):
    for b in range(cnt):
        for i in range(BLK):
            data.append(pat(k, (b - start) * BLK + i))

img2 = bytes(meta) + bytes(data)
assert len(img2) == NBLK2 * BLK
with open('mb_eng2.hex', 'w') as f:
    for b in img2:
        f.write('%02x\n' % b)

# ---------------------------------------------------------------- v1
V1_OFFSET = 256                       # TRKS data starts mid-block 0
V1_BITS = 0x1234                       # bit count captured at raw 6648/6649
v1 = bytearray(14 * BLK)               # 7168 bytes, zero-filled
v1[0:4] = b'WOZ1'
v1[4:8] = b'\xff\x0a\x0d\x0a'
v1[8:12] = b'\x00\x00\x00\x00'
info1 = bytearray(60)
info1[0] = 1      # INFO version 1 -> is_woz_v1
info1[1] = 1
info1[2] = 0
info1[39] = 32
p = 12
v1[p:p+4] = b'INFO'; v1[p+4:p+8] = struct.pack('<I', 60); v1[p+8:p+68] = info1
p += 68
v1[p:p+4] = b'TMAP'; v1[p+4:p+8] = struct.pack('<I', 160)
tm1 = bytearray([0xFF] * 160); tm1[0] = 0
v1[p+8:p+168] = tm1
p += 168
assert p == 248, p                     # TRKS header at byte 248, data at 256
v1[p:p+4] = b'TRKS'; v1[p+4:p+8] = struct.pack('<I', 6656)
d = 256
for i in range(6656):
    v1[d + i] = pat(4, i)              # k=4: distinct from every WOZ2 track
v1[256 + 6648] = V1_BITS & 0xFF
v1[256 + 6649] = (V1_BITS >> 8) & 0xFF
# CRC over bytes 12.. (header checksum is not verified by the controller;
# keep it well-formed anyway)
c1 = zlib.crc32(bytes(v1[12:])) & 0xFFFFFFFF
v1[8:12] = struct.pack('<I', c1)

with open('mb_eng_w1.hex', 'w') as f:
    for b in v1:
        f.write('%02x\n' % b)

print('mb_eng2.hex: %d bytes (%d blocks): t0 %d/%d/%d, t1 %d/%d/%d, t2 %d/%d/%d, t3 %d/%d/%d'
      % (len(img2), NBLK2, T0_START, T0_CNT, T0_BITS, T1_START, T1_CNT, T1_BITS,
         T2_START, T2_CNT, T2_BITS, T3_START, T3_CNT, T3_BITS))
print('mb_eng_w1.hex: %d bytes (%d blocks): trks_base=0 offset=%d v1_bits=%04x'
      % (len(v1), 14, V1_OFFSET, V1_BITS))
