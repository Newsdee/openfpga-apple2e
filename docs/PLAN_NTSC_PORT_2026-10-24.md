# Pocket NTSC color port: coder handoff

Date: 2026-10-24  
Status: implementation plan only; no RTL or build changes made.
Updated 2026-10-24 with the findings of the companion review
[`DESIGN_NTSC_COLOR_PORT_2026-10-24.md`](DESIGN_NTSC_COLOR_PORT_2026-10-24.md);
that note is now subordinate to this plan (its resource estimates are
superseded by the donor-measured figures in section 7 below).

## 1. Objective and scope

Port the active MiSTer Apple II NTSC color path into the Pocket streaming
core. Preserve machine execution, WOZ disk boot, native 560x192 streaming,
OSK colors/transparency, and existing controls.

Implement NTSC before save states. This milestone is a rendering change,
not a CPU, memory, storage, or display-framebuffer redesign.

Recommended initial configuration, to confirm with the owner before coding:

- NTSC-only color renderer with one fixed donor preset: Calibrated
  (`comp_preset=0`), zero fine adjustments, two-line comb enabled.
- Keep the existing raw monochrome path as a compile-time fallback.
- No runtime video menu in this milestone. Once hardware is accepted,
  decide whether to add preset selection or monochrome switching.

These are recommendations, not previously approved UI/configuration choices.
Do not interpret "NTSC-only" as removing the existing monochrome recovery path.

Out of scope:

- RGB-monitor mode as a user-selectable renderer; palette loading.
- PAL, 280-pixel decimation, new aspect modes, scanlines, CRT effects.
- Full-frame buffers, PSRAM use, new PLLs, or SDRAM arbitration changes.
- Save states, sleep/resume, audio changes, disk writes, second drive.
- The pending fingerprint-overlay and disk-insert/reset changes in the
  [M1 handover](HANDOVER_M1_POST_FINGERPRINT_2026-10-24.md).
- Cleanup or tuning of unrelated donor behavior.

## 2. Baseline and source of truth

Workspace: `E:\MiSTer\Apple-II_FPGAdev`.

| Item | Reviewed baseline |
|---|---|
| Pocket repository | `apple2e-pocket`, HEAD `b9fe19562f0ae56e2404ebd9463b12728313639a` |
| MiSTer donor | `Apple-II_MiSTer`, HEAD `168f8f7f75569213395e191c4b947d341d45485b` |
| Latest donor video commit | `9665447`, 2026-10-12, "Video reorg: 8 graphics presets" |
| Active Pocket revision | `apf_stream_video`, top entity `apf_top_stream` |
| Device/toolchain | Cyclone V `5CEBA4F23C8`, Quartus 17.0.2 Lite |
| Latest Pocket fit reviewed | 2026-10-24 09:24:04, successful |
| Hardware baseline | M1 handover records DOS 3.3 and Jungle Hunt booting on October 24 |

Recheck HEAD, worktree, report timestamps, and intervening user changes before
implementation. At review time the M1 handover was an existing untracked file:
preserve it. The donor video worktree was clean **at review time; it is not
clean now** - see the annotation note in section 3. Recheck before copying.

Read [README](../README.md), the workspace
[lessons](../../docs/lessons_learned.md) and
[supplement](../../docs/lessons_learned_2026-09_additions.md).
Some old README sections, source headers, and build-script messages still call
the streaming core a prototype; use the active QSF and current wiring as truth.
Do not develop in the deprecated `Apple-II_MiSTer_newsdee` sibling.

### Current hardware boundaries

- [Streaming top](../src/fpga/core/apple2e/apf_stream_video_top.v):
  65C02, 64 KiB main plus 64 KiB aux, native one-bit video, single read-only WOZ.
- Machine/video domain: `clk_core_14318`, approximately 14.318 MHz.
- APF pixel-clock outputs: that clock and its existing 90-degree PLL output.
- `machine_reset`: synchronized host reset, synchronized PLL unlock, or OSK
  command reset. `osk_reset` excludes the OSK's own command reset.
- Host bridge and SDRAM have separate domains. The NTSC port must not enter
  those domains or alter their reset/clock behavior.
- [OSK adapter](../src/fpga/core/apple2e/apple2e_osk.v) currently expands
  one-bit input to RGB888 before the shared overlay.
