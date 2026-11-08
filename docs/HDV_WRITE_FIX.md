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
