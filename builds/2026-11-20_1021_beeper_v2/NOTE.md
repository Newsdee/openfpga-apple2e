# Build 2026-11-20 10:21 — beeper attenuation ladder v2 + delta console

Commits `1feca5a`->`75f7832`->`4a3c443` (0.4.0 + SSH/SO taps + delta
printing + beeper ladder v2). **DEVKEY_DIAG=1** (console live, now
delta-printed: idle 3 lines/2 s, on-change during activity). NOT
shippable until DEVKEY_DIAG=0.

## Changes vs 09:24

- Beeper ladder v2 (attenuation): 0=OFF, 1=x1/4 (default), 2=x1/2,
  3=x1 = the 0.3.6 pre-feature word bit-exactly. MB ladder untouched.
- Devkey console delta-printing (2 s heartbeat per tap line).
- A&S multi-driver fix: delta latches merged into the generator-FSM
  writer block (Error 10028 shape - Verilator merges, Quartus rejects).
  A&S now clean (10:11); remaining warnings all pre-existing vs 09:24.

## Results

- Fitter Successful 10:21, **Standard Fit**.
- ALM **17,063 / 18,480 (92%)**, registers 18,315 (09:24 was 16,989 /
  18,221 - the delta logic + beeper shifts).
- STA: mp2 setup slack **1.342 ns**, clk_74a 3.605, bridge 9.244,
  TNS 0 across clocks.
- Map: `u_devkey_uart` present (110 refs), `u_floppy_sound` present.

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `09886b4555d31777a80d4889e3eca96fb31239d611b23983daaa88e9eaabfe58`
- `bitstream.rbf_r` (staged) SHA-256:
  `dca462873b44692d5f44815df9748c7dcfb594db004c60a6ce47d832ee10f9d8`

## HW test focus

1. Beeper ladder: 3 = exactly the 0.3.6 beeper, 2 = half, 1 = quarter,
   0 = dead silent; all sitting below the maxed MB.
2. Console: near-silent at idle (3 lines/2 s), bursts on load.
3. Floppy + HDV loads (placement roll #9 on this netlist family).
