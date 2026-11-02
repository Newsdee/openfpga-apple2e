# Build 2026-10-30_0742_v027_eject

Owner-run full compile (quartus_sh --flow compile apf_stream_video) on the
working tree that adds **Floppy Eject** + the **10 s debug-overlay window** on
top of the HDV M10K build.

## What is in this bitstream (vs the 2026-10-29_1240 HDV M10K build)

New since that build:
- **Floppy Eject** (`woz_mount_ctl.v` + `apf_stream_video_top.v`): interact id 7
  "Floppy Eject" (Loaded/Ejected), write-only at `0x01F00010`. While Ejected the
  WOZ drive is held unmounted so the machine does not boot the floppy; releasing
  it re-mounts the still-loaded image without a host reload. `eject_req` gated,
  so the default (Loaded) path is bit-identical to before.
- **Debug-overlay window** (`apf_stream_video_top.v`): `OVL_DBG_WIN_CYCLES`
  parameter, default 10 s (the hardwired `0x3FFFFF` was ~0.29 s despite a stale
  "4.7 s" comment — the reason the on-screen diagnostics could not be
  photographed). Draw-only; no data-path logic.

Carried from the HDV M10K build (unchanged this build): HDV read-only
(`hdd.v` 1-cycle `u_sector_ram` M10K, `hdv_bridge.sv`, `hdd_rom.v`), the WOZ
floppy path, joy2key 0.2.7, `.a2k` profiles.

## Compile (Quartus Prime 17.0.2 Lite, 5CEBA4F23C8)

- A&S: Successful (13,205 registers, 224 pins).
- Fit: Successful — ALM 12,267/18,480 (66%), registers 14,064, pins 224/224
  (100%), RAM 193/308 (63%), DSP 29/66, PLL 2/4.
- STA: **TNS 0.000** all corners. Worst setup +1.178 ns (mp2 divclk), clk_74a
  +1.877 ns, hold met (+0.326/+0.351).
- Assembler: OK, `apf_stream_video.rbf` produced 2026-10-30 07:41.

## Artifacts

- `apf_stream_video.rbf`   1,750,384 B  sha256 95434ccff9b35e44a3597b6960ae6747981da30acbccc3714e98827ce6a6b4dd
- `bitstream.rbf_r`        1,750,384 B  sha256 908f4cf94306d1ffb0e104bdee079731615ad9980d4b4c371944bbd6fb3302cb
- `core.json` 0.2.7 (kept at 0.2.7 — 4th bitstream at this version; H6 bump pending owner decision)
- `data.json` 3 slots (disk id1, hdv id2 deferload, plus existing) — unchanged
- `interact.json` 5 options — **Floppy Eject added** (id 7, writeonly, persist, 0x01F00010)

## Sim gates (pre-compile, this tree)

- HDD equivalence: PASS (rows=7600).
- HDV bridge: ALL CHECKS PASSED (T1 read / T2 protect / T3 NO_DEVICE / T4 write).
- woz_mount_ctl: ALL PASS incl. new T10 eject (unmount / held-blocks-fresh-OK /
  release re-mounts).
- pocket_boot: build clean (full-machine smoke infeasible in wall time here).

## Still to verify on hardware (H5)

- Floppy Eject: Ejected => machine does not boot the floppy; Loaded => restores.
- 10 s overlay window: the MT=/RD=, AC=/MO=, ST=/A=/F=, RQ= lines now last long
  enough to photograph.
- HDV read: boot a ProDOS/Total Replay HD image, confirm catalogue + file read.
- WOZ floppy boot + joystick + audio + NTSC colour regression (the full-machine
  `tb_woz_machine` is a ~7 h Verilator sim — treated as hardware acceptance).