- [Streaming adapter](../src/fpga/core/apple2e/apf_stream_video.v) ships with
  `DEC2X=0`; RGB is already 24 bits end-to-end.

Current order: raw video -> OSK -> storage/status overlay -> APF adapter.
Preserve that overlay priority.

## 3. Donor reuse and file plan

Use these files from the pinned active donor:

| Donor file under `Apple-II_MiSTer\rtl\video` | Purpose |
|---|---|
| `video_pipeline.sv` | Presets, color-kill logic, native sync generation, output alignment |
| `apple_composite.sv` | One-bit video -> signed composite samples; burst generation |
| `composite_decoder.sv` | Luma/chroma separation, burst tracking, YIQ-to-RGB |
| `vga_controller.v` | Elaboration dependency of the unmodified pipeline. **It is NOT a line-doubler** despite its own header comment - see the correction below |

Recommended first implementation: copy these four files byte-identically into
`machine\video` and instantiate the existing pipeline with `use_composite=1`.
Tie unused palette-download inputs to sized constants and leave `ioctl_wait`
unconsumed. **Prove it is inert rather than assuming it:** assert in N1 that
`ioctl_wait` never rises with the download inputs tied off. If it can assert, it
is a backpressure signal into a path the Pocket does not service, and tying it
off silently would be a hang, not a no-op. Also confirm no `data.json` slot is
required (the Pocket machine `ioctl_*` ports are tied to zero today); if a
palette/ROM download turns out to be mandatory, that is a packaging change and
must be re-scoped before RTL work starts. Quartus should remove the unobserved RGB renderer. **Verify this in
the map/fit hierarchy; do not merely assume it.**

Evidence that the removal claim is sound (checked in the donor source, so the
gate above is a confirmation rather than a discovery): `apple_composite` is fed
`.video(VIDEO)` - the raw one-bit machine signal - **not** `r_vga`. The encoder
does not consume the RGB renderer at all. With `use_composite=1` and
`SCREEN_MODE=2'b00` both constant, `video_pipeline` selects `r_comp/g_comp/b_comp`
and `hs_c_s/vs_c_out/hb_c_s/vb_c_out`, so `r_vga/g_vga/b_vga/r_mono/g_mono/b_mono`
and `hs_vga/vs_vga/hbl_vga/vbl_vga` are all unobserved and the whole
`vga_controller` instance should fold away. If the map report shows it retained,
look for a live output or a non-constant select before touching any math.

### Correction: `vga_controller.v` is not a line-doubler (do not plan a doubled raster)

The donor file header reads "A VGA line-doubler for an Apple ][". **That comment
is wrong** and it already caused one reviewer to plan for a doubled 560x384
raster at 28.636 MHz, implying a second PLL output, a new APF raster and new
`video.json` presets. Verified against the body:

- `hcount`/`vcount` free-run on `CLK_14M` at native machine geometry.
- `assign VGA_HBL = ~filtered_timing_active;` / `assign VGA_VBL = vbl_delayed;`
  - native blanking, no line repetition, no second clock.
- `previous_line_rgb[0:559]` x 24 b is a **one-line comb/artefact history**, not
  a doubling buffer.
- `video_pipeline.sv` derives composite sync "from machine blanking using
  **native** geometry" (`HSYNC_FRONT_PORCH=130`, `HSYNC_WIDTH=68`,
  `VSYNC_FRONT_PORCH=33`, `VSYNC_LINES=3`).

**Consequence for this port: `video_pipeline` is a native-rate, `CLK_14M`-domain,
560x192 RGB producer** - exactly the clock and raster the Pocket already streams.
Therefore: **no new PLL, no raster change, no `video.json` change, no manifest
geometry change.** The deployed `video.json` already declares 560x192 with three
aspect presets (10:9, 4:3, 70:24) and stays as-is. Treat any plan that adds a
pixel clock as based on the stale comment.

The donor comment has been **annotated in place** at
`Apple-II_MiSTer/rtl/video/vga_controller.v` (comment-only; every changed line is
a `//` line; no logic touched; CRLF preserved). This means:

