# Build 2026-11-07 18:48 — v0.3.4d "fixprime" (RD_PRIME_STAGE=1 fix experiment)

**Purpose:** decisive hardware test of the model-B core-side fix for the HDV
0x0184 read-back corruption. This build sets `RD_PRIME_STAGE=1` in
`apf_stream_video_top.v` (was `1'b0` in the 15:02 diagnostic build), enabling
the one-register local read stage in `hdv_bridge.sv` (`hdv_ram_word_q`).
Everything else is identical to the 15:02 diagnostic build (OVL_DEBUG=1 overlay
+ A5A5 OOB trace still on).

**Build ID:** `20261107 / 00183343 / 119af7f0`

## What changed vs the 15:02 build (v0.3.4c)
- `apf_stream_video_top.v`: `.RD_PRIME_STAGE(1'b0)` -> `.RD_PRIME_STAGE(1'b1)`.
- No other RTL delta. (`hdv_bridge.sv` already had the parameter + register from
  the earlier commit; this just turns the stage on.)

## Resources / timing (18:48 fitter + STA)
- Fitter: Successful. ALM **15,920**/18,480 (86%) — **+61 ALM** vs 15,859 (the
  now-live 32-bit `hdv_ram_word_q` register + 32-bit mux).
- Registers 15,143, pins 224/224, DSP 29, PLL 2.
- **Block memory bits 1,557,504 (gate exact, unchanged).**
- STA: TNS 0.000 (timing met on all domains).

## Artifacts
- Raw RBF: `src/fpga/output_files_apple2e/apf_stream_video.rbf`
  - 1,804,868 B, sha256 `7b1515ab3e03fc7448001689ada268fbde9ed8ee921bba82b8c70d75760345ff`
- Staged: `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r`
  - sha256 `ac147e849ffdeccc2924660de139c633603f36c27b424e64dff48d8d946465c2`
  - round-trip verified (staged == rev(src), rev(staged) == src).

## The experiment (Copy+ on a throwaway HDV)
| Image diff vs golden | Meaning | Action |
|---|---|---|
| **Byte-exact** | Model B (latency prime) — fix works | HDV writes become trustworthy; flip TB release gate to stage 1 (convert T8/T8c/T8d to prime+discard); ship the fix |
| **Shift worsens to k=2** | Model A (framework start-address bug) | Revert `RD_PRIME_STAGE`->0; framework ticket is the path; HDV writes stay untrusted |
| **Still k=1** | Unexpected (neither pure model) | Investigate |

## Status
Staged in `sd_root` (paired with current `interact.json` = Writable
EXPERIMENTAL, and `video.json` = 4:3 per owner's external test tweak). NOT a
shipping build (OVL_DEBUG=1). HDV writable-media trust remains blocked pending
this test result.
