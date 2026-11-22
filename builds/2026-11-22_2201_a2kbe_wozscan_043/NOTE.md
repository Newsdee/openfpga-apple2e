# Build 2026-11-22 22:01 — 0.4.3 ship (a2k BE capture + WOZ scan-window flux)

Two bug fixes over the 0.4.2 tree (HDV M10K roll-4):

1. **joy2key .a2k capture unpacked big-endian** (apf_stream_video_top.v):
   the host DMAs file words big-endian (first byte in [31:24], the same
   convention as the WOZ/HDD paths); the capture read them little-endian,
   so every 4-byte group of the profile table was byte-reversed on the
   real device. Found 2026-11-22 in hardware via a 16-byte label-test
   profile (every press typed a different slot's label — the exact
   permutation measured: per-word reversal). The sim masked it because
   the TB host model wrote LE words matching the wrong unpack (same trap
   as the HDV 0x0180 fix, 9c05450).
2. **WOZ scan-window non-silent flux** (woz_floppy_controller.sv):
   between mount and woz_valid, bit_count=0 gave total flux silence ->
   RWTS timeout -> "I/O ERROR" flake (mechanism B'). During the scan
   window the controller now presents nominal 40,000 bits with a
   deterministic transition-rich pattern. See
   docs/ADDENDUM_WOZ_LOAD_IOERR_SCAN_WINDOW_2026-11-22.md.

## Results

- Fitter Successful 22:01, Standard Fit, DEVKEY_DIAG=0.
- ALM 11,207 / 18,480 (61 %), registers 12,839, RAM 202/308 (66 %),
  pins 224/224, DSP 29, PLL 2.
- STA: TNS 0.000 all corners (min setup slack 1.162 ns).

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `6560c2fe16f4a5f104acdcbf621cbadae1bfa5a2fff253cde5ae69a487d15cac`
- `bitstream.rbf_r` (staged + shipped) SHA-256:
  `e4ae03a2c3ca8e6c0c1741cdeb47d7cafde0bb4690a6c63712de136c8f5a0ef5`

## HW test (2026-11-22)

1. joy2key label-test profile: every button types its own letter
   (up=U down=D left=L right=R A=A B=B L=O R=P X=X Y=Y;
   Select layer C/D/M/N/W/V).
2. MiSTer-equivalent profile (ThunderbirdsGX): up='A', down=Space,
   left=<- right=->, L=Enter, R='S' — matches the MiSTer core.
3. WOZ disk load (the I/O ERROR flake scenario): clean.

Result: PASS on all three — **0.4.3 released from this build**
(`Apple2e_Pocket_0.4.3.zip`).
