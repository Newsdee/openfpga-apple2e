# Handover: post-M1 tasks — fingerprint overlay removal + optional cold reset on disk insert

Date: 2026-10-24. Written for handover after M1 (WOZ floppy boot) was completed,
verified on hardware, and pushed. M1 state is **stable and green** — this doc

**Status update (2026-10-24, later that day):** both tasks are IMPLEMENTED:
Task 1 (FP_DIAG/FP_EN/SHOW_FP gate, default off) and Task 2 ("Reboot on
disk change" interact.json option -> reboot_ctl.v cold reboot, data.json
bit6 dropped). Verified so far: `tb_reboot_ctl` ALL PASS (unit),
`tb_ovl_status` T0-T8 PASS (SHOW_FP both states), `tb_verifier_fp`/
`tb_vfp_probe` PASS (FP_EN=1), `tb_ovl_dbgrect` PASS. Pending at push time:
`tb_u6_boot` (now wires reboot_ctl + a U6-R full-machine cold-reboot check)
and the M1 fast regression + long storage suites (re-running). QSF updated
for `reboot_ctl.v`. A user Quartus compile of `apf_stream_video` validates
the rest (map report should show the fp registers trimmed at FP_DIAG=0 and
the reboot_ctl/option logic ~tens of ALMs).
covers only the two follow-up tasks the owner asked for, everything already
investigated for them, the decided direction, and what remains to be done.

Repo state at handover:

- `origin/main` = `b9fe195` (two commits: `1a5cc9d` "M1 complete: WOZ floppy
  boot works on hardware — SDRAM read-capture fix + diagnostics" + `b9fe195`
  verdict note). Working tree clean.
- Hardware (2026-10-24): fingerprint matched the PC oracle byte-exact and
  **DOS 3.3 boots**; Jungle Hunt (second image) boots too. Screenshots:
  `I:\Memories\Screenshots\20261024_084738.png`, `20261024_084810.png`.

## Context you must know before touching anything

- M1 root cause (done, for reference): the Pocket SDRAM chip runs in its
  power-up-default **CAS2** mode — the boot "LMR" writes drive
  `CMD_LMR=3'b000`, an undefined SDRAM command real chips ignore — while the
  controller's 4-stage read-capture pipeline assumed CAS3 (the sim model had
  hardcoded CAS=3, hiding it). Fix shipped: `CAP_PIPE=3` parameter in
  `io_sdram_pocket.v` + model `CAS=2` in `verilog/tb/tb_dram_model.sv`.
  Full writeup: `docs/HW_DIAG_IMAGE_FINGERPRINT_2026-10-23.md`.
- The fingerprint overlay (4 always-on lines, rows 65–95, right side of the
  screen) was the diagnostic that proved the fix. It is the subject of Task 1.
