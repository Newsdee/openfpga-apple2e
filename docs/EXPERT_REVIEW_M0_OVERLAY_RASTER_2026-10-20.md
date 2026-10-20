# Expert review request — M0 SDRAM status overlay: raster model, glyph rendering, and the "no visible result" hardware symptom

Date: 2026-10-20
Repo: `apple2e-pocket` (branch `main`), Quartus project `apf_stream_video`, top `apf_top_stream`.
Companion docs: `EXPERT_REVIEW_M0_HARDWARE_NOVIS_2026-10-20.md` (host-bridge side of the
same symptom), `PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` (M0 storage units 1-8).

## 0. One-paragraph summary

The M0 storage path latches an on-screen result (OK CRC / FAIL / NO FILE) plus an
unconditional `M0<stage><status>` corner marker, drawn by
`src/fpga/core/apple2e/sdram_status_overlay.v` in the machine domain (14.318 MHz),
sitting after the OSK compositor. On hardware (Pocket), after selecting a `.woz` the
owner sees **nothing** — no marker, no window text. We rebuilt the overlay testbench
(`verilog/tb/tb_ovl_status.sv`) from a wrong one-clock-`hbl` raster model into a
real wide-blanking raster model and drove it through Verilator; the process exposed
several **real DUT bugs** (glyph horizontal mirror, 5-of-7-row marker truncation, and a
text-line corruption that makes space glyphs render as a 3-px vertical bar) plus
several **TB bugs** (col/row counter width and pacing). The marker now renders
pixel-exact for rows 0-4; the text lines (L1/L2/L3) still render corrupted. We want a
second pair of eyes on (a) the remaining L1/L2/L3 corruption, (b) the raster/counter
model we settled on, and (c) whether the "nothing visible on hardware" symptom can be
the same overlay bugs rather than (or in addition to) the host-bridge hypothesis in
the companion brief.

## 1. Verified facts (all reproduced locally, 2026-10-20)

### 1.1 The machine raster (ground truth from `machine/timing_generator.v` + `apf_video.v`)

- `m_hbl` is a **wide blanking interval**, not a one-clock pulse. In
  `machine/timing_generator.v`: `HBL = ~(H[5] | (H[3] & H[4]))` with the H counter
  ticking per H-slot; 24 H-slots per line x 14 masters ≈ **336 machine clocks of HBL
  per line**, then 560 active samples (apf_video `MAX_CAP = 40 H-slots x 14`).
- Row counting must therefore be **edge-based**: count once per HBL **rising** edge
  while `!vbl`, reset at the VBL **falling** edge — exactly what
  `apf_video.v` (`vline`) and the hardware-verified OSK overlay
  (`machine/osk/virtual_keyboard_overlay.sv`) do.
- The original Unit-7 overlay TB drove a **one-clock hbl pulse** and passed; that
  model was simply wrong about the blanking shape. The DUT was rewritten to the
  edge-based counter in this session.

### 1.2 The DUT counter (current, `sdram_status_overlay.v`)

```verilog
wire hbl_rise = ~hbl_d & hbl;
wire vbl_fall = vbl_r & ~vbl;
always @(posedge clk or posedge reset) begin
    if (reset) begin hbl_d<=1; vbl_r<=1; col<=0; row<=0; end
    else begin
        hbl_d <= hbl; vbl_r <= vbl;
        if (vbl_fall) begin col <= 0; row <= 0; end
        else begin
            if (hbl) col <= 0; else col <= col + 1;
            if (!vbl && hbl_rise && row != 8'd191) row <= row + 1;
        end
    end
end
```

`row` 0..191 (0 = first visible line of the stream frame), `col` = active-sample
index within the line. Note: with the TB raster below, `col` (and the mirror's
`m_col`) reach **1..558 during a row's visible active run and 559 on the first
cycle of the next row's blank**; `0` occurs only inside the blank. The DUT never
renders a pixel during `hbl`, so the visible columns are 1..559 and `px[0]` is never
a visible pixel.

### 1.3 The TB raster (current, `tb_ovl_status.sv`)

- 16->17-bit `fcyc` frame counter (a 16-bit counter **could not reach**
  `FRAME = 80*896 = 71680` and silently truncated the frame to 65536 cycles =
  34 visible lines instead of 40 — this bug masked everything else for most of
  the session).
