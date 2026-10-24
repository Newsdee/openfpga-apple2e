# External review brief — M1: WOZ boot no-boot (post-scan EOF/OOR eject) + Verilator harness anomalies

Date: 2026-10-22
Project: `E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket` (Analogue Pocket Apple IIe core, Quartus Prime Lite 17.0.2, Cyclone V 5CSEBA6U23I7)
Status of the wider M1 work: Quartus compile green at all corners (incl. the SDRAM 133.12 MHz fetcher timing fix), storage TBs all pass, RBF built and flashable. The remaining blocker is the **WOZ floppy no-boot**, now root-caused to a post-scan eject, plus a set of **Verilator harness anomalies** that block direct observation of the root cause in simulation.

Two questions. Q1 is the engineering question (decisive). Q2 is a harness/toolchain question (needed to progress Q1 in simulation).

---

## TL;DR

1. **Q1:** The WOZ engine (byte-pinned from the MiSTer project, `src/fpga/core/woz/woz_floppy_controller.sv`) is supposed to stop scanning a WOZ file as soon as it has parsed the INFO/TMAP/TRKS chunk headers (`parser_done`), which for the test file happens after ~1.5 KB (block 3). In the Verilator full-machine simulation it instead **reads all 458 blocks (234 496 bytes = entire image)**, then issues **one sector read past end-of-image**. The Pocket-owned transport latches an OOR fault on that final read, the mount controller **ejects** the disk, and the machine sits at the ROM monitor (blank screen, "no boot"). The byte stream into the engine has been checked for byte order (MSB-first, correct), phantom bytes (none), and clock domain (engine and transport both on the 14.318 MHz machine clock). We have **not** been able to observe the engine's internal parser state in simulation (see Q2), so the exact mis-parse mechanism is not yet proven. Prime suspect: a **byte-window offset in the Pocket sector fetcher** (`src/fpga/core/apple2e/sdram_sector_fetch.v`) that the round-trip verify command does not cover. The reviewer is asked to (a) audit the fetcher's byte window + the new pipelined bounds logic for a sub-word/word offset, (b) audit the engine parser against the WOZ2 spec for anything that would never complete on this file, (c) recommend the least-invasive Pocket-owned fix for the EOF→OOR→eject chain.

2. **Q2:** In our Verilator 5.050 `--timing` harness (`verilog/pocket_boot/`), two anomalies block instrumentation:
   - TB-level `always`/`wait` conditions on TB regs (`e74a` 74a-clock edge counter, `par_cnt`) **never fire**, even though the C++ main program reads those same regs correctly every millisecond and `$display` statements in the *same* always block that reference *DUT* signals do fire.
   - Delay coroutines with `#20_000_000` / `#200_000_000` (20/200 ms in a 1 ns timescale) effectively fire **immediately**, and `#50_000_000` (50 ms) fires at **10 ms** — an apparent `(t+d) mod 20 ms` behavior — while `#2_000_000`/`#5_000_000` behave correctly. Generated Verilator C++ delay constants are all correct (verified in `obj_dir`); `VlDelayedCoroutineQueue` is a plain `std::multimap`; `VerilatedContext` time is a plain `uint64_t`.

---

## 1. Background (what exists, what works)

- `apf_stream_video_top.v` (top: `stream_video_core_top` under the APF template) instantiates:
  - the Apple IIe machine (`machine/apple2.v` etc.) on `clk_core_14318` (14.318 MHz),
  - the Disk II WOZ variant `disk_ii_woz woz` (`src/fpga/core/woz/disk_ii_woz.sv`) — pinned MiSTer engine `woz_floppy_controller` (drive 0 active) + ROM disk fallback,
  - the Pocket storage path: `sdram_storage` (host 74a-domain bridge protocol → 256-deep slot FIFO → `disk_store` → SDRAM via the M0-proven `io_sdram_pocket` on a 133.12 MHz PLL `mp2`),
  - `sdram_sector_fetch` (machine-domain byte service over the SDRAM image, "frozen window"),
  - `sdram_woz_transport` (machine domain; serves engine `sd_rd`/512-byte blocks from the fetch window; latches `wr_fault`/`oor_fault`),
  - `woz_mount_ctl` (74a domain; lifecycle: mount on load-OK result edge, **eject on transport_fault**, remount dance).
