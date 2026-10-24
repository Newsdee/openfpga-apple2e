# Expert review — M1 WOZ floppy: verified disk on hardware, but no boot (mount/engine sequencing)

Self-contained; no prior context. M0 (disk → SDRAM → readback-verify) is
hardware-accepted. M1 adds the WOZ engine + transport + mount, and the **full
machine boots in the Verilator TB** (`tb_u6_boot`, B0+B1 all pass). But on the
real Pocket the machine does not boot from the floppy. This brief asks you to
pinpoint the sequencing bug and recommend the fix + the diagnostics to add.

## 1. Symptom (hardware, real Pocket)

After the owner loads a `.woz` via the data slot and resets (from the on-screen
keyboard), a screenshot shows:

- **Top-right: `OK CRC=55C57822`** — the disk **loaded into SDRAM and
  readback-verified** (res_code=0 / OK). So the M0 storage path is working.
  (Not the DOSMaster fixture — the owner loaded a different disk, CRC `55C57822`.)
- **The Apple IIe display is black** — no DOS boot lines, no cursor. The machine
  is hung, i.e. it is waiting on the floppy track that never arrives.
- **Top-left** is the overlay's *unconditional storage marker* (`M 0 <stage>
  <status>`), not the mount state. The current overlay does **not** render the
  M1 mount/engine state, so we have no direct read on `img_mounted`/`mc_state`.

**Net:** the image is resident + verified in SDRAM, but the WOZ engine is not
serving a track to the machine. Everything between "verified in SDRAM" and
"CPU reads track 0" is suspect.

## 2. What we know is / isn't the cause

- **Not** the SDRAM load/verify (M0, hardware-accepted; `OK CRC` proves it here).
- **Not** a build/synthesis error (A&S + full compile succeeded; 117 warnings,
  all pre-existing/parked).
- The Verilator **full-machine TB passes** (engine serves track 0 from SDRAM,
  machine boots). So the logic is correct in sim; the failure is a
  **hardware-only** difference (timing, reset sequencing, CDC, or a signal that
  the TB drives differently from the real APF host).

## 3. The M1 data path (machine domain, `clk_core_14318`)

```
WOZ engine (disk_ii_woz)
   .IMG_MOUNTED0 ( mc_img_mounted )   <- gates the engine's mount/parse
   .IMG_SIZE     ( mc_img_size )
   .SD_RD/LBA/ACK ( woz_sd_* )
        |