- the donor worktree is **dirty** relative to the recorded HEAD `168f8f7`;
- byte-parity checks still pass **provided the copies are made after the
  annotation** - copy from the current worktree, or commit the annotation in the
  donor repo first and re-record the donor HEAD here;
- do not "restore" the donor file to clean and lose the annotation, or the next
  engineer repeats the doubled-raster error.

Owner decision needed: commit the annotation in `Apple-II_MiSTer` (preferred -
it is a documentation fix to a live misleading comment) or revert it and carry
the warning only in this plan.

This approach preserves the difficult timing wrapper rather than extracting a
second, subtly different NTSC implementation. Importing the RGB source as an
elaboration dependency is not permission to retain RGB hardware or expose it
as a feature. If synthesis does retain it, first identify the live output or
nonconstant select; consider extraction only with differential proof.

| Pocket file/surface | Planned action |
|---|---|
| `machine\video\` | Add pinned canonical donor sources; retain licenses |
| [check_machine_sync.sh](../check_machine_sync.sh) | Extend existing parity check to the four donor files |
| `machine\\video\\NOTICE.md` (new) | Pinning policy for the imported video files, mirroring `src/fpga/core/woz/NOTICE.md` |
| [streaming top](../src/fpga/core/apple2e/apf_stream_video_top.v) | Instantiate pipeline and select complete RGB/blanking bundles |
| [OSK adapter](../src/fpga/core/apple2e/apple2e_osk.v) | Accept RGB without changing input behavior or canonical overlay |
| [active QSF](../src/fpga/apf_stream_video.qsf) | Register new sources with correct Verilog/SystemVerilog types |
| [APF adapter](../src/fpga/core/apple2e/apf_stream_video.v) | Prefer no logic change; consume selected, aligned blanking |
| [status overlay](../src/fpga/core/apple2e/sdram_status_overlay.v) | Prefer no logic change; connect selected blanking at its instance |
| `verilog\tb` and build runners | Differential tests, shipping-path integration, regression coverage |
| [README](../README.md), [simulation README](../verilog/README.md) | Document configuration, exact commands, results, and limitations |

Find every `apple2e_osk` caller, including legacy tops and TBs, before changing
its interface. Preserve monochrome callers explicitly. Either keep a
compile-time compatibility mode or update each caller to supply the original
black/white RGB expansion; choose the smallest complete change.

**Add a `machine\\video\\NOTICE.md`** recording the pinning policy, in the same
shape as `src/fpga/core/woz/NOTICE.md`: the four files are byte-pinned from
`Apple-II_MiSTer` at a recorded donor revision; no local edits; any required
divergence is a numbered, justified exception. That discipline already paid for
itself during M1 - the question "has anyone modified the pinned engine?" was
settled with one `diff` (byte-identical, with exactly the one documented
`disk_ii_woz.sv` exception). The video files are the same risk class: the donor
video path is still moving (preset changes as recently as 2026-10-12, `9665447`),
and these become a third copy in the workspace alongside the deprecated
`Apple-II_MiSTer_newsdee` archive. Record the donor revision in the NOTICE, and
note the `vga_controller.v` comment annotation above as a known local delta if it
is not committed in the donor.

All Pocket-specific adaptation belongs in the thin wrapper and the top-level
wiring, never in the pinned files. `apple2e_osk.v` changing its background input
from one-bit to RGB is a Pocket-wrapper change and is explicitly allowed;
`machine/osk/virtual_keyboard_overlay.sv` and `virtual_keyboard_controller.sv`
stay byte-identical to MiSTer per the existing mirrored-file rule.

Do not alter canonical OSK/controller/font behavior. Preserve
`pixel_clock_double=1`, reset separation, debounce, release confirmation,
key mapping, transparency levels, and top/bottom placement. Leave legacy
one-bit output behavior intact for harnesses that still use it.

## 4. Signal contract

New logical flow, entirely in the machine clock domain:

```text
apple2 native VIDEO/HBL/VBL and mode flags
              |
              v
video_pipeline [use_composite = constant 1]
              |
              v
{RGB888, HBL_O, VBL_O}
              |
              v
compile-time selection against {raw black/white RGB, raw HBL, raw VBL}
              |
              v
OSK -> existing diagnostic overlay -> apf_stream_video [DEC2X=0]
              |
              v
