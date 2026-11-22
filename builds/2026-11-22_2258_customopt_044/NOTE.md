# Build 2026-11-22 22:58 — 0.4.4 ship (joy2key per-slot Custom + profiles in release)

One feature/UX fix over the 0.4.3 tree:

1. **joy2key per-slot "Custom (.a2k profile)" options**
   (apf_stream_video_top.v + interact.json): DPad Keys value 5 and Fire
   Keys value 3 now select the loaded `.a2k` file as the source for that
   slot's table bytes (DPad = slots 0-3, Fire = slots 4-15), mixing
   freely with presets. Any non-Custom value ignores the file, so
   Off / any preset is a working off-switch for a loaded profile
   (0.4.3 glitch: a loaded profile could not be switched off).
   Custom with no file = blank slot. Behavior change for 0.4.3 users:
   a present profile no longer auto-activates - pick Custom once.
2. **joy2key profiles become tracked + shipped content**:
   sd_root/Assets/.../Joy2key/ (layouts + Game Specific\ + Others\,
   incl. off.a2k and tester.a2k), disk.a2k, and the Assets README are
   now git-tracked (gitignore exception; .woz/.hdv fixtures stay
   untracked). The 0.4.4 zip is the first release to ship the profiles.

## Results

- Fitter Successful 22:58, Standard Fit, DEVKEY_DIAG=0.
- ALM 11,226 / 18,480 (61 %) [+19 over 0.4.3], registers 12,829,
  RAM 202/308 (66 %), pins 224/224, DSP 29, PLL 2.
- STA: TNS 0.000 all corners (min setup slack 1.571 ns).

## Bitstreams

- `apf_apple2.rbf` SHA-256:
  `dd7a3924d4d17ab89328c53aec57c329d94efa38405f42dc73f821e4b4202ecf`
- `bitstream.rbf_r` (staged + to ship) SHA-256:
  `4b07f7ec9b84c6d463cfd30481de81cb9b03059c870423837dd89c7d8c3e3e93`

## Sim / HW status

- pocket_boot --smoke: elaboration + C++ compile clean; functional run
  pending (host AV Phase-2 killed the linked PE during 22:28-23:07;
  rerun: rm Vtb_pocket_boot.exe && bash build.sh && ./Vtb_pocket_boot.exe
  --smoke).
- HW gate (user): pending - verify UI shows 0.4.4; Custom option both
  sides; off-switch (profile + Off/preset = no keys); off.a2k profile;
  and whether the host "joy2key profile" picker shows the new
  Game Specific\ / Others\ subfolders.
