# 2026-11-17 09:02 — word_op_start attribution fix (DIAGNOSTIC — DO NOT SHIP)

- Contents: re-landed fix attempt 2 from
  EXPERT_BRIEF_SAVESTATE_LOAD_WR_OVF_2026-11-16.md §5 with the harness-wiring
  correction (tb_savestate_minirepro.sv now connects word_op_start; the first
  landing's "catastrophic G0" was the owner input tied 0 via PINMISSING):
  - io_sdram_pocket.v (08:48:32): word_op_start pulse at word-op dequeue
    (idle_gap removed/never landed).
  - sdram_word_owner.v (08:48:35): attribution on word_op_start instead of
    word_busy rising edge (pre-armed back-to-back ops no longer missed).
  - sdram_storage.v (08:48:37): ov_word_op_start wiring.
  - Flow: map 08:52:26 (after all edits => fix IS in this bitstream),
    fit Successful 09:02:27, asm Successful 09:02:48.
- Also carries: Steps 2-4 command-path fix (hardware-validated), all
  diagnostics (SSD/SSX, LED_TX=1, OVL_SS_DIAG, cartridge_adapter=0 dev,
  IDLE_PERIOD=10s). Revert list unchanged.
- Fit: 17,947/18,480 ALM (97%), mem 1,560,000 bits (49%), 199/308 M10K,
  min slack +0.629 ns.
- rbf    sha256: f1327da91b204bc7e01f11b54c3eae4001951d86b26a4ad92463dceeebd3cf8f
- rbf_r  sha256: 391df34381f7d05552f2302811d488e3e57639484e7847972288c7cf2d8dea5b
- Sim status at package time: TB re-run in progress (minirepro G0/G1 +
  integration were being re-validated with the corrected wiring).
- Expected hardware result: cold-boot LOAD completes (SS LD -> SS OK),
  wr_ovf (bit 20) stays CLEAR; saves continue to work.
- Staged to sd_root and K:\Cores\Newsdee.Apple2e (hash-verified identical).
