# Build 2026-11-20 09:24 — SSH/SO transport diagnostic (NOT shippable)

Commit `4ae91bd` on `main` (0.4.0 + SSH/SO taps). **DEVKEY_DIAG=1**:
devkey_uart console live on the debug_key pads at 115200 8N1. Revert
to 1'b0 before any shipping compile.

## What it is

Known-bad-tree instrument (23:31 ladder netlist + console) to capture
the shared host->machine region live while the WOZ-floppy + HDV load
failure reproduces (EXPERT_BRIEF_AUDIO_SLIDERS_TRANSPORTS step 2).
New 20 Hz idle lines (phase-cycled SSY/SSH/SO/SSY):
- `SSH s<state> f<fault> E<err> d<ds_done> e<ds_err> c<hex16{fetch,wrcnt}> w<hex2{mnt,prot}>`
- `SO <hex1>` = {fc_req, word_busy, fetch_busy, sector_ready, ssrd, sswr, hr, hwr}
- existing `SSY` (WOZ feed) + `SSD`/`SSX` lines unchanged.

## Results

- A&S Successful 09:14; Fitter Successful 09:24, **Standard Fit**.
- ALM **16,989 / 18,480 (92%)** — the console + taps add ~910 ALM over
  the 23:31 netlist (16,079); register count 17,105→18,221. If the
  transports PASS this build, the extra congestion is a confound (the
  capture still stands: state is live on the console); if they FAIL,
  the SSY/SSH/SO lines at the moment of failure are the data.
- STA: mp2 setup slack **1.683 ns**, clk_74a 3.673, bridge 9.078,
  TNS 0 across all clocks.
- Map: `u_devkey_uart` present (97 refs), `u_floppy_sound` present.

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `0b0752931650eed67b7a2dd84a25bbbd9ef7d9afcc6cdf4cc2be2178e98d8aea`
- `bitstream.rbf_r` (staged) SHA-256:
  `5a408bcbf55a489fbc64da80d4b04a983b13072c8dd7006f46304cfc4d59a3a0`

## Session plan

1. Console attached (115200 8N1, debug-key dongle), capture the
   repeating SSY/SSH/SO lines while a floppy load AND an HDV load
   fail (or succeed - both are data).
2. Beeper A/B: swap in `interact_beeper_swap.json` (on the card),
   power-cycle, walk both volume sliders - whichever sound follows
   the other slider's position names the dead side (Pocket not
   writing 0x2C vs RTL ignoring it).
