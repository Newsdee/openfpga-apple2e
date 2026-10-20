# M1 WOZ fetcher: follow-up implementation brief

Date: 2026-10-20

Review of the updated [M1 design request](EXPERT_DESIGN_M1_WOZ_FETCHER_2026-10-20.md).
Source inspection and independent fixture hashes only; no HDL edits, simulations,
or Quartus runs for this review. M0 hardware acceptance is reported by the owner,
not independently repeated here. Preserve that baseline.

## Decision

Proceed with the unchanged MiSTer WOZ engine, one mounted read-only drive, and
a Pocket sector service. However, this requires **storage ownership, media
lifecycle and boot integration**, not just a byte emitter.

Keep the engine on the existing 14.31818 MHz machine clock. The actual SDRAM
controller runs at **133.12 MHz**, not 74 MHz; the APF bridge is 74.25 MHz.
See the [PLL parameters](../src/fpga/core/apple2e/apple2e_sdram_pll.v).
Do not change the accepted SDRAM clock/phase configuration for this work.

## Corrections before implementation

- The disk module ports are **`WE` and `A`**, not the proposed `CPU_WE` and
  `ADDR`. Connect the machine's CPU_WE, m_addr and m_ram_di respectively.
  `$C600-$C6FF` is the card ROM; `$C0E0-$C0EF` contains its switches.
- `SD_LBA` is a **512-byte sector number**, not a byte offset.
  Byte offset = `LBA * 512`; word offset = `LBA * 128`.
- Set **D1_WP=1 and D2_WP=1**, as well as IMG_READONLY=1. The parser declares
  img_readonly but does not use it; the wrapper's WP override reaches the
  flux drive's write gate. The proposed WP=0 wiring is not read-only.
- The [Disk II ROM](../../Apple-II_MiSTer/rtl/woz/disk_ii_rom.v) initializes
  256 bytes inline. No diskii.hex, generic ROM helper, or extra simulator
  ROM copy is needed for this module.
- DOS 3.3 uses **16 sectors of 256 bytes per standard track**, not 13.
  WOZ stores encoded bits/flux, so decoded sector capacity is not a safe
  basis for shrinking its track cache.
- WOZ1 and WOZ2 are chunk-based formats. Remove the unsupported
  "1997 WOS0/WOZ2 fixed-header" distinction. WOZ2 TRKS descriptors are
  **8 bytes**: little-endian start block, block count, bit count (2+2+4).
  The source uses `trks_index << 3`; a visually repeating 16-byte pattern
  is not the descriptor size. TMAP has 160 byte entries indexing descriptors.
- A BASIC `]` prompt alone does not prove DOS is loaded; CATALOG producing
  the expected directory is the useful acceptance condition. Do not infer
  Integer versus Applesoft BASIC merely from CATALOG failing.

## Answers to Q1-Q11

