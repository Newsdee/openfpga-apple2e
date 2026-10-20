# M1 Expert Design Brief — WOZ floppy machine fetcher (Pocket)

Date: 2026-10-20
Repo: `apple2e-pocket` (branch `main`)
Companion to: `docs/PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` (M0, committed `44c2144`)
Format: self-contained; implement from your answers, as with the M0 auto-verify brief.

## 0. The ask

M0 (host → SDRAM image storage + hardware CRC verify + reset persistence +
status overlay) is **hardware-accepted** (photos: `OK CRC=5505C782`,
`N=00039400`, `R=C=0000E600`, corner `M06O`, reset re-arm, diskless `NO FILE`
boot).

M1 makes the machine actually use the image: **the Apple IIe boots DOS 3.3
from the SDRAM-resident `.woz`** — `]` prompt at the DOS command shell,
`CATALOG` lists the master. (Today the machine falls into ROM Integer BASIC,
which has no disk — hence `CATALOG` → `SYNTAX ERROR`.)

Key finding that shapes the design: **the active MiSTer project
(`Apple-II_MiSTer`, branch `woz-disk-support`) already contains a complete,
hardware-proven WOZ floppy engine** in `rtl/woz/` that replaced
`disk_ii.v`/`drive_ii.v`/`floppy_track.sv` (commit `7e7e13d`, plus `170dd2d`
for drive sound). The M1 design is therefore a **port of that proven engine
into the Pocket core**, with exactly one Pocket-specific new component: an
SDRAM-backed byte-transport shim replacing MiSTer's host SD bridge.

Please review the proposed architecture (§3) and answer Q1–Q11 (§4). I will
implement from your answers and run the acceptance ladder (§5).

## 1. Verified facts

### 1.1 The MiSTer WOZ engine (source of the port)

Files, all under `Apple-II_MiSTer/rtl/`:

| File | Lines | Role |
|---|---|---|
| `woz/disk_ii_woz.sv` | 486 | Disk II slot controller: 6502 interface ($C0E0–$C0EF device, $C600–$C6FF switches), two-drive status (ACTIVE/MOTOR_ON/STEP/TRACK0/IO), wraps the controller + drive model |
| `woz/woz_floppy_controller.sv` | 1552 | Streaming WOZ parser (header + INFO/TMAP/TRKS chunks), track-on-demand loader into BRAM, bit/flux readout, save/dirty path, SD byte transport |
| `woz/flux_drive.v` | — | Flux-timing drive model |
| `woz/woz_bram.sv` | 61 | Dual-port BRAM wrapper (track storage) |
| `woz/woz_cell525.sv` | 141 | 5.25" cell/timing model |
| `woz/disk_ii_rom.v` | — | Disk II slot ROM (with `roms/diskii.hex`) |

`apple2_top.v:697–740` shows the proven instantiation (quoted in §3.3).
History: `7e7e13d "Apple II: add WOZ floppy support (rtl/woz engine,
replaces disk_ii/drive_ii/floppy_track)"`, `170dd2d "Floppy drive sound
restored for WOZ implementation"`.

Note: the workspace `AGENTS.md` description of `rtl/disk_ii.v` /
`rtl/drive_ii.v` / `rtl/floppy_track.sv` as the active floppy path is stale
for this branch — `rtl/woz/` replaced them.

### 1.2 `disk_ii_woz` interface (verified, `woz/disk_ii_woz.sv:24–67`)