unchanged APF DDR output / Pocket scaler
```

Wire live native flags from the existing `apple2` outputs, including
`COLOR_LINE`, `TEXT_MODE`, `EARLY_VIDEO`, `HGR_MODE`, `HGR80_MODE`, `GR2`,
`COL80`, `DHIRES_MODE`, and `RUN_FILL_OK`; do not reconstruct them from pixels.

Initial fixed controls for the recommended baseline:

| Pipeline input | Setting |
|---|---|
| `CLK_14M` | `clk_core_14318` |
| `reset` | `machine_reset` |
| `machine_ce` | Explicitly connected to the present always-running machine enable |
| `use_composite` | `1'b1` |
| `SCREEN_MODE` | `2'b00` (color; line color-kill still applies) |
| `LO_RES_TEXT` | `1'b1` (donor text color suppression) |
| `comp_preset` | `2'd0`, subject to owner confirmation |
| `comp_hue_adj` | `5'd0` |
| `comp_bright_st`, `comp_sat_st`, `comp_contrast_st` | `2'd0` each |
| `NTSC_VERTICAL_COMB` | `1'b1`, subject to owner confirmation |
| `COLOR_PALETTE` / ioctl inputs | Explicitly sized constants; no custom loader |

Do not copy literal color values from old comments or from the first preset
case alone. The donor assigns `p_*` values and then overrides several from
`comp_*` later in the same combinational block. The **effective final values**
are the contract; use the pinned pipeline as the executable reference.

Preserve signed widths and truncation points, `SPC=4`, decoder pixel rate,
burst-window phase, and the encoder/decoder reference relationship.
Do not narrow arithmetic or retune the YIQ matrix to save ALMs in this port.

### Timing and reset requirements

- RGB and its associated HBL/VBL travel together through path selection and
  overlays. Do not combine delayed decoded RGB with raw machine blanking.
- Preserve donor mode-dependent horizontal alignment, including HGR80 and
  smoothing tap selection. Do not replace it with one guessed latency.
- The APF adapter generates Pocket-format one-clock HS/VS pulses from selected
  blanking. Do not drive donor HS/VS directly onto APF.
- Check that delayed VBL transitions still satisfy the adapter's requirement
  that VS be generated during horizontal blanking.
- Preserve all 560 pixels, all 192 active lines, and first/last content edges.
  Derive line timing from the actual machine, not stale 910/912-clock comments.
- Decoder reset is synchronous; the existing APF adapter reset is asynchronous.
  Do not change their styles casually. Some donor phase/history registers
  recover from line events rather than explicit reset: measure startup and
  reset recovery instead of assuming every register resets.
- Keep `machine_ce` explicit for future save-state work. Exercise a coherent
  source/decoder pause in unit tests, but do not freeze the live machine or
  claim APF pause/sleep support in this milestone.
- If recovery needs a validity gate, preserve a legal output raster while
  masking invalid RGB. Never "fix" startup by indefinitely suppressing DE.

## 4a. Sequencing and file collisions with the open M1 follow-ups

Section 1 lists the pending fingerprint-overlay and disk-insert/reset work as out
of scope. Correct - but **out of scope is not the same as unordered**, and both
M1 follow-up tasks edit files this port also edits. Landing them concurrently
guarantees a collision in exactly the modules that are hardest to re-verify.

| M1 follow-up task | Files it touches | Collides with this port on |
|---|---|---|
| Task 1 - gate the fingerprint overlay behind `FP_DIAG`, default OFF | `sdram_status_overlay.v`, `disk_verifier.v`, `sdram_storage.v`, `apf_stream_video_top.v` | the RGB chain and the top-level file |
| Task 2 - cold reset on disk insert, optional per game | `apf_stream_video_top.v` (`machine_reset`, `ram_main`/`ram_aux`), `apple2e_osk.v` (new command key), `data.json` (`parameters` 73 to 0x09) | `apple2e_osk.v` and the top-level file |

**Required order:**

1. **M1 Task 1 first.** It is small and self-contained, it removes four always-on
   diagnostic text lines (rows 65-95) from the screen, and it means the colour
   work is validated against a clean, stable overlay rather than one that is
   changing underneath it. Doing colour first would force every capture and every
   overlay regression to be interpreted with diagnostic text on screen.
