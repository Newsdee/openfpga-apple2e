# Plan — M1 WOZ floppy machine fetcher (implementation plan from expert recommendation)

Date: 2026-10-20
Expert input: `docs/M1_WOZ_FETCHER_RECOMMENDATION_2026-10-20.md` (answers Q1–Q11
+ storage-ownership/media-lifecycle prerequisites + acceptance ladder)
Design brief: `docs/EXPERT_DESIGN_M1_WOZ_FETCHER_2026-10-20.md`
Gate: M0 committed `44c2144` (hardware-accepted). M1 must preserve M0.

## Expert corrections to the brief (all verified against source 2026-10-20)

| # | Correction | Verified at |
|---|---|---|
| C1 | Disk slot ports are `WE`/`A` (map machine `CPU_WE`/`m_addr`) | `woz/disk_ii_woz.sv:29–33` |
| C2 | `SD_LBA` = 512-byte sector number; byte offset = LBA×512, word = LBA×128 | `woz_floppy_controller.sv:750` (`sd_lba <= {16'b0, trk_start_block_side0}`) + block-completion auto-increment (`:683`) |
| C3 | **D1_WP=D2_WP=1** required (parser ignores `img_readonly`; WP reaches the flux drive write gate) | `flux_drive.v:508,678` (`write_strobe_d1 <= ... && !WRITE_PROTECT && ...`) |
| C4 | `disk_ii_rom.v` initializes 256 B inline — no diskii.hex / ROM helper / sim ROM copy | `woz/disk_ii_rom.v:9` (`initial begin`) |
| C5 | DOS 3.3 = 16×256 B sectors per standard track (not 13); WOZ stores encoded bits/flux → do not size the track cache from decoded sector capacity | expert source inspection (accepted) |
| C6 | WOZ1/WOZ2 both chunk-based; WOZ2 TRKS descriptor = 8 B LE (start block u16, block count u16, bit count u32); `trks_index << 3`; TMAP = 160 B entries; my "16-byte repeating pattern" was not the descriptor size | `woz_floppy_controller.sv:1390–1520` (chunk scan, INFO layout), V1 path `:968–1036` |
| C7 | `]` prompt alone ≠ DOS loaded; CATALOG with expected entries is the acceptance condition | — (acceptance policy) |
| C8 | SDRAM domain is **133.12 MHz** (brief said 74 MHz); 74.25 MHz is the bridge/reference clock | `apple2e_sdram_pll.v:4–7` |
| C9 | D_OUT defaults to the data register outside ROM selection — blind OR into PD corrupts other slots | `disk_ii_woz.sv:484` (`D_OUT = IO_SELECT ? rom_dout : data_reg_vis`) |
| C10 | Wrapper latches `media_present` on mount rising edge; falling IMG_MOUNTED does **not** eject; DD_RESET re-pulse remounts old image; remount needs unmount-first to force re-parse | `disk_ii_woz.sv:190–215` |
| C11 | Fit baseline superseded: 5,157/18,480 ALMs (28%), 4,422 regs, 154/308 RAM blocks (owner compile 2026-10-20 12:37:03) | `output_files_apple2e/apf_stream_video.fit.summary` |
| C12 | `data.json` parameters `1` → **`0x49`** = bit0 reloadable + bit3 read-only + bit6 Reset Enter/Exit around reload (intentional UX change; approved by owner in this plan) | APF data.json parameter bitmap (skill ref) |

## Scope (per expert gate)

IN: engine port (6 files byte-identical), Pocket sector service, mount
lifecycle, boot policy, read-only operation, explicit fault reporting.
OUT (defer): floppy sound, drive-status overlay cosmetics, write-back,
alternate image conversion, track-cache optimization, pause/savestate.

## Invariants

- `machine/` byte-identical (no changes — `apple2.v` consumed as-is).
- `src/fpga/core/woz/` byte-identical to `Apple-II_MiSTer/rtl/woz/` (6 files);
  revision/hashes pinned in a note file; license notices preserved.
- M0 behavior preserved: store/verify/overlay/reset-persistence; storage
  TBs green; resident image survives machine reset.
- SDRAM clock/phase config unchanged (133.12 MHz / 180°).
- No `BRAM_ADDR_WIDTH` shrink (FLUX/encoded tracks can exceed decoded size).
- Quartus Q17 syntax; new files LF; QSF CRLF; `build_id.mif` revert before
  commit; no unrelated cleanup.