- Boot sequence in simulation (host = our TB emulating the APF host):
  1. C++ generates `pocket_boot.woz.hex` from `verilog/pocket_boot/disk.woz` (234 496 bytes).
  2. TB host: `0x0010` (reset) → write id/size/words of the WOZ image (paced ~47 74a-cycles/word) → `0x0082` (load) → `0x008f` (verify) → `0x0011` (reset-exit).
  3. Storage coordinator: LOAD → DRAIN → WAITV → RES(OK) → `res_valid_m` rising edge → `woz_mount_ctl` mounts → engine `img_mounted` rises.
  4. Engine enters `S_SCAN_WOZ`, reads 512-byte blocks from the transport starting at LBA 0, parsing WOZ chunks as it goes.
- Verified facts (simulation): load+verify return OK (`res82=0000 res8f=0000`); mount happens at ~89.5 ms; the engine then reads the **entire** image (transport read counter `RD=234496`); at ~110 ms one read is issued past the end of the image; `transport_fault` rises with `oor=1`; `woz_mount_ctl` runs its eject sequence (states 1→2→3→4→0); `img_mounted` falls; the engine never re-scans successfully; the machine stays at the ROM monitor. Video frames render (machine clock is alive) but the screen stays blank (no floppy boot).

### The WOZ test file (`verilog/pocket_boot/disk.woz`, 234 496 bytes)

```
12-byte WOZ2 header: 57 4F 5A 32 FF 0A 0D 0A 66 80 66 6C   ("WOZ2", 0xFF 0A 0D 0A, CRC32)
Chunk stream starts at offset 12:
  off 12    id=INFO size=60      (end 80)    data[0]=version=2, data[1]=disk_type=1, ...
  off 80    id=TMAP size=160     (end 248)
  off 248   id=TRKS size=234240  (end 234496 = exact EOF)
No FLUX chunk. info_version=2 → need_flux = (version>=3 && flux_block!=0) = 0.
= 458 × 512-byte sectors, file ends exactly on a sector boundary.
```

### Expected engine behavior (from the pinned engine)

`parser_done = have_info && have_tmap && have_trks && (!need_flux || have_flux)`.
The streaming parser skips the first 12 file bytes, then parses `[id:4][size:4]` chunk headers. For this file: INFO header completes at byte 20, `have_info` at byte 21 (first INFO data byte); TMAP header at byte 80, `have_tmap` after its 160 data bytes (byte 247); TRKS header at byte 248, `have_trks` after its first 1280 data bytes (byte 1535, i.e. inside block 3). `parser_done` should therefore be true at the **completion of block 3**; the scan loop stops there (`state <= S_IDLE`, `woz_valid <= 1`).

### Observed engine behavior (simulation)

- All 458 blocks are read (`RD=234496`), `parser_done` evidently never becomes true, then one read at LBA 458 (past EOF) → OOR fault → eject.
- The engine's `$display("WOZ_CHUNK: Parsing '%c%c%c%c' size=%0d", ...)` fired ~26 000 times over the scan (≈57 "chunk headers" parsed per 512-byte block) — i.e. the parser is in chunk-header mode most of the time, which means `chunk_left` is repeatedly reaching zero with garbage size decodes. (The `%c` output is garbled in the log, so the counts are indicative, not authoritative.)

---

## 2. Q1 — why does the scan never complete, and what is the right fix?

### 2.1 Evidence gathered so far (ruling things in/out)