2. **Then this NTSC port.**
3. **Then M1 Task 2** - or in parallel only if a different person owns
   `apple2e_osk.v`, since section 3 of this plan also changes that file (RGB
   background input). One owner per file at a time.

If the owner wants the NTSC port to start immediately, the minimum precondition
is that Task 1 is merged and its overlay TBs pass in both `FP_DIAG` states.

## 5. Implementation stages and exit gates

### N0 - Record baseline; establish executable reference

1. Confirm the recommended preset, comb setting, and compile-time fallback
   with the owner. Record baseline revision, dirty files, and report provenance.
2. Capture monochrome shipping-path simulation output and existing warning
   baseline before changing integration.
3. Set up a small donor-versus-candidate TB using the pinned donor pipeline
   as reference. Avoid same-name module collisions by separate builds/traces
   or a simulation-only wrapper arrangement.
4. Use identical clocked native video and mode stimuli on both sides. Include
   real machine-generated traces, not just idealized color bars.

Exit: reference runs reproducibly, stimuli and comparison windows are fixed,
and current APF geometry has measured assertions.

### N1 - Import and prove the NTSC path in isolation

1. Import canonical sources and extend parity checks.
2. Add the constant-configured instance in a narrow test wrapper first.
3. Compare RGB and blanking cycle by cycle against the reference. Exclude only
   an explicitly bounded initial acquisition interval, not mismatching lines.
4. Test reset during active video and blanking, mode transitions, and coherent
   source/decoder enable pauses.

Exit: zero unexplained RGB/timing mismatches; `ioctl_wait` proven never to
assert; exact preset behavior documented;
startup/recovery bound established. If the donor itself violates a required
contract, document the reproducer and agree on a separate fix rather than
silently changing the reference.

### N2 - Wire the shipping path

1. Add one compile-time NTSC enable/fallback parameter to the existing core,
   without introducing another Quartus project.
2. Make OSK RGB input compatible with every caller.
3. Route selected RGB and selected blanking through both overlays and APF.
4. Register sources in the active QSF and targeted simulation runners.
5. Verify fallback is byte/pixel-equivalent to the monochrome baseline.

Exit: shipping-width APF capture, keyboard and overlay tests pass; no machine,
RAM, storage, or audio behavior changes.

### N3 - Synthesis and resource review

Run narrow simulation/lint first. The owner normally performs Quartus builds:
do not start a full compile without explicit authorization.

From `E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\src\fpga`:

```text
quartus_map apf_stream_video --read_settings_files=on --write_settings_files=off
quartus_sh --flow compile apf_stream_video
```

The first command proves analysis/synthesis only. The second is the owner-run
full compile, not a command to run automatically.

Verify fresh map, fit, STA, assembler, and RBF timestamps under
`src\fpga\output_files_apple2e`. Check:

- NTSC hierarchy is present; unused `vga_controller` logic is absent.
- Line storage infers M10K rather than a register array.
- DSP inference and ALM cost are reported, not guessed.
- No new unexplained latch, width/signedness, multiple-driver, or undriven-net
  warnings. Separate donor/existing warnings from introduced ones.
- No new timing violations or unconstrained functional paths. Preserve APF
  forwarded-clock and SDRAM timing constraints.

Exit: successful fit/assembly and timing review, or an explicit owner handoff
stating that synthesis/hardware validation remains pending.

### N4 - Hardware acceptance and documentation

Use the existing [build/staging flow](../apf_stream_video_build.bat) only when
authorized: it compiles and overwrites the staged bitstream. Preserve the
known-good baseline first; do not overwrite user media or unrelated artifacts.

Test on Pocket, and dock if available:

- DOS 3.3 and Jungle Hunt still boot.
- Text, lores, HGR, DHGR, mixed-mode boundaries, and 80-column text render.
- **Pre-classified known issue, not a Pocket regression:** the HGR/DHGR
  left-shift documented in
  `Apple-II_MiSTer/docs/video/VIDEO_RENDERING_ISSUES.md`. It is pre-existing on
  MiSTer (present before that lineage of work), caused by the HGR active window
  having been adjusted against the Total Replay screen. Porting the pipeline
  makes it visible on Pocket. Record it as a known donor artefact in the
  acceptance notes so it is not rediscovered as a new bug, and decide explicitly
  whether fixing it is in scope or deferred. Do not "fix" it by moving a window
  in the pinned files.
