# External review brief — Apple IIe WOZ floppy on Analogue Pocket: drive mounts but engine never scans

**Context.** I'm porting an Apple IIe core to the Analogue Pocket (openFPGA / APF, Cyclone V,
Quartus 17, Verilator 5.050). The floppy is a WOZ Disk II engine (a byte-for-byte port of the
MiSTer `rtl/woz/` controller) that reads a `.woz` image from the Pocket's SDRAM through a
small transport. Storage (load + readback-verify) works. The on-screen CPU/keyboard work.
What's left: the machine hangs at the Apple logo after loading a disk — the floppy never boots.

I've added an on-screen diagnostic. It shows the drive is mounted and the CPU is actively
polling the Disk II, **but the WOZ engine has performed zero SDRAM reads** — i.e. its header
scan never started. I want an independent read on the root cause. Everything you need is in
this brief; no repo access required.

---

## 1. Symptom

Load a `.woz` in the Pocket data slot, boot. The machine prints the **Apple //e logo and stalls**
(no DOS, no CATALOG, no BASIC prompt). Stable across captures seconds apart.

## 2. On-screen diagnostic (always-on overlay, machine domain)

```
MT=1   RD=00000      MT = host mount-controller img_mounted level; RD = cumulative engine read bytes
AC=1   MO=1          AC = engine D1_ACTIVE (drive active); MO = engine D1_MOTOR_ON
ST=1   A=?   F=0     ST = mount-controller state (0 unm / 1 mnted / 2-4 eject); A = transport sd_ack; F = transport fault
```

**Key inferences (already established):**
- `MO=1` + `AC=1` → **the CPU is actively polling the Disk II.** (I fixed an earlier wiring bug
  where the 8-bit slot-select bus was truncated to bit 0; now the CPU correctly reaches slot 6.)
- `MT=1` → the host mount controller latched a mounted image with a **nonzero** size.
- `RD=00000` → **the engine issued zero SDRAM reads.** Its controller's header scan (which reads
  at least the 60-byte INFO chunk) never began.
- Storage reports `OK CRC` → the bytes are in SDRAM and read back correctly. (CRC differs from
  my sim golden disk — a *different* disk, but a valid-sized WOZ.)

So: image is in SDRAM, the CPU is hitting the drive, the host says "mounted" — yet the engine's
internal scan trigger never fired.

## 3. The trigger chain (the code that must fire) — inlined

### 3a. The engine's internal `img_mounted` re-pulse  (`disk_ii_woz.sv`, ~line 205)

`mount` is what the internal WOZ controller sees as `img_mounted`. `mounted_in` is the host
level (`IMG_MOUNTED0`). `DD_RESET` = machine reset. `IMG_SIZE` = host image size.

```systemverilog
reg mounted_d=0, mount=0, remount_pending=0, dd_reset_d=0, media_present=0;
always @(posedge CLK_14M) begin
    mounted_d  <= mounted_in;
    dd_reset_d <= DD_RESET;
    if (!mounted_d && mounted_in)              // latch media presence on host 0->1 edge, reset or not
        media_present <= (IMG_SIZE != 64'd0);
    if (DD_RESET) begin
        mount <= 1'b0; remount_pending <= 1'b0;
    end else if (dd_reset_d) begin
        remount_pending <= media_present;       // re-arm on the machine-reset RELEASE edge
    end else if (!mounted_d && mounted_in) begin
        if (mount) begin mount <= 1'b0; remount_pending <= (IMG_SIZE != 64'd0); end
        else        mount <= (IMG_SIZE != 64'd0);
    end else if (remount_pending) begin
        mount <= 1'b1; remount_pending <= 1'b0;
    end
end
```

### 3b. The controller starts its scan only on that re-pulse's rising edge  (`woz_floppy_controller.sv:547`)

```systemverilog
// from S_IDLE:
if (img_mounted && !prev_mounted) begin   // img_mounted is the internal `mount` from 3a
    state <= S_DETECT;                     // -> S_SCAN_WOZ (reads INFO/TMAP/TRKS from SDRAM)
end
...
prev_mounted <= img_mounted;
```

So for the engine to read anything, `mount` must go 0->1, which (from 3a) needs
`media_present`/`IMG_SIZE != 0` plus either the host `IMG_MOUNTED0` edge (while not in reset)
or the machine-reset-release edge.

### 3c. The host mount controller — drives the `IMG_MOUNTED0` level + size  (`woz_mount_ctl.v`)

Reset by **power-on only** (NOT machine reset), so its `img_mounted` level persists across a
machine reset. The mount transition:

