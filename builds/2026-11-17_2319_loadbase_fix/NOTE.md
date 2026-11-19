# 2026-11-17 23:19 — LOAD base fix: BLOB_BASE+1 → BLOB_BASE (DIAGNOSTIC — DO NOT SHIP)

- Root cause (resolved, EXPERT_BRIEF_SAVESTATE_LOAD_WROVF_HYPOTHESES_2026-11-17.md §10):
  the host's load-write STRIPS the file's stale leading word (window k <-
  stored[k+1] — observed via the 22:45 build's SS HD capture
  `SS HD 01000001 00000000`), so the window after a host round-trip is
  word-identical to the save-time window. The core's load base was
  BLOB_BASE+1 (2026-11-15 file-only decode, off by one word) → manager read
  {vercpu,size} where {size,counter} belongs → fail_code 2, instant ERR.
- Contents (vs previous build 2026-11-17_2245_sshd_diag, sha rbf_r
  cddf8189…):
  - savestate_slot.v: ssrd_base_sum = BLOB_BASE + 2a (the +1 REMOVED; load
    base now equals the save base) + header/inline comment correction.
    NOTE: the expert's proposed BLOB_BASE-1 was one word too far (would read
    the pre-window word and still fail at MAGIC) — not used.
  - savestate_manager.sv + slot: sticky last_fail_code latch — the SS HD
    errcode field now prints the TRUE code (E0 in the 22:45 capture was a
    1-cycle-pulse sampling artifact; true code was 2).
  - Everything from 22:45 carried: H2 queue persistence, Steps 2-4, devkey
    edge-latch, SSD/SSX + SS HD diagnostics, LED_TX=1, OVL_SS_DIAG,
    cartridge_adapter=0 dev, IDLE_PERIOD=10s.
  - build_id.mif: new ID (user touch).
- Flow: map 23:09, fit Successful 23:19:04, assembler Successful 23:19:25.
  Fix RTL mtimes 23:04 predate map start => fix IS in this bitstream.
- Fit: 18,210/18,480 ALM (99%), no failing endpoints, min slack +0.969 ns.
- rbf    sha256: 0954e53dfde1dd4f0926569f7c7a6b07b6cb4c82bcde3ed467d035c5f11ff103
- rbf_r  sha256: d25df3885e3cc4e78d9e02d35e1daeb983351602a566959c1e0de2b6618221b2
  (staged 23:2x to builds/, sd_root/, K:\Cores\Newsdee.Apple2e\ — all three
  hash-verified identical)
- Sim validation at package time (ALL post-fix):
  - integration (default, observed-host stripped model): PASS (G1..G6 incl.
    G5 real-file load — the exact hardware scenario)
  - integration +UNPACED (88-cycle worst case): PASS wr_ovf=0 load_ok=1
    magic_ok=1; scan SIZE@W1 MAGIC@W3 = the hardware host's exact layout
  - integration +UNPACED+HDRSHIFT: REPRODUCED (offset-0 hypothesis stays a
    valid discriminator)
  - roundtrip T0-T5: PASS (T3 error taxonomy updated to stripped layout)
  - minirepro G0: PASS; cmdrace 6/6: PASS; devkey: ALL CHECKS PASSED
- Hardware test: reboot, one save (expect SS OK), one load — EXPECT
  `SS LD` → busy polls → `SS OK` (the fix). If it still fails: SS HD now
  prints the true fail code (2=invalid, 3=incompatible) + header words.
