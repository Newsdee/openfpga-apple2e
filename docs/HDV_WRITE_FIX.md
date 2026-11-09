# HDV write corruption — root cause and fix (technical)

Developer notes for the 0.3.5 HDV write fix. The user-facing summary is in
[`RELEASE_NOTES_0.3.5.md`](RELEASE_NOTES_0.3.5.md); this file holds the technical
detail (root cause, fix, validation).

## The internal build arc

The writable-HDV feature was developed across internal builds (never released):

- **0.3.3 (internal)** — added writable HDV behind a Hard Disk Write Protect option
  (default protected). First hardware test (Copy+ folder creation on a Writable HDV)
  left the image unbootable: ProDOS header + directory sectors came back
  positionally corrupt, same sectors shifted by the same amounts in an independent
  second run.
- **0.3.4 (internal)** — fixed two core-side bugs found in sim (an arm race, an
  out-of-window wrap) and added on-screen counters, but writes were still corrupt;
  its own notes flag that a fresh compile was required before any further test.
- **0.3.5 (shipped)** — fixes the last of it: the `0x0184` read-back alignment. Writes
  are now byte-exact.

## Root cause (model B — the framework's latency prime)

The framework's `0x0184` data phase issues **129** 32-bit reads for a 512-byte
sector: it primes word 0, discards that first sampled value, and keeps words
1..128. The core's HDV read port was **one** register stage (data valid on the first
strobe). So the framework's discarded prime threw the kept stream off by one word:
every warm sector came back shifted k=1 word (4 bytes), and the cold first write of a
session shifted k=2 (8 bytes) with a repeated final beat.

The corruption was **positional only** — a MiSTer known-good control showed the
captured *content* was byte-correct, just placed late (the Pocket image matched the
known-good image after undoing the shift, 0 mismatches). The image alone could not
separate a "start-address bug" from a "latency prime" because the discarded prime
(word 0) is in-window and leaves no trace. The deciding fact (129 strobes) was settled
by building the fix and testing it on silicon.

## The fix (one local register stage)

`hdv_bridge.sv` gained a parameter `RD_PRIME_STAGE` and a local register
(`hdv_ram_word_q`) on the HDV read port. `RD_PRIME_STAGE=1` makes the host-visible
HDV read **two** register stages, matching the framework's prime+discard convention —
the kept words are then exactly words 0..127.

- Kept **local** to `hdv_ram_word`; the global `bridge_rd_data` mux in
  `apf_stream_video_top.v` is untouched (a read-back-mux change once broke disk
  loading on silicon — never touched again).
- **`RD_PRIME_STAGE=1` is the 0.3.5 default.**
- Resource/timing: +61 ALM, no M10K change (block memory bits stay **1,557,504**),
  timing met.

## Validation

- **Simulation (T8e):** a harness test models the framework's exact convention (129
  reads at words 0..128, discard the first sample, keep 128). Against the 1-stage
  port it reproduces the hardware k=1 shift exactly; with `RD_PRIME_STAGE=1` it lands
  byte-exact (words 0..127). The TB release gate runs at `RD_PRIME_STAGE=1`
  (T8/T8c/T8d converted to prime+discard so all checks are green at the shipping
  stage).
- **Silicon (decisive):** the `RD_PRIME_STAGE=1` build ran Copy+ creating two folders
  (TEST, HOPE) on a throwaway HDV. The result image
  (`scratch_hdv_corrupt/SmartportHD_correct.HDV`, sha256
  `430c27c54624d0175da70a1092cdc24c36116864e5489fc2a8ff383567b9831c`) is byte-exact vs
  the golden except **7 sectors** of legitimate ProDOS updates (header counters,
  bitmap bits, the TEST + HOPE directory entries). No rotation, no shift, no A5A5
  bleed; the "TEST"/"HOPE" names are readable in the written directory entries. The
  changed sector set matches the MiSTer known-good reference's pattern.

