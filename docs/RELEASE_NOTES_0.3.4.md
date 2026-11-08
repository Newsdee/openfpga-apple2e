# Apple IIe for Analogue Pocket — 0.3.4

**HDV write-leg corruption fixes.** 0.3.3's first hardware test (Copy+ folder
creation on a Writable HDV) left the image unbootable: the ProDOS header and
directory sectors came back byte-rotated against the original, and the same
five sectors rotated by the same amounts in a second, independent run. This
release fixes two core-side bugs found in simulation and adds on-screen
counters so the hardware re-test can attribute any remaining problem to the
core or to the host framework.

**Status of the hardware bug (2026-11-06):** an expert review of the
corruption signature concluded the deterministic rotations are most plausibly
the **0x0184 read-back misalignment** (see "Expert review" below), not the
race fixed in the first half of this release. The core-side fixes are both
real (both were reproducible in sim), but the **staged 0.3.4 bitstream
predates the expert-review fix** — a fresh compile is required before any
further hardware write test (see "Rebuild required" at the bottom).

## What was wrong (root cause #1 — arm race, fixed in the staged build)

The 0x0184 host write-back armed on a **fixed short guard after the
walk-done edge**. On the real 14.318 MHz → 74.25 MHz async clocks the arm
could beat the final CDC byte commit into the sector RAM, so the host DMA'd a
sector buffer that still held the **previous** write's content. A sector was
"rewritten" with stale data — one of the corruption shapes seen in the
corrupted image (and one shape of the "write never finishes" symptom).

The original harness passed because sim clocks phase-align; the failure was
invisible there until a test wrote the **same sector twice** (the corruption
scenario) and captured the 0x0184 stream byte-exactly.

## Expert review (2026-11-06): root cause #2 — the 0x0184 read-back alignment

The hardware signature is **deterministic** (bit-identical rotations across
two runs: header sector rotated 8 B, directory sectors rotated 4 B) — a
random timing race does not produce that. The review's finding, now
implemented and sim-verified:

- The host pulls the 512-byte sector back as **128 consecutive 32-bit reads
  from `0x01F01000`**. The bridge's word select was only 7 bits
  (`bridge_addr[8:2]`), while the decode arm was the full 4 KB `0x01F01xxx`
  region: a read at `0x01F01200` **silently wrapped to word 0**. If the
  framework's first read lands k words in (its read port is **registered** —
  `core_bridge_cmd`'s `bridge_rd_data_out` is one clock late), the 128-word
  stream comes back **cyclically rotated by 4k bytes** — exactly the observed
  +8 B / +4 B sector rotations, with the last k words (zeros) landing at the
  tail. New file extensions (the clean +206-sector tail) are unaffected
  because they are read back from freshly written, non-overlapping regions.
- **Fix:** narrowed the read decode to the real 512-byte window
  (`bridge_addr[11:9]` must be 0); out-of-window reads now return `0`
  instead of wrapping.
- **New diagnostic `hdv_oobcnt`** (on-screen `K=NN`): counts out-of-window
  reads during the last 0x0184 — it **measures the host's start offset k**
  on silicon, turning the hypothesis into a number.

### Test gap found by the review (the prior round-trip test was vacuous)

The 0.3.4 (staged build) T8 round-trip test read the DUT's **combinational**
`hdv_ram_word` output directly. Two things it therefore never exercised,
both of which had to be fixed in the harness:

1. **No registered read stage.** The framework reads through
   `core_bridge_cmd`'s one-clock-late `bridge_rd_data_out`; the test must
   model that stage or the 1–2 word pipeline offset is invisible. The
   harness now captures through a `rd_pipe` register.
2. **No out-of-window addresses.** The old capture read words 0–127 only,
   so the wrapping decode never misbehaved in sim. New tests **T8c/T8d**
   drive the 0x0184 DMA starting 1 and 2 words into the window (k=1, k=2)
   and assert: in-window words byte-exact, out-of-window reads return 0
   (no wrap), and `hdv_oobcnt` == k.
3. (Found while bringing the tests up) the TB host model left
   `bridge_wr` **asserted** after a 0x0180 replay, continuously re-writing
   the last replayed word into the RAM — it masked exactly this class of
   read-back bug for the first three tests. The model now deasserts
   `bridge_wr` between DMA beats, as the real framework does.

**Lesson recorded:** a 0x0184 capture that reads the DUT's combinational
output and stays inside the window proves the data is present, not that the
host's read stream is aligned. The harness now fails a misaligned or
wrapping read path.