## Units

### Unit 1 — Digest (this doc)
Corrections C1–C12 verified against source (table above); brief updated
(133.12 MHz, fit baseline). Expert answers Q1–Q11 absorbed below.

### Unit 2 — SDRAM sector-ownership service (controller domain, 133.12 MHz)
Expert prerequisite items 1–4: the M0 `sdram_storage` `req_kind` mux is a
convention serializer, not a multi-client arbiter. New explicit ownership:
- **Owner latch**: each accepted request latches {address, op, write
  payload}; explicit grant; owner retained until completion; read data
  routed only to that owner; a higher-priority load must not change an
  in-flight read's address.
- **512 B scratch buffer** in controller domain; sector fetched whole, then
  buffer ownership handed to the machine-domain emitter (Unit 3) via a
  stable request/completion handshake — never independently synchronize a
  changing address/data bus; buffer held until emission finishes; one
  outstanding sector initially.
- **Bounds**: validate widened LBA×128 word offset against `res_nbytes_m`
  and the allocated image region before narrowing to the 24-bit word
  address; reject requests starting wholly beyond EOF; EOF tail = bytes
  below EOF + deterministic pad (never stale SDRAM); pad is not permission
  to accept truncated track/chunk structures (fault instead).
- **Word unpack order**: bits 31:24 first, then 23:16, 15:8, 7:0 (file
  order) — validate against the M0 store's write order.
- **Generation invalidation**: an accepted new slot load (0082) invalidates
  the mounted generation and cancels/retires outstanding reads before image
  memory is overwritten; late responses must not reach the new generation.
  If quiescing needs time, implement the APF request-write acceptance
  handshake rather than unconditional ACK.
- Verifier stays a client of the same ownership (no concurrent
  verifier/fetcher — serialize load → verify → mounted fetch; `stage_m`
  is a display summary, not a grant).
- TB (ladder stage 1): real SDRAM model; all 512 bytes compared;
  first/last byte, word endianness, consecutive sectors, delayed
  completion, EOF tails (synthetic partial file), overflow LBA, timeout,
  prohibited write (fault), reload/reset during outstanding request, no
  stale-generation completion. Nonzero exit on failure.

### Unit 3 — Machine-domain emitter `sdram_woz_transport.v` (14.318 MHz)
Q1 pacing contract, exact:
- One request transfers 512 bytes. Latch LBA while ACK low; request may
  register before ACK rises.
- Raise ACK **before** delivering byte 0; strobe addresses 0..511, at most
  one byte per machine rising edge; gaps with WR low allowed.
- Byte 511 must be sampled with ACK high; lower ACK on a later edge.
- Retire the request before accepting another.
- Drive-2: ACK low, mount inactive, output ports unconnected (not driven).
- `SD_WR` from the engine = **explicit invariant fault**: no SDRAM write,
  no fake successful ACK; latch a visible fault and cancel/unmount through
  the lifecycle controller (Unit 4); never hang, never ack a no-op.
- `DIN` (engine write-back output) unused for read-only service.
- TB: transport alone vs the Unit-2 service + DRAM model (handshake edge
  cases, fault injection via a forced-write engine stub).

