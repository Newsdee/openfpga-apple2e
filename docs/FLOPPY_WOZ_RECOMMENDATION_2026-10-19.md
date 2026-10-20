# WOZ floppy: review and implementation handoff

Date: 2026-10-19  
Scope: review of [the design request](EXPERT_DESIGN_FLOPPY_WOZ_2026-10-19.md).
Source/documentation inspection only; no HDL edits, simulation, or Quartus run.

## Recommendation

Proceed with one mounted, read-only 5.25-inch WOZ image, loaded through an
ordinary APF data slot into **core-managed external image RAM**. Reuse the
existing WOZ controller unchanged, entirely in the machine clock domain.
Put CDC at the image-storage/block-service boundary, not inside the drive.
Integrate first in the known-good streaming build; preserve its video path.

**First milestone: prove image storage and readback, not disk boot.**
The current Pocket top ties SDRAM off. Adding only a block shim is not
enough to implement the proposed resident-image architecture.

## Blocking corrections to the design request

| Claim in request | Correction / consequence |
|---|---|
| Disk II uses the keyboard's `$C000/$C010` protocol | Slot 6 ROM is `$C600-$C6FF`; Disk II switches are `$C0E0-$C0EF`. Wire both slot-ROM and device-select paths into the peripheral read mux. Preserve unrelated I/O. |
| No boot-ROM integration is needed | The Disk II card's P5A ROM is essential. System firmware can enter the slot ROM; a successful BASIC prompt alone does not exercise floppy boot. Test cold boot and explicit slot-6 entry such as `PR#6` where supported. |
| APF automatically loads into 120 MB of SDRAM | A slot address is a **bridge destination decoded by the core**, not automatic RAM. Pocket has a physical 64 MiB SDRAM chip, but the core must implement its controller, initialization, refresh and arbitration. Other external RAM is separate. |
| Core reads SDRAM through the bridge read mux | That mux answers **host reads of core addresses**. A core-side memory client needs its own connection to the memory controller. |
| SD blocks/buffer are 256 bytes | The WOZ interface transfers **512-byte sectors**, with byte addresses 0-511. LBA is a sector index within the WOZ file. |
| Run parser at 74.25 MHz and flux engine at 14 MHz unchanged | The controller has one `clk`; both track-RAM ports use it. The disk wrapper clocks parser and drive from `CLK_14M`. Splitting this requires a real redesign, not just using the RAM's second clock pin. |
| `IMG_READONLY=1` disables writes | In the inspected parser, `img_readonly` is declared but unused. Set `D1_WP=1` and `D2_WP=1`; the flux engine gates writes using `WRITE_PROTECT`. Do not drive a controller's `SD_WR` output to zero. |
| 32 KiB track RAM costs four M10Ks | It contains 262,144 bits: at least 26 M10Ks by raw capacity, commonly 32 at 8-bit port geometry. The unmodified disk wrapper instantiates **two drive engines**. Do not assume the absent drive's RAM disappears before fitting. |
| The WOZ Disk II ROM needs a staged hex | The inspected `rtl/woz/disk_ii_rom.v` initializes its 256 bytes inline; it does not use `$readmemh`. Do not confuse it with the older nibble-controller ROM helper. |

The proposed 5-6-block total is invalid. Budget two track engines plus
metadata and transport storage conservatively; use actual synthesis/fit
results to determine pruning and memory packing. Do not promise an ALM cost
from source line counts. A whole WOZ image also will not fit comfortably in
the remaining on-chip memory; external storage is a separate dependency.

## Proposed architecture

```text
APF host loads WOZ through bridge writes (clk_74a)
    -> address decoder / bounded ingress / external-memory controller
    -> resident image storage
    -> 512-byte sector fetch + stable request/completion handshake
    -> dual-clock sector scratch RAM with exclusive ownership
    -> machine-clock sector emitter (ACK, ADDR, DOUT, WR)
    -> unchanged disk_ii_woz / woz_floppy_controller / flux_drive
    -> slot-6 ROM and switch response into apple2 peripheral PD bus
```

Reuse a proven Pocket memory controller if available and compatible; SDRAM
is a sensible NES-style choice, not a service already supplied by APF.
Its operating clock may require a separate validated PLL configuration.
Keep machine timing unchanged and constrain each actual clock relationship.

