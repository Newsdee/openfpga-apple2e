# Build 2026-11-19 09:13 - SSY WOZ feed diagnostic (DIAGNOSTIC - DO NOT SHIP)

Purpose: EXPERT_BRIEF_WOZ_FLOPPY_HW_REGRESSION_2026-11-19.md action C -
serial capture of the WOZ nibble-feed taps on a failing bitstream to show
WHERE the feed dies (H6-flavored adjudication: specific marginal path).

Tree: MB audio fix (x16) + SSY tap set:
- devkey_uart.v: SSY line, 32 chars, 20 Hz while idle:
  SSY s<mstate> m<mounted> a<D1_ACTIVE> q<woz_sd_rd> k<sd_ack> f<tfault> b<sd_buff_wr> d<reads[15:0]>
- apf_stream_video_top.v: ssy_snap (machine-domain word, one toggle cross to 74a)
  inside g_devkey_diag; DEVKEY_DIAG sub-module default 1.
- apf_top_apple2.v: TOP-LEVEL DEVKEY_DIAG = 1 (the effective switch - the
  08:57 build flipped only the sub-module default and came out console-less,
  byte-identical placement to the 00:51 probe).

## Build facts
- devkey_uart verified in map hierarchy (94 refs incl. u_devkey_uart|gen_state)
- 16,551 / 18,480 ALM (90%), 17,930 regs, fitter successful
- STA: mp2 (machine domain) setup 0.253 ns (worst yet - console added),
  74a 2.214, spiclk 9.668, mp1 33.45. TNS=0 (met on paper).
  Expected to fail floppy the same way; that is the point of the capture.

rbf:   (see bitstream.rbf)
rbf_r: b179d65204461efa422678e63c7dc6f22bb15bfa72bec7483053bfe760457385

## Capture procedure
1. Power-cycle Pocket, .woz selected, dev-key dongle connected.
2. Let it retry the floppy ~30-60 s; grab the serial (115200 8N1).
3. Decode per the brief: s=0 => never mounted (host side); s=1 q=0 => engine
   never requests; q=1 k=0 => no transport ack; f=1 => fault latched;
   d frozen => no bytes moved; d climbing => feed alive, bug above it.

## Hardware result (2026-11-19)
- WOZ floppy load: WORKS (despite 0.253 ns mp2 slack - worst of all builds).
- MB audio x16: WORKS, "sounds like I expected" (x16 gain hardware sign-off).
- devkey UART: silent on PuTTY (dongle-side; the 22:45 build decoded fine on
  the same dongle). SSY capture not obtained.
- CONSEQUENCE: the mp2-slack acceptance gate is refuted (0.858 pass / 0.547
  fail / 0.685 fail / 0.253+console PASS). The WOZ feed is
  placement-specific (H6); shipping gate = hardware floppy test per build.
- Do-not-ship status stands (console on, 90% ALM, 0.253 margin) - this was
  the capture vehicle, and it doubled as the luckiest placement draw yet.
