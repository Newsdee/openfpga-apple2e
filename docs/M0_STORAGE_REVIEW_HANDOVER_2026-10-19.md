# M0 external storage: review and handoff

Date: 2026-10-19  
Review target: [M0 review request](EXPERT_REVIEW_M0_STORAGE_2026-10-19.md).
Companion: [WOZ architecture recommendation](FLOPPY_WOZ_RECOMMENDATION_2026-10-19.md).

## Verdict

**Accept the external-image-storage direction; do not accept M0 as verified.**
The current implementation is a compiled write-only integration with no
hardware integrity proof. Keep M1/M2 integration behind the M0 acceptance
gate below. No need to abandon SDRAM, but reference provenance does not
establish a safe transaction interface for this integration.

This review inspected RTL, the pinned local reference, manifests and the
existing Quartus reports. No HDL was edited and no new build or simulation
was run.

Confirmed:
- Imported `io_sdram.v` is byte-identical to the local reference:
  SHA-256 `0c53ad4d83b24b8b1772730c9daf8b73f6ccd8868876fd43c90d906c5b7d5738`.
- The 23:14 fitter report succeeds: 3,533 ALMs, 2,132 registers,
  152 RAM blocks, **2 of 4 PLLs**. The PLL wrapper's "three PLLs" comment
  is not the device allocation reported by Quartus.
- Reported SDRAM controller setup slack +1.683 ns is real, but does not
  establish external-memory timing closure.

## Blocking findings

### 1. The word interface does not retain transactions

In [io_sdram.v](../src/fpga/core/apple2e/io_sdram.v):

- Lines 125-136 synchronize request edges and declare synchronized
  address/data buses.
- Lines 309/317 actually read **raw `word_addr`**, not `word_addr_s`.
- Lines 361/372 read **raw `word_data`** in two different write states,
  not `word_data_s` or a latched transaction payload.
- Lines 537-541 retain only request bits, not address/data records.
- `word_busy` is only assigned zero (line 300); it is never asserted.

Consequences under overlapping requests:
- A pending request can use a later word's address.
- Two halfword writes can use data from different source words.
- Repeated requests collapse into a single pending bit.
- Adjacent bridge write cycles leave `sdram_word_wr` continuously high;
  a rising-edge detector sees one event, not one store per cycle.

These are source-level failure mechanisms. Actual Pocket loader spacing
has not been measured here, so this is **not** a claim that every real
load necessarily fails. It is a rejection of an unproven throughput/CDC
assumption as the integrity contract.

A wider request counter is not a fix: it still loses payload identity.
Likewise, merely changing uses to the synchronized multi-bit buses does
not guarantee coherent data or preserve queued words.

### 2. Storage readiness and completion are not integrated

The [top](../src/fpga/core/apple2e/apf_stream_video_top.v) reports boot/setup
ready from the machine PLL alone (lines 338-339), unconditionally accepts
slot writes (350-351), and ties SDRAM reset high (785).

The SDRAM boot FSM waits approximately 30,000 controller clocks before its
initialization commands. There is no exported initialized/ready signal,
no transaction completion handshake, and no load-drained condition.
`008F` means the host has finished sending; it does not prove the SDRAM has
committed the last queued write.

Adding PLL LOCKED alone is insufficient. Reset currently restores only
selected controller state; request queues and transaction ownership also
need defined reset/abort semantics.

### 3. External SDRAM timing is not checked by the reported slack

[The SDC](../src/fpga/core/apple2e/apple2e_core_constraints.sdc) places the
controller and phase-shifted chip outputs in separate asynchronous groups.
They are related outputs of the same PLL, not independent clocks.

The [TimeQuest report](../src/fpga/output_files_apple2e/apf_stream_video.sta.rpt)
explicitly lists SDRAM address, bank, command, DQ, DQM, CKE and clock outputs
as unconstrained. Unconstrained outputs increased to 58. These newly live
pins are not covered merely because similar warnings existed previously.

Keep the two SDRAM clocks related, establish the forwarded-clock
relationship, and constrain command/write setup/hold and read-data arrival
using the actual chip specification, phase and board assumptions. Do not
invent delay numbers or blanket-false-path the memory bus.
Reassess timing with readback actually connected; an unused read datapath
may be optimized away in the current write-only build.

### 4. Hardware storage integrity has no observable result

`word_rd` is tied low, `word_q` is unused, and bridge reads outside the
command region return zero. A working Apple II screen cannot distinguish
valid SDRAM contents from missing or corrupt writes.

**Readback belongs in M0, not M1.** Add a small hardware verifier or a
properly handshaken debug readback path. Simulation cannot prove PCB/pad
timing, real host pacing, or retention/refresh on the physical chip.

## Recommended transaction architecture

```text
bridge writes at clk_74a
  -> FIFO of complete {address, data, relevant metadata} records
  -> controller-clock transaction owner
  -> accepted request with latched payload, explicit done/read-valid
  -> SDRAM
  -> hardware readback/verifier and stable diagnostic result
```

- Capture every bridge write beat, including consecutive cycles.
- A dual-clock FIFO or an equivalent proven mailbox protocol must transfer
  coherent records. A mailbox is sufficient only with proven pacing and
  a way to retain all arrivals while it is occupied.
- Serialize word operations in the controller domain; latch address and
  data on acceptance and retain them through both halfword writes.
- Implement real initialized/ready and completion/read-valid semantics.
  Do not build a client waiting for the current `word_busy` to rise.
