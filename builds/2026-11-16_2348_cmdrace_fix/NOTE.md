# 2026-11-16 23:48 — savestate command-race fix build (DIAGNOSTIC — DO NOT SHIP)

- Contents: Steps 2-4 of EXPERT_BRIEF_SAVESTATE_WEDGE_MACH_SIDE_2026-11-16(-REVISION).md
  - savestate_slot.v (mtime 12:55:08): captured-token pender, per-command
    level-gated ack (no stale self-hold), rst_74a on all 74a command regs,
    100 ms handoff watchdog + sticky wd_err fast-ERR path.
  - core_bridge_cmd.v (mtime 12:55:23): registered request-hold gate
    (ss_start_req_q / ss_load_req_q) on 00A0/00A4 ack exit.
  - Flow: map 23:38:08 (after both edits => fix IS in this bitstream),
    fit Successful 23:48:36, asm Successful 23:48:58.
- Still carrying diagnostics: SSD/SSX/SS-lines, LED_TX=1, OVL_SS_DIAG,
  cartridge_adapter=0 (dev), IDLE_PERIOD=10s. Revert list unchanged.
- Fit: 17,974/18,480 ALM (97%), min slack +0.166 ns.
- rbf    sha256: 40df6f1aa0b32ef196d56af6bedcec584116c802c21fa87926542493401829b4
- rbf_r  sha256: 4b488af96d8d8eab3cc03a39bc55938945931d3d637a8d2cb525dda7134b7458
- Prior hardware result (12:02 build + this fix family): save #1 OK, single
  SS ST (race closed); LOAD fails fast with wr_ovf=1 => held second bug
  (hwr host-data path, integration G5/G6 class), NOT the command path.
- Staged to sd_root and K:\Cores\Newsdee.Apple2e (hash-verified identical).
