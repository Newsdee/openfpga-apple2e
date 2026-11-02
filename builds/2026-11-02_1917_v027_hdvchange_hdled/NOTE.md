# Build 2026-11-02 1917 - v0.2.7 HDV change-reboot + HD drive lamps

Two items added on top of the HDV big-endian fix (v027_hdvbe), both validated
statically + lint + a clean owner Quartus compile, and (for the boot path) in the
Verilator pocket_boot harness.

## Item 1 - HDV cold-reboot on image change (apf_stream_video_top.v)
The HDV mounts via the 0x008A dataslot update -> hdv_size_q -> hdv_mounted_m,
NOT via the WOZ mount controller, so the existing mc_mount_rise never saw it.
An equivalent rising edge is now derived from the already-synchronized
hdv_mounted_m (no new CDC) and ORed into reboot_ctl, gated by the same
"Reboot on load" interact option (id 2). Changing the HD image now cold-boots
the machine so the ROM slot-scan picks the new HDV up - no OSK Reset needed.

Power-on edge case: reboot_ctl suppresses only the FIRST mount_rise after rst
(its `ever` flag). With two sources (WOZ + HDV) a power-on double-mount would
else cause a spurious second reboot. A ~175 ms power-on blanking window
(MOUNT_BLANK_MAX = 25'd25000000 @ 143.18 MHz) masks every real edge, and a
synthetic one-cycle `blank_arm` rise at the window start pre-arms `ever`
(inert - reboot_ctl excludes first_rise from rebooting). reboot_ctl.v is
UNTOUCHED. The WOZ mc_mount_rise path is unchanged (this does not affect the
pre-existing WOZ MT=0 open finding).

Reset-polarity note: machine_reset_base is active-HIGH
(~rst_sync[1] | ~lock_sync[1] | osk_cmd_reset); the blanking counter clears on
`if (machine_reset_base)`.

## Item 2 - HD drive lamps (sdram_status_overlay.v)
The J9 three 2x2 lamps (top-right, not gated by OVL_DBG, so visible in
gameplay) now share between floppy and HD, decoded in place from hd_dbg_m
(which already carries the bridge FSM state - no new ports):
  green = floppy active  OR HD read in flight  (state 1/2/3 FETCH/WALK_IN/WALK_OUT)
  red   = floppy motor   OR HD write in flight (state 4/5 ARM_WRITE/WRITE)
  white = floppy sector  OR HD block completed (fetch_cnt changed)
hd_dbg_m bit order confirmed = {mounted(15), fault(14), state[13:11],
err[10:8], fetch_cnt[7:0]}; state encoding matches hdv_bridge.sv:349-354 exactly.
Caveats: red stays dark until write-back lands (core is read-only, hdd_protect=1);
white stops blinking after 255 blocks (fetch_cnt saturates by design).

## Validation
- Static: state encoding + bit packing + reset polarity + CDC + reboot_ctl
  pre-arm all verified against source.
- Lint: verilator --lint-only over the full model, exit 0; ZERO new warnings
  (HEAD and this tree both 95 warnings; none in the two changed files).
- Sim: full pocket_boot rebuild exit 0; machine runs with both changes in
  context (t=164ms, frames + video advancing). WOZ smoke not "BOOT OK" only
  due to the pre-existing MT=0 finding (unaffected by these edits).
- Quartus (owner): map/fit/sta/asm all Successful (see below).

## Quartus 17.0.2 Lite, apf_stream_video, 5CEBA4F23C8 (owner-run, 2026-11-02 19:09-19:17)
- A&S: Successful. regs 13,366, pins 224, DSP 29, PLL 2.
- Fit: Successful. ALM 12,884 / 18,480 (70 %), regs 14,244, pins 224/224,
  RAM 193/308 (63 %), DSP 29/66 (44 %), PLL 2/4.
- STA: TNS 0.000 on every constraint; tightest setup 1.182 ns (Slow 0C); all
  hold/recovery/removal/min-pulse slacks positive.
- Asm: Successful, 0 errors, 0 critical warnings. .rbf 1,752,808 bytes.

## Artifacts
- apf_stream_video.rbf  sha256 c7759020ac4ccd820ae33a6d4ea73040c723ca0ccf32e8a033b60e8b35ade8f4
- bitstream.rbf_r       sha256 895c9c56e4378b88113e4fb648551331d4e9b82ca5913ef56f916338a16bdd8a

## Hardware checks still open (not proven by sim)
- Item 1: the reboot-on-change trigger + MOUNT_BLANK_MAX window. Power-on
  double-boot -> lengthen MOUNT_BLANK_MAX; a genuine change ignored -> shorten.
- Item 2: the on-glass lamp colors (decode proven correct; visual confirm).