```verilog
ST_UNMOUNTED: begin
    img_mounted <= 1'b0; img_size <= 64'd0;
    if (do_mount) begin size_l <= pend_size; state <= ST_MOUNTED; end   // do_mount: OK result
end
ST_MOUNTED: begin
    img_mounted <= 1'b1; img_size <= {32'd0, size_l};   // size_l was latched the prior cycle
    if (pend_valid || fault_pend || newload_rise) state <= ST_EJ1;    // eject on new load/fault
end
```

### 3d. Clock / reset domains

- Engine `CLK_14M` = machine clock (post-PLL-lock). Engine `RESET` = `DD_RESET` = `machine_reset`.
- `machine_reset = ~rst_sync[1] | ~lock_sync[1] | osk_cmd_reset` (power-on + PLL-lock + host/OSK reset).
- The **host mount controller is NOT reset by the machine reset** (power-on only).
- The Pocket data-slot file has `parameters: 73` → **bit 6 = reset-around-reload** (the host
  resets the machine around the file reload).

## 4. The puzzle

On paper the re-pulse should fire in *both* reset orderings:
- If the host mount edge lands **while** the engine is in reset → `media_present` latches, then
  the reset-release edge sets `remount_pending` → `mount` rises next cycle.
- If the host mount edge lands **after** the release → `mount` rises directly (not-in-reset branch).

Yet hardware shows `RD=00000` with `MT=1, MO=1, AC=1`. So one of my assumptions about the
sequence is wrong. I could not resolve it from the RTL alone.

## 5. Hypotheses

- **H1 — reset-around-reload ordering eats the re-pulse.** The host reset lands such that the
  `media_present` latch or the `remount_pending` re-arm is missed (e.g. `machine_reset`
  re-asserts after the single release edge, or the MC edge + release are mis-ordered vs the
  engine's clock/lock). Engine sits at internal `mount=0` forever while `MT=1`. *Leading
  hypothesis; directly falsifiable by clearing bit 6.*
- **H2 — transport not servicing the engine's reads.** The engine re-pulsed and requested a
  byte, but the transport never acks (or faults), so the scan stalls at its first read. Distinguish
  with `A` (sd_ack) / `F` (transport fault). A transport fault forces an MC unmount (ST would
  drop), which `MT=1` argues against — but the line-6 capture will confirm.
- **H3 — image not a parseable WOZ.** Unlikely to be the *first* failure (that needs the scan to
  have started, i.e. RD>0), but relevant once RD is nonzero.
- **H4 — `IMG_SIZE` is 0 at the MC `img_mounted` edge.** If the engine latches `media_present`
  on a cycle where `img_size` is still 0 (a 1-cycle skew in ST_UNMOUNTED->ST_MOUNTED), it latches
  `media_present=0` and never re-pulses.

## 6. What I'd like you to decide

1. **Which hypothesis** (H1–H4) is most consistent with `MT=1, RD=00000, MO=1, AC=1` given the
   exact re-pulse logic in §3a–3c — and the **specific** reset ordering that breaks it. Or, if the
   re-pulse is provably guaranteed to fire from §3a+§3c, tell me where the real fault is.
2. **Is the `data.json` bit-6 flip (`73 -> 65`) the right first experiment**, and exactly what
   outcome confirms vs. refutes H1?
3. **The correct minimal fix** and **where it lives** (Pocket top / mount controller / data.json).
   The 5 WOZ engine files are byte-pinned to MiSTer (I'd strongly prefer not to edit them); if an
   engine edit is truly unavoidable, say so and what breaks.
4. **Minimal persistent diagnostic set** to make the next capture unambiguous. I already surface
   MT/AC/ST/A/F. Can the engine's **internal `mount` / scan state** be observed *without* editing
   the pinned engine — e.g. via an existing port, or a shadow edge-latch in the top on the
   `woz_sd_*` / `IMG_MOUNTED0` / motor signals?
5. **Confirm or refute H4** from §3c: does `img_size` become nonzero on the **same cycle**
   `img_mounted` rises, or is there a 1-cycle skew that would make the engine latch
   `media_present=0`?

## 7. Constraints

- 5 WOZ engine files are byte-pinned to MiSTer (SHA-pinned). Prefer top / mount-controller /
  data.json fixes.
- Machine reset must **not** reset the SDRAM image / FIFO / verifier (the resident image survives).
- Save-states are a later milestone; keep the design RAM-only/capturable.
- I launch Quartus compiles; keep the fix small and compile-light.

## 8. Suggested format for your answer

- **Verdict** (one of H1–H4, or "evidence insufficient — here's the one measurement that decides").
- **The failing condition**, precisely (signal, line, cycle relationship).
- **The minimal fix** (exact change + where it lives).
- **The diagnostic set** you'd keep permanently.
- Cite the inlined code by section (§3a–3d) and line where helpful.
