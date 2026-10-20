# EXPERT DESIGN BRIEF — Floppy (.woz, single drive) for the Apple IIe Pocket core

**Date:** 2026-10-19 · **Author:** Newsdee (with assistant) · **Status:** design request
**Repo:** `E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket` (github.com/Newsdee/openfpga-apple2e)
**Machine source of truth:** `E:\MiSTer\Apple-II_FPGAdev\Apple-II_MiSTer` (active MiSTer project)

You are reviewing/designing the floppy milestone for a working Apple IIe
Analogue Pocket (openFPGA/APF) core. The machine already boots, displays, and
has a working full-color on-screen keyboard (all hardware-verified). This
brief is self-contained: everything needed is stated here or referenced by
path. Where I have a recommendation, it is marked **(rec: …)** — I want your
independent judgment, including on whether to disagree.

## 1. Goal and hard constraints

- Add **floppy disk** support: **1 drive** (5.25"), **WOZ format only**, on the
  Pocket. The Apple IIe software (BASIC `BOOT`, ProDOS, DOS 3.3…) accesses the
  disk through the usual Disk II slot ($C000) — the IIe BIOS does **not**
  boot from floppy, so no BIOS/boot-ROM integration is needed.
- **No C++/host-side processing.** On MiSTer the Pocket's host C++ converts
  `.nib/.do/.img → .woz` at mount and serves file bytes. The Pocket has no
  such host: the FPGA must do all format work. This is why the format is
  settled on **.woz** — see §3: the active MiSTer project's working Woz
  floppy path already does the WOZ parsing **entirely in FPGA RTL**.
- Target device: Cyclone V `5CEBA4F23C8`, Quartus Prime **17.0.2 Lite**,
  APF framework (template v1.3.0). Machine clock domain: **14.318 MHz**
  (single `CLK_14M`); APF host/bridge domain: **74.25 MHz** (clk_74a); the two
  are asynchronous.
- The machine RTL in the Pocket repo (`machine/`) must stay **byte-identical**
  to `Apple-II_MiSTer/rtl` (enforced by `check_machine_sync.sh`). All
  Pocket-specific glue goes in the Pocket top-level files.
- Resource context (current Phase-2 streaming core fit): **3,330/18,480 ALMs
  (18%), 1,893 registers, 152/308 M10K blocks** — ~156 M10Ks and ~15k ALMs
  free. The working frame-buffer core has similar headroom.

## 2. How the Pocket loads files (facts)

From the APF docs/skill references (`references/json-files.md`,
`references/host-target-commands.md` in the analogue-pocket-dev skill):

- **Data slots** (data.json, ≤32): at boot the host loads each non-deferload
  slot's file from the SD card into the **bridge address space** (APF SDRAM,
  120 MB available to the core) at the slot's `address`. Boot order:
  host 0082 (write request) + data per slot in order → 008F (all complete) →
  core reports Ready-to-Run (0140) → interact writes → 0011 Reset Exit.
- **Slot ID/size table:** bridge `0xF8002000`, word N at `+4·N`: word0 = slot
  ID, word1 = file size in bytes (Pocket writes the loaded size; 0 = unused).
  **Gotcha (KB, hardware-observed 2026-09):** a bridge read/write using the
  wrong base address still returns result 0 while moving wrong data — always
  read back + checksum the first transfer of a new design.
- **Core → SDRAM reads** are a plain bridge read mux on `bridge_addr`
  (the NES reference core does exactly this for its ROM: `bridge_addr[31:28]
  == 4'h2 → sd_read_data`). Bridge reads may lag one strobe (legal) — muxes
  must tolerate late data.
- **`deferload` + target 0181/0185** (file stays on SD, core reads/writes
  over the bridge, framework ≥2.1) is the alternative model. Note the
  template bridge FSM does **not** implement 0181/0185/0188 (verified in
  source) — a core wanting them must add the target state machine itself.
- **data.json flags** relevant here: `required` (missing → file browser),
  `extensions` (browser filter), `address`, parameters bit0 =
  user-reloadable via Interact menu (runtime image swap), bit3 = read-only.
