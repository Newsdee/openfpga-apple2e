# Known-good RBF — 2026-10-24 09:24 build (pre-closeout M1)

- Source: src/fpga/output_files_apple2e/apf_stream_video.rbf
- sha256: e46034c94fdbb6ae2d12d360c5040a97230562a4745308cff312de1842ef3cbf
- Staged bitstream.rbf_r sha256: 5bafbf84d4abbfcd719f577e093413f69adf226d4f2787ec4eb792a521823996
- RTL state: M1 closeout NOT included (no FP_DIAG gate, no "Reboot on disk change",
  no RAM clear of any kind; fingerprint overlay still always-on).
- Hardware verified: WOZ boot, fingerprint byte-exact vs PC oracle (CRC 74EA1324),
  DOS 3.3 + Jungle Hunt boot (screenshots 20261024_084738/084810).
- This is the last build proven to boot on the Pocket. If a later compile
  overwrites output_files_apple2e/ and the new RBF misbehaves, restore from here:
  copy this .rbf over output_files_apple2e/apf_stream_video.rbf, regenerate
  bitstream.rbf_r with tools/rbf2rbf_r.py, re-stage the card.