- No cropped/wrapped edges, colored text contamination, pink/blank display,
  unstable hue, rolling image, or persistent post-reset corruption.
- OSK glyphs, positioning, transparency, and input behavior are unchanged.
- Existing status overlays remain legible and correctly positioned.
- Existing aspect presets still work without manifest geometry changes.
- Repeat host reset, OSK reset, and normal disk-load scenarios.

Capture comparison images and record hardware/firmware, bitstream hash,
preset, and build revision. Update the README status only to the level
actually verified; a fitted design is not hardware acceptance.

## 6. Validation matrix and runner pitfalls

| Test | Required assertion |
|---|---|
| Donor parity | Imported canonical files match pinned originals |
| Monochrome fallback | Pixel/timing-equivalent to recorded baseline |
| NTSC differential | Zero RGB/blanking mismatches after bounded acquisition |
| Pattern coverage | Black, white, alternating bits, phase-shifted patterns, edge markers, adjacent-line changes |
| Mode coverage | 40/80-column text, lores, HGR, DHGR, mixed mode, HGR80, page changes |
| APF output | 560 contiguous DE clocks per active line; 192 active lines per stable frame |
| Sync/blanking | One-clock HS/VS; no DE overlap; RGB zero outside DE; first HS at least 3 clocks after VS |
| Longevity | At least 120 consecutive stable frames without geometry drift |
| Reset recovery | Recovery within a proposed 2-frame bound; measure it and review any required relaxation |
| Overlay/input | All opacity levels and both positions; no duplicate keypresses or glyph changes |
| Whole-core regression | Current full-top integration plus M1 boot checks; compare machine behavior, not just picture presence |

Useful existing tests:

- [tb_phase2_shots.sv](../verilog/tb/tb_phase2_shots.sv) and
  [runner](../verilog/verilate_phase2_shots.sh): extend for NTSC captures.
  **The TB defaults to `DEC=1`, while shipping is `DEC2X=0`.** Explicitly use
  `DEC=0`; do not pass a 280-pixel experiment as shipping-path validation.
  This runner also mixes local and live sibling machine sources and broadly
  suppresses warnings. Make the new candidate run use the local shipping
  sources, keep the pinned donor isolated as reference, and expose relevant
  warnings. Preserve existing users of the runner.
- [tb_wrapper_kbd.sv](../verilog/tb/tb_wrapper_kbd.sv),
  [tb_kbd_protocol.sv](../verilog/tb/tb_kbd_protocol.sv), and
  [tb_osk_ctrl.sv](../verilog/tb/tb_osk_ctrl.sv): reuse the relevant input tests.
- [tb_ovl_status.sv](../verilog/tb/tb_ovl_status.sv) and
  [tb_ovl_dbgrect.sv](../verilog/tb/tb_ovl_dbgrect.sv): overlay regression.
- [tb_top_storage.sv](../verilog/tb/tb_top_storage.sv): inspect and reuse its
  real-top integration for source-list/port coverage.
- [tb_u6_boot.sv](../verilog/tb/tb_u6_boot.sv) and
  [verilate_u6.sh](../verilog/verilate_u6.sh): existing machine/WOZ boot check.
  It checks storage, boot-sector reads and CPU progress, not full visual boot
  correctness. It does not by itself validate the new video wiring.

The current [M1 rerunner](../verilog/rerun_m1_regress.sh) reconstructs commands
from ignored build directories and starts long jobs; it is not a clean-checkout
entry point. The [overlay runner](../verilog/run_ovl_suites.sh) references
`woz_bram.v`, while the active source is `woz_bram.sv`. Verify/fix only the
selected runners needed for this work; do not launch them blindly or count
missing-source/empty-output runs as passes.

Provide a checked-in build/run command for each new test, with explicit source
lists, ROM working directory, output directory and nonzero failure exit.
Require both the expected PASS/coverage verdict and successful process exit.
Do not depend on old executables, ignored `verFiles.dat`, or stale captures.

