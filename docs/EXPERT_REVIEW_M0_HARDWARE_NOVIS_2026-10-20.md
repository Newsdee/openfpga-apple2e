# Expert review — M0 storage: hardware shows no visible behavior beyond file selection

**Date:** 2026-10-20
**Status:** awaiting expert response
**Related:** `EXPERT_DESIGN_M0_AUTOVERIFY_2026-10-19.md` (accepted design),
`EXPERT_REVIEW_M0_STORAGE_2026-10-19.md` (the rework review),
`PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` (implementation record)

## 1. The hardware symptom

The M0 rework (Unit 1–6) is TB-verified, compiled clean by the owner (Quartus
17, fit 24% ALMs, timing met), and staged to the SD card (`bitstream.rbf_r`,
`data.json` disk slot `required:false`, fixture at `Assets/apple2e/common/disk.woz`).

On the Pocket, the owner reports: **the only confirmed behavior is that a .woz
file can be selected** (i.e., the host file browser works and accepts the
file). Nothing else has apparent behavior: no `OK CRC=… N=…` overlay, no
`NO FILE`, no `FAIL` — the screen looks exactly like the pre-M0 build.

Note on expectations: the Apple II in this core has **no floppy at all yet**
(the WOZ/Disk II path is M1–M3, not ported). M0's only designed-visible
behavior is the on-screen storage diagnostic. So the symptom reduces to:
**the coordinator never produced a latched result the overlay could show, or
the overlay never drew.**

## 2. What we verified locally this pass (facts, not guesses)

### 2.1 The real `core_bridge_cmd` decode is correct (new integration TB)

Previous TBs drove `ds_requestwrite`/`ds_allcomplete` directly (an abstraction
of `core_bridge_cmd`). That is exactly the "passes in sim, dead on hardware"
gap, so we added `verilog/tb/tb_bridge_storage.sv`, which instantiates the
**real** `src/fpga/core/core_bridge_cmd.v` (the template decoder, same as the
top) and drives it with the documented host sequence:

- `0x0000` status poll (params/commands via `0xF8000000`, result polled for
  the `0x4F4B` prefix), `0x0011` reset exit, `0x0082` with id/size in
  `0xF8000020`/`0xF8000024`, paced bridge word writes at slot address `0x0`,
  `0x008F`.
