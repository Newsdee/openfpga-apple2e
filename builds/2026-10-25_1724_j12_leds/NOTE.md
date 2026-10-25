# Build 2026-10-25_1724_j12_leds

## Identity
- **Logic:** 09:26 disk-proven base + J8 Y-flip + J10 (joystick option
  removed, Absolute hardwired) + J11 rev2 (overlay = OSK visible OR ~4.7 s
  post-reset boot window, 26-bit counter) + **J12** (always-on 2x2
  drive-status LEDs top-right: green=drv_active, red=drv_motor,
  white=drv_ack). `OVL_DEBUG=1` build gate.
- **Purpose:** shippable candidate #2 after the 16:16 build: shorter
  diagnostics window (owner found 9.4 s "always on") + the J9 drive lamps.
- **Source state:** uncommitted WIP at 2026-10-25 ~16:15.

## Artifacts
| File | SHA-256 | Size |
|---|---|---|
| `apf_stream_video.rbf` | `2f4be5c77c0c2129d989221ed4e091c475ac56ffc691b4a48c129847c03ffd32` | 1,620,508 |
| `bitstream.rbf_r` | `5b60115701377bf32200db77f58b1a214b5b892398335be2797f94fb11976520` | 1,620,508 |

Staging verified: rbf2rbf_r re-derivation matches staged + sd_root copies.

## Quartus (flow complete 17:24, 0 errors)
- **OVL_DBG = 1 CONFIRMED in map.rpt** (pre-test check, per J10 lesson).
- Resources: 6,696 regs (+14 vs 16:16), 1,527,836 mem bits (identical), 4 DSP.
- Timing: 80/80 TNS 0.000; mp2 worst setup 0.978 ns @85C (positive).

## Simulation (pocket_boot, 16:20)
- read-back check (Reboot-only) OK; PDL-PROBE hardwired Absolute, X ALIVE,
  Y ALIVE, `Y-flip PASS (81/7f)`; SMOKE BOOT OK frames=9 crc=74EA1324 mt=1
  (byte-exact baseline).

## Manifest
core.json 0.2.2; interact.json: only "Reboot on load".

## Hardware test (pending at archive time)
Expect: disk boots; badge + verify lines ~4.7 s after boot/reboot then
clean; LEDs top-right always visible (green steady when drive active,
red on motor, white flashing on IO); keyboard open => diagnostics;
Core Settings shows only "Reboot on load". If all pass => 0.2.2 shippable.
