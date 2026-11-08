# Apple IIe for Analogue Pocket — 0.3.5

**HDV writes now work.** 0.3.4 fixed the core-side arm race and the
out-of-window wrap, but hardware writes were still corrupt: the ProDOS
metadata sectors came back **shifted 4-8 bytes** (a positional offset, not a
rotation). 0.3.5 fixes the last of it — the 0x0184 read-back alignment — so
HDV writes are now byte-exact and trusted with real media.

## Root cause (model B — the framework's latency prime)

The framework's 0x0184 data phase issues **129** 32-bit reads for a 512-byte
sector: it primes word 0, discards that first sampled value, and keeps words
1..128. The core's HDV read port was **one** register stage (data valid on the
first strobe). So the framework's discarded prime threw the kept stream off by
one word: every warm sector came back shifted k=1 word (4 bytes), and the cold
first write of a session shifted k=2 (8 bytes) with a repeated final beat.

The corruption was **positional only** — the MiSTer known-good control showed
the captured *content* was byte-correct, just placed late (the Pocket image
matched the known-good image after undoing the shift, 0 mismatches). The image
could not separate a "start-address bug" from a "latency prime" because the
discarded prime (word 0) is in-window and leaves no trace. The deciding fact
(129 strobes) was settled by building the fix and testing it on silicon.

## The fix (one local register stage)

`hdv_bridge.sv` gained a parameter `RD_PRIME_STAGE` and a local register
(`hdv_ram_word_q`) on the HDV read port. `RD_PRIME_STAGE=1` makes the
host-visible HDV read **two** register stages, matching the framework's
prime+discard convention — the kept words are then exactly words 0..127.

- Kept **local** to `hdv_ram_word`; the global `bridge_rd_data` mux in
  `apf_stream_video_top.v` is untouched (a read-back-mux change once broke
  disk loading on silicon — never touched again).
- +61 ALM, no M10K change (block memory bits stay **1,557,504**), timing met.
- **`RD_PRIME_STAGE=1` is the 0.3.5 default.**

## Validation

- **Simulation (T8e):** a harness test models the framework's exact convention
  (129 reads at words 0..128, discard the first sample, keep 128). Against the
  1-stage port it reproduces the hardware k=1 shift exactly; with
  `RD_PRIME_STAGE=1` it lands **byte-exact** (words 0..127).
- **Silicon (decisive):** the `RD_PRIME_STAGE=1` build ran Copy+ creating two
  folders (TEST, HOPE) on a throwaway HDV. The result image
  (`scratch_hdv_corrupt/SmartportHD_correct.HDV`, sha256
  `430c27c54624d0175da70a1092cdc24c36116864e5489fc2a8ff383567b9831c`) is
  **byte-exact** vs the golden except **7 sectors** of legitimate ProDOS
  updates (header counters, bitmap bits, the TEST + HOPE directory entries).
  No rotation, no shift, no A5A5 bleed; the "TEST"/"HOPE" names are readable in
  the written directory entries. The changed sector set matches the MiSTer
  known-good reference's pattern.

## What changed vs 0.3.4

- `hdv_bridge.sv`: `RD_PRIME_STAGE` parameter + local `hdv_ram_word_q` read
  stage; **ships at 1**.
- `apf_stream_video_top.v`: `.RD_PRIME_STAGE(1'b1)`; the diagnostic overlay is
  reverted for shipping (`OVL_DEBUG=0`, `ovl_debug_en` back to the post-reset
  window) — the always-on debug text is gone, the drive lamps remain.
- `interact.json`: "Boot Media" and "Hard Disk Write Protect" are combined
  into one 5-value option (see the option-change section below); the
  write-protect is no longer a separate option (HDV writes are now trusted).
- `apf_stream_video_top.v`: the combined option is decoded from one
  `cfg_hdd_word` register (`0x01F00010`) into the media select + the
  write-protect bit; the retired `cfg_wp_word` / `0x01F00018` arm is removed.
- `core.json`: version 0.3.4 → 0.3.5.
- TB release gate moved to `RD_PRIME_STAGE=1` (T8/T8c/T8d converted to
  prime+discard so all checks are green at the shipping stage).

## Option change: Boot Media + Write Protect combined

The two storage options are merged into one (a menu consolidation, not a new
feature). "Boot Media" (`0x01F00010`) now carries the write-protect too, as a
5-value list:

| value | name |
|---|---|
| 0 | Both, read-only (default) |
| 1 | Both, write |
| 2 | Floppy (no HD) |
| 3 | HDD, read-only |
| 4 | HDD, write |

The old "Hard Disk Write Protect" option (`0x01F00018`, id 9) is retired.
"Floppy" takes the HD off the bus, so write-protect is moot there - hence 5
values, not 6. Default 0 = Both + read-only = the same safe state as before.
One-time migration effect: a previously-persisted "Writable" (id 9) is
orphaned and the combined option defaults to read-only; re-pick "write" to
enable it. The bitstream and `interact.json` still ship as a pair.