## What changed (RTL)

- **Commit-count arm handshake** (`hdv_bridge.sv`, in the staged build):
  the arm waits for a counter of all 512 CDC byte writes into the sector
  RAM (`wo_landed == 512` and no write in flight) — a data handshake
  instead of a timing guess. The counter resets on the raw walk-request
  level rising edge; the done check also requires the walk to have run at
  least one cycle (kills a same-cycle race where the stale 512 from the
  previous walk armed the new walk instantly).
- **Read window narrowed + OOR counter** (`hdv_bridge.sv`, post-staged):
  `0x01F01200+` reads return 0 instead of wrapping; `hdv_oobcnt` counts
  out-of-window reads of the last 0x0184 (the host start offset k).
- **Timeout covers every non-IDLE state** (3.6 s, in the staged build):
  a stuck transfer releases the 6502 from `cpu_wait` and latches a fault
  visible on screen and at C0F1.
- **On-screen diagnostic** (`sdram_status_overlay.v`): the HDV debug line
  is now `S=S F=F N=NN M=M W=NN K=NN` — **W** = 0x0184 read words the host
  pulled for the last write (want **128**); **K** = out-of-window reads
  (want **0**). The line moved to X0=402 to fit (26 chars on the 560-px
  raster).
- **Option warning** (`interact.json`): the write-protect option's Writable
  value is now **"Writable (EXPERIMENTAL)"** — HDV writing is not trusted
  with real media until the hardware re-test below comes back clean.

## Interpreting the hardware re-test

Run the Copy+ folder test again on a **throwaway** HDV with
**Hard Disk Write Protect = Writable**, then read the debug line:

- **W=128, F=0, K=0** — the core side is clean and the framework's DMA is
  aligned: every sector was fully committed before the host DMA, all 128
  words pulled, no out-of-window reads. If the image is still corrupted in
  this case, the corruption is downstream of the 0x0184 stream (framework
  file placement) — take the image and the debug line to the framework
  maintainers.
- **W=128, F=0, K>0** — the framework started its DMA k words into the
  window. The narrowed decode no longer rotates the sector (out-of-window
  reads are zeros now), but the first 4k bytes still land shifted — the
  K value is the exact evidence for the host-side alignment fix.
- **W<128, F=1** — the framework gave up mid-DMA (or the timeout fired);
  the file holds a partial stream.
- **Freeze > ~5 s** — the 3.6 s timeout did not fire; separate
  core-side state bug, chase from the FSM state shown in `S`.

## Validation

- `verilog/hdv_bridge` harness extended as described above (registered
  `rd_pipe` capture, T8c/T8d k=1/k=2 DMAs, host-model `bridge_wr` fix).
  Result: `HDV BRIDGE ALL CHECKS PASSED`, `read_cmds=6 write_cmds=7
  failures=0`, zero warnings.
- Quartus 17.0.2 Lite full compile (owner-launched, **for the staged
  build only**): A&S + fitter + STA + asm all successful. ALM 13,897 /
  18,480 (75 %), block memory bits unchanged (1,557,504), TNS 0.000 on
  every constraint (`clk_74a` setup slack +2.163 ns). No new warnings
  (only the pre-existing 10268 blocking/non-blocking notes).

## Rebuild (done 2026-11-06 10:32)

The expert-review changes were **not in the 01:41 staged bitstream**
(which contains only the first-half fixes and was what produced the second
corrupted image). A fresh owner-launched compile + repackage completed at
10:32 with all of them: build archive `builds/2026-11-06_1032_v034b_hdvroo/`
(build ID `20261106 / 00101901 / c2558012`, fit ALM 13,979, block memory
bits unchanged 1,557,504, TNS 0.000, clk_74a setup +2.287 ns; rbf_r
sha256 `9182aa70…a89c`). The staged `bitstream.rbf_r` in
`sd_root/Cores/Newsdee.Apple2e/` is now the 10:32 build, paired with the
`interact.json` carrying the "Writable (EXPERIMENTAL)" warning — copy the
whole core dir to the SD card. (Version/commit decision for this delta is
left to the owner: ship as 0.3.4-final or bump to 0.3.5 at commit time.)

## No user-facing option changes

No new interact options; the option set is unchanged from 0.3.3 (10
options) apart from the Writable value's name gaining the EXPERIMENTAL
suffix. The bitstream and `interact.json` still ship as a pair.