```
input  CLK_14M, RESET,            // Apple RESET: switches + sequencer only
       DD_RESET,                  // cold/OSD reset: drives + track engines
       PHASE_ZERO,                // PHI0 level, 1 MHz
       IO_SELECT,                 // $C600-$C6FF
       DEVICE_SELECT,             // $C0E0-$C0EF
       WE,                        // CPU write cycle
       [15:0] A, [7:0] D_IN,
output [7:0] D_OUT,
output D1_ACTIVE, D2_ACTIVE,      // motor incl. 1 s holdover
       D1_MOTOR_ON, D2_MOTOR_ON,  // immediate motor cmd (sound tap)
       D1_STEP, D2_STEP, D1_TRACK0, D2_TRACK0, D1_IO, D2_IO,
input  D1_WP, D2_WP,              // write-protect overrides
output [31:0] SD_LBA0, SD_RD0, SD_WR0, input SD_ACK0, output [7:0] SD_BUFF_DIN0,
       (same for drive 1),
input  [8:0] SD_BUFF_ADDR, [7:0] SD_BUFF_DOUT, input SD_BUFF_WR,
input  IMG_MOUNTED0, IMG_MOUNTED1, IMG_READONLY, [63:0] IMG_SIZE
```

No IRQ output — the real Disk II is polled, so no interrupt wiring exists
or is needed.

### 1.3 Machine core (`machine/apple2.v`, byte-identical in both repos)

Already exposes everything the port needs — **no `machine/` changes at all**:

```
input  CLK_14M;  output PHASE_ZERO;  // + PHASE_ZERO_R/_F
input  reset, cpu, STALL;
output [15:0] ADDR, [7:0] D;  input [7:0] PD;  output CPU_WE;
output [7:0] IO_SELECT, DEVICE_SELECT;
```

Pocket top today (`apf_stream_video_top.v` apple2 instance, ~line 620):
`.PHASE_ZERO(m_pz)`, `.PD(8'h00)`, `.CPU_WE()` (unconnected),
`.IO_SELECT(m_io_sel)`, `.DEVICE_SELECT(m_dev_sel)`. So the top-level diff is:
add `disk_ii_woz` + the shim, drive `.PD(DISK_DO)`, connect `CPU_WE`.

### 1.4 WOZ file format support (verified against engine source AND a real file)

The engine parses the **modern streaming WOZ** (not the 1997
`WOS0`/`WOZ2` fixed-header layout):

- `woz_floppy_controller.sv:353–356`: *"WOZ header is 12 bytes: 4 bytes
  signature ("WOZ1"/"WOZ2"), 4 bytes 0xFF 0x0A 0x0D 0x0A, 4 bytes CRC32"*
- Chunk-based: `S_SCAN_WOZ` (line 271) scans and caches INFO/TMAP/TRKS;
  8-byte chunk headers; `SCAN_BLOCK_LIMIT = 16000` (~8 MB safety, line 381);
  WOZ2 `bit_timing` byte at INFO offset 39 (line 1426); v1 raw fallback
  (`v1_raw_addr`, line 1520); FLUX tracks supported
  (`is_flux_track`, `flux_data_size`, `flux_total_ticks`).
- Real file check: `sd_root/Assets/apple2e/common/disk.woz` (the repo test
  fixture, an Applesauce v1.1 export) first 32 bytes:

```
57 4f 5a 32  | ff 0a 0d 0a  | 66 80 66 6c  | 49 4e 46 4f  | 3c 00 00 00 | 02 01 01 00
"WOZ2"       | 0xFF 0A 0D 0A | CRC32 (LE)  | "INFO"       | len=0x3C   | version 2.1.1.0
```

i.e. the fixture header matches the engine's expected format exactly,
followed by an INFO chunk naming "Applesauce v1.1". The same bytes are in
`DOSMaster.woz` (byte-identical to `disk.woz`, CRC32 `74EA1324`, 234,496 B)
— this is the in-repo sim golden (Q11). The image the owner booted on the
card (DOS 3.3 master, 234,496 B, CRC32 `5505C782`) is a *different* DOS 3.3
master; hardware acceptance uses whichever `disk.woz` the card carries —
the decode path is image-independent.