- Reset queues, pending ownership and completion events deliberately.
  Preserve resident-image contents across an ordinary machine reset.
- Keep the pinned reference immutable. Document/test necessary changes in
  the Pocket-local implementation; byte identity is not a reason to retain
  an unsuitable interface.
- Size buffering against worst-case bursts, initialization and refresh
  stalls, not average host bandwidth. A finite FIFO cannot solve sustained
  overload. Record occupancy/high-water and sticky overflow/error status.
- Gate acceptance of a whole slot until storage is initialized and capable
  of accepting it. `0082` readiness is not per-word flow control.
- After `008F`, wait for FIFO empty **and final SDRAM completion** before
  marking the image available. Handle diskless setup separately.

## Answers to the seven questions

**Q1 - Load flow control:** do not accept "probably slow enough." The
7-10-cycle write estimate omits waits in the actual state machine; measure
the complete request-to-completion interval, including refresh. Test
adversarial arrivals and measure actual hardware ingress. Use payload
storage, not an N-bit request count. No slower-load mode was established
by this review.

**Q2 - Hardware proof:** choose minimal readback now. Recommended diagnostic
results: initialized/load/drained/verified flags, loaded byte count,
received and committed word counts, overflow/timeout flags, and a CRC of
the bytes **read back from SDRAM**. Compare with an independently known
fixture CRC; optionally also keep an ingress CRC. An ingress checksum
alone never verifies memory. Check first/last data and endianness explicitly.

**Q3 - Required file:** either setting is technically valid, but use
`required:false` for a regression package intended to retain diskless boot.
The acceptance test must actually load a known fixture. Manifest-only
changes do not require recompiling the RBF. Do not distribute someone
else's disk image without permission; use a locally owned/native WOZ or
an explicitly identified storage-test fixture.

**Q4 - Slot definition:** ID 1, base zero and a 4 MiB cap are reasonable if
reserved and enforced. `parameters:1` means reloadable, not read-only.
For the planned read-only/reset-assisted reload policy, use bits 0, 3 and
6 (`0x49`) once the lifecycle is implemented; bit 1 would only make the
asset core-specific, not protect it. Keep nonvolatile false. A host-side
size cap does not replace core-side load/address bounds and actual-size
tracking. Until reload is safe, do not expose it as a working feature.

**Q5 - LOCKED/reset:** provide a deliberate power/lock reset with locally
safe release, then wait for SDRAM initialization. A fixed delay started
on an unqualified clock is not equivalent to a readiness contract.
On lock loss, invalidate the image and report/recover explicitly. Do not
tie memory reinitialization to every Apple II reset, and do not create a
boot deadlock waiting for host Reset Exit before allowing initial loading.

**Q6 - Testbench:** unit first, integrated storage second, hardware third.
Keep Disk II SD_ACK emulation in M1. A sector is **128 32-bit words**, not
13. The full top currently has no reader; add the real verifier/client
before claiming a full-top readback test, rather than forcing internal
signals around the integration under review.

**Q7 - Address space:** the current `[31:25]==0` decode accepts
`0x00000000-0x01FFFFFF` (32 MiB), not merely `0x00xxxxxx` (16 MiB).
The 24-bit word-address port can address 64 MiB, but this decode forces
its top bit low. The reference instead uses `[31:24] == 000000xx`, covering
64 MiB. Neither is a problem for a bounded 4 MiB slot, but they are not
identical mappings. Reserve the chosen window explicitly; `0xF8xxxxxx`
remains APF command space. Other cores' save-state bases are not a global
reservation.

## Test gates

Start by encoding failures against the current interface; do not wait for
a full machine testbench. Tests must fail before the relevant fixes and
pass afterward.

1. **Transactions:** isolated and back-to-back distinct words; requests
   during refresh/boot; source data changing during pending operations;
   adjacent high bridge-write cycles; overflow, reset and timeout.
   Verify no missing, duplicated, reordered or mixed-halfword writes.
2. **Memory model:** prefer a compatible existing vendor model if usable.
   Otherwise model all four banks, each bank's active row, row/column
   addressing, CAS latency, CKE, precharge/auto-refresh, DQM and bidirectional
   bus turnaround. A single global open-row model is insufficient.
   Check the relevant chip timing limits and refresh cadence at 133.12 MHz;
   ideal digital models still cannot prove physical timing margins.
3. **Boundaries/data:** an exact 512-byte block plus larger patterns across
   row boundaries and the allocation end; address-as-data, walking bits
   and asymmetric byte/halfword patterns. Test bank crossings in controller
   tests if claiming the full 64 MiB address space.
4. **File sizes:** zero, one/two/three-byte tails, 511/512/513 bytes and
   maximum size. Define partial-word padding/masks and CRC over the exact
   file length. Out-of-allocation requests must produce explicit failure,
   not arbitrary successful data. Read bytes beyond actual EOF are not
   image data.
5. **Integrated/hardware:** host load -> drain -> SDRAM readback -> known
   checksum and byte checks. Repeat after idle/refresh, reload and cold
   start; test ordinary machine reset separately. Capture the host write
   spacing and FIFO high-water mark on real hardware.

**M0 exit:** exact storage results, bounded/observable failures, deliberate
startup/reload ordering, external-memory timing coverage, and successful
hardware readback. "Machine still boots" is only a regression check.

May wait for M1+: sector ACK sequencing, WOZ parser/mount validation,
Disk II slot wiring, filesystem boot and writable media. ECC/scrubbing
may remain out of scope; overflow, timeout, readiness and integrity
reporting may not.
