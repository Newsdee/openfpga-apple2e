# Build 2026-10-30_1159_v027_bootmedia

Owner-run full compile (quartus_sh --flow compile apf_stream_video) on the
working tree that adds the **Boot Media combined option**, the **HDV fetch
timeout**, and the **on-screen HD debug line** on top of the
2026-10-30_0937_v027_oskcold tree.

## Why

Hardware run of the 0937 build: selecting a `.hdv` stopped the floppy from
booting, and the HD never booted either ("nothing happens"). The ROM does
this correctly per its slot scan (HD card found before the floppy) — the
failure moved to the HDV fetch path, which had **no timeout**: a 0x0180
the host never completes holds `cpu_wait_hdd` high forever (permanent
machine freeze). There was also no way to take the HD card off the bus at
runtime, so a selected HDV blocked the floppy with no recovery short of
changing the media selection.

## What changed vs the 2026-10-30_0937 build

- **`interact.json`**: "Floppy Eject" (id 7, 0x01F00010) replaced by
  **"Boot Media" (id 8, same address, write-only, persisted)**:
  0=Both (HD card + floppy; ROM tries HD first, falls back to floppy) /
  1=Floppy (HD card off the bus) / 2=HDD (floppy unmounted).
- `apf_stream_video_top.v`:
  - `cfg_media_word` latches the write (proven write-only pattern — the
    01F00xxx read-back wildcard is untouched).
  - `media_m` (2-bit, synch_3 to 14.318 MHz); bit1 = WOZ eject level
    (HDD entry); bit0 = `hd_off_m` gate: slot-7 mux returns the
    empty-slot value (0x00) and `hdd` is deselected, so the ROM
    slot-scan signature check (C701=$20/C703=$00/C705=$03) never
    matches and falls through to the slot-6 WOZ drive. Default
    (host never wrote) = 00 = Both = bit-identical to the pre-gate
    wiring. hdd.v is untouched.
  - 16-bit `hd_dbg` sync (74a -> 14M) of {cpu_wait, fault, state, host
    err, fetch count} for the overlay debug line.
- `hdv_bridge.sv`:
  - `parameter [27:0] FETCH_TO = 28'h0FFFFFFF` (~3.6 s at 74.25 MHz):
    a 0x0180/0x0184 that never completes aborts to IDLE, releases the
    CPU stall, and latches `hdv_fault` (cleared by a clean completion or
    reset). No more permanent freezes. (28'h1000_0000 does not fit 28
    bits — 2^28 needs 29 — default is the 28-bit max.)
  - New diagnostic outputs: `hdv_state` (FSM), `hdv_fault`,
    `hdv_fetch_cnt` (completed 0x0180 fetches, saturates at 255).
- `sdram_status_overlay.v`: new `hd_dbg_m` input + glyph 'H' + line
  `HD=S F=F E=E N=NN W=W` (rows 65..71, col 460; inside the existing
  10 s OVL_DBG window, gated by OVL_DBG && debug_en like the other
  debug lines): S=bridge state (0 idle, 1 fetch, 2 walk-in, 3 walk-out,
  4 arm, 5 write), F=timeout fault, E=last host err (0=OK), N=completed
  fetches, W=6502 stalled right now.

Carried unchanged from 0937: OSK Reset = cold boot, 10 s debug overlay
window (OVL_DBG_WIN_CYCLES), HDV read-only path (hdd.v 1-cycle M10K +
bridge + hdd_rom), WOZ floppy, joy2key 0.2.7, HD slot = raw .hdv only.

## Compile (Quartus Prime 17.0.2 Lite, 5CEBA4F23C8)

- Fit: ALM 12,498/18,480 (68%), registers 14,144, pins 224/224 (100%),
  RAM 193/308, DSP 29/66, PLLs 2/4.
  (vs 0937: ALM +230, registers +129 — media gate + timeout counter +
  debug sync + overlay line; no logic removed.)
- STA: TNS 0.000 all corners.
- Assembler: Successful 2026-10-30 11:59.

## Artifacts

- `apf_stream_video.rbf`     1,754,888 B  sha256 c43236f93ddf445d3de6b8f9a2f6f1c77aef73a6e089859f4be8865f08753230
- `bitstream.rbf_r`          1,754,888 B  sha256 33fe15123ceeb1c8a7e58ad03d6827b80cfe7fcfb826acaf0b508c650b530ced
- `core.json` 0.2.7 (6th bitstream at this version; H6 bump pending owner decision)
- `interact.json` — 5 options: Reboot on load (2), Color Preset (4),
  DPad Keys (5), Fire Keys (6), **Boot Media (8, 0x01F00010, write-only,
  persisted, default Both)**

## Sim gates (pre-compile)

- `tb_hdv_bridge`: **5/5 PASS** — T1-T4 regression intact + new
  T5 (host never completes -> timeout releases the CPU, fault latches,
  a clean fetch recovers and clears the fault; FETCH_TO shrunk to
  1024 bridge clocks in the TB).
- `pocket_boot` full machine: build clean, `--smoke` SMOKE BOOT OK
  (frames=10, mt=1, identical to the pre-change smoke).
- Overlay unit TBs unaffected: the new line is inside the OVL_DBG gate
  (T9 pass-through intact); T8's two DUTs see identical tie-offs.

## Still to verify on hardware (H5)

1. **Boot Media = Floppy with a `.hdv` still selected -> the floppy MUST
   boot** (the exact regression the owner hit; proves the slot-7 gate).
2. Boot Media = HDD or Both + `.hdv` selected, OSK Reset (cold boot),
   photograph the 10 s window:
   - `W=1` stuck with `S=1`, later `F=1` -> the host 0x0180 never
     completed (check `E` — non-zero names the host-side error).
   - `S=0, N>0, E=0, W=0` but no HD boot -> transfer worked; inspect
     block 0 content (offset/endianness/deferload mapping, or the
     image's own block 0).
   - `N=0, W=0` -> the ROM never executed a C0F0 READ (boot path did not
     commit to the HD).
3. Joystick released + OSK Open-Apple latch clear ($C77F trap); trigger
   the read explicitly with C700G / PR#7.
