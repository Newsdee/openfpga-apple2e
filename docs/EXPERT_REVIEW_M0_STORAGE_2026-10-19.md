# Expert review request: Apple IIe Pocket core — Floppy M0 (external image storage), as built

Date: 2026-10-19
Repo: `apple2e-pocket` (Newsdee/openfpga-apple2e), branch `main`
Build under review: streaming-core Quartus project `src/fpga/apf_stream_video.qsf` (top `apf_top_stream`)

## 1. Context

This is an Apple IIe core for the Analogue Pocket (openFPGA/APF), Cyclone V 5CEBA4F23C8,
Quartus Prime Lite 17.0.2. The machine (6502, video, OSK) is complete and
hardware-verified. Floppy support is being added in a milestone ladder:

- **M0 (this review)**: external image storage — the Pocket's 64 MB mobile SDRAM,
  core-owned, loaded from the host via an APF data slot (`.woz` file).
- M1: 512-byte sector transport (the WOZ `SD_LBA`/`SD_ACK` handshake)
- M2: byte-identical port of the proven MiSTer WOZ path (`Apple-II_MiSTer/rtl/woz/`)
- M3: machine wiring (Disk II at slot 6, boot, reload)
- M4: hardware disk boot

The WOZ file itself is parsed entirely in FPGA RTL (MiSTer's `woz_floppy_controller`
does all WOZ parsing; no host-side conversion exists on the Pocket, which is why
`.woz` is the format). M0's job is only: **get the file bytes from the host into
SDRAM, and prove they are there exactly**. The machine does not touch them yet.

## 2. Platform facts

- APF bridge at `0xF8000000`; `clk_74a` = 74.25 MHz (host/main clock).
  `bridge_wr` is a one-cycle pulse per host 32-bit store (direct PMP wiring,
  **no FIFO between host and core** in the template).
- Data slots: host loads an SD file into the core's address space at boot.
  `data.json` gives each slot an `address` (32-bit bridge load address),
  `size_exact`/`size_maximum`, `required`, `extensions`, `parameters`.
  The host also writes a size table at bridge `0xF8002000` (word N at +4N:
  slot id, size in bytes) so the core learns the exact byte count.
- Onboard SDRAM: AS4C32M16MSA-6BIN, 64 MB, 16-bit, CAS3 @ 166 MHz max.
- Machine clock 14.318 MHz (PLL `mp1`); video 12.288 MHz + 90° (same PLL);
  audio 3.072 MHz. `mp1` had all its useful outputs in use, hence a second PLL.
- Device: 3-4 PLLs total; 1 used before M0.

## 3. What M0 implements

The core implements its own SDRAM controller (the bridge read mux serves host
reads, not core-side memory clients — this was corrected by the expert in the
earlier floppy design review). Controller choice: **basicassets `io_sdram.v`**
(open-fpga `core-example-basicassets` @ `e5f9c0a`, pinned byte-identical copy in
`refs/basicassets/`, sha-verified; 572 lines; fit- and hardware-verified in the
reference on this exact device/chip).

Files:

| File | Change |
|---|---|
| `src/fpga/core/apple2e/io_sdram.v` | new, byte-identical to reference |
| `src/fpga/core/apple2e/apple2e_sdram_pll.v` | new — 2nd `altera_pll`, refclk `clk_74a`, 3× 133.12 MHz |
| `src/fpga/core/apple2e/apf_stream_video_top.v` | modified — tie-offs removed, bridge decode, 2 new instances |
| `src/fpga/core/apple2e/apple2e_core_constraints.sdc` | modified — async groups for the new PLL |
| `src/fpga/apf_stream_video.qsf` | modified — 2 new `VERILOG_FILE` entries |
| `sd_root/Cores/Newsdee.Apple2eStreamVideo/data.json` | modified — new `disk` slot |

### 3a. PLL (exact grid-legal values copied from the reference's generated file)

```verilog
apple2e_sdram_pll mp2 (
    .refclk   ( clk_74a ),
    .rst      ( pll_rst_pulse ),
    .outclk_0 ( sdram_ctrl_clk ),    // 133.119993 MHz, 0 ps     -> io_sdram controller_clk
    .outclk_1 ( sdram_chip_clk ),    // 133.119992 MHz, 6573 ps  -> io_sdram chip_clk
    .outclk_2 ( sdram_chip_clk_90 ), // 133.119990 MHz, 5634 ps  -> io_sdram clk_90
    .locked   ( sdram_pll_locked )   // currently unused
);
```