## What changed in the tree (0.3.4 → 0.3.5)

- `hdv_bridge.sv`: `RD_PRIME_STAGE` parameter + local `hdv_ram_word_q` read stage;
  **ships at 1**.
- `apf_stream_video_top.v`: `.RD_PRIME_STAGE(1'b1)`; diagnostic overlay reverted for
  shipping (`OVL_DEBUG=0`, `ovl_debug_en` back to the post-reset window) — the
  always-on debug text is gone, the drive lamps remain.
- `interact.json`: "Boot Media" + "Hard Disk Write Protect" combined into one 5-value
  option (see the release notes).
- `core.json`: version 0.3.4 → 0.3.5.

## Post-0.3.5: sector RAM → M10K (attempted, then REVERTED 2026-11-09)

> The 0.3.5 **ship** used `RD_PRIME_STAGE=1` (the local `hdv_ram_word_q` stage
> described above). After 0.3.5 we moved the sector RAM from a ~4,096 flip-flop array
> into block RAM (an explicit `altsyncram`, 128×32, 2 M10Ks) for hygiene and headroom,
> removing `RD_PRIME_STAGE` on the assumption that the M10K Port A readout was a
> drop-in for the stage. That change **shipped a regression** and was **reverted** on
> 2026-11-09: `hdv_bridge` is back to the flip-flop array + `RD_PRIME_STAGE` (the
> proven, byte-exact 0.3.5 behavior). The M10K is parked pending a real silicon probe.
> Details below; per-component resource history in
> [`RESOURCE_UTILIZATION.md`](RESOURCE_UTILIZATION.md); full arc in the expert briefs
> and [`PLAN_HDV_BRIDGE_RAM_M10K_2026-11-08.md`](PLAN_HDV_BRIDGE_RAM_M10K_2026-11-08.md).

### The M10K regression (found 2026-11-08, reverted 2026-11-09)

The M10K move corrupted hardware writes (`SmartportHD_corrupted{6,7,8}.HDV`). The
diagnosis went in circles before we reverted:

- **2026-11-08 (wrong):** the first brief concluded Port A read was 0-cycle and a
  `q_a_q` stage was added to "fix" it.
- **2026-11-09 (also wrong):** an expert review + the fitter RAM Summary
  (`ramprobe_z`: `Port A Input Registers: yes`) said Port A read is 1-cycle, so
  `q_a_q` made the read 2-cycle; `q_a_q` was deleted and the sim model set to 1-cycle.
  The bench passed — but the fresh `q_a_q`-deleted build **still** produced a corrupted
  HDV (`corrupted8`), so the read-latency theory was a red herring.
- **2026-11-09 (decisive):** a numeric, full-sector diff of `corrupted8` showed the
  corruption is an **inconsistent left shift** — sector 2 shifted **8 B** (502/504
  match), sectors 546/11675 shifted **4 B** (507–508/512). A *fixed* read/write
  latency produces a *uniform* shift; 8-vs-4 does not. That is the signature of the
  M10K host-read stage **not being a uniform 1 cycle** — a timing interaction on the
  bidir dual-clock M10K that the behavioral sim model (fixed 1-cycle) cannot reproduce,
  which is why the bench passed while silicon failed.

**Decision — revert to the flip-flop array + `RD_PRIME_STAGE`.** The M10K path is
parked: it needs a **real silicon probe** of the exact bidir dual-clock read/write
timing (a behavioral model has misled us repeatedly) before it is safe. We revisit the
M10K only if ALMs/LEs run out — the flip-flop `hdv_bridge` costs ~5,000 ALMs, and pins
(224/224), not ALMs, are the binding constraint. `ramprobe_z` (the 128×32 dual-clock
probe) is retained in `tools/ramprobe/` as a reference; `hdd.v` still uses its own
`altsyncram` and passes (`HDD EQUIVALENCE PASS`), as does the reverted `hdv_bridge`
(`HDV BRIDGE ALL CHECKS PASSED`).