| Question | Recommendation |
|---|---|
| Q1: pacing | One request transfers 512 bytes. Latch LBA while ACK is low; allow request registration before ACK. Raise ACK before delivering byte zero, then strobe addresses 0..511, at most one byte per machine rising edge. Gaps with WR low are allowed. Byte 511 must be sampled with ACK high; lower ACK on a later edge. Retire the request before accepting another. |
| Q2: writes | Force both WP overrides. Any SD_WR is an explicit invariant fault: no SDRAM write and no fake successful ACK. Latch a visible fault and cancel/unmount/reset the disk transaction through the lifecycle controller. Do not silently hang or acknowledge a no-op. No write-back implementation in M1. |
| Q3: reset | RESET clears switches/sequencer; DD_RESET resets drive and parser. The wrapper retains media presence across DD_RESET and remounts after release. Keep ordinary machine reset separate from SDRAM initialization and load/verify state. Power loss or FPGA reconfiguration is not a valid retained-image guarantee. |
| Q4: tracks | Preserve the wrapper's quarter-track mapping: `qtrack >= 2 ? qtrack[7:0]-2 : 0`. TMAP maps positions to track records; it is not a DOS sector table. An FF entry takes the empty-track path, sets bit_count=0 and invalidates cached block pointers. Do not promise a 6502 error message: Disk II firmware can continue polling. Use a bounded test watchdog. |
| Q5: ownership | Serialize load -> verify -> mounted fetch for M1. Do not concurrently run verifier/fetcher merely because both are reads. Add explicit transaction ownership and completion routing; stage_m is a display summary, not a grant. See below. |
| Q6: buffer bus | The shim owns ADDR, DOUT and WR for reads; WR writes into the engine's parser/track path, not into an APF transport buffer. DIN is the engine's write-back output and is unused for read-only service. Keep drive-2 ACK low and mount inactive; leave its output ports unconnected, not driven. |
| Q7: clock | Use ungated clk_core_14318 with STALL=0 as today. No new fabric-gated clock. Future pause/savestate support must coordinate engine and transport; it is outside M1. |
| Q8: ROM | Import disk_ii_rom.v unchanged; retain registered-read timing. Register all six explicitly named engine sources in the active QSF and relevant simulation lists. |
| Q9: resources | Keep the default 32 KiB track cache per 5.25-inch engine. Budget both generated drive instances until fitting proves pruning. Detailed baseline below; no defensible ALM prediction from line counts. |
| Q10: taps | Activity/motor/step outputs are observational. Leaving them open is fine; floppy sound and cosmetic drive overlays can wait. Transport faults must still be observable. |
| Q11: tests | Use the ladder below, including full-machine simulation. Do not defer all boot validation to hardware or build a reference decoder solely by transcribing the DUT. |

## Storage ownership and media lifecycle: implementation prerequisites

The current [storage wrapper](../src/fpga/core/apple2e/sdram_storage.v)
serializes M0 writes and verifier reads by convention. Its `req_kind` address
mux is **not a general multi-client arbiter**. The underlying word port has
shared address/data signals and delayed request handling.

Recommended minimal design:

1. A controller-domain owner latches each accepted request's address, operation
   and write payload, retains ownership until completion, and routes read data
   only to that owner. Requests wait for an explicit grant; a higher-priority
   load must not change an in-flight read's address.
2. Fetch a sector into a 512-byte scratch buffer, then transfer buffer ownership
   to the machine-clock emitter. A stable request/completion handshake crosses
   domains; do not independently synchronize a changing address/data bus.
   Hold the buffer unchanged until emission finishes. One outstanding sector
   is sufficient initially.
3. Validate the widened LBA arithmetic against the actual file size and the
   allocated image region before narrowing to the 24-bit word address. Unpack
   the M0 word in file order: bits 31:24 first, then 23:16, 15:8, 7:0.
4. A new accepted slot load invalidates the mounted generation and cancels or
   retires old reads before image memory is overwritten. Late responses must
   not reach the new generation. If quiescing needs time, implement the APF
   request-write acceptance handshake rather than retaining unconditional ACK.
5. Load completion + drain + successful verification publishes stable size and
   a new mount event. Failed/no-file generations remain unmounted. M0 OK means
   completed readback, not independently proven CRC equality or valid WOZ.

**Do not wire mount directly to result-valid and assume falling means eject.**
The [disk wrapper](../../Apple-II_MiSTer/rtl/woz/disk_ii_woz.sv) latches media
presence on a rising mount edge; falling IMG_MOUNTED does not clear its internal
mount. Use an explicit zero-size mount event to eject, or an equivalent
documented lifecycle sequence. DD_RESET alone preserves media presence and
will remount the old image. An invalid reload must not leave old track RAM
serving apparently valid data over an overwritten image.

For reset-assisted user reload, recommend manifest parameters **0x49**
(reloadable + read-only + reset during load), replacing 1. This is an intentional
UX change to approve/document. APF Reset Exit can precede local verification:
hold the necessary Pocket-local disk/boot state until the new generation is
usable; never reset SDRAM to achieve this. Do not gate APF's pre-load setup
readiness on verification, which cannot happen until loading is allowed.

## Boot and peripheral-bus integration

Import the six named files byte-identically from
[the active MiSTer WOZ directory](../../Apple-II_MiSTer/rtl/woz/), pin their
source revision/hashes, preserve license notices, and leave machine/ unchanged.