At minimum this work needs image-load/storage integration, block transport,
mount lifecycle, slot wiring, and manifests/tests. These may share existing
modules, but "one new shim and nothing else" is not a complete scope.

## Exact read-sector contract

Derived from the live parser and the existing simulator block service:

1. With ACK low, observe `SD_RD` and latch the requested LBA once. It is a
   held request while waiting, not necessarily a one-clock pulse. Allow the
   controller to record its request before acknowledging it.
2. Fetch file bytes at `image_base + (LBA * 512)`. Check arithmetic,
   allocation bounds and actual file length; do not let an invalid LBA wrap.
3. Once data is available in the machine domain, raise `SD_ACK`.
4. Keep ACK high while presenting byte addresses **0 through 511 in order**,
   matching `SD_BUFF_DOUT`, and asserting `SD_BUFF_WR` on each accepted byte.
   Idle gaps with WR low are permitted. Deliver no more than one byte per
   machine rising edge. There is no per-byte backpressure input.
5. Ensure byte 511 is sampled while ACK is still high. Then drop WR and
   drop ACK on a subsequent edge. The controller recognizes completion on
   the ACK falling edge of an active transfer.
6. Keep a clean idle/retirement interval before servicing the next request.
   No unsolicited ACKs, repeated sectors, missing byte zero or stale data.

The shim drives buffer address/data/write-strobe. For reads,
`SD_BUFF_DIN` is not the source data; it is the controller's write-back
output. Serialize transfers on the shared buffer bus.

Use a stable multi-bit request payload plus synchronized ownership/event
handshakes across domains. Never independently synchronize each address or
data bit. A scratch sector must not be overwritten until consumption ends.
Reset/reload must invalidate outstanding requests so old-image responses
cannot complete against a newly mounted image.

For a final partial sector, define deterministic padding only beyond the
known EOF; reject wholly invalid requests and truncated required structures.
There is no native SD error input here: expose a fault and withdraw/reset
the media transaction rather than inventing successful disk data.

## Answers to the nine design questions

1. **Load model:** resident, ordinary data slot is the preferred first
   implementation **provided external storage is implemented first**.
   `deferload` is a legitimate alternative, not impossible, but requires
   target-command implementation and measured service latency. Do not
   combine both transports in v1.
2. **SD contract:** use the 512-byte protocol above. The logical file image,
   not the SD card's physical sector map, is the block-address space.
3. **Image size:** read the actual dataslot table by slot ID after load
   completion. Each entry is two 32-bit words, an 8-byte stride, at
   `0xF8002000` on the bridge. Use the existing local datatable port for
   core access. `size_exact` is a host-side filter, not a variable WOZ
   filesize source. Configure `size_maximum` to the storage allocation.
4. **Clock split:** keep the entire imported WOZ path on `CLK_14M`.
   Preserve warm `RESET` versus cold/media-engine `DD_RESET` semantics.
   Do not copy MiSTer's gated clock blindly into a continuously running
   Pocket machine; review pause/stall integration if subsequently added.
5. **Read-only:** set both WP overrides, file readonly flag and
   `IMG_READONLY`. Assert in tests that write attempts neither modify track
   RAM nor issue SD writes. Unexpected `SD_WR` is a visible fault, not a
   request to acknowledge and discard silently.
6. **Absent second drive:** hold `IMG_MOUNTED1=0`, `SD_ACK1=0`, and WP high;
   do not service drive-1 requests. The wrapper derives motor/flux presence
   from mounted state. Test selecting drive 2 and returning to drive 1;
   do not confuse this with synthesizing only one drive engine.
7. **Canonical sources / Q17:** use `machine/woz/` with recorded upstream
   commit/hash and existing parity checks. The active MiSTer implementation
   is the starting point, but run narrow lint and owner-approved Analysis &
   Synthesis before claiming Pocket compatibility or RAM inference.
   Generate Q17 variants only for a demonstrated tool limitation.
8. **Tests:** reuse the WOZ harness references below, not the old
   nibble-controller equivalence test. Add Pocket transport tests and actual
   boot/data assertions; activity or nonblank video alone is not boot proof.