- The storage path is wired exactly as the top wires it (raw `bridge_*` +
  `core_bridge_cmd`'s `dataslot_*` outputs, both on `clk_74a`).
- `bridge_endian_little = 0`, `dataslot_requestwrite_ack/ok = 1` (same as
  top and NES reference), savestate/target/datatable ports tied off.

**Result: BRIDGE STORAGE PASS** — all nine scenarios green:

```text
B0: boot + status: 0000 -> idle (3)
B1: 0011 reset exit OK
B2: 008F-only load -> NOFILE result
B3: real-bridge 512-byte load auto-verify OK crc=c9260f5e
B4: reload 1001 bytes (partial word) auto-verify OK crc=eebd60c5
B5: wrong slot id ignored, result unchanged
B6: incomplete transfer rejected FAIL IN
B7: FIFO overflow rejected FAIL OV (later 008F did not clobber)
B8: machine reset - result persists (image survives by design)
B9: re-arm after failed generation -> OK crc=c9260f5e
```

Verified from the source (not inference): `0082` is a ~1–2 cycle level (set in
ST_PARSE, cleared when the state machine returns to ST_IDLE); it clears
`dataslot_allcomplete` in the same cycle; `008F` **sets** `dataslot_allcomplete`
(our rising-edge detector polarity is correct); the command completes
immediately because the top hardwires `ack/ok = 1`.

### 2.2 The overlay had two real bugs (never seen on hardware before)

`sdram_status_overlay` is the only user-visible M0 signal and had **never been
on hardware** before this bitstream. Reviewing it found:

1. **The "5 s show window" never expired.** The counter runs to
   `SHOW_CYCLES` and holds, but `show` only checked `show_cnt != 0` — so once
   a result existed, the two-line text was **permanent**. (Invisible on
   hardware, so this was not the cause of the symptom, but it is a behavior
   bug vs. the module's own contract.)
2. No state was visible after the window (or at all, if no result latched).

Fixed + extended:

- `show` now genuinely expires (`show_cnt != 0 && show_cnt != SHOW_CYCLES`).
- **Persistent 2-glyph corner mark** (top-right, rows 0..4): `OK` / `FF` / `NF`
  stays on for as long as a result is latched, and re-arms on every machine
  reset (module reset clears the window; `res_valid_m` stays high). So every
  reset re-displays the last result for the window.
- **Line 3 (debug counters, drawn during the window):** `R=NNNNN C=NNNNN[OTS]`
  — words received / committed, plus flags O=FIFO overflow, T=store timeout,
  S=verifier stuck. New inputs `dbg_rc_m` (48-bit, 3-stage synced in the top)
  and `dbg_fl_m` (3 flags, machine domain).
- `SHOW_CYCLES` is now a parameter (shipping default unchanged: 5 s).

New `verilog/tb/tb_ovl_status.sv` raster-level pixel tests — all pass:

```text
O1: no result -> no pixels
O2: OK result -> pm=20 l1=149 l2=115 l3=167 (out=0)
O3: window expired -> only persistent mark (pm=20)
O4: machine reset re-armed the window (l1=149)
O5: new NOFILE generation re-latched (l1=60 pm=16)
```

(TB raster note: the machine's `hbl` is a 1-cycle pulse per line and `vbl`
stays high through the first visible line's pulse — the overlay's row counter
and `apf_stream_video`'s `vs_pulse` both depend on that shape.)

### 2.3 Regression state

- `tb_top_storage`: PASS (storage module untouched this pass).
- `tb_bridge_storage`: PASS (above).
- `tb_ovl_status`: PASS (above).
- Verilator lint: overlay now **warning-free** under strict lint (width-clean
  part-selects); top clean under project flags; only pre-existing
  `io_sdram_pocket.v` COMBDLY remains.

## 3. Hypotheses for the hardware symptom (ranked)

- **H1 — the host does not do what we model on the user's flow.** The owner's
  only confirmed action was *selecting* a file. If that went through the
  Interact menu's user-reloadable slot (bit 0), the host command sequence for
  a **runtime reload of an already-loaded slot** is the unknown. We model
  `0082 (id/size) → data writes → 008F` on every load; if the host does
  something else for reloads (e.g., only `008A` update, or no `0082` because
  the slot is "already loaded"), our coordinator sees no generation and stays
  silent.
- **H2 — bridge write shape differs on hardware.** E.g., writes to a different
  address range, or a burst rate that overflows the 64-deep FIFO (the sticky
  overflow would produce `FAIL OV`, which the overlay *would* show — so if the
  host bursts pathologically, we'd expect to see FAIL OV, not silence).
- **H3 — hardware-only storage/PLL issue** (warm SDRAM init on restart, etc.).
  Unlikely as the *first-boot* explanation since the machine + OSK work and
  `status_setup_done` (which gates on `stor_init_done`) clearly rose (the host
  got past [Setup] to run the core).
- **H4 — overlay geometry vs the real 228×280 raster.** The overlay draws at
  native-raster rows 0..31, cols 68..185. If the machine raster's visible
  region is offset (e.g., overscan rows before content starts), the text could
  land outside what `apf_stream_video` passes through. The debug build makes
  this checkable (see §4) — if the host path works but the screen stays blank,
  this is the remaining suspect.

## 4. What the debug build will show on the next hardware run

After the owner compiles the current tree and re-stages (same commands as
before), the screen should decode as:

| Observation | Diagnosis |
|---|---|
| No corner mark at any time (after boot + after file select) | No result ever latched → host-path issue (H1/H2). Next step: 0xF9 diag reads can't be host-triggered, so we add a minimal host-visible probe (a spare `status[]` bit or 0xF9 echo in a host-pollable register) — pending this review's direction. |
| Corner mark appears (OK/FF/NF) but window text never does | Overlay window/geometry bug (H4) — rows/cols visible to the stream are wrong; move the text block. |
| `OK` + `R=NNNNN C=NNNNN` with R=C=expected | Path is fully healthy on hardware → the pre-debug build's silence was purely the (now fixed) overlay behavior. |
| `FF` + `OV`/`TO`/`IN` flag in line 3 | Real storage failure class identified directly (overflow/timeout/incomplete). |

Plus the reset behavior check: after a machine reset (OSK Apple key), the
5-second window should re-display the last result (re-arm) — and the image
must survive (B8 in the bridge TB).

## 5. Questions for the expert

1. **Reload sequence (H1):** for a user-reloadable data slot (parameters bit 0)
   reloaded at runtime via the Interact menu, what exactly does the host
   transmit? `0082 (params in 0x20/0x24) → bridge writes at the slot address →
   008F`? Anything else — a preceding `0000`/status exchange, `008A` update,
   slot query, or a "reload" that omits `0082` when the slot was already
   loaded?
2. **Partial last word (Q2):** for a slot file whose byte size is not a
   multiple of 4, what does the host put in the final 32-bit bridge word —
   zero-extension, truncated size in the `0082` size parameter, or garbage?
   (Our verifier CRCs exactly the latched byte count, so zero-extension and
   garbage both verify correctly; a *truncated* size changes the expected CRC
   on hardware.)
3. **Burst rate (H2):** worst-case bridge write rate during a slot load
   (words/s or minimum gap). Our FIFO is 64 words (256 B) deep and the store
   commits ~1 word / ~10–15 SDRAM-ctrl cycles (~90–150 ns); a sustained
   burst faster than that overflows (→ `FAIL OV`).
4. **Core restart retransmit:** on a full core restart (bitstream reload,
   same bitstream), does the host always retransmit all data slots (including
   non-required ones), or only when the user selected new data? The shutdown
   doc says "may reload … if a user wants to restart with new data" — we need
   the no-change case defined.
5. **Load in-flight aborts:** if the core reports [Setup] promptly and the
   slot load is taking a while, are there host-side timeouts/aborts we should
   design against (we currently only time out a single stuck SDRAM word op)?

## 6. Behavior changes in this pass (flag for sign-off)

- The detailed overlay text is now **transient** (5 s window, as originally
  documented) instead of permanent; the 2-glyph corner mark is the persistent
  indicator. One-line revert if the expert/owner prefers permanent text.
- New overlay inputs (48-bit counter vector + 3 flags) — 102+3 FFs of
  3-stage sync in the top; negligible resources.

## 7. Files changed this pass

- `src/fpga/core/apple2e/sdram_status_overlay.v` — window expiry fix,
  persistent mark, line 3, `SHOW_CYCLES` parameter, width-clean lint.
- `src/fpga/core/apple2e/apf_stream_video_top.v` — 48-bit counter sync,
  overlay debug inputs.
- `verilog/tb/tb_bridge_storage.sv` — new (real-bridge integration TB).
- `verilog/tb/tb_ovl_status.sv` — new (overlay raster TB).