| Check | Result |
|---|---|
| Byte order fetcher→engine | **OK.** `sdram_sector_fetch`: `widx = addr[8:2]`, `bsel = addr[1:0]`, byte 0 = word[31:24] (MSB-first). Matches the host word layout (`$readmemh` word i = file bytes 4i..4i+3, first byte = MSB). |
| SDRAM content vs image | **OK** via the core's own verify command (`0x008f` → OK). Note: the verifier compares **SDRAM words**, so it does *not* exercise the fetcher's byte window (`sector_byte_addr`→`sector_byte_data`) — a 4-byte (1-word) or sub-word window offset would pass verify. |
| Phantom bytes in S_HOLD | **OK.** `sd_buff_wr = (state == S_DATA)` — the 3-cycle ACK hold after byte 511 has `wr=0`, engine ignores it. |
| Engine vs transport clock | **Same domain.** Transport `clk` = 14.318 MHz machine clock, one byte per machine cycle; no rate aliasing. |
| Ack/strbe pattern | Transport: S_REQ (fetch) → ACK raised before byte 0 → 512×(ack,wr) cycles → 3-cycle hold → release. Engine handshake regs (`old_ack`, `transfer_active`, `request_issued`) per excerpts below. |
| Parser state init | Mount-edge reset in the engine clears `have_*`, `hdr_pos`, `chunk_*`, `info_*`, `scan_*` (see excerpt). First scan starts clean. |
| `WOZ_CHUNK` log | Garbled/unreliable (repeated `%c` formatting artifacts) — treated as indicative only. |

### 2.2 Candidate root causes (ranked, unproven — this is what the review should target)

**A. Pocket fetcher byte-window offset (prime suspect).**
`sdram_sector_fetch.v` was modified this round for the SDRAM timing fix (3-stage pipelined bounds arithmetic with `(lba, gen)` freshness tags `g_lba_p*/g_gen_p*`, `geom_fresh` gating, `oor_p3`/`nrd_p3` in `ST_IDLE`). If the frozen window is off by one word (or a nibble/byte) for the sectors the scan reads — e.g. first-sector-after-generation staleness, an sbuf index off-by-one, or a `sector_byte_addr` mapping skew — the parser would see a persistently misaligned stream, decode garbage chunk sizes, and never complete. Crucially this is **Pocket-specific**: the MiSTer path serves blocks from `hps_io` and never touches this fetcher. A 4-byte misalignment also matches the "many small garbage headers" signature.

**B. Engine parser bug on this file (less likely: engine is byte-pinned from MiSTer).**
e.g. an off-by-one in `chunk_left`/`chunk_index` accounting, or the `have_trks` set condition never met for a TRKS of exactly 234 240 bytes. But the same engine is reported to work in the MiSTer project (with `hps_io` as the byte source) — worth confirming which WOZ files actually work there and whether any WOZ2 file without FLUX was ever scanned to completion.

**C. Handshake byte loss under the Pocket transport's ack pattern.**
The engine gate `(transfer_active || (!old_ack && sd_ack))` exists to reject unsolicited re-served LBAs from the HPS. If the Pocket transport's exact ack waveform (raise-before-byte-0, 3-cycle hold, release) interacts with `request_issued`/`transfer_active` such that bytes are dropped (e.g. `transfer_active` never set on some blocks → only the first byte of a block passes), the stream fragments. The observed ~55–57 bytes/block processed pattern is roughly consistent with large byte loss *or* with misalignment — not yet distinguishable.

