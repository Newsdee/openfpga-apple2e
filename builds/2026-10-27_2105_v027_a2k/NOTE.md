# Build 2026-10-27 21:05 — core 0.2.7 (joy2key + .a2k profiles)

## Identity
- Revision `apf_stream_video`, top `apf_top_stream`, Cyclone V 5CEBA4F23C8,
  Quartus Prime 17.0.2 Lite.
- Compile: owner-run 2026-10-27 20:22 (A&S) / 20:28 (fitter + assembler),
  all Successful, all timing corners met. rbf2rbf_r + staging 21:05.
- RTL tip: `3b74673` (feat: joy2key Phase 2 - .a2k profiles) on top of
  `cf2bf89` (joy2key rework, this is the first bitstream containing it).

## What this build adds vs the 13:05 build
- **joy2key Phase 2: `.a2k` keymap profiles.** An optional 16-byte `.a2k`
  file next to the disk image (data.json slot 3, id 3, `parameters 6` =
  basename-cloned from the disk, read-only, not required) REPLACES the
  whole joy2key table and overrides the DPad/Fire preset options. No file
  -> preset behavior exactly as before. Editor: `tools/a2k_editor.html`
  (workflow in `tools/A2K_README.md`).
- First bitstream with the joy2key **Select-layer rework + OSD renames**
  from `cf2bf89` (DPad Keys / Fire Keys option names, Select-hold Fire
  layers, value-3 removal) — the 13:05 image predates it.
- Expert review brief: `docs/REVIEW_BRIEF_A2K_2026-10-27.md` (untracked
  by repo convention; check item 5.1 = SDRAM map at 0x01F10000).

## Resources / timing
- ALM 9,218 / 18,480 (50%)  [13:05 build: 9,138 — +80 for the a2k poller,
  byte capture, 129-bit CDC and loader extension]
- Total registers 8,679; RAM 192/308 blocks; DSP 29; PLL 2
- Setup worst slack +1.203 ns (Slow 1100mV 85C, PLL divclk corner)
- Hold  worst slack +0.144 ns (Fast 1100mV 85C)
- TNS 0.000 all corners; no negative slacks
- New map warnings: none (the `casex(bridge_addr)` completeness warning at
  apf_stream_video_top.v:379 is pre-existing). One Quartus-only fix since
  the 13:05 attempt: `a2k_m` made a `wire` (Error 10663 — module output
  port to a reg).

## Artifacts (SHA-256)
- apf_stream_video.rbf    413df8972ea0082d732b8e60d00cd68bd3aa63dc693ca44b9162d633a6e1f6d1
- bitstream.rbf_r         9a6524ff90dffef6a075cef07b57577a4ea3d9f94f788b1fedbbcf6939d6eeb0
- staged at sd_root/Cores/Newsdee.Apple2e/ (core.json 0.2.7, data.json
  now carries slot 3 for .a2k)

## Sim verification (pre-compile, see commit 3b74673)
pocket_boot `--smoke`: exit 0, smokePass=1, all j2k checks pass:
- presets/Select layers/OSK gating (from cf2bf89) still green
- a2k: file present -> up/A/A+Sel = 46/53/57 (file bytes beat presets)
- a2k: byte 3 edit -> reload to 47 without touching presence
- a2k: size word -> 0 (readback-verified) -> presets return (49/20)

## Hardware checklist (pending — one card session covers everything)
1. (0.2.7) OSD: DPad Keys / Fire Keys lists present, Select-layer Fire
   works (hold Select: A -> Space, B -> Return), both default Off.
2. (0.2.7) Off/Off: no keys typed while playing (paddles unaffected).
3. (0.2.7) Direction Keys = Cursor Keys: I/J/K/L typed + absolute paddle
   motion simultaneously.
4. (0.2.7) Fire Keys = U O: A/U, B/O; and the +Select layer.
5. (0.2.7) Any preset on: keys stop while the on-screen keyboard is open.
6. (.a2k) Put `Jungle Hunt.woz` + `Jungle Hunt.a2k` on the SD card, mount
   the disk: DPad up -> F, A -> S, A+Select -> W (file bytes, not the
   preset keys).
7. (.a2k) Remount the same disk (or mount a disk with no `.a2k`): keys
   revert to the active preset options.
8. (.a2k) No `.a2k` anywhere: preset behavior identical to pre-0.2.8
   expectations (regression guard for the loader extension).
9. (0.2.6 regression) disk boot, colour presets, diagnostics hidden while
   OSK open, 555 audio, Reboot option.
