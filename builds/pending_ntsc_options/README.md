# Pending: stage the NTSC OSD-options build (core 0.2.5)

Held back deliberately. `sd_root/` currently ships the **0.2.4 hardwired-defaults**
image (`bitstream.rbf_r` sha256 `239eb666...`) with a **1-variable**
`interact.json`, so that the first hardware test isolates the video pipeline from
any bridge-decode change. Advertising options that the staged bitstream does not
implement would poison that test: switching Display Mode to Monochrome and seeing
no change looks exactly like "NTSC is broken".

The options RTL is committed (`8beaf2a`) and proven:

- `+opt_test` PASS against the real top - defaults 0/0, bridge writes reach
  `video_pipeline_q17`'s own `SCREEN_MODE`/`comp_preset` ports, and the
  `01F0xxxx` read-back wildcard still returns `cfg_reboot_word` unchanged.
  Non-vacuity verified by corruption (a hardwired `SCREEN_MODE` is caught).
- Compile 23:21 -> 23:30, 0 errors, 0 critical warnings: 9,034/18,480 ALMs (49%),
  8,153 registers, 1,544,220 memory bits (unchanged), 29/66 DSP, 2/4 PLLs,
  mp2 setup +1.123 ns, TNS 0.000, Unconstrained Clocks 3.
- Options rbf sha256 `75e2c3b3e142d6fe56690bd36f78db1b01b3934aff50226a9b3e1762e537ab5b`
  (from `src/fpga/output_files_apple2e/apf_stream_video.rbf` at 23:30). Note that
  output_files is overwritten by any later compile - rebuild before staging if
  this no longer matches.

## To stage, after the 0.2.4 defaults image passes on hardware

1. `cp builds/pending_ntsc_options/interact.json sd_root/Cores/Newsdee.Apple2eStreamVideo/`
2. Bump `sd_root/Cores/Newsdee.Apple2eStreamVideo/core.json` to **0.2.5** and drop
   the "hardwired defaults - hardware test image" wording from the description.
3. Rebuild if needed, then convert + stage the bitstream:
   `python tools/rbf2rbf_r.py src/fpga/output_files_apple2e/apf_stream_video.rbf output/bitstream_streamvideo.rbf_r`
   and copy to `sd_root/Cores/Newsdee.Apple2eStreamVideo/bitstream.rbf_r`.
   (`apf_stream_video_build.bat` does compile+convert+stage in one go.)
4. Record the new build under `builds/` per the existing NOTE.md convention.
5. On the card, delete
   `/Settings/Newsdee.Apple2eStreamVideo/Interact/interact_persist.json` before
   first run - persisted values are matched by ID, and IDs 4/5 are new.

## Manifest details that must not be lost

- Both options are `"writeonly": true`, so the host never reads `0x01F00004` /
  `0x01F00008`. That is what keeps the `01F0xxxx` read-back wildcard identical to
  its proven 09:26 form - the read-back mux arm is what the J7/J9 bisection
  implicated in disk-load failures. Do not add read-back support for these
  addresses without re-running that bisection.
- IDs are **4** and **5**, never 3: APF matches persisted values by ID and the
  removed Joystick option used 3, so reusing it would inherit a stale value.
- Display Mode labels follow the MEASURED semantics (plan addendum 9g):
  0=Colour (real NTSC decode), 1=Monochrome (B&W), 2=Green, 3=Amber. Modes 2/3
  are tinted-phosphor, still luma-driven - they are not artefact colour.
- Colour Preset labels come from the donor: 0=Calibrated, 1=Eyeballed, 2=Punchy,
  3=Muted (`machine/video/video_pipeline.sv:50`).