- Persistence: a plain read-only data slot needs **no** write-back
  (nonvolatile flush happens only for nonvolatile slots on quit).

**(rec: data-slot model)** The .woz file (~350–400 KB for a 140K disk) loads
into SDRAM at boot via a data slot — the same proven pattern as the NES ROM.
`deferload`+0181 would add a target command FSM the template lacks and buys
nothing (the file easily fits in SDRAM and is read intensively at track-load
time). Please sanity-check this.

## 3. The existing Woz RTL (the asset we port)

The active `Apple-II_MiSTer` project's floppy path is **WOZ-based** (the old
`disk_ii.v` nib-era controller is retired; `rtl/woz/` is the live path —
hardware-verified there, "DOS 3.3 .woz boots fine"). Files
(`Apple-II_MiSTer/rtl/woz/`):

| File | Role | Lines |
|---|---|---|
| `disk_ii_woz.sv` | Disk II slot controller ($C000/$C010 byte protocol, stepping, motor, 2-drive glue). Instantiates per drive: `flux_drive` + `woz_floppy_controller`; plus `woz_cell525` cell-timing LUT and `disk_ii_rom`. Header comment: *"Every disk image reaches this module as WOZ: Main_MiSTer converts .dsk/.do/… [to WOZ]"* — i.e., on MiSTer the **C++ does the non-WOZ→WOZ conversion**, the FPGA does the WOZ. | — |
| `woz_floppy_controller.sv` | **WOZ format parser, all in RTL**: scans header (12 B) + chunks, caches INFO/TMAP/TRKS; track load/save FSM over the SD block interface; track RAM. Params: `IS_35_INCH` (0 for Apple 5.25"), `BRAM_ADDR_WIDTH = 15` for 5.25" (32 KB). | — |
| `flux_drive.v` | Bit-level FM/flux engine (the Disk II "drive"). | 2001 |
| `woz_cell525.sv` | 5.25" bit-cell timing LUT (timing→cell counts). | small |
| `woz_bram.sv` | Dual-port RAM, **two independent clock ports** (`clock_a`, `clock_b`), inferred. | small |
| `disk_ii_rom.v` | Disk II controller ROM ($readmemh; hex staged like the other machine ROMs). | 268 |

**Host interface to be replaced** (MiSTer "SD block" hps_io channel, from
`rtl/apple2_top.v` + the woz controller ports):

```
per drive i (0/1):  SD_LBAi[31:0]  (out), SD_RDi, SD_WRi (out), SD_ACKi (in),
                    SD_BUFF_DINi[7:0] (out — core writing data to host buffer)
shared:             SD_BUFF_ADDR[8:0] (in), SD_BUFF_DOUT[7:0] (in),
                    SD_BUFF_WR (in)   // the ~256-byte buffer is host-owned
status:             IMG_MOUNTED0/1 (in), IMG_READONLY (in), IMG_SIZE[63:0] (in)
```

On MiSTer the C++ owns the 256-byte buffer and does file I/O; the core
requests bytes by LBA and receives them through that buffer. **On the Pocket
the FPGA must own the buffer** (256×8 — MLAB) and fill it from SDRAM.

Note the dual-clock `woz_bram` design intent: load-side (port A) and
flux-read side (port B) can run in different clock domains.

## 4. Proposed architecture (for review)

```
[SD card .woz] --(boot: host 0082)--> [APF SDRAM @ slot address]
                                          |  bridge reads (74.25 MHz)
                                          v
        woz_sd_bridge  (NEW, Pocket-only)  -- emulates the MiSTer SD-block
        contract: 256-B buffer RAM, SD_LBA/SD_RD/SD_ACK handshake,
        img_mounted/readonly/size sources; CDC 74.25 <-> 14.318
                                          |
        ┌────────────────────────────────┘
        v
   woz_floppy_controller (IS_35_INCH=0)   woz_sd_bridge clocking:
        (load FSM + WOZ parse)  --port A-->  (load side: 74.25 MHz domain)
        track_ram (32 KB, 5.25" single-sided) --port B-->
        flux_drive (14.318 MHz, machine domain)  [CDC only on control
        disk_ii_woz: $C000 protocol, stepping, motor]     signals]
        v
   Pocket top IO slot 6 (same wiring as Apple-II_MiSTer/rtl/apple2_top.v
   lines ~697-738: disk_ii_woz instance, IO_SELECT[6], DISK_DO -> data bus)
```

Key points:

1. **Port the woz files byte-identical** into the Pocket repo (e.g.
   `machine/woz/` or `src/fpga/core/apple2e/woz/` — your call; `machine/`
   would keep the byte-identity invariant meaningful, but `machine/` is
   currently a *copy of Apple-II_MiSTer/rtl* and `rtl/woz/` IS in that tree,
   so `machine/woz/` is the consistent choice), plus `disk_ii_rom` hex in
   `src/fpga/rtl/roms/`.
2. **`woz_sd_bridge` is the only new module.** It presents exactly the
   MiSTer SD-block contract, so the ported files are untouched. The load FSM
   runs in the 74.25 bridge domain (port A of the track RAM); flux_drive /
   disk_ii_woz stay in 14.318 (port B). Only a handful of control signals
   cross (track_id, track_load_complete, ready, busy, disk_mounted,
   track_data_valid…) — synchronizers/handshake per repo CDC rules.
3. **Read-only v1:** `IMG_READONLY=1`, `SD_WR` tied off (the controller's
   save FSM/bit_we unused); data slot non-flagged nonvolatile (no
   write-back). Write support = later milestone (bridge writes to SDRAM
   work — the save-state path proves it — plus an 0188-flush or quit-time
   strategy if we ever move to deferload; out of scope now).
4. **One drive:** wire drive 0 to the real controller; drive 1
   `IMG_MOUNTED1=0` ("no disk" — verify the controller leaves D2 in a
   sane not-ready state; the machine handles absent drive 2 like real HW).
5. **data.json** for the streaming core (and later the stable core):
   slot `disk`, id, `required: true`, `extensions: ["woz"]`,
   `address: 0x02000000` (or similar, away from existing regions),
   parameters = bit0 (user-reloadable, runtime swap via Interact menu)
   | bit3 (read-only). Core reads actual size from the 0x2000 table after
   008F.
6. **Which core first:** the **Phase-2 streaming core**
   (`apf_stream_video.qsf`, actively iterated) — the disk path is
   machine-domain and independent of the video path, so it should also land
   in the stable core later via the shared module.

## 5. Resource estimate (for confirmation)

- Track RAM 32 KB ×1 side (5.25") ≈ **4 M10K**; meta/chunk-cache RAM
  (2 KB) ≈ 1 M10K (may pack); 256-B SD buffer → MLAB; `disk_ii_rom` → MLAB/
  M10K. Total ≈ **5–6 of the 156 free M10Ks**.
- ALM: `flux_drive` (2001 lines, bit-level FM) + `woz_floppy_controller` +
  `disk_ii_woz` + `woz_cell525` + the bridge shim. Unknown until a fit —
  the streaming core has ~15k ALMs free, so even a generous 2–3k ALM delta
  is fine. **First hardware build should capture the ALM/M10K/STA delta
  explicitly** (per the project's resource-comparison rules).

## 6. Save states (out of scope, design constraint)

Pocket savestates ("Memories", host 00A0/00A4 + a state blob in SDRAM at a
core-declared addr/size; the NES reference core has working plumbing at
0x40000000) are a **later milestone** — but the floppy must be designed so
a future savestate engine can capture it by plain RAM copy: **all disk
state (track RAM, drive position, motor/ready state) must live in
registers/RAM, no state hidden elsewhere.** Read-only .woz keeps the blob
small (the image file is host-owned and unchanged; only the drive's small
RAM state joins the ~64 KB machine state).

## 7. Questions (numbered — answer each)

1. **Load model:** data slot (SDRAM-resident) vs `deferload`+0181 — confirm
   or refute my recommendation, given the template's missing 0181 FSM.
2. **SD-block contract details:** I have not traced the exact handshake in
   `woz_floppy_controller.sv` (per `SD_RD` pulse at `SD_LBA`, how many bytes
   arrive; is `SD_BUFF_ADDR` swept by the core or the host; is `SD_LBA` an
   absolute byte offset or block?). Please specify the contract precisely
   so `woz_sd_bridge` can be built against it, and flag any MiSTer-host
   assumptions (e.g., latency, backpressure) the shim must replicate.
3. **`img_size` sourcing:** read the 0x2000 table at setup (after 008F) vs
   trust data.json `size_exact`? Any reason to prefer one?
4. **Dual-domain split:** run the load/parse FSM at 74.25 (port A) and flux
   at 14.318 (port B) vs run the whole woz path at 14.318 with the bridge
   shim as pure CDC. Which has less risk, given `woz_bram`'s two clock
   inputs and the track RAM's read-during-load behavior?
5. **Read-only v1:** confirm the save FSM can be cleanly disabled with
   `IMG_READONLY=1`/`SD_WR=0` (no latches/hang states), or name the minimal
   tie-offs.
6. **Drive-1 absent:** confirm `IMG_MOUNTED1=0` behavior (D2 ready/busy
   states, motor, any C++-dependency).
7. **Byte-identical port vs q17 variants:** the OSK port needed generated
   Quartus-17 variants of canonical machine files. Do you expect any of the
   woz files to need the same (the old disk_ii/dpram ports hit similar
   issues), or do these port clean?
8. **Test ladder:** propose a concrete Verilator TB plan:
   (a) `woz_sd_bridge` unit TB (fake SDRAM, verify contract + CDC);
   (b) woz-path TB: synthesize a minimal valid .woz (or use a real small
       one) in SDRAM, drive `disk_ii_woz` reads through the $C000 protocol,
       verify sector bytes come out correct (and motor/step/ready
       behavior); (c) machine-level: 6502 + BIOS does `BOOT`-style track
       reads. Note Apple-II_MiSTer has `module_tests/` differential
       harnesses for the *old* disk_ii — check whether anything exists for
       the woz path we can reuse.
9. **UX:** is data-slot + Interact-reloadable the right image-swap story,
   or is there a better Pocket idiom we're missing?

## 8. References

- Pocket file loading: `references/json-files.md` (data.json §),
  `references/host-target-commands.md` (§0x2000 table, 0181 template gap,
  0082/008F boot order) — in the `analogue-pocket-dev` skill.
- NES ROM-from-SDRAM precedent: `refs/nes-pocket/core_top.v` (bridge read
  mux `bridge_addr[31:28]==4'h2 → sd_read_data`), pinned
  `agg23/openfpga-NES` @ `be5f130`.
- Woz RTL + top-level wiring: `Apple-II_MiSTer/rtl/woz/*.sv|v`,
  `Apple-II_MiSTer/rtl/apple2_top.v` (SD-block port list ~lines 219–256;
  `disk_ii_woz` instance ~697–738; `clk_14m_disk = CLK_14M & machine_ce &
  ~cpu_stall`).
- Pocket tops to modify: `apple2e-pocket/src/fpga/core/apple2e/
  apple2e_core_top.v` (machine IO bus already exposed: `m_io_sel`,
  `m_dev_sel`, `m_io_str` at the `apple2 d1` instance) and
  `apf_stream_video_top.v`.
- Current fits / staging / packaging conventions: this repo's
  `apple2e_build.bat`, `tools/rbf2rbf_r.py`, `sd_root/Cores/…`.

## Review outcome (2026-10-19)

Reviewed: `FLOPPY_WOZ_RECOMMENDATION_2026-10-19.md`. Architecture approved
with the recommendation's corrections (accepted: SDRAM is core-implemented
external storage, not an automatic service; 512-byte sector protocol;
single CLK_14M WOZ path; WP is the write gate; two drive engines; slot-6
$C600/$C0E0 wiring; parser does not validate files). Owner decisions:
basicassets `io_sdram.v` controller first, slot `required: true`, drive 2
unmounted. See `PLAN_FLOPPY_M0_STORAGE_2026-10-19.md` for the corrected
milestone plan (M0 storage → M1 transport → M2 WOZ path → M3 machine →
M4 hardware).
