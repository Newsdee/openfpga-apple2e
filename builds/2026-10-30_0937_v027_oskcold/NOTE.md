# Build 2026-10-30_0937_v027_oskcold

Owner-run full compile (quartus_sh --flow compile apf_stream_video) on the
working tree that adds **OSK Reset = true cold boot** on top of the
2026-10-30_0742_v027_eject tree.

## Why

Expert review (REVIEW_RESULTS_HDV_BOOT_HWTEST_2026-10-30) showed the ROM's
HD slot-scan only runs on a COLD boot (the cold-reset path at $FA9B-$FAA9
checks $03F2/$03F3 and can JMP $E000 first). The OSK Reset was a WARM reset
(RAM retained), so pressing Reset on hardware could never exercise the HD
boot path. Fix: OSK Reset release now forces the reboot_ctl cold reboot
(RAM sweep + reset hold), NOT gated by the "Reboot on disk change" option
(the user explicitly pressed Reset).

## What changed vs the 2026-10-30_0742 build

- `reboot_ctl.v`: new `osk_cold_req` input; ORed combinationally into
  `cold_reset` (no out-of-reset glitch on the request cycle) and into the
  trigger (with option OFF).
- `apf_stream_video_top.v`: 2FF sync of `osk_cmd_reset` to 14.318 MHz +
  falling edge -> `osk_cold_req`. (osk_cmd_reset already leaves
  `apple2e_osk` in the machine domain, so the 2FF is a same-clock ~140 ns
  delay, not a CDC fix.)
- `verilog/tb/tb_reboot_ctl.sv`: T8 (OSK release cold-boots with the option
  OFF, exact CLR/HOLD window, glitch-checked) + T9 (request during an
  active reboot neither restarts nor extends).

Carried unchanged from the 0742 tree: Floppy Eject option + 10 s debug
overlay window (OVL_DBG_WIN_CYCLES), HDV read-only (hdd.v 1-cycle
u_sector_ram M10K + hdv_bridge + hdd_rom), WOZ floppy, joy2key 0.2.7,
.a2k profiles, HD slot = raw .hdv only (data.json).

## Compile (Quartus Prime 17.0.2 Lite, 5CEBA4F23C8)

- Fit: ALM 12,268/18,480 (66%), registers 14,015, pins 224/224 (100%),
  DSP 29/66. (vs 0742: ALM +1, registers -49 - fitter packing noise on a
  3-FF delta; no logic removed.)
- STA: TNS 0.000 all corners. Worst setup +1.079 ns (mp2 divclk),
  clk_74a +2.344 ns, hold met (+0.346/+0.380/+0.436).
- Assembler: Successful 2026-10-30 09:37 (0 errors, 1 warning).

## Artifacts

- `apf_stream_video.rbf`     1,727,652 B  sha256 6f92f43b718128cafedc1b4cc5d8db689ac5e29e75909da0fa65512ba877ae13
- `bitstream.rbf_r`          1,727,652 B  sha256 f5c69968bb05122f465a4656721c3be274aa4a185842a9e05c4ac8fb4b59ed9e
- `core.json` 0.2.7 (5th bitstream at this version; H6 bump pending owner decision)
- `interact.json` unchanged vs 0742 (5 options incl. Floppy Eject id 7)

## Sim gates (pre-compile)

- `tb_reboot_ctl`: 9/9 PASS (T1-T7 regression + new T8/T9 osk-cold).
- `pocket_boot` full machine: build clean, `--smoke` SMOKE BOOT OK
  (frames=10, t=215.6 ms sim).
- HDD equivalence / HDV bridge / woz_mount_ctl: PASS as of the 0742 tree
  (hdd.v / hdv_bridge.sv / woz_mount_ctl.v unchanged since).

## Still to verify on hardware (H5)

- OSK Reset on the Pocket now cold-boots: RAM cleared, ROM slot-scan runs.
- HDV boot test per REVIEW_RESULTS procedure: raw .hdv staged
  (Assets/apple2e/common: NoxArchaist.HDV + Total Replay v6.1.hdv),
  joystick released, OSK Open-Apple latch clear, trigger C700G/PR#7;
  negative control = Open Apple held -> floppy.