Raw inventory of `DOSMaster.woz` (header verified; chunk fields as
labeled by position, NOT yet interpreted — the TRKS record layout is
derived from the engine's parser source, Q4/Q11):

```
234,496 B total; 12-B header verified (§1.4)
@12   "INFO" len=60      (INFO data contains version/tool fields;
                         the "Applesauce v1.1" string sits in this region)
@80   "TMAP" len=160     (track map: 160 B; per-track entries like
                         `ff NN NN NN` observed — see Q4 for the encoding)
@248  "TRKS" len=234,240 (track/sector records; first records show a
                         repeating 16-B pattern: 2B offset (stride 13),
                         2B 0x000D, 4B 0x0000C480, 4B 0x00000000 —
                         uninterpreted)
final offset = end of file (no trailing data)
```

### 1.5 SD byte-transport contract (what the shim must implement)

From `woz_floppy_controller.sv`:

- Request/ack handshake (lines 407–433): the engine asserts `sd_rd` or
  `sd_wr` with `sd_lba` (32-bit file offset) while `sd_ack == 0`; the
  transport pulses `sd_ack` while a transfer is in flight; rising
  `sd_ack` after a request = transfer started; falling = complete. The
  engine edge-protects with `transfer_active` (its own logic — the shim
  just has to behave like the MiSTer host bridge: `sd_ack` high during the
  multi-byte transfer).
- Byte delivery: data streams byte-wise through the shared 1-byte buffer —
  `sd_buff_dout` (transport → engine) and `sd_buff_din` (engine →
  transport), `sd_buff_wr` strobes byte writes into the transport buffer.
  `sd_buff_addr[8:0]` is the **byte index within the current 512-byte
  block** (the transport's counter, consumed by the engine for BRAM
  addressing: `save_bram_addr = {blocks_processed[...], sd_buff_addr}`,
  line 145; also used by the scanner, lines 1471/1474/1520).
- Transfers are 512-byte blocks (`blocks_processed` 16-bit, line 402).

### 1.6 Scan/mount lifecycle (verified)

- `S_DETECT` (line ~660): on `img_mounted && !scan_failed` → `S_SCAN_WOZ`,
  `sd_lba <= 0`, scan from file start.
- `ready` (line 540/543): `woz_valid && state == S_IDLE && current track
  matches` — tracks load on demand from `S_IDLE` on `track_id` change
  (line ~1128 → `S_READ_TRACK`), byte-streamed into BRAM.
- `disk_mounted = img_mounted && !scan_failed` (line 331) — stays high
  through seeks; `busy` covers load/save.

### 1.7 M0 infrastructure available (commit `44c2144`)

- `io_sdram_pocket.v` — basicassets `io_sdram` Pocket variant (4-signal
  diff; byte-identical reference `io_sdram.v` in-tree + regeneration
  script `tools/_build_io_sdram_pocket.py`), 74 MHz, word port,
  **owner-priority arbitration**, 180° SDRAM phase (`apple2e_sdram_pll.v`).
- `slot_fifo.v` — dual-clock record FIFO, the only CDC boundary (bridge →
  74 MHz).
- `disk_store.v` — controller-domain image store (exact byte size, word
  commit counter).
- `disk_verifier.v` — hardware CRC32 readback, `timeout_override` test port.
- `sdram_storage.v` — coordinator: APF `0082`/`008F` metadata contract,
  exact-size auto-verify/load, per-load re-arm, guarded result latching.
  Machine-domain outputs: `res_valid_m`, `res_code_m` (0=OK, 1=FAIL,
  2=NOFILE), `res_crc_m`, `res_nbytes_m`, `stage_m`, `dbg_rc_m`, `dbg_fl_m`.
- Hard invariant (hardware-verified): **machine reset must not re-init
  SDRAM, reset the store/verifier, or re-stream the image** — the resident
  image survives; only display windows re-arm.

### 1.8 Clocks and resources

- Machine domain: `clk_core_14318` (14.31818 MHz) + `machine_reset` — the
  WOZ engine runs here (MiSTer gates `CLK_14M & machine_ce & ~cpu_stall`;
  Pocket has no stall/pause today, Q7).
- SDRAM domain: **133.12 MHz** (`apple2e_sdram_pll.v` outclk_0/1/2; 74.25 MHz
  is the Pocket bridge/reference clock, not the SDRAM clock). 180° SDRAM
  phase. Do not change the accepted clock/phase configuration.
- Device: Cyclone V `5CEBA4F23C8`. Baseline (owner fit, 2026-10-20
  12:37:03): **5,157/18,480 ALMs (28%), 4,422 registers, 154/308 RAM
  blocks**, all slacks positive (min 0.320 ns). The WOZ
  engine adds the controller (1552 lines), flux drive model, and the track
  BRAM (`woz_bram` — sizing per its instantiation in `disk_ii_woz.sv`,
  Q9).

## 2. What the Pocket does NOT have (vs MiSTer)

- No host SD bridge for the machine domain — MiSTer's `SD_*` transport is
  served by the MiSTer host file machinery; the Pocket equivalent is the
  M0 SDRAM resident image. **This is the only functional gap** — hence the
  shim (§3.2).
- No drive-status LED / floppy sound in the Pocket yet (MiSTer uses
  `D1_MOTOR_ON` taps + `floppy_sound.sv` / `drive_status_overlay.sv`).
  Defer to a later milestone (wire the taps, don't build them in M1).

## 3. Proposed architecture (review requested)

### 3.1 Copy the engine byte-identical

`Apple-II_MiSTer/rtl/woz/*.v{,hd}` → `apple2e-pocket/src/fpga/core/woz/`
(6 files) + `roms/diskii.hex` (verified word-for-word against the MiSTer
copy, as with `machine/`). Same philosophy as the `machine/` invariant and
the `io_sdram_pocket.v` precedent: byte-identical if possible; any mandated
change becomes a documented Pocket variant with a regeneration script.

### 3.2 New: `sdram_woz_transport.v` (machine domain) — the shim

Implements §1.5 exactly, backed by SDRAM:

- **Reads**: on `sd_rd` request (block start in `sd_lba`) → issue
  74 MHz word reads under the M0 owner-priority arbitration → stream the
  block's 512 bytes into `sd_buff_dout` with `sd_buff_wr`-style byte
  pacing, present `sd_buff_addr` = in-block index, hold `sd_ack` high for
  the transfer, deassert on completion.
- **Mount signals**: `IMG_MOUNTED0 = res_valid_m && res_code_m == 2'd0`,
  `IMG_SIZE = {32'd0, res_nbytes_m}` (extend width as needed),
  `IMG_READONLY = 1'b1`, `IMG_MOUNTED1 = 1'b0` (single drive, M0 contract).
- **Writes**: none expected while `IMG_READONLY = 1` (Q2); shim may treat
  `sd_wr` as a fault/log or minimal no-op per your ruling.

### 3.3 Top wiring (`apf_stream_video_top.v`)

Mirror `apple2_top.v:697–740`:

```
disk_ii_woz disk(
    .CLK_14M(clk_core_14318),          // Pocket: no stall gating (Q7)
    .RESET(machine_reset),             // Apple reset: switches + sequencer
    .DD_RESET(core-level reset),       // cold: drives + track engines
    .PHASE_ZERO(m_pz),
    .IO_SELECT(m_io_sel[6]),           // slot 6, as MiSTer
    .DEVICE_SELECT(m_dev_sel[6]),
    .CPU_WE(/* apple2 CPU_WE wire, currently unconnected */),
    .ADDR(ADDR from apple2), .D_IN(D from apple2),
    .D_OUT(→ apple2 .PD, replacing 8'h00),
    .D1_ACTIVE/.D2_ACTIVE/.D1_MOTOR_ON/... (status taps, Q10),
    .D1_WP(1'b0), .D2_WP(1'b0),
    .SD_LBA0/SD_RD0/.../SD_BUFF_*(→ shim), .SD_*1/(drive 2 unused, tied)
    .IMG_MOUNTED0/1, IMG_READONLY, IMG_SIZE (from M0 coordinator, §3.2)
)
```

`machine/` remains byte-identical — zero changes to `apple2.v`.

### 3.4 Reset semantics

- Machine reset → `RESET` (sequencer/switches re-init; per the port
  comment the drives/track engines are NOT reset by this). `img_mounted`
  stays high (M0 latches survive) → no re-scan required, or a cheap
  re-scan if the controller does reset (Q3).
- Core/power reset → `DD_RESET` (full engine re-init; image still resident
  in SDRAM — M0 invariant).

## 4. Questions (each answer drives an implementation decision)

**Q1 — Transport pacing.** Confirm the exact byte/block protocol the shim
must present: one `sd_rd` request = one 512-byte block; `sd_ack` high for
the whole block; per-byte `sd_buff_dout` update + `sd_buff_wr`? (I read the
handshake at :407–433 and BRAM addressing at :145 that way, but confirm,
and state the minimum cycle count per byte the engine tolerates.)

**Q2 — Write path under `IMG_READONLY=1`.** `img_readonly` is declared
(:40) but I find no other use of it inside `woz_floppy_controller.sv`; the
save states assert `sd_wr` at :758/:787/:875/:909/:1309. Confirm where
read-only actually gates (in `disk_ii_woz.sv`? the drive model?) and rule
on the shim's `sd_wr` behavior: no-op + debug flag, or implement 512-byte
buffered writes? (M1 scope is read-only boot — but I need certainty that a
6502 disk write cannot corrupt the resident image or hang the transport.)

**Q3 — Re-arm after machine reset.** Does `RESET` (Apple) clear
`woz_valid`/scan state (forcing a re-scan from offset 0 on the next
`img_mounted`), or only `DD_RESET`? Either is acceptable (image is
resident; a re-scan is cheap) — I need to know which, to set expectations
for boot-to-`ready` latency after reset.

**Q4 — Apple 5.25" track addressing.** With `IS_35_INCH=0`: confirm the
`track_id` encoding `disk_ii_woz` presents for an Apple II single-sided
DOS 3.3 disk (TMAP layout: how many tracks? quarter-track bits?), and the
failure mode on a TMAP/track miss (what the 6502 observes — ROM error
path? timeout?) so the sim golden can assert both success and error paths.

**Q5 — Arbitration priority.** M0's owner-priority port serves store
(load) and verifier today. Propose: (a) host load > (b) verifier > (c)
M1 fetcher; fetcher only issues when no load is in progress (gate on
`stage_m`/coordinator state). Confirm or correct — in particular, is it
safe/acceptable for the fetcher to run concurrently with the post-load
verifier pass (they're both reads; only the priority bit matters)?

**Q6 — `sd_buff_addr`/`sd_buff_wr` ownership.** In MiSTer these come from
the shared host buffer (multi-user). The Pocket shim is dedicated: confirm
the shim owns `sd_buff_addr` as its own in-block counter and `sd_buff_wr`
as the per-byte strobe into `sd_buff_dout`, with no other users' semantics
to honor.

**Q7 — Clock gating.** MiSTer gates the engine clock with
`machine_ce & ~cpu_stall` (save-state/OSD). Pocket has neither: tie
`STALL=0` and use ungated `clk_core_14318`. Confirm nothing in the engine
depends on the gating behavior (e.g., assumptions about time stopped).

**Q8 — ROM.** `disk_ii_rom.v` + `roms/diskii.hex` via the existing Pocket
`rom.v` helper pattern (`$readmemh` from Quartus CWD, as M0's ROMs):
confirm the hex path/widths match `rom.v`'s generics, and note any Verilator
runtime-copy requirement (mirroring the M0 `verilator/rtl/roms/` layout).

**Q9 — Resources.** Estimate the `woz_bram` footprint (depth × width per
its instantiation) and total ALM delta against the current 4,779 ALM /
~4,342 reg build on `5CEBA4F23C8`. Flag if the BRAM would exceed the
device's M10K budget or if the engine needs a parameter to shrink the
track window (single-drive, DOS 3.3 = 13×256 B sectors; a track-sized
window should be far smaller than a 3.5" high-density track).

**Q10 — Status/sound taps.** M1 ships `D1_ACTIVE`/`STEP`/`TRACK0`/`IO`/
`MOTOR_ON` as unconnected taps (or minimally into the existing status
overlay, e.g. a drive-activity glyph). Confirm the overlay hook is
optional-deferrable without affecting the engine (they are pure outputs).

**Q11 — Sim strategy.** Propose the TB ladder; my draft:
  (a) **unit**: `sdram_woz_transport` alone vs the `tb_dram_model` SDRAM
  model — byte-transport correctness incl. back-to-back blocks, partial
  file tail (234,496 B is not a multiple of 512 — 458.85 blocks; how does
  the engine read the final partial block? confirm shim behavior),
  `sd_ack` edge cases;
  (b) **integration**: `disk_ii_woz` + `woz_floppy_controller` + shim +
  DRAM model, fed `sd_root/Assets/apple2e/common/DOSMaster.woz` (in-repo
  DOS 3.3 master, CRC32 `74EA1324`, verified modern-WOZ header §1.4) —
  golden: header scan OK, `ready` after load,
  track-0 bitstream matches an independent Python reference decoder of the
  WOZ chunks (I'll write the decoder from the TRKS-parsing layout at
  :1390–1520, cross-checked with you), TMAP-miss error path;
  secondary image `Situation-Critical.woz` (181,562 B game disk, same
  WOZ2 format + trailing META chunk, known-good from MiSTer use) —
  scanner must walk past META, multi-track seek/load coverage;
  (c) **full machine**: `apple2` + engine boots DOS 3.3 (boot banner +
  `]` prompt visible in video output) — or defer (c) to hardware if you
  judge cycle-exactness risk in sim too high;
  (d) state which MiSTer-side golden comparisons (the controller's
  sim-vs-golden `dbg_load_*` hooks, line ~87–92) we should reuse.

## 5. Acceptance

**Sim (Verilator 5.050, per repo TB rules):** ladder per Q11 all PASS;
strict lint clean on the new files; storage TBs (`tb_bridge_storage`,
`tb_top_storage`, `tb_ovl_status`) still PASS (M0 regression).

**Hardware (owner compile of `apf_stream_video`):**
1. Boot with `disk.woz` (DOS 3.3 master) on the card → DOS 3.3 command
   shell `]` (not Integer BASIC); `CATALOG` lists master + disk contents.
2. M0 overlay still correct: `OK CRC=…` / `N=…` / `R=C=…` window, corner
   marker; machine reset → disk still mounted, reboot → still `]`
   (image survived; at worst a re-scan, Q3).
3. Diskless boot unchanged: `NO FILE`, Integer BASIC (regression).
4. Motor/step status taps behave plausibly (optional check, Q10).

## 6. Invariants (unchanged from M0)

- `machine/` byte-identical to `Apple-II_MiSTer/rtl` (this port touches
  none of it — `apple2.v` is consumed as-is).
- `src/fpga/core/woz/` byte-identical to `Apple-II_MiSTer/rtl/woz` unless
  you mandate otherwise (then: documented Pocket variant + regen script).
- M0 behavior untouched: storage/verify/overlay/reset-persistence are
  additive-only dependencies; the fetcher is a new SDRAM reader under the
  existing arbitration.
- Quartus Q17 syntax rules; EOL discipline (new files LF, QSF CRLF);
  `build_id.mif` revert before commit; no unrelated cleanup.

## 7. Files for you to read

- `Apple-II_MiSTer/rtl/woz/` (all six files — the port source)
- `Apple-II_MiSTer/rtl/apple2_top.v:690–745` (proven instantiation)
- `apple2e-pocket/machine/apple2.v` (machine bus, lines 11–125)
- `apple2e-pocket/src/fpga/core/apple2e/{apf_stream_video_top.v, sdram_storage.v, io_sdram_pocket.v, slot_fifo.v, disk_store.v, disk_verifier.v}` (M0 context)
- `apple2e-pocket/docs/PLAN_FLOPPY_M0_STORAGE_REWORK_2026-10-19.md` (M0 record, incl. Unit 10)