9. **UX:** a reloadable WOZ slot is appropriate. For v1, prefer reset-assisted
   reload (parameters bit 6) while replacing a single resident image.
   Make `required` a product choice: optional permits diskless BASIC.
   Nonvolatile must remain false for this read-only milestone.

## Mount, reload and failure requirements

- Do not acknowledge host readiness before storage can accept the transfer.
  Prove bridge burst/word ordering, byte lanes and ingress capacity; the
  current constant-ready slot acknowledgements are not storage flow control.
- Do not advertise a disk until all writes are committed, the actual size
  is latched, and minimum format/type checks have passed.
- The disk wrapper consumes a mount **edge**, with size stable alongside it;
  zero-size notification ejects. Replacing an already mounted image needs
  a fresh event, not an unchanged high level.
- Define boot/reset ordering so media is available when firmware probes the
  slot, without deadlocking APF setup waiting for a reset-held parser.
- Keep media size/presence across warm machine reset. Cold reset, reload
  and failed load need explicit remount/invalidation sequencing.
- Do not assume the parser validates arbitrary files: its header path skips
  signature bytes and CRC, and `img_size` is unused. Bound the transport,
  check signature/type and supported track sizes, and surface unsupported
  or corrupt files. Do not advertise CRC verification unless implemented.

## Validation ladder and stop gates

1. **Storage only:** load an owned test asset; verify first/last bytes,
   byte ordering, unaligned ends and a full checksum/readback. Exercise
   refresh and read/write arbitration. No fake successful host responses.
2. **Sector transport:** synthetic coordinate-tagged sectors; compare all
   512 bytes, especially bytes 0/255/256/511. Randomize clock phase and
   memory latency; test consecutive/repeated LBAs, EOF, reset during
   transfer, reload and timeouts.
3. **WOZ path:** native valid WOZ fixtures, metadata and exact track-byte
   checks, bit counts, quarter-track stepping, unmapped tracks, motor
   holdover, write protection and absent-drive selection. Exercise each
   WOZ variant claimed as supported; do not infer universal support from
   a filename extension.
4. **Machine:** check slot ROM reads and `$C0E*` accesses, boot-sector bytes
   deposited in RAM, and a known DOS/ProDOS boot milestone. Test warm/cold
   reset and image A -> B reload without stale tracks. Run existing
   video/keyboard regression checks against the integrated source set.
5. **Hardware:** owner-run compile, storage proof first, then known-good
   disk boot and reload. Record image/source hashes, ALM/M10K deltas,
   memory inference, CDC/timing reports and outstanding warnings.

Existing reusable simulation references:
- [WOZ machine harness](../../Apple-II-Verilog_MiSTer/unit_tests/level_2b/main_l2b.cpp)
- [Block-host wrapper](../../Apple-II-Verilog_MiSTer/unit_tests/level_2b/l2b_disk_host.h)
- [Machine testbench](../../Apple-II-Verilog_MiSTer/unit_tests/level_2b/tb_l2b.sv)

These C++ files are **test infrastructure**, not a proposed runtime host
dependency. Use native WOZ fixtures without their non-WOZ conversion path.

Source anchors:
- [Disk wrapper, slot decode, mount and WP wiring](../../Apple-II_MiSTer/rtl/woz/disk_ii_woz.sv)
- [Parser, RAM clocks and sector handshake](../../Apple-II_MiSTer/rtl/woz/woz_floppy_controller.sv)
- [Flux write-protect gating](../../Apple-II_MiSTer/rtl/woz/flux_drive.v)
- [Current Pocket top: SDRAM tie-offs and slot hooks](../src/fpga/core/apple2e/apf_stream_video_top.v)
- Official [data slots](https://www.analogue.co/developer/docs/openfpga/core-definition-files/data-json),
  [command/table contract](https://www.analogue.co/developer/docs/openfpga/host-target-commands),
  [bridge direction](https://www.analogue.co/developer/docs/openfpga/bus-communication),
  and [physical memory](https://www.analogue.co/developer/docs/openfpga/external-hardware).

**Go/no-go:** approve the corrected architecture, then prove external image
storage and one exact 512-byte transaction before integrating disk boot.