- 40 VBL lines at frame start, 40 visible lines; per line 336 HBL + 560 active;
  `hbl`/`vbl` are registered versions of `in_hbl`/`in_vbl` (one-cycle lag, same as
  on hardware where the machine's `m_hbl`/`m_vbl` are register outputs).
- A **mirror** of the DUT's counters (`m_row`/`m_col`, identical reset/increment
  logic) selects which physical line a sample belongs to; `sample_line(V)` captures
  `px[m_col]` for the 559 values `m_col` takes while `m_row == V && !hbl`.
  `px[C]` is therefore exactly the DUT's output pixel at DUT column `C`, DUT row `V`.
- An **independent** 5x7 reference font (`refg`, transcribed row by row from the
  DUT's `gf` table) is used for exact per-pixel comparison; every rendered glyph is
  compared pixel-for-pixel (not white-pixel counts). All 16 hex digits are
  exercised in one result; the 128-word counter case ("000080") checks the low
  nibble; each fault flag (O/T/S) is tested individually; the marker stage digit
  is tested; window expiry and reset re-arm are tested.
- `SHOW_CYCLES` is a DUT parameter; the TB overrides it to 400000 (~446 lines) so
  the show window covers the multi-line test flow.

### 1.4 DUT bugs found and fixed this session (each verified in sim)

1. **Glyph horizontal mirror.** The pixel index used `rmbits[c]` instead of
   `rmbits[4-c]` (glyph bit 4 = leftmost pixel). Symmetric glyphs (M, 0, O, 8)
   were unaffected, which is why the marker "looked right"; asymmetric glyphs
   (K, R, C, L, F, S, V, 2, 3, 4, 5, 7, 9, D, P...) were mirrored. Fixed in all
   four boxes (marker + L1/L2/L3). The marker now decodes pixel-exact.
2. **Marker height truncation (still present — see 1.6).** `in_lm = (row < 5)`
   renders only rows 0-4 of the 7-row glyph.
3. **Show-window expiry (Unit-8 fix, verified).** The old counter saturated and
   `show` never expired; `show` now = `res_valid_m && show_cnt != 0 && show_cnt !=
   SHOW_CYCLES`.
4. **Verifier read-timeout hang (Unit-8 fix, in `disk_verifier.v` +
   `sdram_storage.v`).** A verifier timeout latches `stuck` and returns to IDLE
   **without asserting `done`**; the coordinator now releases on
   `v_done_rise_74 | v_stuck_74` and latches `FAIL TO` on the stuck path. The
   verifier has a `timeout_override` port so the TB can drive the real timeout
   path (the storage unit TBs exercise it).

### 1.5 TB bugs found and fixed this session

1. `sample_line` waited for a 560th pixel that never exists (col caps at 559;
   see 1.2) — every check hung at `c=559`.
2. `fcyc` 16-bit truncation (1.3).
3. The mirror's `m_row` caps at 33 when `fcyc` cannot reach the frame end (consequence of 2); `sample_line`'s 40000-cycle wait window was shorter than the worst-case row wait (~77 lines = 69k cycles) — bumped to 150000.
4. `$fopen("/tmp/...")` from a native Windows PE does not create the file (path
   is not MSYS-translated); dump now writes to
   `verilog/obj_dir_ovl/ovl_px.txt` (repo-relative).
5. A stale `set_marks` result (the TB built the expected marker array before the
   `stage_m` NBA assignment landed) made T0 fail by 2 pixels; fixed by settling
   the inputs before building the expectation.

### 1.6 Current sim state (what still fails, decoded pixel-for-pixel)

`tb_ovl_status` results (latest run, all tests now complete — no hangs, no
watchdog):

```
T0  PASS: quiet marker exact (marker rows 0-4, no stray pixels on a text line)
T1a FAIL  L1 'OK CRC=12345678'  (187 px)
T1b FAIL  L2 'N=00030000'       (141 px)
T1c FAIL  L3 'R=000080 C=000080' (237 px)
T1d PASS  marker 'M0 6O' exact
T2a FAIL  FAIL-result text (OV/TO/IN/ST variants)
T2b FAIL  NO FILE text
T3a-c FAIL per-flag / hex-digit / counter cases
T4  PASS  marker 'M0 3' (stage 3, no result) exact
T5  FAIL  window text still on after expiry (cols 426-440)
```

Decoded bitmaps from `ovl_px.txt` (offline decode against an independent
transcription of the `gf` table; `#` = white pixel, cells = 5 px + 1 gap):

**Marker `M06O` (X0=4, 4 cells) — rows 0-4 exact; rows 5-6 completely blank:**

```
cell0 M: ..#..   r0 exact
         .##..   r1 exact
         #..#.   r2 exact
         #...#   r3 exact
         #...#   r4 exact
         .....   r5  <- missing (glyph rows 5,6 not drawn)
         .....   r6  <- missing
```

`in_lm = (row < 8'd5)` — the marker band is 5 rows but the glyphs are 7 rows.
Fix is `row < 8'd7` (rows 0..6), **but** L1 starts at row 8, so rows 5-6 at X0=4
do not collide with L1 (X0=460) — the fix is geometry-only.

**L1 `OK CRC=C9260F5E` (X0=460) — per-cell decode (7 rows shown per cell):**

```
cell 0 'O': .#### #.### #.### #.### #.### #.### .####    (O r0/r6 gained c4)
cell 1 'K': #.### #.### #.### ##### #.### #.### #.###    (solid-ish, wrong)
cell 2 ' ': ..### ..### ..### ..### ..### ..### ..###    (space -> 00100 bar!)
cell 3 'C': .#### #.### #.### #.### #.### #.### .####
cell 4 'R': ##### #.### #.### ##### #.### #.### #####
cell 5 'C': .#### #.### #.### #.### #.### #.### .####
cell 6 '=': ..### ..### .#### ..### .#### ..### ..###
cell 7 'C': ..### .#### ..### ..### ..### ..### .####
cell 8 '9': .#### #.### ..### ..### .#### #.### .####
cell 9 '2': .#### #.### ..### ..### ..### #.### .####
cell10 '6': ..### ..### .#### #.### .#### ..### ..###
cell11 '0': ##### #.### ##### ..### ..### #.### .####
cell12 'F': ..### .#### #.### ##### #.### #.### .####
cell13 '5': ##### ..### ..### ..### .#### .#### .####
cell14 'E': .#### #.### #.### .#### #.### #.### .####
```

**L3 `R=000080 C=000080` (X0=424) — cells 0-5 exact (`R = 0 0 0 0`), then:**

```
cell 6 '8': .#### #.### #.### .#### #.### #.### .####
cell 7 '0': ..### .#### .#### .#### .#### .#### ..###
cell 8 ' ': ..### ..### ..### ..### ..### ..### ..###   (space -> 00100 bar!)
cell 9 'C': .#### #.### #.### #.### #.### #.### .####
cell10 '=': ..### ..### .#### ..### .#### ..### ..###
cells11-14 '0': ..### .#### .#### .#### .#### .#### ..###  (exact 0s)
cell15 '8': .#### #.### #.### .#### #.### #.### .####
cell16 '0': ..### .#### .#### .#### .#### .#### ..###
cells17-20 ' ': ..### ..### ..### ..### ..### ..### ..###  (spaces -> bars!)
```

Observations that pin the failure to glyph selection / row bits, **not** to the
raster counters (which are proven by the exact marker rows and the exact L3
cells 0-5, 11-14):

- Exact glyphs appear at exact columns with exact row bitmaps (L3 cells 0-5,
  11-14; L1/L2 several cells) — so `row`, `col`, `cidx`, `cin` arithmetic, the
  `4-c` mirror, and the row slice are all demonstrably correct where they land on
  the right `ln` entry.
- **Space glyphs (code 26, `gf = 35'd0`) render as a constant `00100` vertical
  bar** at every space position (L1 cell 2, L2 cell 1, L3 cells 8, 17-20). A
  35-bit-zero lookup cannot produce that; something else is driving those
  pixels (a different `ln` entry being read, a `cin`/`cidx` alias, an OR of
  neighbors, or the `ln` latch not holding the SP code).
- Where a non-space cell is "wrong", the rendered pattern looks like the OR of
  the correct glyph and a `0`-glyph (e.g. 'O' r0 = 01110 rendered as 01111 =
  01110 | 00111|c4; 'C' cells gaining c4; 'K' cell nearly solid). The extra
  pixels always match the row bits of glyph **0** at the same cell.
- Cells that should be blank (SP) and cells that render "extra 0-pixels" are
  **not adjacent** in a single-cell shift pattern (L1: cells 0,1,2,3,4,5,6,7 all
  wrong together from the left edge; L3: 0-5 exact, 6-16 wrong, 11-14 exact
  inside that) — it is not a uniform index offset.

**Working hypothesis (unverified):** the `ln1/ln2/ln3` latch arrays are not
holding the latched codes at the sampled time, or `gf`'s `case` is being
evaluated with a stale/aliased index under Verilator's two-state scheduling
(e.g. `ln1[cidx1_w[3:0]]` where `cidx1_w` is a 10-bit wire and the array has
15 entries — the high bits should be don't-care but the decoded pattern is not
consistent with that either). A second reader of the latch+lookup path is wanted
before more TB cycles are burned.

### 1.6b Storage-side status (unchanged this session, re-verified passing)

- `tb_bridge_storage.sv` (real `core_bridge_cmd` + real storage path, documented
  host sequence `0000/0011/0082+writes/008F`): all 9 scenarios PASS
  (idle, reset-exit, NOFILE, 512B OK crc=c9260f5e, 1001B partial-word OK, wrong
  slot ignored, FAIL IN, FAIL OV with 008F no-clobber, reset-preservation,
  re-arm after failed generation).
- `tb_top_storage.sv` (unit-level integration): PASS (boot, store, CRC,
  reset-preservation, tails, auto-verify no-file/pause/reload/tails/
  incomplete/overflow/chip-fault).
- `tb_slot_fifo.sv`, `tb_disk_store.sv`: PASS.
- Coordinator: 3-bit state (5 states), result latching guarded (`allc_edge &&
  !res_valid`), OK clears `res_fail`, stuck-verifier path latches FAIL TO
  (1.4.4).
- Bitstream provenance: the newly compiled `apf_stream_video.rbf`
  (1,402,216 B, flow successful 2026-10-20 11:19) was re-staged through
  `tools/rbf2rbf_r.py` to `sd_root/Cores/Newsdee.Apple2eStreamVideo/
  bitstream.rbf_r` (sha256 `2610357c...b6fbe` verified identical on both sides).
  `src/fpga/apf/build_id.mif` was rewritten by Quartus and reverted before this
  write.

## 2. Open questions for the expert

1. **L1/L2/L3 glyph corruption** (1.6): with the counters proven correct (exact
   marker rows 0-4, exact L3 cells), what in the `ln` latch -> `gf` -> row-slice
   path would (a) make a zeroed 35-bit glyph render as a `00100` bar and (b) OR
   `0`-glyph row bits into non-zero cells? Is there a Verilator two-state
   scheduling artifact in `ln1[cidx1_w[3:0]]` (10-bit index into a 15-entry
   packed array) or in the `case (g)` function that would show in sim but not
   synthesis? What is the cheapest TB-side probe that discriminates
   "wrong `ln` code latched" from "wrong `gf` result"?
2. **Raster/counter model**: is the settled model (edge-based row on HBL rising
   while `!vbl`, VBL-fall reset, col 1..559 visible, `px[0]` never visible) the
   correct one-to-one with the hardware `m_hbl`/`m_vbl` waveforms and
   `apf_video.v`'s `vline`? Any off-by-one risk at the first visible line or the
   559th column that the TB's mirror cannot catch because it copies the DUT's
   own counter logic?
3. **Hardware symptom linkage**: the owner's hardware shows *nothing* (no
   marker at all) after `.woz` selection. Given (a) the marker is unconditional
   and now proven to render in sim, (b) the old shipped bitstream contained the
   mirror bug + 5-row truncation (marker would still have been *partially*
   visible — M/0/O glyphs are symmetric, so `M0<st><st>` would have shown
   rows 0-4 even in the buggy build), and (c) the overlay sits after the OSK
   compositor and wins `rgb_out` — is "absolutely nothing visible" more
   consistent with (i) the host never sending the `0082`/data/`008F` sequence
   (no result, but the marker should still show), or (ii) the overlay instance
   not being in the video path at all on hardware (port binding / `rgb_in`
   source / `hbl`/`vbl` source mismatch in `apf_stream_video_top.v`)? What
   one-cycle hardware-visible probe (e.g. force `rgb_out` white for a known
   line region regardless of any input) would settle (ii) in one flash?