The controller's D_OUT defaults to its data register outside ROM selection.
Blindly connecting it to PD changes reads of unrelated unimplemented slots
from the current zero fallback. Qualify the Pocket peripheral mux with slot-6
ROM/device selection; retain the existing fallback for other addresses.

**Diskless boot needs an explicit policy.** Advertising a bootable Disk II ROM
with no mounted disk can leave firmware polling instead of reaching the current
BASIC prompt. To preserve the requested diskless experience, recommend hiding
the slot-6 ROM when there is no usable image, and advertising it only once a
loaded generation is usable. Hold initial boot/reload appropriately, or provide
an explicit boot action; verify cold boot and manual PR#6 where supported.
Keep parser/fetch clocks running while any CPU boot hold is asserted.

## Bounds, fixtures and memory budget

- Independently checked local disk.woz and DOSMaster.woz: both **234,496 bytes =
  458 complete sectors**, CRC32 **74EA1324**, SHA-256
  `17507a18412ce0991b751b2ae0ec288775e1f349f4944e1bb614e848a845d0f6`.
  The updated brief correctly distinguishes the owner's 5505C782 image.
  Record the exact fixture/hash used for each acceptance run.
- Test partial tails separately. For a valid final partial sector, copy only
  bytes below EOF and pad the remainder deterministically; never expose stale
  SDRAM. Reject a request starting wholly beyond EOF. Padding is not permission
  to accept truncated required track/chunk structures. Surface faults and
  invalidate media rather than fabricate a successful read.
- The parser skips the header CRC and does not enforce img_size. Validate
  supported format/descriptor bounds; the scanner's block limit is not a file
  bounds check. A trailing META chunk need not be fetched once required parsing
  is complete: do not make reading every trailing chunk an acceptance rule.
- Latest inspected [fit summary](../src/fpga/output_files_apple2e/apf_stream_video.fit.summary),
  2026-10-20 12:37:03: **5,157/18,480 ALMs, 4,422 registers,
  154/308 RAM blocks**, superseding the brief's older baseline.
- Each track RAM is 32,768 x 8; metadata is 2,048 x 8 per engine. At byte-wide
  M10K geometry, budget roughly 32+2 blocks per drive, about 68 for two drives,
  plus ROM/transport storage. This suggests headroom, not a fit guarantee.
  Do not shrink BRAM_ADDR_WIDTH: FLUX and encoded tracks can exceed decoded
  DOS sector storage. Check inference, packing and timing in the next fit.

## Acceptance ladder and handoff gates

1. **Owner/sector unit tests:** real SDRAM model, all 512 bytes compared;
   first/last byte, word endianness, consecutive sectors, delayed completion,
   EOF tails, overflow LBA, timeout, prohibited write, reload/reset during an
   outstanding request, and no stale-generation completion.
2. **WOZ integration:** unchanged engine plus Pocket service. Compare identical
   sector responses and debug loaded-track bytes/bit counts against direct-file
   service using the existing
   [level-2b host](../../Apple-II-Verilog_MiSTer/unit_tests/level_2b/l2b_disk_host.h).
   Supplement shared-engine comparisons with independently parsed WOZ metadata
   and raw track bytes. Cover TMAP FF, seeks, malformed/truncated input, remount,
   write protection, and the second known-good image.
3. **Full machine:** actual slot-6 ROM entry, disk activity, known DOS-loaded RAM
   or execution milestone, then CATALOG with expected entries. A prompt or
   nonblank frame alone is insufficient. Test diskless boot and reset/reload.
4. **Regressions:** M0 FIFO/store/bridge/verify/overlay tests, including bounded
   failure cases; machine/ and imported-engine byte parity. Fatal test failures
   and watchdogs must produce nonzero exits.
5. **Owner Quartus + hardware:** compile the single active project, confirm
   source bindings and block-RAM inference, inspect fit/timing deltas and new
   warnings, verify staged bitstream provenance, then repeat DOS CATALOG,
   diskless boot, reset persistence and reload on Pocket.

Do not add floppy sound, write-back, alternate image conversion or track-cache
optimizations to this milestone. Stop at a reproducible, read-only DOS boot with
preserved M0 behavior and explicit failure reporting.