### Unit 4 — Mount/lifecycle controller + `data.json` 0x49 + boot policy
- Mount events from the coordinator: load complete + drain + verify OK
  → publish stable size + **mount event** (rising edge into
  `disk_ii_woz.mounted_in`). Failed/no-file generations stay unmounted.
  M0 OK = completed readback (not proven CRC equality / valid WOZ — the
  engine's own scan validates the format).
- **Eject** = explicit zero-size mount event (C10: falling mount does not
  clear `media_present`). DD_RESET preserves media presence → remounts old
  image (accepted behavior; expert item).
- Fault (Unit 3 SD_WR fault or transport error) → cancel transaction +
  unmount + visible status (overlay/bridge diagnostic word).
- **Reset mapping**: `RESET` = machine reset (switches/sequencer only);
  `DD_RESET` = core-level reset (drive + parser; wrapper re-pulse re-parses).
  Machine reset stays separate from SDRAM init and load/verify state.
  Power loss / FPGA reconfig = not a retained-image guarantee (documented).
- **0x49 reload flow** (C12): host sends Reset Enter around reload → core
  reconfigures → SDRAM contents persist (SDRAM init must not re-run on core
  reset for the image region — verify M0 init trigger; if it does, gate it
  to power-on only) → host streams new file → Reset Exit. Hold Pocket-local
  disk/boot state until the new generation is usable; never reset SDRAM to
  achieve this. Do NOT gate APF pre-load setup readiness on verification
  (verification can't happen until loading is allowed).
- **Boot policy** (diskless): hide the slot-6 ROM when no usable image;
  advertise only once a loaded generation is usable. Hold initial
  boot/reload appropriately (parser/fetch clocks keep running while any CPU
  boot hold is asserted). Preserve today's diskless experience (BASIC
  prompt). Verify cold boot and manual reset key where supported.
- `data.json`: `"parameters": 1` → `0x49` (bit0+bit3+bit6).

### Unit 5 — Engine import + top wiring + integration TB
- **STATUS (2026-10-21): COMPLETE — `tb_woz_machine` ALL PASS (nfail=0).**
  6 engine files byte-identical in `src/fpga/core/woz/`; top wired; QSF
  registered; integration TB covers T0 (SDRAM init + coordinator OK),
  T1 (mount + engine SD_RD + transport ACK), T2 (512 B verified through
  the data path, byte-exact vs golden `DOSMaster.woz` prefix), T2b
  (malformed image → OOR fault → eject), T3 (remount + machine-reset
  persistence + engine re-scan), T4 (new-generation 16 KiB reload).
  Key fixes found during bring-up:
  * Transport must NOT abort S_DATA/S_HOLD on `!sd_rd` — the engine
    legitimately drops `sd_rd` ~2 cycles after the ACK rises during its
    live WOZ scan; aborting truncated every block to ~2 bytes and broke
    the header scan. Abort only on `!drive_active` (real eject).
  * Scoreboard compares against the LIVE engine LBA (stable per block),
    not a 1-cycle-stale latch (which produced one false mismatch/block).
  * Proactive unmount: `sdram_storage` now emits `new_load_m` (machine-
    domain pulse on generation change); `woz_mount_ctl` ejects the
    mounted drive when a new 0082 arrives, so the engine stops scanning
    the old image before the new load (previously it scanned the whole
    load, starving the store).
  * Store record FIFO deepened 64→256 (AW now derives from DEPTH) to
    absorb the start-of-load burst (SDRAM write op is slower than the
    host write rate while the store re-arms); `tb_top_storage` T7
    updated to a 512-word burst for the deeper FIFO.
  * `sdram_word_owner` attribution (current-edge model), `disk_store`
    level-held write, `sdram_sector_fetch` early-gen-invalidation +
    ST_HOLD self-release timeout, `io_sdram_pocket` edge-latch queue
    (POCKET-DIFF #5) — all verified by the unit TBs + machine TB.
- Copy 6 files byte-identical `Apple-II_MiSTer/rtl/woz/` →
  `src/fpga/core/woz/`; pin hashes in `src/fpga/core/woz/NOTICE.md` (or
  equivalent) with source revision; register all six in
  `apf_stream_video.qsf` + every sim file list.
- Top wiring (`apf_stream_video_top.v`):
  - `disk_ii_woz` with C1 port names: `.WE(m_cpu_we)`, `.A(m_addr)`,
    `.PHASE_ZERO(m_pz)`, `.RESET(machine_reset)`, `.DD_RESET(core reset)`,
    slot-6 selects, `D1_WP=1'b1`, `D2_WP=1'b1` (C3), STALL=0, ungated
    `clk_core_14318` (Q7), drive-2 per Q6.
  - **PD mux qualified by slot-6 selection** (C9): `PD = sel6 ? D_OUT :
    existing fallback` — never a blind OR.
  - Mount/lifecycle signals from Unit 4; fault word to the existing
    diagnostics path.
- Integration TB (ladder stage 2): unchanged engine + Pocket service vs
  direct-file service — identical sector responses; loaded-track bytes and
  bit counts compared using the existing `level_2b` host pattern
  (`Apple-II-Verilog_MiSTer/unit_tests/level_2b/l2b_disk_host.h`);
  independently parsed WOZ metadata + raw track bytes (Python reference
  decoder built from the C6 descriptor facts, cross-checked — not
  transcribed from the DUT); cover TMAP-FF (empty track), seeks,
  malformed/truncated input (fault + unmount, no fabricated data),
  remount, write protection (WP fault path), second image
  (`Situation-Critical.woz`, META-variant + multi-track).

### Unit 6 — Full-machine TB (ladder stage 3)
Real `apple2` + imported engine: slot-6 ROM entry, disk activity, a known
DOS-loaded RAM/execution milestone, then **CATALOG with expected
directory entries** (C7 — a prompt/nonblank frame is insufficient).
Diskless boot per Unit-4 policy; reset/reload flow.

### Unit 7 — Regression + owner compile + hardware (ladder stages 4–5)
- M0 regression: FIFO/store/bridge/verify/overlay TBs (incl. bounded
  failure cases); `machine/` and engine byte parity; strict lint; fatal
  tests nonzero-exit.
- Owner Quartus (single active project): source bindings, block-RAM
  inference check (track RAM 32,768×8 per drive + 2,048×8 metadata ≈
  32+2 M10K blocks/drive, ~68 for two drives + ROM/transport — budget, not
  a prediction), fit/timing deltas vs the 5,157-ALM/154-RAM baseline, new
  warnings, staged bitstream provenance (sha256).
- Hardware: DOS 3.3 CATALOG acceptance (owner's card `disk.woz`, CRC
  recorded per run), diskless boot, reset persistence, 0x49 reload
  (Interact → reset around reload → new generation usable).

## Ladder summary (expert, adopted)

1. Owner/sector unit tests (Unit 2)
2. WOZ integration vs direct-file golden (Unit 5)
3. Full machine → CATALOG (Unit 6)
4. M0 + parity regressions (Unit 7)
5. Owner Quartus + hardware (Unit 7)

Stop condition: reproducible read-only DOS boot, M0 preserved, explicit
failure reporting. No scope additions.

## Progress (updated 2026-10-20)

- **Unit 1 (QSF registration / storage base): done** — carried in M0 gate `44c2144`.
- **Unit 2 (SDRAM sector-ownership service): done, committed `9c6f852`** —
  `sdram_word_owner.v` (pure pass-through word-port ownership: arm-time
  attribution, done levels exact M0 1-FF shape, store writes masked while
  any read client is armed) + `sdram_sector_fetch.v` (per-word sector
  fetcher, ST_IDLE/WAIT/GAP/HOLD/FAULT; edge-based acceptance; generation
  invalidation). `tb_sector_fetch.sv` T0-T8 ALL PASS; M0 regression
  `tb_top_storage` PASS; strict Verilator lint clean on new files. Tooling
  notes recorded in the commit (Verilator 5.050 drops transitions for
  2-bit case items against a wider register; state localparams widened to
  4 bits; 1-bit `word_q` port truncation fixed).
- **Unit 3 (machine-domain emitter): done** (commit `2bc283c`) —
  `sdram_woz_transport.v` (14.318 MHz): latches LBA while ACK low, raises
  ACK before byte 0, mirrors `sd_buff_addr` into the Unit-2 frozen-window
  readout (zero-latency byte mirror), holds ACK through byte 511 sampling
  (`sd_buff_wr` at addr 511) and lowers it on a later edge; one outstanding
  sector; `sd_wr` from the engine = latched invariant fault (no write,
  no fake ACK, `fault_clr` restore); OOR LBA (high 16 bits) = latched
  `oor_fault`, no ACK; `drive_active` low = quiet. `tb_woz_transport.sv`
  T0-T6 ALL PASS (512-byte verified reads incl. tail sector 464+48 pad,
  gaps, write-fault + recovery, OOR, inactive drive).
- **Unit 4 (mount/lifecycle controller): done this session** —
  `woz_mount_ctl.v` (14.318 MHz, power-on-reset only via `~sdram_path_rst`):
  OK result -> mount (IMG_MOUNTED rise with IMG_SIZE); new generation or
  transport fault -> explicit zero-size eject (fall -> rise(0) -> fall),
  which is what clears the engine's HELD mount level (verified against
  disk_ii_woz.sv:205-232 + woz_floppy_controller.sv:325-331); remount with
  the new size forces a re-parse; FAIL/NOFILE stay unmounted; levels held
  across machine reset (engine self re-pulses via its own
  media_present/DD_RESET dance). `tb_woz_mount_ctl.sv` (DUT + cycle-
  accurate engine drive-level mount model) T1-T9 ALL PASS. `data.json`
  disk slot `parameters` 1 -> 73 (0x49: reloadable + read-only + Reset
  Enter/Exit around reload, per C12). QSF registered.
- Next: Unit 6 (full-machine CATALOG TB), Unit 7 (regression + owner
  compile + hardware). Unit 5 is complete (see its STATUS note).
