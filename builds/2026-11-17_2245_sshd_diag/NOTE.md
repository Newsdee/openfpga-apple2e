# 2026-11-17 22:45 — SS HD load-discriminator diagnostic (DIAGNOSTIC — DO NOT SHIP)

- Contents (vs previous build 2026-11-17_1134_h2_queue_persistence, sha rbf_r
  d0ae3f39…): everything from 11:34 is carried (H2 write-queue persistence,
  Steps 2-4 command-path fix, devkey edge-latch fix, all SSD/SSX diagnostics,
  LED_TX=1, OVL_SS_DIAG, cartridge_adapter=0 dev, IDLE_PERIOD=10s) PLUS the
  new **SS HD one-shot diagnostic**:
  - savestate_manager.sv (+6): latches the two 64-bit header reads
    (dbg_hdr0 = {size_dwords, counter}, dbg_hdr1 = {MAGIC, {ver,cpu}}) at
    LOAD_HEADER0/1.
  - savestate_slot.v (+7): passes dbg_hdr0/dbg_hdr1/error_code out.
  - apf_stream_video_top.v (+11/-2): wires both through to devkey_uart.
  - devkey_uart.v (+76/-2): EV_SSHD (id 14) — on the ss_busy_fall && ss_err
    edge of a failed load, emits ONE line after `SS ERR`:
    **`SS HD <hex8 size field> <hex8 MAGIC field> E<errcode>`** (28 chars,
    gated on txf_empty; line[] widened 36→48).
    Expected readings (from EXPERT_BRIEF_SAVESTATE_LOAD_WROVF_HYPOTHESES_2026-11-17.md §9):
      - H6 (host streams .sta from file offset 0): `SS HD 54030200 672575BE E2`
      - H4 (nothing landed):                     `SS HD 00000000 00000000 E2`
  - build_id.mif: new ID (user touch, 22:32).
- Flow: fit Successful 22:44:45, assembler Successful 22:45:06. All four SS HD
  RTL edits (mtimes 12:02-13:12) predate the flow start => diagnostics ARE in
  this bitstream.
- Fit: 18,264/18,480 ALM (99%), +239 ALM vs 11:34 (SS HD diagnostic). Timing
  met, min slack +0.325 ns.
- rbf    sha256: 4f057ccf6100b8b95d14049d5b73b4da24922d4b51c6ab7dacdc6e3e449cd1fd
- rbf_r  sha256: cddf8189807312dcd7fbafd4f207518ea6d115f0aaedfadefa83078129edcf87
  (staged 22:4x to sd_root/ and K:\Cores\Newsdee.Apple2e\, all three copies
  hash-verified identical)
- Sim validation at package time (this tree):
  - tb_devkey_uart: ALL CHECKS PASSED (incl. the exact
    `SS HD 00008040 41324C31 E2` line on a synthetic failed load).
  - integration: PASS; +UNPACED: PASS (wr_ovf=0 load_ok=1);
    +UNPACED+HDRSHIFT: **REPRODUCED** (H6 shape: wr_ovf=0, immediate ERR,
    SIZE/MAGIC at window words 150/152).
  - cmdrace 6/6, roundtrip PASS, minirepro G0 PASS.
- Hardware test procedure: reboot card, one save (expect SS ST → busy polls →
  SS OK), then one load (expect SS LD → SS ERR → **SS HD …** line). The SS HD
  line decides H6 vs H4. (wr_ovf must stay clear on ID lines — H2 regression
  check.)
