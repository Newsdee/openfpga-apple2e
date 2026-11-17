# 2026-11-17 11:34 — H2 write-queue persistence fix (DIAGNOSTIC — DO NOT SHIP)

- Contents (vs previous build 2026-11-17_0902_wordopstart, sha rbf_r 391df343…):
  - io_sdram_pocket.v (10:28): WRITE-QUEUE PERSISTENCE (H2 fix per
    EXPERT_BRIEF_SAVESTATE_LOAD_WROVF_HYPOTHESES_2026-11-17.md review 2,
    mechanism (a)): word_wr_queue no longer clears when the request level
    falls — once queued, only the dequeue clears it (write-side twin of the
    READWEDGE Layer-1 semantics). Explicit init + deterministic reset added.
  - savestate_bridge.v (10:43): touched in the same session (no functional
    FSM change observed vs the 2026-11-16 reworked WR FSM).
  - Everything from the 0902 build is carried: word_op_start attribution fix,
    Steps 2-4 command-path fix (hardware-validated), all diagnostics
    (SSD/SSX, LED_TX=1, OVL_SS_DIAG, cartridge_adapter=0 dev, IDLE_PERIOD=10s).
- Flow: fit Successful 11:21:18, assembler Successful 11:34:10 (edits 10:28/
  10:43 predate map => fix IS in this bitstream).
- Fit: 18,025/18,480 ALM (98%), registers 17,270, mem 1,560,000 bits (49%),
  199/308 M10K, 29/66 DSP, min slack +0.670 ns.
- rbf    sha256: efe0aa733a440890311c6fe8d4ff5e5e336c1b69fed2bfd4bc1fa657f719ddd1
- rbf_r  sha256: d0ae3f395fa3ae003de5080d77240af21b297538cf2297701e47acc03409eccf
- Sim validation at package time (ALL post-edit builds):
  - integration TB: PASS incl. the NEW UNPACED gate —
    `UNPACED-VERDICT gap=88 wr_ovf=0 load_ok=1 load_err=0 magic_ok=1`
    (32,833-word blob at the documented 88×74a bridge rate, posted, no
    backpressure; MAGIC + SIZE found in window; load completes ok=1).
  - roundtrip: PASS (T0-T5). cmdrace: 6/6 PASS.
  - minirepro: G0 PASS; G1 = 5 pre-existing aa000000 baseline failures
    (known, separate workstream), 0 wedges.
  - M0/M1 ladder: 9/10 ran green per console (bridge_storage incl., ~17 min
    sim); tb_woz_machine still executing at package time (CPU-bound, healthy).
- Expected hardware result: cold-boot LOAD completes (SS LD -> SS OK),
  wr_ovf (bit 20) stays CLEAR; saves continue to work (no regression).
- Staged to sd_root and K:\Cores\Newsdee.Apple2e (hash-verified).