4. **`show` window vs T5**: T5 (expiry) still fails with text on cols 426-440
   after the window should have closed. With `SHOW_CYCLES=400000` the window is
   ~446 lines; is the T5 check racing the window (TB pacing) or is the expiry
   still wrong in the DUT? (The 1.4.3 logic reads correct on paper:
   `show = res_valid_m && show_cnt != 0 && show_cnt != SHOW_CYCLES`.)
5. **Marker geometry**: confirm `in_lm = row < 7` is safe (L1 starts row 8 at
   X0=460; marker X0=4 — no column overlap, so 7-row glyphs at rows 0-6 do not
   collide) or whether the marker should stay 5 rows for panel-margin reasons.

## 3. Reproduction

```bash
# overlay TB (the failing one)
cd E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket
# MSYS2 ucrt64, VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
verilator_bin --binary --timing -j 4 --top tb_ovl_status \
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
  --Mdir verilog/obj_dir_ovl \
  src/fpga/core/apple2e/sdram_status_overlay.v verilog/tb/tb_ovl_status.sv
./verilog/obj_dir_ovl/Vtb_ovl_status        # decode dump: verilog/obj_dir_ovl/ovl_px.txt

# storage-side TBs (passing) - shared deps: apf/common.v (synch_3),
# io_sdram_pocket.v, verilog/tb/tb_dram_model.sv (SDRAM behavioral model),
# core_bridge_cmd.v lives in src/fpga/core/ (NOT src/fpga/apf/)
verilator_bin --binary --timing -j 4 --top tb_bridge_storage \
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
  --Mdir verilog/obj_dir_brg \
  src/fpga/apf/common.v src/fpga/core/core_bridge_cmd.v \
  src/fpga/apf/mf_datatable.v src/fpga/core/apple2e/sdram_storage.v \
  src/fpga/core/apple2e/slot_fifo.v src/fpga/core/apple2e/disk_store.v \
  src/fpga/core/apple2e/disk_verifier.v src/fpga/core/apple2e/io_sdram_pocket.v \
  verilog/tb/tb_dram_model.sv verilog/stubs/altsyncram_sim.v \
  verilog/tb/tb_bridge_storage.sv
./verilog/obj_dir_brg/Vtb_bridge_storage     # "BRIDGE STORAGE PASS: ..."
```

