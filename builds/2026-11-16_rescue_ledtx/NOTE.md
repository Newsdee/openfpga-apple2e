# Build 2026-11-16 ~09:27 — rescue LED build (devkey UART link rescue attempt)

DIAGNOSTIC BUILD — do not ship. Carries `devkey_uart #(.LED_TX(1))` plus the
registered-LED / debounce fixes for the floating-A0 storm.

## What it contains (vs the 2026-11-15 23:07 discovery build)

- `devkey_uart.v`:
  - Registered LED (`led_r`): no combinational path from any input
    (including floating A0/button) to any pad in any mode.
  - Raw `btn_s2` removed from the LED in all modes; replaced by a
    debounced ~100 ms press flash (`btn_flash`).
  - BTN TX event gated by 1 ms solid-press debounce (`btn_db`) — the A0
    crosstalk storm (half-period 87 clk) can never fire it.
  - `LED_TX=1` here: mirrors the `uart_tx` stream onto the LED pin (/RD,
    bank0[5]) so the ID/status text rides BOTH /WR and /RD.
  - `rx_blink` OR-term width fix (`(rx_blink != 14'd0)`) — a bare 14-bit
    counter in a 1-bit OR would have re-radiated a 74 MHz edge storm on
    the pad (review catch, 2026-11-16).
  - `DISCOVERY` parameter retained at default 0 (pruned).
- `apf_stream_video_top.v`: `devkey_uart #(.LED_TX(1)) u_devkey_uart`
  (REVERT-for-shipping comment at the instance).

Root cause it addresses: the ~5.76 kHz "wall of garbage" on the dev-key
UART line was the core's own LED pin re-radiating the floating A0 button
line (`btn_s2` ORed into `led`, combinational; A0 floats and edge-storms
when a core runs). See `docs/EXPERT_BRIEF_DEVKEY_UART_AB_RESULTS_2026-11-15.md`
§9.

## Build facts

- Raw rbf: sha256 `4748115221e58498cbc534c2175d33f26011ea8d7ec938b53aed50ff5d21b22e`
  (1,871,756 bytes) — `src/fpga/output_files_apple2e/apf_apple2.rbf`
- Staged rbf_r (Perl bit-reversal, validated):
  sha256 `6e6487d688033dbd0e219256bee1990a6b46be9d0584b0fb5124f67182acd02d`
  → `sd_root/Cores/Newsdee.Apple2e/bitstream.rbf_r` + `K:\Cores\Newsdee.Apple2e\`
- Fit: 17,642 / 18,480 ALM (95%), 16,128 registers, Fitter Successful
  2026-11-16 09:26:57, Quartus 17.0.2 Build 602 Lite. (Diagnostic-level
  utilization: `OVL_SS_DIAG=1` overlay still in this tree.)
- Verilator: `run_tb_devkey_uart.sh` PASS 11/11 (before and after the
  rx_blink width fix); width lint clean on the `led_r` line.
- Card manifests (`core.json` etc.) were already identical to sd_root;
  only the bitstream was synced.

## Bench result (2026-11-16 ~10:00) — DEAD END (clean)

`tools/com4_probe.ps1` at 115200/116015/57600/230400/9600: no ID/banner
text at any rate. The wire carries a periodic ≈7.25 kHz signal
(period 16 bits @ 116015, 32 @ 232050; perfect autocorrelation) =
**116,015 / 16 = the CP210x's own 16× oversample bit clock** — a
dongle-internal artifact on a floating/mis-routed RXD pin. A/B bench test:
the 7.25 kHz is present WITH AND WITHOUT a core loaded → not core-gated.

- The old 5.76 kHz A0-storm re-radiation is GONE (fix worked; its
  masking confound is gone too).
- RXD is not on /WR (uart_tx), /CS2 (discovery), or /RD (this build,
  now storm-free) — all three drivable fingers eliminated without
  confounds.
- **The dev-key UART link is unfixable in core RTL on this
  board/dongle revision. Effort put aside 2026-11-16.** Savestate
  observation continues sim-side (minirepro TB — the reproducible
  failure there is the owner↔port write-handshake desync, see
  `docs/EXPERT_BRIEF_SAVESTATE_MINIREPRO_TB_2026-11-15.md` §8).

## Ship discipline (for any future release from this tree)

- Revert `apf_stream_video_top.v` to plain `devkey_uart u_devkey_uart (`
  (LED_TX=0; comment is at the instance).
- `OVL_SS_DIAG` → `1'b0`; `cartridge_adapter` → -1 in `core.json`.
- The `DISCOVERY` parameter stays in `devkey_uart.v` (default 0, pruned)
  for future boards with correct UART routing.
- New caveat for future boards: a CP210x emits a 16×-baud clock artifact
  on RXD when the pin floats — wire probes must distinguish it (present
  with no core loaded) from real core signals.
