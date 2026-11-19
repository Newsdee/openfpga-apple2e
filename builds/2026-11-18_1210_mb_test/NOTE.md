# 2026-11-18 12:10 — Mockingboard test build (post-0.3.6 RC, DEV tree — DO NOT SHIP)

Built on top of the 0.3.6 RC shipping tree (builds/2026-11-18_1100_ship_036,
rbf_r 3b27bbd5...) PLUS the single-instance Mockingboard port per
docs/PLAN_MOCKINGBOARD_PORT_2026-11-18.md:

- src/fpga/core/mockingboard/{mockingboard.v, via6522.v, YM2149.sv} (11:25,
  vendored from ../Apple-II_MiSTer/rtl/mockingboard/ + NOTICE.md).
- apf_stream_video_top.v (11:27): MOCKINGBOARD mb_4 instantiation (:2124),
  cfg_mb_word bridge option register @0x01F00020 (:1398-1401), option CDC
  74a->14.318 (:2106).
- speaker_i2s.v (11:27): stereo mixer stage for MB L/R + speaker.
- sd_root interact.json: "Mockingboard" check variable id=11, address
  0x01F00020, default OFF, writeonly+persist.
- Flow: fit Successful 12:09:55, sta + asm 12:10 (all sources predate map).
- Fit: 15,731/18,480 ALM (85%), 16,967 regs, 198/308 M10K, min slack +0.858 ns
  (vs RC 14,823/80%: MB costs ~900 ALMs - better than the 1.2-2.5k estimate).
- rbf   sha256: d6cb4774ae719668c435ba848895142148c3544668f913948bad95febbc94aed
- rbf_r sha256: fe885e9feb65534625f051f24ef68b90e129c8c1774be32b3872cf7ccc9a42bd
- Dev tree: DEVKEY/SSD diagnostics state per whatever flags the 11:2x tree
  had (sd_root core.json: cartridge_adapter=0, version string 0.3.5,
  sleep_supported=true). NOT the shipping flag set (RC had DEVKEY_DIAG=0,
  OVL_*=0) - verify on-wire banner before interpreting captures.

TEST PROCEDURE (hardware):
1. Full core relaunch (bitstream loads at core start only).
2. Menu: enable "Mockingboard" (id 11) - default OFF must keep audio
   bit-identical to the RC.
3. Boot a MB title (Ultima IV/V music, Berzap! fx); verify music/sfx on
   both channels, speaker audio unchanged when MB idle, no buzz/DC offset.
4. Regression: savestate save+load still works (MB state NOT in blob -
   board resets on wake/load, known limitation per plan §5).

Staged to sd_root/Cores/Newsdee.Apple2e + K:\Cores\Newsdee.Apple2e
(hash-verified). K: previously carried the 0.3.6 RC (3b27bbd5...).