Known host quirk: freshly linked C++ PEs are intermittently killed by the
endpoint-protector (exit 127, no output); relink-and-run in one command, or
wait; it does not affect the RTL conclusions above.

## 4. What we deliberately did NOT change

- `machine/` OSK RTL (byte-identical parity with the MiSTer reference).
- The storage path (`sdram_storage.v` coordinator, `disk_verifier.v`,
  `disk_store.v`, `slot_fifo.v`, `io_sdram_pocket.v`) beyond the Unit-8
  verifier-timeout release (1.4.4), which is covered by passing TBs.
- The host-bridge side (`core_bridge_cmd.v` usage) — that question lives in the
  companion brief; this brief is the overlay/raster half of the same symptom.

## 5. Resolution (2026-10-20, same day — expert findings implemented)

1. **Text layers drawing outside their rows** — confirmed in source
   (`px1/px2/px3` enables lacked `in_l1/in_l2/in_l3`; fallback glyph 0 =
   digit '0', row offset 0). Added the vertical gates. This was the
   corruption: after the fix, all text lines decode pixel-exact.
2. **T5 expiry** — TB now uses one shared parameter (SHOW_CYCLES=4_000_000),
   pre-checks text ON, waits 4_200_000 cycles past the threshold, checks
   OFF. T5a/T5b PASS.
