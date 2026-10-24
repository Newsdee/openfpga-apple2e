# Expert review — M1 WOZ floppy "stuck at logo" (engine never scans)

**Date:** 2026-10-21
**Project:** `apple2e-pocket` (Analogue Pocket / openFPGA Apple IIe core, WOZ floppy via Pocket SDRAM)
**Repo:** `E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket`, Quartus top `apf_stream_video` (run from `src/fpga`)
**Reviewer role:** bounded read-only root-cause critic. Do not change files; recommend a fix + a diagnostic set.

---

## 0. TL;DR / the ask

The WOZ floppy drive now (a) mounts from SDRAM correctly and (b) is correctly reached by the
CPU — but the WOZ engine **never starts its header scan** (`RD=00000`, zero SDRAM reads), so
the machine hangs at the Apple logo. I need you to adjudicate the root cause among the
hypotheses below and recommend the concrete fix + the minimal diagnostic set, with the
reset-domain / mount-repulse reasoning made explicit.

---

## 1. Symptom (hardware, owner)

- Load a `.woz` disk via the Pocket data slot, boot. Machine shows the **Apple //e logo and
  stalls** (no DOS, no CATALOG, no BASIC prompt). Black screen below the logo.
- Two screenshots 3 s apart show an identical steady state (not a transient).
- Owner screenshots: `I:\Memories\Screenshots\20261021_092926.png` / `_092929.png`.

## 2. On-screen diagnostic readout (added for this, always-on)

A temporary overlay (machine domain, after the OSK compositor) prints three always-on lines:

```
MT=x  RD=NNNNN     line 4: MT = mount-controller img_mounted level; RD = cumulative engine sd read bytes
AC=x  MO=x         line 5: AC = engine D1_ACTIVE; MO = engine D1_MOTOR_ON
ST=x  A=x  F=x     line 6: ST = mount-controller state (0 unm,1 mnted,2-4 eject);
                             A = transport sd_ack level; F = transport fault latch
```

**Observed (stable across both captures):**
```
OK CRC=5B5CB782     <- storage readback-verify OK (a valid-sized WOZ is in SDRAM)
MT=1  RD=00000
AC=1  MO=1
ST=1  A=?  F=0      <- ST/A not yet captured on the current card (line 6 was added after); F assumed 0 (no unmount)
```

### What this already tells us
- `MO=1` + `AC=1` = **the CPU is actively polling the Disk II**. The earlier slot-6 wiring fix
  is working (the original bug — 8-bit slot bus into a 1-bit port — would have shown the
  machine *never* selecting the drive).
- `MT=1` = the mount controller latched a mounted image with a nonzero size.
- `RD=00000` = **the WOZ engine issued zero SDRAM reads** → its controller never began the
  header scan. If the scan had started it would read at least the 60-byte INFO chunk.
- `OK CRC` only proves readback; it does **not** prove WOZ validity.

## 3. The trigger chain (the code path that must fire)

The engine is the byte-pinned MiSTer WOZ controller. The scan starts **only** on the rising
edge of the engine's *internal* `img_mounted` re-pulse:

**`src/fpga/core/woz/woz_floppy_controller.sv:547`**
```systemverilog
if (img_mounted && !prev_mounted) begin      // S_IDLE -> S_DETECT -> S_SCAN_WOZ
    state <= S_DETECT;
```
`prev_mounted <= img_mounted` (line 622). So the scan needs the internal `mount` to go 0->1.

**`src/fpga/core/woz/disk_ii_woz.sv:205-224`** — the internal `mount` re-pulse machine:
```systemverilog
reg mounted_d, mount, remount_pending, dd_reset_d, media_present;
always @(posedge CLK_14M) begin
    mounted_d  <= mounted_in;        // mounted_in = IMG_MOUNTED0 = the mount-controller level
    dd_reset_d <= DD_RESET;          // DD_RESET = machine_reset (engine reset)
    if (!mounted_d && mounted_in)    // latch media presence on the MC 0->1 edge, reset or not
        media_present <= (IMG_SIZE != 64'd0);
    if (DD_RESET) begin
        mount <= 1'b0; remount_pending <= 1'b0;
    end else if (dd_reset_d) begin
        remount_pending <= media_present;      // re-arm on the machine-reset release edge
    end else if (!mounted_d && mounted_in) begin
        if (mount) begin mount <= 1'b0; remount_pending <= (IMG_SIZE != 64'd0); end
        else        mount <= (IMG_SIZE != 64'd0);
    end else if (remount_pending) begin
        mount <= 1'b1; remount_pending <= 1'b0;
    end
end
```
So `mount` goes high either (a) on the `IMG_MOUNTED0` 0->1 edge **while not in reset**, or
(b) on the **machine-reset-release edge** via `remount_pending = media_present`. Both require
`media_present`/`IMG_SIZE != 0`.

**`src/fpga/core/apple2e/woz_mount_ctl.v`** — the mount controller (reset by `~sdram_path_rst`,
i.e. **power-on only, NOT machine_reset**). Drives `img_mounted` (the level) + `img_size`.
- `ST_UNMOUNTED -> ST_MOUNTED` on an OK result: `img_mounted` 0->1 with `img_size = res_nbytes`.
- On a new load / fault it runs an eject sequence (`ST_EJ1..EJ3`: fall -> zero-size rise -> fall)
  then re-mounts. **Falling `IMG_MOUNTED` alone does not unmount**; a zero-size rise clears it.