- The active Quartus project is `src/fpga` (top `apf_stream_video`, device
  5CEBA4F23C8, Quartus 17.0.2 Lite at
  `C:\intelFPGA_lite\17.0\quartus\bin64\`). **The owner compiles; do not start
  long compiles.** After any fresh RBF: regenerate the card bitstream with
  `python tools/rbf2rbf_r.py <rbf> sd_root/Cores/Newsdee.Apple2eStreamVideo/bitstream.rbf_r`.
- EOL discipline: run `bash eol_guard.sh` from the **workspace root**
  (`E:\MiSTer\Apple-II_FPGAdev`) after edits; committed blobs are LF,
  autocrlf=true makes `git add` warn — that warning is surface-only, ignore it.
- Verilator on this host: MSYS2 UCRT64
  (`/c/msys64/ucrt64/bin/verilator_bin` — the Perl wrapper is broken under
  MINGW64), `mingw32-make.exe` + a `make.exe` shim in `C:/msys64/tmp/makeshim`,
  `VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator`, and **the host AV layer
  kills freshly linked Verilator exes outside a ~1–2 min grace window** —
  always relink + launch in one chained command; long sims survive because
  they start inside the window. Build recipes for every suite live in
  `verilog/rerun_m1_regress.sh`, `verilog/run_ovl_suites.sh`,
  `verilog/run_bridge_final.sh`, `verilog/rerun_long_storage.sh`.
- `tb_u6_boot` runs with CWD = `verilog/u6/`; `tb_woz_machine` with CWD = repo
  root (golden path `verilog/tb/golden/dosmaster_16k.hex`).
- `tb_woz_machine` is **deferred** (four AV kills, 0-byte logs); its coverage
  is superseded for M1 by `tb_u6_boot` ALL PASS + the storage suites. Re-run
  it when convenient; it is not a gate for these tasks.

## Task 1 — remove the fingerprint overlay, but keep the capability

Owner's words: remove it, but "can't we use it for something else later?"
Agreed direction (decided, not yet implemented): **gate the whole mechanism
behind one compile-time flag, default OFF**, so the shipping screen is clean
and the diagnostic is one flag away for the next unknown load problem.

### Decided design

New top-level parameter in `apf_stream_video_top.v`:

```verilog
parameter FP_DIAG = 0   // 1 = build with the SDRAM image-fingerprint diagnostic
```

Fan-out (parameter passes, no new wires):

- `sdram_storage` gets `parameter FP_EN = 0` → passes to its `disk_verifier`
  instance as `FP_EN`.
- `disk_verifier.v` gets `parameter FP_EN = 0`: wrap the fingerprint state
  (`wcrc` accumulator, `fp_raw`, `fp_first`/`fp_last` latches, `fp_w0..w3`
  window latches, `wbase_idx`) in `if (FP_EN)` (an `if` on a parameter folds
  the registers out of the shipping build — verify in the map report that
  they're gone when OFF). Outputs tie to 0 when OFF.
- `sdram_status_overlay.v` gets `parameter SHOW_FP = 0`: gate the four line
  masks (rows 65–95) and the `GL_W` glyph fetch. Everything else in the
  overlay (badge, status lines, mount state) is untouched and always on.

Do **not** delete any of: the verifier logic, the storage pass-through ports
(`fp_first_m`/`fp_last_m`/`fp_w_m`), `tools/woz_fingerprint.py` (PC oracle —
zero cost, works for any build), or the TBs (updated per below). When OFF the
fingerprint ports simply carry 0 / the overlay draws nothing.

### Exact touch points (verified line numbers at handover)

- `src/fpga/core/apple2e/apf_stream_video_top.v`: bridge/diagnostic region
  around lines 305–330 (storage diag mux), `stor` instance ~lines 796–860
  (fp outputs `stor_fp_*`), `ovl` instance ~lines 1000–1015 (fp inputs),
  `machine_reset` gen at line 532 (Task 2 anchor).
- `src/fpga/core/apple2e/sdram_storage.v`: fp pass-through outputs
  (`fp_first_m`, `fp_last_m`, `fp_w_m` [95:0]) and the `verifier` instance.
- `src/fpga/core/apple2e/disk_verifier.v`: 7 fp outputs
  (`fp_first`, `fp_last`, `fp_w0..fp_w3`); accumulators live next to the
  existing `crc_w` per-byte CRC step (runs only during the verify pass —
  no extra SDRAM traffic either way).
- `src/fpga/core/apple2e/sdram_status_overlay.v`: 3 fp inputs
  (`fp_first`, `fp_last`, `fp_w` [95:0]); 4 line blocks in the RGB/1-bit
  generators; `GL_W` glyph.
- TBs:
  - `verilog/tb/tb_ovl_status.sv` — **T7** drives the fp inputs and checks the
    four lines pixel-exact (expected strings are in the TB and in
    `docs/HW_DIAG_IMAGE_FINGERPRINT_2026-10-23.md`). Update: instantiate the
    overlay with `#(.SHOW_FP(1))` for T7; add a default-mode check
    (SHOW_FP=0 → rows 65–95 blank, all other lines unchanged).
  - `verilog/tb/tb_verifier_fp.sv` and `verilog/tb/tb_vfp_probe.sv` —
    instantiate `disk_verifier` with `#(.FP_EN(1))`; they check
    zlib-oracle-identical windows (7 cases).
  - `tb_bridge_storage` / `tb_top_storage` / `tb_u6_boot` — fp outputs are
    unconnected or unused there; with the parameter defaulting OFF they are
    untouched. Confirm no `#()` overrides are needed (grep the TBs for
    `disk_verifier`/`sdram_status_overlay` instantiations).

### Verification for Task 1

1. `bash verilog/run_ovl_suites.sh` (overlay TBs, fast) — must pass in both
   parameter states.
2. Fast M1 regression (`verilog/rerun_m1_regress.sh`) for the
   verifier/parameter change — at minimum `tb_sector_fetch`,
   `tb_disk_store`, `tb_woz_transport`, `tb_u6_boot`; long storage suites only
   if you touch the storage module's ports (a parameter pass should not).
3. Full-design lint clean.
4. User compile; check the map report: fingerprint registers **absent**
   when `FP_DIAG=0` (ALM delta ≈ 0 vs `b9fe195`), present when `FP_DIAG=1`.
5. Hardware: overlay block gone from screen; machine still boots DOS 3.3.

## Task 2 — cold reset on disk insert, optional per game

Owner's words: "does the core do a 'warm' reset after inserting a disk? I'd
want to change that to cold reset AND make it optional in core settings (as I
won't want to do that for all games)."

### What was verified (the answer to the question)

**The core RTL does NOT reset on disk change.** `apf_stream_video_top.v:532`:

```verilog
wire machine_reset = ~rst_sync[1] | ~lock_sync[1] | osk_cmd_reset;
```

Only host (bridge) reset, PLL unlock, and the on-screen-keyboard reset key
drive the machine reset. `woz_mount_ctl` (the mount FSM) outputs only
`img_mounted`/`img_size`/`img_readonly`/`mount_state_m` — nothing reaches
`machine_reset`. So after a new WOZ load the machine just keeps running.

**The "warm reset after disk insert" the owner observed comes from the
framework, not the core**: `sd_root/Cores/Newsdee.Apple2eStreamVideo/data.json`
declares `"parameters": 73` (= 0x49) on the `disk` data slot. Per the
openFPGA framework spec (analogue-pocket-dev skill,
`references/json-files.md`, "Parameters bitmap"), the bits are **framework
behaviors, fixed per core package — not user-selectable**:

- bit0 (0x01) user-reloadable via Interact/settings menu → the "Reload" action
- bit3 (0x08) read-only slot (correct for WOZ images)
- **bit6 (0x40) "send Reset Enter/Exit around a reload"** ← the current
  warm reset: the framework presses the Pocket's reset around every disk
  reload → host drives `reset_n` → `machine_reset` pulse, **RAM preserved**

(Other bits, for reference: bit7 0x80 = "restart whole core around reload",
bit8 0x100 = full reload incl. bitstream, bit1 = core-specific asset path,
bit2 = cloned filename, bit4 = instance JSON, bit5 = nonvol init,
bit9 = persist filename.)

**RAM semantics for "cold"** (verified): the machine's RAM is two inferred
M10K arrays `ram_main` / `ram_aux` (64K each) in
`apf_stream_video_top.v` ~lines 563–579, written by `m_ram_we` from
`machine/apple2.v` (`ram_addr`/`ram_di`/`ram_we`). No initial block, no reset
→ warm reset preserves contents; power-up gives hardware init (zero).
So **cold reset = `machine_reset` pulse + synchronous clear of both arrays**:

```verilog
// inside the existing RAM always block
if (ram_cold_clear) begin
    for (i = 0; i < 65536; i = i + 1) begin
        ram_main[i] <= 8'd0;
        ram_aux[i]  <= 8'd0;
    end
end else begin ... existing write/read ... end
end
```

This idiom maps to the Cyclone V M10K's built-in clear (no added M10Ks);
hold the CPU in reset for the whole clear window so no `m_ram_we` conflicts
(the 6502 doesn't read RAM while reset is asserted).

**The mount event to hang this on already exists**:
`apf_stream_video_top.v:902` `wire mc_mount_rise = mc_img_mounted && !mc_mounted_d;`
— pulses on every successful mount (including the initial power-up mount;
note the initial pulse coincides with the PLL-lock reset, so it must be
suppressed/ignored at power-up or it double-resets — verify in sim).

### Constraint that shapes the design (important — corrected 2026-10-24)

**openFPGA DOES have a user-selectable per-core options menu** — via
`interact.json` `variables[]` (Analogue docs, "Up to 16 UI entries from
interact.json can be shown"). Each variable:

- `name`<=23, `id` (unique 16-bit, persistence key across updates)
- types: `check` (on/off), `radio` (group), `slider_u32`, `list`
  (<=16 named options; list options do NOT count toward the 16-entry cap),
  `number_u32` (read-only hex display), `action` (one-shot write)
- `address` = 32-bit **bridge address the core decodes** (framework writes
  the selected value there); optional `persist`, `defaultval`, `value`,
  `value_off`, `mask` (read-modify-write), `writeonly`, `enabled`
- persistence: `/Settings/Author.Core/Interact/interact_persist.json`, and
  **per-asset menus keyed to the slot-0 asset path** persist to
  `/Settings/.../Interact/<slot0 asset path>.json` and override the core
  menu → **per-selected-disk-file (per-game) settings come for free**
- timing: values are written into the core register space **at boot,
  immediately before Reset Exit**, and read back at shutdown (after Reset
  Enter)

Menu budget (KB-079, hardware-validated): max **16** shown interact
entries, and interact + reloadable-data-slot entries max **20 combined**
(entries beyond the cap vanish silently — no error). We currently use
1 data entry (the reloadable `disk` slot) + 0 variables → plenty of room.

What still does NOT exist: arbitrary core-authored settings beyond what
interact.json declares (no OSD-style freeform register UI), and the core
must implement the bridge-write decoder for each variable address.

**Current interact.json is empty** (`"variables": []`) — first variables
will go in there.

1. **OSK runtime toggle (recommended)**: the core already exposes the
   on-screen keyboard as a command surface — `apple2e_osk.v` outputs
   `command_reset` (pattern for a new command: K/akd/open-apple inputs,
   `command_*` outputs; see `apple2e_osk.v:41-51,191`). Add a command
   (key combo TBD — inspect the OSK's existing command keys for a free one)
   that toggles an `auto_cold` register; show its state on the status overlay
   (there are free overlay lines/patterns to follow). Per-session (lost on
   power cycle — acceptable for v1; document it).
2. **Two core variants** (e.g. via `cores[]`/`variants.json`, up to 8 per
   package) — one built cold-on, one cold-off. Heavier (two bitstreams),
   but a true "per core" setting. Fallback if the owner prefers.
3. Rejected: data.json bit7 (0x80) — framework full-core restart around
   reload; not user-selectable, longer reboot, and it restarts the whole core
   rather than power-cycling just the machine.

### Recommended implementation (pending owner confirmation of the open questions)

**Option A (recommended): interact.json variable + core bridge decoder.**

- `interact.json`: one variable (owner decision 2026-10-24: simple On/Off,
  **no warm-reset mode** — "warm reset on disk insert makes no sense"):

  ```json
  { "name": "Reboot on disk change", "id": 1, "type": "check",
    "persist": true, "defaultval": 1, "address": "0x00F00000",
    "value": 1, "value_off": 0 }
  ```

  (`name` must be <=23 chars — "Reboot on disk change" = 21 ✓. Per-asset
  persistence gives per-game selection for free — verify the per-asset
  override on hardware; the docs describe it but it is unverified on our
  card.)
- Core (`apf_stream_video_top.v`): latch `bridge_wr_data` when
  `bridge_wr` targets the chosen address (the bridge write bus is currently
  broadcast; add one consumer). **Pick an address clear of the in-use
  bridge spaces** (`0xF8xxxxxx` = core_bridge_cmd commands, `0xF9xxxxxx` =
  storage diagnostics): `0x00F00000` is free. The latch **must not be
  cleared by `machine_reset`** — the framework reads the value back at
  shutdown, after a Reset Enter. Feed the latched mode to the mount-edge
  reset logic below.
- Reset-on-mount logic (`apf_stream_video_top.v`):
  - on `mc_mount_rise` (line 902; suppress/ignore the power-up pulse that
    coincides with the PLL-lock reset — verify in sim):
    - option **ON** → assert `machine_reset` + `ram_cold_clear` (synchronous
      clear of `ram_main`/`ram_aux`, ~lines 563–579; hold the CPU in reset
      for the clear window) — a full cold reboot from the new disk.
    - option **OFF** → nothing (true hot-swap; the machine keeps running,
      user can press the OSK reset key to boot from the new disk manually).
  - show the option state on the status overlay (free line patterns exist).
- `data.json`: change `"parameters": 73` → **`0x09`** (drop bit6) so the
  framework's around-reload *warm* reset disappears — the core owns the
  reboot policy entirely. Keep bit0 (0x01) so the Reload action stays in
  the menu (with the option OFF, selecting a new disk hot-swaps and the
  user reboots via the OSK key).

**Option B (fallback): OSK runtime toggle.** The core's on-screen keyboard
command surface (`apple2e_osk.v` outputs `command_reset` — pattern for a
new command: K/akd/open-apple inputs, `command_*` outputs, lines 41–51/191)
could carry an in-machine toggle instead. Per-session only (lost on power
cycle), and less discoverable than Core Settings. Keep as fallback if the
owner prefers in-machine control.

**Option C: two core variants** (cold-on / cold-off builds via `cores[]`/
`variants.json`, up to 8 per package) — true per-core setting, two
bitstreams. Heavier; last resort.

Rejected: data.json bit7 (0x80) — framework full-core restart around
reload; not user-selectable, longer reboot, restarts the whole core.

### TB coverage to add

- Bridge-write decode: framework-style write to the option address latches
  the bit; value survives `machine_reset` (shutdown read-back requirement).
- Mount edge, both states:
  - ON → `machine_reset` pulses AND a pre-settled RAM word reads 0 after
    (cold reboot from the new image).
  - OFF → no reset, RAM preserved, machine keeps running (hot-swap).
  - plus: the power-up mount pulse must not double-reset (suppression
    check).
  (Extend `tb_u6_boot` — it already exercises mount + boot — or a focused
  new TB.)

### Open questions for the owner (mostly resolved 2026-10-24)

1. **Resolved:** option is `Reboot on disk change` On/Off; ON = cold reboot
   (no warm-reset mode), OFF = no reboot (hot swap).
2. **Default value — recommended ON** (preserves today's "insert disk → it
   boots" UX, now as a proper cold boot; turn OFF per game for hot-swap).
   Confirm or flip.
3. Per-session vs persisted: `persist: true` recommended (free); per-asset
   (per-disk) overrides to be verified on hardware.
4. Confirm the OSK fallback is not wanted (interact.json check is the
   mechanism).

## Build / test quick reference (so you don't re-derive)

- Fast regression: `bash verilog/rerun_m1_regress.sh` (from MSYS ucrt64, repo
  root). Suites: sector_fetch, slot_fifo, woz_mount_ctl, woz_transport,
  disk_store, u6, + long storage via `rerun_long_storage.sh` /
  `run_bridge_final.sh`. Overlay suites: `bash verilog/run_ovl_suites.sh`.
- u6 golden/ROM CWD = `verilog/u6/`; woz_machine CWD = repo root; all DUT
  `$readmemh` paths are CWD-relative.
- Quartus (owner runs): `cd src/fpga && quartus_sh --flow compile apf_stream_video`;
  reports in `src/fpga/output_files_apple2e/` (fit.summary, sta.summary,
  map.rpt). Critical path: the 133.12 MHz mp2 PLL domain
  (`ic|mp2|altera_pll_i|...divclk`), was +1.080/+0.967 ns at 85C/0C after M1.
- Card staging: `sd_root/` (single core `Newsdee.Apple2eStreamVideo` +
  `Assets/apple2e/common/disk.woz`, 234,496 B, CRC `74EA1324`).
  `bitstream.rbf_r` + `Assets/` are gitignored (by design).
- Fingerprint oracle: `python tools/woz_fingerprint.py <image>` → expected
  N/CRC/W0–W3/F/L; for `disk.woz`: `N=00039400 CRC=74EA1324
  W0=C59C65F2 W1=63610555 W2=3E949994 W3=E24FAE89 F=574F5A32FF0A0D0A
  L=0000000000000000`.

## Suggested order of work

1. Task 1 (self-contained, small): parameter-gate the fingerprint → overlay
   TBs in both states → fast regression → lint → owner compile (verify fp
   registers gone at `FP_DIAG=0`) → hardware check (screen clean, still boots).
2. Ask the owner the five open questions for Task 2.
3. Task 2: interact.json `check` "Reboot on disk change" (default ON
   pending owner confirmation) + core bridge decoder + cold reboot on
   mount edge + data.json 0x09 → focused TB (bridge decode, mount edge
   both states, reset-survives-read-back, power-up pulse suppression) →
   fast regression → owner compile → hardware: (a) ON: swap in a second
   WOZ (e.g. Jungle Hunt) → machine cold-boots from it; (b) OFF: hot-swap
   with no reset, OSK reset key still boots manually; (c) option persists
   after power cycle and, if the framework supports it on our card,
   per-disk-file.
4. Once both are green on hardware: consider removing the fingerprint
   mechanism entirely (verifier fp state + overlay ports + oracle) — or keep
   it gated, per the owner.