Note: `io_sdram` declares a `clk_90` port but **never uses it in its body**
(port list only, line 11). Quartus therefore pruned tap 2
(`Warning 14320: Synthesized away ... mp2|altera_pll|outclk_wire[2]`) — identical
to how `mp1`'s audio tap is pruned in every prior build of this core. The SDC
was updated to group only the two surviving taps.

### 3b. Top-level wiring (the part I actually wrote)

The old `dram_*` tie-offs were removed. Host-side load decode, `clk_74a` domain:

```verilog
reg         sdram_word_wr;
reg  [23:0] sdram_word_addr;
reg  [31:0] sdram_word_data;

always @(posedge clk_74a) begin
    if (bridge_wr && (bridge_addr[31:25] == 7'b0)) begin
        sdram_word_wr   <= 1'b1;
        sdram_word_addr <= bridge_addr[25:2];
        sdram_word_data <= bridge_wr_data;
    end else begin
        sdram_word_wr   <= 1'b0;
    end
end
```

This is the basicassets mapping (their `core_top.v` does the same decode for
both of their slots at addresses `0x0` and `0x400000`).

`io_sdram` instance: `phy_*` → the `dram_*` pads; `reset_n` tied `1'b1`
(reference behavior — "fsm has its own boot reset"; boot sequence
`ST_RESET → ST_BOOT_0..5` does the mode-register init with tISL wait); burst
ports unused/tied off; **word port** connected (host write above; `word_rd`
tied 0 for now — M1's 14.318-MHz machine-domain fetch uses the same port from
the other side; the port synchronizes cross-domain requests internally via
three `synch_3` stages).

### 3c. SDC

`set_clock_groups -asynchronous` with the existing 4 `mp1` divclk groups plus
`ic|mp2|altera_pll_i|general[0]` and `general[1]` divclk groups (the naming
pattern — internal `divclk` nets, not top-level wires — was verified against
the working `mp1` groups).

### 3d. data.json

```json
{
    "name": "disk",
    "id": 1,
    "required": true,
    "filename": "disk",
    "extensions": [ "woz" ],
    "address": "0x00000000",
    "size_maximum": 4194304,
    "parameters": 1
}
```

For comparison, basicassets' `data.json`: slot 1 at `0x00000000`
(`size_exact`, `parameters: 3`), slot 9 at `0x00400000` (`size_maximum:
0x3C00000`, `parameters: 3`) — both served by the same `bridge_addr[31:24]==
0x00xx` decode into `word_addr = bridge_addr[25:2]`.

## 4. Evidence so far

1. **Verilator lint** (`--lint-only`, full streaming top + machine + OSK +
   io_sdram + both PLLs + stubs): clean; only pre-existing-style `PINMISSING`
   warnings on optional `synch_3` ports.
2. **Quartus 17.0.2 full compile**: A&S / fitter / STA / assembler all
   **successful**. Deltas vs the previous (pcd) streaming build:
   - ALMs 3,330 → **3,533** (+203), registers 1,920 → **2,132** (+212)
   - M10K **unchanged** (152), PLLs **1 → 2**
   - New SDRAM domain worst setup **+1.683 ns** (slow 85C), hold +0.412,
     min-pulse +3.013; machine/video/audio timing unchanged.
   - STA confirms both SDRAM taps at 133.12 MHz (7.512 ns period), second with
     the 6.573 ns phase shift — the reference's grid values were accepted.
3. **Warnings**: one new — `Warning (21300): LOCKED port on the PLL is not
   properly connected` on `mp2` (Quartus suggests using LOCKED to gate the
   controller; basicassets likewise leaves it unused). All other fitter/STA
   warnings are the pre-existing set (template SDC line-7 leftovers, audio
   divider, cart pins, …).

## 5. Questions (my lean in each)

