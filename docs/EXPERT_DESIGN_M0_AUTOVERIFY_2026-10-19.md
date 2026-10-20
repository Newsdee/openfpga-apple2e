# EXPERT DESIGN BRIEF — M0 auto-verify (on-hardware trigger for the storage verifier)

**Date:** 2026-10-19 · **Author:** Newsdee (with assistant) · **Status:** design request
**Companion docs:** `docs/PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` (Unit 4/5 done,
Unit 6 = hardware), `docs/EXPERT_REVIEW_M0_STORAGE_2026-10-19.md` (the rework mandate).

## 1. Where we are

The M0 rework (post-expert-review architecture) is complete in simulation:

```
host data-slot stream (bridge, 32-bit words, addr 0x0000_0000+)
  -> sdram_storage (74.25 MHz):  slot_fifo (64 x 56b, the only CDC boundary)
  -> disk_store (133.12 MHz): one word op at a time, waits word_done
  -> io_sdram_pocket: 64 MiB mobile SDRAM (133.12 MHz chip clk, 180 deg vs ctrl)
  -> disk_verifier (14.318 MHz): readback + reflected IEEE CRC32 + first/last word
  -> sdram_status_overlay: on-screen "OK CRC=XXXXXXXX N=XXXXXXXX" (~5 s, after
     the OSK in the video chain)
```

`tb_top_storage.sv` (full path, behavioral SDRAM model with 1.5 ns command/DQ
delays) passes: boot, 128-word store, 12 per-address spot-checks, CRC verify,
verifier-reset image survival, 511-byte and 1-byte tails. All DUT bugs found
during integration are fixed (ST_END re-arm; CRC byte-merge direction).

**The gap:** on real hardware, *nothing triggers a verify*. `n_bytes`
(0xF9000004) and `start` (0xF9000024[0]) are written only by the testbench.
The Pocket host does not know about the 0xF9 diag space. So with a file
loaded, the image is silently stored into SDRAM and the on-screen result —
the M0 hardware acceptance signal — never appears.

## 2. Hard facts constraining the design (verified, not assumed)

1. **Host load ordering.** The host waits for `status_setup_done` (host word
   0082 = machine PLL lock **and** SDRAM init done) *before* streaming the
   data-slot file. The file is streamed via the bridge at boot; there is no
   host-side "load complete" signal we have found.
2. **Bridge direction.** In this APF template (and in the pinned NES
   reference core, same port list) `bridge_rd` is a host-driven input; the
   core only returns `bridge_rd_data` through a mux. **The core cannot
   initiate a bridge read**, so it cannot read the host slot table at
   0xF8002000 (word N at +4N: id, size) directly.
3. **0xF9 space is core-owned.** Writes arrive as ordinary bridge writes;
   reads are muxed out. The host never touches it on hardware.
4. **Verifier semantics.** Level `start` + machine-synced rising edge;
   one-at-a-time; `done` held in ST_END until `start` falls;
   `n_bytes == 0` is handled (empty-file CRC 0x00000000, immediate done).
   `TIMEOUT_CYCLES` bounds a stuck word read (stuck flag, no hang).
5. **Store observability (already in 0xF9000000):** init_done, load_drained,
   store_busy, store_timeout, fifo_overflow, verifier busy/ok/done, plus
   `words_received` / `words_committed` at 0xF9000008/0C, and
   `n_bytes` readback at 0xF9000004.
6. **Reset domains.** Machine reset (host 0088) does NOT reset the storage
   path — the resident image survives (proven in TB test D). Only core
   power / PLL lock (`sdram_path_rst`) resets it. Data slots are loaded once
   per core boot; a machine reset does not re-stream the file.
7. **Quartus 17 parser strictness.** Verilog-2005 sized casts (`24'(...)`)
   are rejected (hit in `disk_verifier.v`, fixed); declaration-style
   `wire x = expr;` assigns parse fine (proven by this compile).

## 3. Candidate design (for review)

A **one-shot auto-verify** in `sdram_storage.v`, host domain (clk_74a),
parameterized for simulation:

- Track `last_wr_word` = max of `bridge_addr[25:2]` over accepted FIFO writes
  (the host streams from 0 upward, so last == max; max used anyway).
- Quiescence counter: counts cycles with **no** new FIFO write; resets on any
  write. Default threshold `AUTO_QUIET_CYCLES = 7,425,000` (100 ms @ 74.25 MHz).
- Arm condition (one-shot `auto_armed` flag):
  `init_done && load_drained && quiet >= AUTO_QUIET_CYCLES && !auto_armed`
  -> `v_n_bytes_host <= (words_received > 0) ? (last_wr_word + 1) * 4 : 32'd0;`
  -> `v_start_host <= 1'b1;`  (0->1 edge; the verifier is in ST_IDLE by then —
  no explicit start has ever happened on hardware)