3. **Generation events** — `set_result` models a fresh generation (valid
   low, settle, payload, valid high). T2/T3/dump now re-latch correctly.
   No RTL change for relatching.
4. **Failure reporting** — aggregate `fails` with per-scenario `fbase`
   deltas; `$fatal(1)` on sample timeout, final failure, and watchdog.
   Exit code 0 now means PASS.
5. **Raster alignment** — synthetic wide-blanking raster retained as the
   unit model; DE-based stream-level verification (560 px/line, full frame)
   recorded as a follow-up in the plan. (Also found while verifying: the
   TB must wait for the first visible line after reset — `m_row==0` is
   stale during the initial VBL, which had made T0's row-0 marker check
   read a VBL line.)
6. **Marker height** — `in_lm` now `row < 7`; T0 checks all 7 marker rows
   pixel-exact. **Diagnostic rectangle** — new `DBG_RECT` parameter
   (default 0) draws a persistent 50x3 white rectangle (rows 10..12,
   cols 100..149) independent of storage/font logic; verified by
   `tb_ovl_dbgrect` (PASS). The one-shot hardware build sets
   `#(.DBG_RECT(1))` in `apf_stream_video_top.v` (line 854) to settle
   question 3 (is the overlay in the video path at all).

Final sim state: `tb_ovl_status` 14/14 scenario checks PASS, exit 0;
`tb_ovl_dbgrect` PASS; overlay strict lint clean. A fresh owner compile of
`apf_stream_video` is required (staged bitstream predates these fixes);
the diagnostic build should include `#(.DBG_RECT(1))`.
