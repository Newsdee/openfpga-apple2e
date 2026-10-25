# Build 2026-10-25_1616_j10_j11_ship

## Identity
- **Logic:** 09:26 disk-proven base + **J8 Y-flip** + **J10** (joystick option
  removed: no cfg_joy_word, no 0x01F00004 bridge traffic, mode hardwired
  Absolute = analog stick + d-pad snap) + **J11** (overlay visibility =
  OSK visible OR ~9.4 s post-reset boot window; `OVL_DEBUG=1` build gate).
- **Purpose:** shippable candidate after the disk-regression bisection.
  The 15:24 bisect proved this logic family boots disks (two-line delta
  isolated as the J7/J9 culprit and now absent).
- **Source state:** uncommitted WIP at 2026-10-25 ~15:50. See plan doc
  J8-J11 for the full delta table from the 09:26 base.

## Artifacts
| File | SHA-256 | Size |
|---|---|---|
| `apf_stream_video.rbf` | `fb12992677a89eb5969d7858c2b352b2417393458dd3baa83be37c98f2762844` | 1,622,388 |
| `bitstream.rbf_r` | `209d5452e576c58c1313d9e4859704b4b4307cb31f0e80b56df55bbe30382dac` | 1,622,388 |

## Quartus (flow complete 16:16, 0 errors)
- **OVL_DBG = 1 CONFIRMED in map.rpt** (the 14:54/15:18 mid-compile miss was
  checked this time - see plan doc J10 "Overlay miss explained").
- Resources: 6,682 regs (up vs 15:24's 6,295: overlay now actually
  synthesized + boot-window counter), 1,527,836 mem bits (identical), 4 DSP.
- Timing: 80/80 TNS 0.000; mp2 worst setup 0.988 ns @85C (positive; slack
  proven not to be the disk-load discriminator).

## Simulation (pocket_boot, 15:47)
- read-back check: Reboot-only (no joystick option) OK
- PDL-PROBE: hardwired Absolute, X ALIVE, Y ALIVE, `Y-flip PASS (81/7f)`
- SMOKE BOOT OK: frames=9 reads=0 crc=74EA1324 mt=1 (byte-exact baseline)

## Manifest
core.json 0.2.2; interact.json: ONLY "Reboot on load" (Joystick variable
removed - the host no longer writes/reads 0x01F00004 at all).

## Hardware test (pending at time of archive)
Expect: disk boots; badge + verify lines visible ~9.4 s after boot/reboot,
then clean screen; keyboard open => diagnostics visible; analog stick +
d-pad with correct Y; Core Settings shows only "Reboot on load".
If disks boot => 0.2.2 shippable; remaining polish = J9 drive-status
pixels + two-line fitter mystery (open issue, option must not return in old
form).