Use MSYS2 UCRT64 Verilator, native `mingw32-make` and its `make.exe` shim,
`VERILATOR_ROOT`, writable TMP/TEMP/TMPDIR, and `sh` as the recipe shell.
Use `--binary --timing` for self-driving SV TBs. Relink and launch promptly
because of the documented host AV issue. If execution is blocked, report it;
lint is not a substitute for functional tests.

## 7. Resource budget and interpretation

Existing report evidence, not guarantees for the new Pocket fit:

| Configuration | ALMs needed | M10Ks | DSPs |
|---|---:|---:|---:|
| Pocket baseline, October 24 | 8,978 / 18,480 | 190 / 308 | 0 / 66 |
| MiSTer NTSC encoder + decoder, October 12 | 806 | 2 | 22 |
| MiSTer RGB renderer, October 12 | 1,032 | 3 | 6 |
| MiSTer full selectable video pipeline | 1,879 | 5 | 31 |

The NTSC row already includes the decoder. Do not add parent/child hierarchy
rows. NTSC uses more DSPs but fewer ALMs than this particular RGB renderer.
Simple donor-cost addition suggests about 53% Pocket ALM utilization for
NTSC alone, before integration and changed packing. A fixed preset may
optimize further; do not promise that saving.

Compare baseline versus NTSC-only whole-design fit with the same constraints
and seed. Report ALMs needed, placed ALMs, registers, M10Ks, DSPs, and timing.
There is no justified hard incremental-ALM ceiling yet. If costs resemble the
full dual pipeline, investigate retained RGB hardware before optimizing math.

Cross-check of the M10K column against the donor arrays (agrees with the
measured rows above, so use the measured rows):
`composite_decoder.linebuf_mem[0:1023]` x 16 b = 16,384 bits, and
`vga_controller.previous_line_rgb[0:559]` x 24 b = 13,440 bits - but the latter
lives in the RGB-renderer row, which should fold away per section 3, leaving
roughly 16 Kbit (about 2 M10K) for the NTSC path. `composite_decoder.ybuf` is
`[15:0][15:0]` (registers, not RAM), as are the `seam_*_window[0:8]` arrays.
Note for the record: an earlier review quoted 107 Kbit for `previous_line_rgb`;
that was an arithmetic error (it is 13,440 bits, not 107,520). The
donor-measured table above is authoritative.

With 118 free RAM blocks and 66 free DSPs (current DSP use is zero, so any DSP
in a future report is new and expected - the donor NTSC row uses 22), memory and
DSP are not constraints. **ALMs are the only real budget risk**, and there are
9,502 free.

Do not add a full-frame buffer: two native RGB888 frames require 5,160,960
bits, more than the entire Pocket FPGA block-memory capacity. Small decoder
line history is expected and is not a framebuffer redesign.

## 8. Completion handoff

Deliver:

1. Exact changed files and donor revision/provenance.
2. Confirmed fixed controls and effective decoder values.
3. Block diagram and measured RGB/blanking/reset timing contract.
4. Reproducible test commands, coverage, warning baseline and outcomes.
5. Fresh resource/timing comparison, or clearly marked owner-pending compile.
6. Hardware captures/results, or clearly marked hardware-pending status.
7. Updated usage/build documentation and remaining risks.

Keep the change surgical. Preserve mixed line endings and unrelated work;
run diff checks, whitespace-sensitive/insensitive statistics, and the workspace
EOL guard after RTL edits. Do not commit unless requested.

**Forward note on user options (deferred, but reserve the space).** This
milestone ships no runtime video menu, which is the right call. When presets
are added later, the pipeline needs roughly eight user entries (`SCREEN_MODE`,
`COLOR_PALETTE`, `NTSC_VERTICAL_COMB`, `use_composite`, `comp_preset`,
`comp_hue_adj`, `comp_bright_st`, `comp_sat_st`, `comp_contrast_st`), and M1
Task 2 may want one for the cold-reset toggle. `interact.json` is currently
empty, so there is room - but per skill **KB-079 interact silently caps at 16
shown UI entries**. The cap fails silently, so allocate the list deliberately
when that work starts rather than discovering the ceiling then.

Save states remain a separate follow-up. The decoder enable/reset ports are
preparation only: this milestone does not solve WOZ state capture, APF raster
continuity while frozen, or persistent snapshot transport.