sdram_woz_transport (drive_active = mc_img_mounted, fault_clr = mc_mount_rise)
        |   (fetches sectors from the image in SDRAM on the engine's read)
sdram_sector_fetch -> sdram_word_owner -> io_sdram_pocket (SDRAM)

woz_mount_ctl (por_n = ~sdram_path_rst = ~pll_rst_pulse  [power-on only])
   in : res_valid_m, res_code_m, res_nbytes_m, new_load_m, transport_fault
   out: img_mounted (-> mc_img_mounted), img_size, mount_state_m
```

**Reset domains (the key asymmetry):**
- WOZ engine: `RESET = DD_RESET = machine_reset` (button reset + power-on).
- `woz_mount_ctl` + transport: reset by **`~sdram_path_rst` only**
  (`pll_rst_pulse` = PLL power-on/lock). A **button/OSK reset does NOT reset the
  mount or the transport** — only the engine.

**`data.json` `parameters = 73` (0x49):** bit0 reloadable, bit3 read-only,
**bit6 = reset-around-reload** — the host wraps each disk reload in a machine
reset. So a reload sequence is: 0082 (new generation) → host writes the image to
SDRAM → machine reset asserted → image verified (result) → machine reset released.

## 4. The mount logic (`woz_mount_ctl.v`) — the prime suspect

- `do_mount = (state==ST_UNMOUNTED) && pend_valid && (pend_code==0)`.
- `pend_valid` is set only on `res_rise` = a **0→1 edge** of `res_valid_m`.
- `res_valid` (internal) is **cleared on every `ds0082`** and re-set when the
  result is ready → so it does produce a fresh rising edge per new load.
- Eject: `ST_MOUNTED` → `ST_EJ1` (fall) → `ST_EJ2` (zero-size rise) → `ST_EJ3`
  (fall, then remount if `pend_valid && pend_code==0`, else back to ST_UNMOUNTED).
  Triggered by `new_load_m` (a new 0082) or `transport_fault` while mounted.
- The engine latches `media_present` on the `IMG_MOUNTED` **rising edge**
  (nonzero size); `DD_RESET` wipes the parse and re-pulses the mount from
  `media_present`, so `IMG_MOUNTED`/`IMG_SIZE` must stay **stable across a
  machine reset**.

## 5. My hypotheses (please evaluate / refute)

- **H1 — mount never re-engages after the reset.** The result's `res_rise` and
  the reset-around-reload (bit6) land close together; if the mount is mid-eject
  (`ST_EJ1/2/3`) when `res_rise` fires, the same-cycle `resolve` can consume
  `pend_valid` before the `ST_EJ3` remount branch sees it, dropping the mount
  back to `ST_UNMOUNTED`. (In sim the timing differs, so this stays latent.)
- **H2 — `res_rise` is missed.** `res_valid_m` is a 3-FF sync of `res_valid`; if
  the `ds0082` clear and the re-set are too close in the ctrl domain, the
  synced edge in the machine domain may not register as a clean 0→1.
- **H3 — spurious `transport_fault`.** A one-shot fault (SD_WR invariant / OOR
  LBA) after mount would eject to `ST_UNMOUNTED`. Would show as `mount_state`
  cycling through EJ on hardware.
- **H4 — engine-side, not mount.** `mc_img_mounted` *is* high, but the engine's
  parse fails on hardware (e.g. the transport/sector_fetch SDRAM reads don't
  complete under real DDR timing), so `scan_failed` holds `disk_mounted` low and
  the machine times out.
- **H5 — reset sequencing.** The engine's `DD_RESET` (machine reset) coinciding
  with the `IMG_MOUNTED`/`IMG_SIZE` update leaves `media_present` in a state that
  doesn't re-trigger the parse after reset release.

## 6. What I need from you

1. **Which hypothesis is most likely** given the mount logic + the reset asymmetry,
   and the exact sequencing that leaves the engine unable to serve.
2. **The fix** (minimal, in `woz_mount_ctl.v` / top wiring / `data.json`). If the
   reset-around-reload (bit6) is the trigger, say so and whether clearing it
   (parameters 73 → 9) is an acceptable workaround vs. fixing the re-parse.
3. **The diagnostics to add to the on-screen overlay** so the next hardware test
   is conclusive. Minimum set I'd expect: `mount_state_m` (0..4), `img_mounted`,
   `res_valid_m`, `new_load_m` (latched), `transport_fault` (latched), and the
   engine's parse/scan status if reachable. Confirm/extend the list.

## 7. Constraints

- `machine/` OSK RTL and the `woz/` engine files are byte-identical / pinned —
  fixes must be in `woz_mount_ctl.v`, the top wiring, `data.json`, or
  `sdram_*` (Pocket-owned), not the pinned files.
- `sdram_path_rst` (PLL power-on) is intentionally *not* a button reset — the
  resident image + mount must survive a button reset by design.
- A sim pass already exists; the fix must be validated in sim AND on hardware.

## 8. Reproduction / files

- Repo `E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket`, branch `main`.
- Mount: `src/fpga/core/apple2e/woz_mount_ctl.v`.
- Wiring: `src/fpga/core/apple2e/apf_stream_video_top.v` (M1 block ~lines 868–995).
- Coordinator result: `src/fpga/core/apple2e/sdram_storage.v` (`res_valid` latch,
  `new_load_m`, `ds0082` clear at the generation re-arm).
- Overlay: `src/fpga/core/apple2e/sdram_status_overlay.v`.
- Full-machine sim: `verilog/tb/tb_u6_boot.sv` (passes).
- `data.json` `parameters: 73`.

---

## RESOLUTION (2026-10-21, owner + agent)

The review's top finding was **correct and is the root cause**: the top
connected the full 8-bit `m_io_sel`/`m_dev_sel` buses to the Disk II's
**1-bit** `IO_SELECT`/`DEVICE_SELECT` ports (truncating to bit 0), and the
`m_pd_mux` used the whole buses. The Verilog-model ancestor wires
`disk_ii_woz` to `IO_SELECT[6]`/`DEVICE_SELECT[6]` (slot 6), confirming the
intended slot.

**Fix applied** (both files, byte-identical intent):
- `apf_stream_video_top.v`: `.IO_SELECT(m_io_sel[6])`,
  `.DEVICE_SELECT(m_dev_sel[6])`, and
  `m_pd_mux = (m_dev_sel[6] | m_io_sel[6]) ? woz_dout : 8'h00;`.
- `tb_u6_boot.sv`: the same `[6]` fix.

**TB strengthened per the review** (the old "ALL PASS" was a byte-count
false positive):
- Byte-content compare: every `sd_buff_dout` byte is checked against
  `image[sd_lba*512 + sd_buff_addr]` (0 content mismatches required).
- Slot-6 wiring guard: Disk II data must appear ONLY on slot 6, never on
  any other slot (regression check for the bit-0 truncation).
- Track-0 load required (`ntrack0 >= 5000`, not a raw count; the header
  scan alone is ~228 B).
- Failures + watchdog now `$fatal` (nonzero exit).
  Re-run: `TB U6 BOOT: ALL PASS (content_fail=0 slot6_fail=0 track0=5000)`.

`data.json` parameters stay **73** (bit 6 reset-around-reload is correct;
the bug was the slot wiring, not the reset). Next: owner recompiles
`apf_stream_video` + Pocket hardware boot / CATALOG acceptance.