**D. `scan_skip_*` path or meta-write side effects.** `scan_skip_active` is only armed from the TRKS-skip optimization (needs `need_flux`), so it should be inert for this file — verify the reviewer finds no accidental arming. `meta_we` writes during the scan target metadata BRAM only (shouldn't affect the byte stream).

### 2.3 The EOF/OOR/eject chain (secondary question: even if the parser eventually works, is the chain right?)

`src/fpga/core/apple2e/sdram_woz_transport.v`:

```verilog
assign transport_fault = wr_fault || oor_fault;      // latched
// S_IDLE:
if (drive_active && sd_rd && !wr_fault && !oor_fault) begin
    if (sd_lba[31:16] != 16'd0) oor_fault <= 1'b1;    // >32 MiB
    else begin lba_l <= sd_lba[15:0]; ... S_REQ; end
end
// S_REQ:
if (fetch_fault) begin ... oor_fault <= 1'b1; end     // fetch service rejected LBA (>= img_nbytes/512)
```

`src/fpga/core/apple2e/woz_mount_ctl.v`: `transport_fault` rising edge → `fault_pend` → eject sequence (ST_EJ1→EJ2→EJ3) → ST_UNMOUNTED; re-mount only on a new load result.

So **any** out-of-range sector read — including a legitimate "one past the end" probe — permanently ejects the drive until a new host load. The pinned engine's scan loop has an explicit `SCAN_BLOCK_LIMIT` error path (16 000 blocks → `scan_failed`) but no end-of-image stop: it relies on `parser_done`. In MiSTer (hps_io), reads past EOF presumably return stale/zero bytes without faulting (HPS behavior), so the scan limit or parser_done eventually stops it — the fault-based eject behavior is a Pocket-transport invention.

**Ask:** recommend the least-invasive Pocket-owned fix, evaluating:
1. Transport returns a **non-faulting end-of-image** response for the specific case of a read one-past-EOF during scan (e.g. serve the frozen window as zeros / NACK with `sector_done` and no `oor_fault`), keeping OOR faults for truly invalid requests; or
2. A Pocket-owned **scan stop condition** using the known image size (`img_nbytes` is available in the 74a domain — needs CDC) that terminates the engine's scan cleanly; or
3. Something else the reviewer prefers (e.g. mount_ctl tolerating a single OOR during the scan window).
Constraints: the WOZ engine is byte-pinned (one documented exception already exists in `disk_ii_woz.sv` — see `src/fpga/core/woz/NOTICE.md`); prefer not to add a second; the fix must keep genuine OOR fault behavior for post-boot track reads beyond the image.

### 2.4 Key code excerpts

Engine scan loop (`woz_floppy_controller.sv` ~664–725):

```verilog
S_SCAN_WOZ: begin
    if (!sd_ack && !(old_ack && transfer_active)) sd_rd <= 1'b1;
    if (scan_skip_active) begin ... end
    else if (!scan_skip_active && old_ack && !sd_ack && transfer_active) begin
        scan_blocks <= scan_blocks + 1'd1;
        scan_skip_discard <= 1'b0;
        if (parser_done) begin
            woz_valid <= 1'b1; busy <= 0; state <= S_IDLE;
            $display("WOZ_CTRL: Parsed INFO/TMAP/TRKS%s ...", ...);
        end else if (scan_blocks >= SCAN_BLOCK_LIMIT) begin
            woz_valid <= 1'b0; busy <= 0; state <= S_INIT; scan_failed <= 1'b1;
            $display("WOZ_CTRL: ERROR: WOZ scan limit reached ...", ...);
        end else begin
            sd_lba <= sd_lba + 1'd1;
        end
    end
end
```

Handshake regs (~412–435):

```verilog
always @(posedge clk) begin
    old_ack <= sd_ack;
    if (!old_ack && sd_ack && request_issued) begin
        transfer_active <= 1'b1;  request_issued <= 1'b0;
    end
    if (old_ack && !sd_ack) transfer_active <= 1'b0;
    if ((sd_rd || sd_wr) && !sd_ack && !transfer_active && !request_issued)
        request_issued <= 1'b1;
end
```

Parser byte gate + streaming parser (~1381–1475; abridged):

```verilog
if (sd_ack) begin
    if (sd_buff_wr) begin
        if (state == S_SCAN_WOZ && !scan_skip_discard &&
            (transfer_active || (!old_ack && sd_ack))) begin
            b = sd_buff_dout;
            if (hdr_pos < 4'd12) hdr_pos <= hdr_pos + 1'd1;        // skip 12-byte header
            else begin
                if (chunk_left == 32'd0) begin
                    if (chunk_hdr_pos < 3'd4)
                        chunk_id <= {chunk_id[23:0], b};            // id (4 bytes)
                    else begin
                        chunk_size_acc <= chunk_size_acc | (b << ((chunk_hdr_pos-4)*8)); // size LE (4 bytes)
                        chunk_hdr_pos <= chunk_hdr_pos + 1'd1;
                        if (chunk_hdr_pos == 3'd7) begin
                            chunk_left <= chunk_size_acc | (b << 24);
                            chunk_index <= 32'd0; chunk_hdr_pos <= 3'd0; chunk_size_acc <= 32'd0;
                            $display("WOZ_CHUNK: Parsing '%c%c%c%c' size=%0d", ...);
                        end
                    end
                end else begin
                    // INFO: have_info at chunk_index==0 (info_version := byte 0)
                    // TMAP: meta writes; have_tmap at chunk_index==159
                    // TRKS v2: meta writes for first 1280 bytes; have_trks at chunk_index==1279
                    chunk_index <= chunk_index + 1'd1;
                    chunk_left  <= chunk_left  - 1'd1;
                    if (chunk_left == 32'd1) begin chunk_id <= 32'd0; chunk_hdr_pos <= 3'd0; chunk_size_acc <= 32'd0; end
                end
            end
        end
    end
end
```

`parser_done` (~379–381):

```verilog
wire need_flux   = (info_version >= 8'd3) && (info_flux_block != 16'd0);
wire parser_done = have_info && have_tmap && have_trks && (!need_flux || have_flux);
localparam [15:0] SCAN_BLOCK_LIMIT = 16'd16000;
```

Transport byte stream (`sdram_woz_transport.v` ~160–205; abridged):

```verilog
S_REQ:  if (fetch_fault) begin ... oor_fault <= 1'b1; state <= S_IDLE; end
        else if (sector_ready) begin sd_ack <= 1'b1; byte_cnt <= 10'd0; state <= S_DATA; end
S_DATA: // one byte per cycle; sd_buff_wr = (state==S_DATA); sd_buff_addr = byte_cnt[8:0]
        if (!drive_active) abort;
        else if (byte_cnt == 10'd511) begin hold_cnt <= 3'd0; state <= S_HOLD; end
        else byte_cnt <= byte_cnt + 10'd1;
S_HOLD: // ack stays high 3 cycles
        if (hold_cnt == 3'd2) state <= S_RELEASE;
S_RELEASE: sd_ack <= 1'b0; state <= S_IDLE;
```

Fetch byte window (`sdram_sector_fetch.v` ~344–358):

```verilog
wire [6:0] widx8 = sector_byte_addr[8:2];
wire [1:0] bsel  = sector_byte_addr[1:0];
wire [31:0] wsel_eff = ({3'b000, widx8} < {1'b0, nrd_l}) ? sbuf[widx8] : 32'd0;
case (bsel) 0: byte_eff = wsel_eff[31:24]; 1: [23:16]; 2: [15:8]; default: [7:0]; endcase
assign sector_byte_data = byte_eff;
```

(Also audit the surrounding pipeline: `g_lba_p0..p3`/`g_gen_p0..p3` freshness tags, `geom_fresh`, `rem->remc->nrd_l` 3-stage bounds pipeline, `pend_accept`, `ST_HOLD`/`sector_done` — the whole module is small and the reviewer should read it in full: `src/fpga/core/apple2e/sdram_sector_fetch.v`.)

### 2.5 Simulation evidence (logs)

`verilog/pocket_boot/run_boot3s.log` (800 ms budget run):

```
TB: mount_ctl state 0->1 rv=1 rc=00 ... t=89518180000      (89.5 ms mount)
SMOKE BOOT OK: frames=211 reads=234496 t=800001.292ms
TB: mount_ctl state 1->2 rv=1 rc=00 ... t=110030281000
TB: mount_ctl state 2->3 rv=1 rc=00 ... t=110030294000
TB: mount_ctl state 3->4 rv=1 rc=00 ... t=110030307000
TB: transport_fault 0->1 wr=0 oor=1 ... t=110030254000    (OOR latch, ~110.030 ms)
TB: transport_fault 1->0 wr=0 oor=0 ... mstate=0 t=110030321000  (fault cleared, ejected)
TB: mount_ctl state 4->0 ... t=110030321000
```

`verilog/pocket_boot/run_70.log` (70 ms budget run, current reconstructed TB — shows the pre-scan phase; mount would occur at ~89.5 ms):

```
t=2004.601ms host=busy st=1 ... mrs=1 rstn=0               (0x10 at 2 ms)
t=41045.243ms host=idle st=4 ... mrs=0 rstn=1               (0x11 at ~41 ms, machine released)
t=44048.370ms frames=1 ... MT=0 RD=0                        (video alive, no mount yet)
```
(Note: the C++ "t=" labels in these logs are **µs mislabeled as ms**; the TB `$time` values in the `TB:` lines are ps.)

---

## 3. Q2 — Verilator `--timing` harness anomalies

Harness: `verilog/pocket_boot/` — `tb_pocket_boot.sv` (full `stream_video_core_top` DUT + `tb_dram_model` SDRAM model + TB-generated 74.25 MHz clocks), `pocket_main.cpp` (SDL2 front end + main loop), built with Verilator 5.050 (`--cc --timing`, manual g++ link, `MSYS2 ucrt64`). The machine simulates correctly (video frames, host protocol, storage, transport counters all behave) at ~0.9 ms machine-time per wall-second.

### 3.1 Main loop (`pocket_main.cpp` ~183–205)

```cpp
while (!quit && !ctx->gotFinish()) {
    // periodic SDL/frame/log work every batch of up to 2000 slots
    for (int i = 0; i < 2000 && !quit && !ctx->gotFinish(); i++) {
        top->eval();                                  // processes events at current time
        if (!top->eventsPending()) {
            double nt = top->nextTimeSlot();
            if (nt > ctx->time() + 1.0) {
                ctx->time(nt);                        // advance to next scheduled slot
                continue;                             // re-eval at the new time
            }
            break;
        }
        ctx->time(top->nextTimeSlot());
    }
    ... frame capture / logging / smoke-exit checks ...
}
```

Context: generated model's `eval()` = `eval_step()` (initials on first call, then act/inact/nba convergence per slot); `eventsPending()` = delay-queue non-empty; `nextTimeSlot()` = min of the delay queue. Verilator 5.050 `--timing` generated delays are picoseconds; `ctx->time()` is ps (this was previously a bug in our harness and is fixed).

### 3.2 Anomaly 1 — delays ≥ 20 ms fire early

Observed firing times (TB `$time`, ps):

| TB delay (1 ns timescale) | Scheduled at | Expected fire | Observed fire |
|---|---|---|---|
| `#2_000_000` (2 ms) | t=0 | 2 ms | **2 ms ✓** |
| `#4_000_000` (4 ms) | t=0 | 4 ms | 4 ms ✓ (por_done) |
| `#5_000_000` (5 ms) | t=0 | 5 ms | **5 ms ✓** (e74a=370953 at fire) |
| `#20_000_000` (20 ms) | t≈2 ms | ≈22 ms | **≈2.2 ms (load started immediately after 0x10)** |
| `#50_000_000` (50 ms) | t=0 | 50 ms | **10.00001 ms** |
| `#200_000_000` (200 ms) | t≈40 ms | ≈240 ms | **≈0 (host re-loops immediately after cycle done)** |

Consistent with `fire_time = (t_sched + d) mod 20 ms`. The generated Verilator C++ delay constants are all correct (`delay(0xba43b7400ULL)` = 5×10¹⁰ ps for the 50 ms one, etc.). `VlDelayScheduler::delay()` schedules `m_context.time() + delay` into a plain `std::multimap<uint64_t, ...>`; `VerilatedContext::m_time` is a plain `uint64_t` (no wrap/clamp found in `verilated.h`/`verilated_timing.h` 5.050 headers). So the wrap appears to be an **interaction between our main loop and the generated model**, not a visible constant. (We have not yet located the mechanism — that is part of the ask.)

### 3.3 Anomaly 2 — TB-level conditions on TB regs never fire

In `tb_pocket_boot.sv` (timescale 1ns/1ps):

```verilog
reg [31:0] e74a /* verilator public */;   // + initial e74a = 0
always @(posedge clk_74a) e74a <= e74a + 32'd1;     // clk_74a = TB-generated 74.25 MHz
```

- C++ reads `P(e74a)` every ~1 ms: **advances exactly at 74.25 MHz** (0 → 74217 → 148545 → … → 817492 over 11 ms). So the counter is alive and visible.
- Yet **none** of these ever fire in runs up to 70 ms (each verified present in the generated C++):
  - `initial begin wait (e74a > 32'd370000); $display(...); end`
  - `always @(posedge clk_74a) if (!flag && e74a >= 32'd1000) $display(...);`
  - `if (e74a == 32'd370000) $display(...);` (inside a monitor always block)
  - `if (par_cnt == 32'd371250) $display(...);` where `par_cnt` (21-bit) is incremented in the same monitor block.
- **But** in that same monitor always block, `$display` statements gated on **DUT-signal** changes fire correctly (e.g. mount-control state transitions, storage coordinator state, transport-fault edges — all observed in logs). Delay-based initials (`#2_000_000`, `#5_000_000`) also fire (when their delay "works").
- The generated code is standard: the wait's trigger pre-eval is `0x0005a550U < vlSymsp->TOP__tb_pocket_boot.e74a`, conditions compile flat, the root `___024root___eval` runs the act/inact/nba convergence loops, `timing_resume` resumes `__VdlySched` and the trigger schedulers.

Net effect: we cannot tap any TB-local or DUT-hierarchical counter/condition in this harness; only DUT-signal-change displays and (partially working) delays work. Hierarchical DUT taps (e.g. `dut.woz.drive_g[0].ctrl.parser_done`) were accepted by Verilator at compile time but have not been verified to fire — the WOZ parser state we most need (Q1) is exactly the class of signal that has proven unobservable.

**Ask:** (a) what is wrong with the main loop / time-advancement relative to the canonical Verilator 5 `--binary --timing` pattern (for comparison: the standard generated loop is essentially `while (!gotFinish) { time(nextTimeSlot()); eval(); }`); (b) what could make trigger conditions on top-level TB regs stop firing while DUT-signal triggers in the same process fire — any known Verilator 5.050 `--timing` interaction with `/* verilator public */` regs, multi-clock TBs, or our 2000-slot batch loop; (c) the fastest reliable way to get per-block WOZ-parser-state visibility in this harness (e.g. different main loop, `--trace` + external decode, a TB-side shadow parser fed from the transport boundary, public-memory exports, or something else).

---

## 4. How to reproduce

Build (MSYS2 UCRT64):

```sh
cd /e/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/pocket_boot
export PATH=/c/msys64/tmp/makeshim:/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp SHELL=/c/msys64/usr/bin/sh
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
bash build.sh        # Verilator 5.050 --cc --timing + make in obj_dir
g++ -O2 -o obj_dir/Vtb_pocket_boot.exe obj_dir/pocket_main.o \
    obj_dir/libVtb_pocket_boot.a obj_dir/libverilated.a obj_dir/Vtb_pocket_boot__ALL.a \
    -lSDL2 -lopengl32 -lgdi32 -limm32
```

Run (needs `rtl/roms/{apple2e,video2,keyboard}.hex` + `disk.woz` in the harness dir; C++ regenerates `pocket_boot.woz.hex`):

```sh
./obj_dir/Vtb_pocket_boot.exe --smoke --budget-ms 800     # ~15-20 min wall; reaches scan + OOR eject
./obj_dir/Vtb_pocket_boot.exe --smoke --budget-ms 70      # ~1 min; pre-mount phase only
```

Notes: host AV may kill freshly linked exes outside a short grace window — run immediately after linking. The harness must be run with CWD at the repo root-relative layout it was built with (ROM `$readmemh` paths).

## 5. File map

| File | Role |
|---|---|
| `src/fpga/core/woz/woz_floppy_controller.sv` | Pinned WOZ engine (byte-pinned from MiSTer; do not modify). Parser ~1370–1545, scan ~660–730, handshake ~400–470, mount-edge reset ~555–620. |
| `src/fpga/core/woz/disk_ii_woz.sv` | Drive wrappers; `ctrl` per drive in `generate ... drive_g`; one documented exception (NOTICE.md). |
| `src/fpga/core/woz/NOTICE.md` | Byte-pinning policy + the one allowed exception. |
| `src/fpga/core/apple2e/sdram_sector_fetch.v` | **Pocket-owned** machine-domain byte fetch service (timing fix this round; prime suspect A/D). |
| `src/fpga/core/apple2e/sdram_woz_transport.v` | Pocket-owned engine-facing byte streamer + fault latch. |
| `src/fpga/core/apple2e/woz_mount_ctl.v` | Pocket-owned lifecycle (mount/eject). |
| `src/fpga/core/apple2e/sdram_storage.v`, `disk_store.v`, `slot_fifo.v` | Host store path (all TB-verified). |
| `src/fpga/core/apple2e/apf_stream_video_top.v` | Top; instantiation/clock wiring (engine+transport on `clk_core_14318`). |
| `verilog/pocket_boot/tb_pocket_boot.sv`, `pocket_main.cpp`, `build.sh` | The harness (Q2). |
| `verilog/pocket_boot/run_boot3s.log`, `run_70.log` | Evidence logs. |
| `verilog/tb/tb_dram_model.sv`, `verilog/stubs/altera_pll_sim.v` | TB-only SDRAM model (relaxed to M0-proven controller timing) and SDRAM-PLL sim stub (133.12 MHz free-running pair, 0°/180°/90°). |
| `docs/VERILATOR_BOOT_HARNESS_2026-10-21.md` | Harness documentation (boot sequence, diagnostics, known limits). |

## 6. Constraints for the review

- The WOZ engine (`woz_floppy_controller.sv`) is **byte-pinned**; prefer Pocket-owned fixes (`sdram_woz_transport.v`, `woz_mount_ctl.v`, `sdram_sector_fetch.v`, or a thin Pocket wrapper). A second `disk_ii_woz.sv`-style exception is possible but must be justified.
- The SDRAM controller (`io_sdram_pocket`) is M0 hardware-proven — do not change its timing; TB relaxations are allowed where the TB was stricter than hardware.
- Keep the change surface minimal; STA is green and the current RBF is flashable — any RTL change must re-verify the fetcher/storage TB ladder before another compile.
- Simulation speed is ~0.9 ms machine-time per wall-second; debug budgets should stay ≤ ~1 s machine-time (~20 min wall).
- Q2 fixes are simulation-infrastructure only (TB/harness/stubs) — no production RTL.

## 7. What a good answer looks like

- **Q1:** a verdict on the mis-parse mechanism (with the specific line/signal responsible, or the next single experiment that would prove it — e.g. "compare `sector_byte_data` against expected file byte at `sd_buff_addr` for the first 20 bytes of the first two sectors, here's the tap"), plus a recommended EOF/OOR/eject fix with the tradeoffs of options 1–3 in §2.3.
- **Q2:** a diagnosis of the main-loop/time-advance interaction (what the canonical `--timing` loop does differently) and a concrete reliable instrumentation path for the parser state.

Anything else the reviewer wants to see (more logs, more code, a smaller repro harness) — the harness is fast to rebuild once a specific signal tap is known to work.
