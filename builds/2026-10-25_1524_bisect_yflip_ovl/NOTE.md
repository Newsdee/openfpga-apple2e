# Build 2026-10-25_1524_bisect_yflip_ovl

## Identity
- **Logic:** exact 09:26 logic (wildcard `01F0xxxx` read-back -> reboot word,
  `cfg_joy_word` init `32'd1`) **+ Y-polarity flip** (J8: negate Y byte before
  the PDL timer, 0x80 remap) **+ `OVL_DEBUG=1`** (diagnostic overlay drawn:
  badge + MT/RD/AC/MO lines).
- **Purpose:** disk-regression bisect (see PLAN_JOYSTICK_INPUT J7/J9). Splits
  the suspects: this build vs the 12:49 card (pure 09:26, proven to boot).
- **Source state:** uncommitted WIP tree at 2026-10-25 ~15:20 (the two-line
  read-back fix and Absolute default are REVERTED in this build; J9 feature
  work not yet started). Reconstructable from the plan doc delta table, but
  not bit-exact guaranteed through today's evolved db/.
- **Manifest:** core.json 0.2.2 (2026-10-25); interact.json Joystick
  `defaultval = 1` (Relative normal - the 09:26-era value, so the host writes
  the same value as the passing builds).

## Artifacts
| File | SHA-256 | Size |
|---|---|---|
| `apf_stream_video.rbf` | `4a0b2863ef38fd48031a9fa3cb58566463750fd5a7c9e6d47a03da9e0cd1835a` | 1,590,264 |
| `bitstream.rbf_r` | `20251978faa0e214f6eab2bd4e27e5556b676516bcd34bbb5d2fe4e7b5be24a9` | 1,590,264 |

## Quartus (flow complete 15:24:36, 0 errors)
- Resources: 6,680 ALM, 6,295 regs, 1,527,836 block memory bits (identical to
  all other builds), 4 DSP.
- Timing: all 80 STA entries TNS 0.000. Worst setup: mp2 (SDRAM machine
  domain) 1.097 ns @85C / 1.024 ns @0C.

## Simulation (pocket_boot, 15:18)
- `PDL-PROBE Y-flip: up=81 down=7f -> PASS (real-hardware convention)`
- `TB: interact read-back: 0x01F00004 -> reboot word (TEMP DISK-BISECT wildcard, as expected)`
- `SMOKE BOOT OK: frames=9 reads=0 crc=74EA1324 mt=1` (crc is the
  storage-result CRC, not frame CRC - unaffected by overlay drawing)

## Hardware test (pending at time of archive)
- Expect to read the top-left badge `M 0 <stage> <status>` + ~5 s detail
  lines (overlay is ON in this build - first build where the badge is visible
  on a failing-or-passing run).
- Verdict:
  - disks BOOT  -> the two lines (read-back fix + Absolute init) are the
    culprit; this build is shippable as interim (disks + Y fix; option-stick
    bug returns temporarily).
  - disks FAIL  -> the Y-flip is the culprit (pure 09:26 proven by the 12:49
    card); the badge data localizes the broken load-chain link.
