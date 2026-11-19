# Build 2026-11-18 23:15 (rbf 00:50) - MB x16 probe placement

RTL: audio fix (point-sample CDC + x16 MB gain) - the x16 volume tree.
Fitter seed actually used: 1 (default - the pinned seed was stripped by a GUI
project-save at 23:11, before the fitter ran at 23:15:52).

## Timing
- machine domain (mp2 divclk) SETUP slack: 0.685 ns
  (12:10 good build: 0.858 | 21:25 broken build: 0.547)
- 74a: 3.098 | bridge_spiclk: 10.67 | holds >= 0.329
- 15,781 / 18,480 ALM (85%), 16,901 regs, fitter successful

## Hardware result (2026-11-18/19)
WOZ floppy STILL FAILS (strong red LED, no load). => the working
machine-domain setup margin threshold is above 0.685 ns.
Next builds: re-roll placement, stage only when mp2 setup slack >= 0.8.
rbf: 5a9113a558de54feae6cc4b87229fb6697e8010ec9eb4c5f2426d2bf5c53edb8
rbf_r: 8d8564dcdb1a0e0c0aa1bf8b0dcaa8c730c08067b8773a2b61cb085c9c9211c6