**Q1 — Load flow control / word loss (the main risk I can't verify from here).**
`bridge_wr` is a one-cycle pulse per host store with no FIFO; the host can pace
its stores however it likes. `io_sdram` catches `word_wr` through a 3-stage
synchronizer into a **single-bit queue**: if a second write pulse arrives while
the FSM is mid-write *and* the queue bit is already set, the second word is
dropped silently. The write engine does ~7–10 controller cycles per word
(≈55–75 ns ≈ 53–73 MB/s sustained). basicassets does exactly this and its slot
loads (up to 60 MB audio) work on real hardware, so the host loader rate is
*probably* sustainable — but I cannot measure the Pocket host's data-slot
write rate from RTL.
(a) Is the loss window real at Pocket host-loader rates, or is the host
    naturally paced below ~1 word/75 ns?
(b) If it can be tight: is a 1-bit → N-bit queue (a few ALMs) in the top-level
    decode the right fix, or is there a platform-sanctioned slower-load mode?
My lean: accept reference behavior for M0, let the sim checksum TB be the
proof, fix only if it shows loss.

**Q2 — M0 hardware proof strategy.** The core cannot report a checksum back
(no debug path exists yet; the machine doesn't read the image in M0).
Options: (a) hardware M0 = "core loads with the slot present + machine boots
exactly as before" and the *integrity* proof lives entirely in the Verilator
TB (word-port readback + checksum); (b) add a minimal readback/echo now;
(c) something platform-standard I'm missing (e.g. a way for the host to verify
SDRAM contents — the bridge read mux serves host reads at 0xF8xxxxxx only;
reading back SDRAM words via the bridge would need a new read-decode entry).
My lean: (a), with (c)-style readback deferred to M1 where the fetcher exists.

**Q3 — `required: true` before any `.woz` exists.** The slot is required, so
the core will not load at all without a `.woz` file. For the first hardware
regression (machine boots as before, SDRAM tree inert), I plan to supply a
real `.woz` file (content validity is irrelevant in M0 — the parser runs in M2).
Alternative: ship this RBF with `required: false` and flip later.
My lean: keep `required: true` + ship a test `.woz` (avoids a second build and
matches the end state).

**Q4 — data.json details.** `size_maximum: 4194304` (4 MB; real WOZ images run
~130–1400 KB), `parameters: 1` (bit 0 = user-reloadable only; basicassets uses
3), `id: 1`, `address: 0x00000000`. Confirm.

**Q5 — PLL LOCKED warning (21300).** Accept as-is (reference parity; io_sdram
has its own boot FSM), or wire `locked` (synchronized) into `io_sdram`'s
`reset_n` — which deviates from the reference but satisfies the warning and is
arguably more correct (hold the controller in reset until clocks are valid)?
My lean: accept as-is for M0; revisit in M1 if the boot-order interaction
matters (it shouldn't — the controller's init sequence only needs valid
`controller_clk`/`chip_clk`, which exist as soon as the PLL is up… but the
`locked` signal would make that explicit).

**Q6 — Testbench design (the go-gate).** Plan: Verilator `--binary --timing`
TB (this repo's toolchain: Verilator 5.050, Verilog-2001, MSYS2 UCRT64),
with a **behavioral mobile-SDRAM model** (mode-register init, ACT/READ/WRITE
with tRCD/tCAS/tWR/tRP/tRC enforced, auto-refresh with tRFC, single row
buffer) + ideal clocks for the three domains (74.25 writer, 133.12
controller/chip, 14.318 reader). Tests:
  1. unit: `io_sdram` alone — init completes, single word write/readback,
     back-to-back writes, machine-domain read while host writes (CDC),
     unaligned end, read beyond loaded size (returns *something* — M1's
     fetcher will bound by the 0x2000 size table, not the SDRAM);
  2. full-top: `stream_video_core_top` with bridge-driven host writes +
     machine-domain readback, **one exact 512-byte sector** (the M1 transport
     pattern: 13×4B words… i.e. 512 bytes = 128 words at `word_addr` =
     LBA×128), byte-exact compare + checksum.
Questions: (a) is that DRAM-model fidelity enough to trust a pass, or must I
model row-buffer/bank behavior more deeply? (b) full-top TB in one shot, or
unit TB first then top? (c) the "one exact 512-byte sector" — should it
also exercise the M1 fetch protocol (LBA latch while ACK low, raise ACK,
ordered bytes, drop) with a *stub* of `woz_floppy_controller`, or is M0's gate
purely storage (write block N, read it back) with the protocol landing in M1's
own TB? My lean: storage-only for the M0 gate; the 512-byte transaction is
"host writes the block, machine-domain reads it back byte-exact" — the SD_ACK
handshake is M1's concern.

**Q7 — Address space.** SDRAM window at bridge `0x00xxxxxx` (32 MB reachable
via `word_addr[23:0]`), matching basicassets. The bridge command block is
`0xF8xxxxxx`; the NES reference uses `0x40000000` for savestate. Any platform
convention I should know that reserves `0x00xxxxxx` or the low 32 MB of bridge
space (e.g. future save-state, other cores' expectations, host-side tooling)?

## 6. Explicitly out of scope for M0

- Machine floppy wiring, Disk II slot 6, boot (M2/M3)
- The 512-byte fetcher and SD_ACK handshake (M1)
- Drive 2, 3.5", `.nib`/`.do` (single-drive WOZ only)
- Savestates (later milestone; design constraint: all disk state RAM-capturable)
- WOZ file validation (the MiSTer parser does not validate signatures/CRC —
  bounding + checksumming is transport's job, landed in M1/M2)
- SDRAM error handling (no ECC/scrub; the chip is new and the reference runs
  it the same way)

## 7. Requested

Verdict + corrections in the style of `FLOPPY_WOZ_RECOMMENDATION_2026-10-19.md`
(accepted direction with blocking corrections). Flag anything that must change
**before** I build the testbench, and anything that can wait for M1.


---

## Review outcome (2026-10-19)

Expert response: `M0_STORAGE_REVIEW_HANDOVER_2026-10-19.md`.
**Verdict accepted: direction stands, M0 is NOT yet verified.** All four
blocking findings were re-verified against the source (the expert read RTL
only; we confirmed each at line level):

1. **Confirmed** — `io_sdram.v`: `ST_IDLE` latches raw `word_addr` (lines
   309/317), `ST_WRITE_2`/`ST_WRITE_3` sample raw `word_data` two cycles apart
   (lines ~361/372 — upper/lower halfwords can come from different host
   words), synchronized `word_addr_s`/`word_data_s` (synch_3 s4/s5) are
   unused in the write path, request retention is single-bit, and
   `word_busy` is assigned zero only (line 300, never asserted).
2. **Confirmed** — top reports readiness from the machine PLL alone
   (`status_boot_done`/`status_setup_done = pll_core_locked_s`), accepts
   slot writes unconditionally (`dataslot_requestwrite_ack/ok = 1`), ties
   `io_sdram.reset_n` high; the controller's ~30,000-clock boot wait has no
   ready/completion handshake.
3. **Confirmed** — our SDC put the two related SDRAM taps in async groups
   with no memory-bus constraints; the reference's own SDC
   (`refs/basicassets/src/fpga/core/core_constraints.sdc`) carries exactly
   the pattern we omitted (input/output delays vs `dram_clk`, multicycle
   controller→chip path, at the identical 133.12 MHz clocks).
4. **Accepted** — no observable storage result in hardware; readback
   belongs in M0.

Accepted answers/corrections (applied to the M0 plan, see
`PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md`):

- **Q1**: reject "probably slow enough"; measure the full
  request-to-completion interval; the fix is a record FIFO with latched
  payload, not a wider request counter.
- **Q2**: minimal hardware readback now — verifier computing a CRC over
  bytes read back from SDRAM, plus initialized/load/drained/verified
  flags, loaded byte count, received/committed word counts,
  overflow/timeout flags. Result made observable (bridge debug read +
  temporary on-screen diagnostic; photo-capable for the owner).
- **Q3**: ship the regression RBF with `required: false` (manifest-only,
  no recompile); the acceptance test loads a known local fixture (owned /
  storage-test WOZ — not someone else's disk image).
- **Q4**: keep id 1 / base 0 / 4 MiB cap; `parameters: 1` stays for now
  (reloadable is a real capability to expose only once the reload
  lifecycle is safe; 0x49 policy deferred).
- **Q5**: deliberate power/lock reset + wait for SDRAM init; do NOT tie
  memory re-init to machine reset (resident image must survive it);
  no boot deadlock waiting on host Reset Exit.
- **Q6**: unit TB first (multi-bank DRAM model — a single global open-row
  model is insufficient), then integrated storage, then hardware.
  512 bytes = **128** 32-bit words. The full top needs a real
  verifier/client before any full-top readback claim.
- **Q7**: our decode `[31:25]==0` is a 16 MiB bridge window → 32 MiB of
  SDRAM; the reference's `[31:24]==000000xx` is 32 MiB → full 64 MiB.
  Adopt the reference mapping explicitly and reserve the window.

Consequence: M0 is re-scoped from "wiring + lint + compile" to the expert's
recommended transaction architecture (record FIFO → controller-domain
transaction owner → latched payload → explicit done/read-valid → SDRAM →
hardware verifier). The pinned `refs/basicassets/` copy stays immutable;
controller modifications live in a Pocket-local `io_sdram` variant with a
documented minimal diff (done/read-valid signals).
