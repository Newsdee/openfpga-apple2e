# Build 2026-11-02_2352 — v0.3.0, OVL_DEBUG=0 (shipping overlay off)

## What changed vs the 2250 build
- `apf_stream_video_top.v`: `parameter OVL_DEBUG = 1'b0;` (was 1). Disables the
  on-screen HD/PC/DA debug text + lines now that HDV bring-up is verified.
  The drive **lamps are NOT gated by OVL_DEBUG** — they remain active.
- No other RTL changes. HDV auto-boot + two-tone lamps + HDV big-endian fix all
  carried over from the 2250 build.

## Quartus 17.0.2 Lite (5CEBA4F23C8, top apf_stream_video)
- A&S: Successful
- Fit: Successful — **10,991 / 18,480 ALMs (59%)**, 13,741 registers
- STA: **TNS 0.000** all constraints (tightest setup slack 0.866 ns, Slow 1100mV 85C)
- Asm: Successful — 0 errors, 1 benign warning (NUM_PARALLEL_PROCESSORS)
- ALM delta vs 2250 (13,011): **−2,020** — the freed logic is the debug overlay
  text/lines removed by OVL_DEBUG=0 (lamps remain).

## Bitstream
- Source `.rbf` SHA-256: `fb3e536996dd7b26405e78fc2f132c1484157194d16506eee216245b60b2f89f` (1,698,948 B)
- `bitstream.rbf_r` SHA-256: `e3d82c9c67c6c3100eaef2c7a1dc423afd030c66c510d6fddc3e0643df41bbe0`

## Card config (this build + current sd_root JSONs)
- `video.json`: scaler modes **10:9 / 70:24 / 10:9** (Fit / Integer=true-70:24 / Integer+=fill-10:9);
  display mode **CRT Trinitron only** (`0x10`).
- `core.json`: **0.3.0**, framework **2.0**.
- To apply: re-copy just `bitstream.rbf_r` (JSONs already on card).