- `auto_armed` exposed as a new bit in 0xF9000000.
- `AUTO_QUIET_CYCLES` is a module parameter: the TB overrides it (e.g. 5 ms)
  and gains test **F** — after the explicit-path tests (which end with
  `start=0`), wait for `auto_armed`, check `n_bytes` readback == 512 and
  post-run CRC == the reference. A second short run (no writes at all)
  covers the empty case: auto-verify fires with `n_bytes=0`.

Cost: < ~50 ALMs, no new clock domain, no new pads.

**Consequences to accept (flag for review):**
- `N` is the **4-byte-aligned** size: if the host pads a final partial word,
  the displayed/file N is up to +3 bytes vs the true file size, and the CRC
  covers the pad byte. Self-consistent (stored == readback, exactly), but
  not the host's file length.
- No file (slot `required:false`): the screen shows
  `OK CRC=00000000 N=00000000` — the diagnostic path is still visible.
  (The overlay's glyph set cannot spell "NO FILE"/"NONE"; if you prefer an
  explicit no-file state, tell us and we extend the font.)
- One-shot per core boot: a machine reset does not re-verify (the image
  survives; re-verify would need a new start, which nothing on hardware
  issues).

## 4. Questions

**Q1 — load-complete signal.** Have we missed any host-visible "slot load
done" signal (a bridge status word the host sets after streaming, a host
command, or a data.json feature)? If one exists, we'd rather gate on it than
on quiescence. From our reading of the APF data-slot docs and the NES
reference there is none — please confirm or correct.

**Q2 — exact size via the host command channel.** The 0xF8000000 host
command channel (0180/0184/0188 family): is a **core-initiated read** of the
host-side slot table (0xF8002000: id, size per slot) supported in the
standard APF bridge, and is it safe to issue while/after the host has
streamed? If yes, we'd take the exact byte length (drops the +0..3-byte
caveat and gives M1 a trustworthy size for free). If not, or if the cost/
risk isn't worth it for M0, we accept the 4-aligned N.

**Q3 — quiescence value.** 100 ms: safe against intra-stream host gaps
(host streams at SD-card speed; worst file 4 MiB ≈ up to a few hundred ms
total — mid-file gaps should be far smaller), and short enough that the
overlay appears ~1 s after the machine is visible. Anything you'd change
(e.g. 250 ms, or "N words of quiet *and* load_drained has been stable for
N")?

**Q4 — one-shot vs re-arm.** Machine reset does not reload the slot; core
boot re-arms everything (fresh state). We propose strictly one-shot per core
boot. Do you agree, or is there a scenario where a re-verify on the same
boot is wanted (and what would re-arm it)?

**Q5 — empty-load display.** `OK CRC=00000000 N=00000000` for "no file", or
should the overlay get an explicit no-file state (font extension)?

## 5. Exit criteria for this unit

- TB (shortened `AUTO_QUIET_CYCLES`): test F auto-fires with `n_bytes=512`,
  CRC == reference; empty case auto-fires with `n_bytes=0`; explicit 0xF9
  path (tests C–E2) still passes unchanged.
- Lint clean (Q17-parseable syntax only — no Verilog-2005 constructs).
- Hardware (Unit 6, with the regression RBF, `required:false` slot):
  boot with a .woz (e.g. `DOS 3.3 System Master.woz`, 234,496 B) -> on-screen
  `OK CRC=… N=…` within ~1 s of machine display, held ~5 s; boot without a
  file -> `OK CRC=00000000 N=00000000`.

## 6. Files touched (expected)

- `src/fpga/core/apple2e/sdram_storage.v` — auto-verify logic + parameter +
  status bit (the only RTL change)
- `verilog/tb/tb_top_storage.sv` — parameter override + test F (+ empty case)
- `docs/PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` — status update

Nothing else in the storage path changes. M1 (WOZ 512-byte sector transport)
sequels onto this without redesign: the fetcher will need its own read
requests through the same word-port arbitration (the `req_kind` mux already
anticipates it).

---

## Resolution (2026-10-19)

The expert review rejected the quiet-time proposal and specified the APF
metadata contract (0082 request pulse with id + exact size, 008F
all-complete, drain/commit, explicit failure reporting, per-load re-arm,
no size rounding). Implemented per that contract — see
`PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` Unit 6 implementation:
coordinator FSM in `sdram_storage.v`, result contract (OK/FAIL/NOFILE +
fail subcode OV/TO/IN/ST), per-generation fault clearing, exact-size
verifier arm, overlay displays, `data.json` required:false. Full
integration TB passes (no-file, pause, reload, 1/511/512/513-byte tails,
incomplete, overflow, chip-fault readback). Two DUT bugs found and fixed
during integration: 2-bit state reg truncating CO_RES to CO_IDLE, and a
stale fail subcode surviving an OK result.
