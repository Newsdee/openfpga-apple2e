# Build 2026-11-02 2050 - v0.2.7 HD drive lamps (change-reboot reverted)

Follow-up to the 1917 build (v027_hdvchange_hdled). The HDV mount -> forced
cold-reboot (Item 1) is REVERTED; the HD drive lamps (Item 2) remain.

## Why Item 1 was reverted (hardware finding)
The 1917 build's HDV-mount edge fired on the 0x008A dataslot update, i.e.
MID-way through the host's own select / Reset-Enter -> Data-slot-update ->
Reset-Exit sequence. It forced a machine-level RAM-sweep cold reset (~465 us)
in the middle of that handshake, so the 6502 came out of the forced reset
before the host finished arming the HD -> the FIRST HDV select landed on a
black idle screen. Re-selecting the HDV always booted it on its own (no forced
reboot, hdv_mounted_m already high so no new edge), proving the host's select
path is sufficient. So the forced HDV reboot is removed: reboot_ctl is back to
the WOZ-only mc_mount_rise. See the NOTE comment at the reboot_ctl instance in
apf_stream_video_top.v.

## Item 2 - HD drive lamps (kept, unchanged)
sdram_status_overlay.v: the J9 three 2x2 lamps (top-right, not gated by
OVL_DBG) share between floppy and HD, decoded in place from hd_dbg_m:
  green = floppy active  OR HD read in flight  (state 1/2/3)
  red   = floppy motor   OR HD write in flight (state 4/5)
  white = floppy sector  OR HD block completed (fetch_cnt changed)
hd_dbg_m bit order = {mounted(15), fault(14), state[13:11], err[10:8],
fetch_cnt[7:0]}; state encoding matches hdv_bridge.sv:349-354 exactly.
Caveats: red stays dark until write-back lands (read-only core); white stops
blinking after 255 blocks (fetch_cnt saturates by design).

## Validation
- Lint: verilator --lint-only over the full model, exit 0, zero new warnings.
- Quartus (owner, 2026-11-02 20:43-20:51): map/fit/sta/asm all Successful.
  ALM 12,862 / 18,480 (70 %) [down ~22 from 1917 - the removed 25-bit
  blanking counter], regs 14,161, pins 224/224. STA TNS 0.000 on all 80
  constraints. Asm 0 errors, .rbf 1,756,864 bytes.

## Artifacts
- apf_stream_video.rbf  sha256 afb30228b239e7a3387af0aa8125e71d544097fa868df3b06f5bbcbf4eb27af3
- bitstream.rbf_r       sha256 e4e4718c9feec3c715fc3f2f4c8a16809b006fcd4363ac6bdcdfae9faefdbe33

## Hardware checks open
- First HDV select now boots directly (no forced reboot, no black idle, no
  re-select, no OSK Reset).
- HD lamps light during HD fetch (green read / white blink; red stays dark).