### Clock / reset domains (the crux)
- Engine `CLK_14M` = `clk_core_14318` (machine clock, post-PLL-lock).
- Engine `RESET` = `DD_RESET` = `machine_reset`.
- `machine_reset = ~rst_sync[1] | ~lock_sync[1] | osk_cmd_reset` (`apf_stream_video_top.v:532`).
- Mount controller `clk` = machine clock, `por_n` = `~sdram_path_rst` (power-on only) → **it is
  NOT reset by the machine reset**, so its `img_mounted` level persists across a machine reset.
- `data.json` `"parameters": 73` → bit 6 = **reset-around-reload** (host resets the machine
  around the file reload).

## 4. The discrepancy

On paper the re-pulse should fire in both reset orderings (reset before or after the MC mount
edge): either `media_present` latches on the MC edge + re-pulses on reset release, or the MC
edge arrives after the release and `mount` rises directly. Yet hardware shows `RD=00000` with
`MT=1, MO=1`. So something in the assumed sequence is wrong. Candidate gaps I could not
resolve from the RTL alone:

- **H1 — reset-around-reload ordering eats the re-pulse.** The host reset lands such that the
  `media_present` latch or the `remount_pending` re-arm is missed (e.g. `machine_reset` re-asserts
  after the one release edge, or the MC mount edge + release are mis-ordered relative to the
  engine's clock/lock). The engine sits at internal `mount=0` forever while `MT=1`.
  *This is the leading hypothesis and is directly falsifiable by clearing bit 6 (see §6).*
- **H2 — transport/fetch not servicing the engine's reads.** If the engine *did* re-pulse and
  request a byte but the transport never acks (or faults), the scan would stall at its first
  read. Distinguishing signal: `A` (sd_ack) / `F` (transport fault) on the new line 6. A
  transport fault also forces an MC unmount (ST would drop), which `MT=1` argues against — but
  the line-6 capture will confirm.
- **H3 — image is not a valid/parseable WOZ** (the loaded disk `CRC=5B5CB782` differs from the
  DOSMaster golden `74EA1324`). If the engine parsed but `scan_failed`, it still would not serve
  track 0 — but that requires the scan to have *started* (RD>0), which contradicts RD=0. So H3
  is unlikely to be the *first* failure; keep it in mind after RD becomes nonzero.
- **H4 — the engine's `img_size` is 0 at the MC edge**, so `media_present` latches 0. Would mean
  the MC asserted `img_mounted` before `img_size` was set (a 1-cycle skew in the MC's
  ST_UNMOUNTED->ST_MOUNTED transition). Need to confirm the MC sets `img_size` on the same cycle
  `img_mounted` rises.

## 5. Key files (for the reviewer)

- `src/fpga/core/woz/disk_ii_woz.sv` (byte-pinned engine; mount re-pulse ~205-224) — **do not edit**.
- `src/fpga/core/woz/woz_floppy_controller.sv` (scan trigger :547; state machine).
- `src/fpga/core/apple2e/woz_mount_ctl.v` (MC: img_mounted/img_size level + eject).
- `src/fpga/core/apple2e/sdram_woz_transport.v` (host-paced engine read service; fault latch).
- `src/fpga/core/apple2e/apf_stream_video_top.v` (wiring; `machine_reset` :532; engine instance
  ~903; overlay instance ~990; the new drive-activity probes ~977-1007).
- `src/fpga/core/apple2e/sdram_status_overlay.v` (the always-on MT/AC/ST lines).
- `sd_root/Cores/Newsdee.Apple2eStreamVideo/data.json` (`parameters: 73`).

## 6. What I'd like the expert to decide

1. **Which hypothesis is most consistent** with `MT=1, RD=00000, MO=1, AC=1` given the exact
   re-pulse logic in §3 — and the *specific* reset-ordering that breaks it (or why the re-pulse
   is guaranteed to fire, in which case point at the real fault).
2. **Is the `data.json` bit-6 flip (73 -> 65) the right first experiment**, and what result
   confirms vs. refutes H1? (My plan: 73->65; if it boots, the fix is to re-arm the engine scan
   after the host reset — not a storage change; if not, line-6 A/F localizes H2.)
3. **The correct fix** for the confirmed cause — e.g. if H1: make the engine re-scan on the
   first machine access after reset release (or reorder the host reset vs. the MC mount),
   expressed as the minimal change and where it lives (top vs. engine). If the engine must stay
   byte-pinned, what top-level sequencing guarantees the internal `mount` re-pulse fires?
4. **Minimal persistent diagnostic set** to make the *next* capture unambiguous (I've already
   added MT/AC/ST/A/F; do you want the engine's internal `mount`/scan-state surfaced somehow
   without editing the pinned engine, e.g. via an existing port or a shadow latch in the top?).
5. **Confirm or refute H4** (MC `img_size`/`img_mounted` same-cycle alignment) from `woz_mount_ctl.v`.

## 7. Constraints
- The 5 WOZ engine files are byte-pinned to MiSTer (SHA-pinned). Prefer fixes in the Pocket-owned
  top / mount controller / data.json; only propose an engine edit if truly unavoidable and note
  it breaks byte-pinning.
- `machine_reset` must not reset the SDRAM image / FIFO / verifier (resident image survives).
- Save-states are a later milestone; the design must stay RAM-only/capturable.
- Owner launches full Quartus compiles; keep the fix small and compile-light.

## 8. Reproduction
Load a `.woz` in the Pocket data slot → boot → Apple logo, then stall. Read the overlay lines
above. `ST`/`A` on line 6 will be captured on the next card image (already added to the overlay).
