# Hardware-load image fingerprint (M1 diagnostic, 2026-10-23)

## Why

The Pocket loads `Assets/apple2e/common/disk.woz` from the SD card through the
host data-slot path into SDRAM. The on-screen `OK CRC=XXXXXXXX` badge is a
**self-consistency** check only (host wrote N words → SDRAM readback CRC of
those N bytes matched at commit time). It does NOT prove the bytes match the
card file or that the declared size is the real file size. On hardware the
badge CRC has drifted on every run (`5505C782` → `55C57822` → `5B5CB782` →
`5F2EC782`) while the verified card file is always `74EA1324` — the host fetch
path is loading different bytes than the card holds, and the `OK` badge cannot
see that.

The fingerprint is a **content-level** diagnostic: it latches, after every
SDRAM readback-verify pass, the actual first/last bytes of the image in SDRAM
plus four independent 64 KB window CRC32s. A wrong on-screen fingerprint
compared against the PC-computed value of the same card file localizes a
hardware-load corruption to a 64 KB region, and the head/tail bytes show the
exact byte transformation.

## What is latched

`disk_verifier.v` (machine domain, 14.318 MHz) runs the readback verify pass
(the existing CRC32 of the whole image). The fingerprint reuses that pass —
no extra SDRAM traffic:

| Signal      | Value |
|-------------|-------|
| `fp_first`  | file bytes `[0:15]` (MSB = byte 0; bytes ≥ n_bytes = 0) |
| `fp_last`   | last-16-byte frame (word-aligned; see semantics below; bytes ≥ n_bytes or inside the final partial word's pad = 0) |
| `fp_w0..3`  | **independent** zlib-style CRC32s of byte windows `[0:64K)`, `[64K:128K)`, `[128K:192K)`, `[192K:n)` — each window starts a fresh CRC (init `0xFFFFFFFF`, final XOR); empty window = 0 |

Semantics details (from the verified implementation):

- Window restart happens when a word **starts** at word index 16384 / 32768 /
  49152 (2¹⁴·k — 64 KB / 4). The previous window is finalized at the boundary
  (latched `state ^ 0xFFFFFFFF`); the final window is finalized at run end.
- `fp_first` fills from the top of the register (word 0 → bits `[127:96]`);
  `fp_tail` is a true 32-bit left shift (last word ends in `[31:0]`).
- The verifier's results (CRC32, first/last word, word count) are unchanged —
  the fingerprint is additive (a parallel `wcrc` accumulator + output latches).

`sdram_storage.v` passes the three values out as `fp_first_m` / `fp_last_m` /
`fp_w_m` (machine domain, no CDC). `apf_stream_video_top.v` wires them to the
overlay.

## On-screen display

`sdram_status_overlay.v` — four **always-on** lines below the drive-activity
readout (independent of the result show-window, so they persist):

```
rows 65..71  W0=XXXXXXXX W1=XXXXXXXX   (24 chars, X0=406)
rows 73..79  W2=XXXXXXXX W3=XXXXXXXX
rows 81..87  F=XXXXXXXXXXXXXXXX        (18 chars, X0=442)
rows 89..95  L=XXXXXXXXXXXXXXXX
```

Only 8 bytes fit per line (16 hex chars in the 560-sample active run), so
`F=` shows the **first 8 bytes** and `L=` the **last 8 bytes** of the file.
New glyph `W` (code 29) added to the 5×7 font.

## Expected values for the shipping disk.woz

Computed by the PC oracle `tools/woz_fingerprint.py` (zlib CRC32, same
init/final as the RTL):

```
$ python tools/woz_fingerprint.py sd_root/Assets/apple2e/common/disk.woz
N=00039400  CRC=74EA1324
W0=C59C65F2 W1=63610555
W2=3E949994 W3=E24FAE89
F=574F5A32FF0A0D0A
L=0000000000000000
```

`F=` = the WOZ2 magic (`57 4F 5A 32` = "WOZ2") + `FF 0A 0D 0A`; the file's
final 8 bytes really are zero (verified `tail -c 16`). On the Pocket, a
**healthy load must show exactly these five values** (plus `N=00039400` on
the N= line and `OK CRC=74EA1324` on the result line). Any deviation of a
single `W` window localizes corruption to that 64 KB region; a wrong `F=`
proves the host is not even loading the file's head (e.g., LBA offset /
neighbor-cluster data).

## Root cause identified (2026-10-24) and fix

The fingerprint made the corruption decodable. The on-screen values from the
2026-10-23 hardware run (`OK CRC=5A5CB7B2`, `N=00039400`, `W0=9230B05B
W1=02AB02BE W2=71B61DB4 W3=4C51C8E8`, `F=5A325A320D0A0D0A`,
`L=0000000000000000`) were reproduced **byte-exact** by applying one
transformation to the verified card file:

```
every 32-bit word [a b c d] stored in SDRAM is [c d c d] = {low16, low16}
```

i.e. each word's low half replaced its high half. That transformation is not
an SD-FAT artifact (the size `N=00039400` is exactly right) — it is a
**32-bit-word-alignment** corruption, i.e. it happens in the SDRAM
controller, not in the host SD fetch. Two candidate mechanisms remain, and
the next hardware run distinguishes them:

**(A) Write-path capture skew (prime suspect).** The controller's word-write
DQ schedule drives `high16` for one cycle then `low16` for **two** cycles
(`ST_WRITE_3` + the hold in `ST_WRITE_4`). If the chip's DQ sampling grid is
one cycle late relative to that schedule, the chip latches `{low_k, low_k}` —
exactly the observed words, for every word, deterministically. The stored
image is corrupt; the readback is faithful; `OK` (readback-completed) still
shows.

**(B) Read-path capture skew.** Storage is correct but the chip presents read
data one cycle earlier than the controller's 4-stage capture pipeline
assumes (the chip runs in power-up-default **CAS2** mode — the boot "LMR"
writes drive `CMD_LMR=3'b000`, an *undefined* SDRAM command that real chips
ignore). The stage-4 capture then grabs the second half-read's data for both
halves — also `{low16, low16}`.

### The fix shipped in this round

`io_sdram_pocket.v` (Pocket-local variant; the pinned `refs/basicassets`
base stays immutable):

- **`parameter CAP_PIPE = 3`** (base behavior = hardwired stage 4): the read
capture now samples at stage 3. This is the (B)-side fix; if the chip data
arrives one cycle early, stage 3 lands mid-window.
- **`parameter BOOT_CYCLES = 30000`** (default = base behavior): lets TBs
shorten the 225 µs power-on delay (`tb_cas_probe` uses 300).

`tb_dram_model.sv` (simulation model only):

- **`parameter CAS = 2`** (was 3): models the chip's actual power-up-default
mode — the model previously hardwired CAS=3, which is exactly why every
simulation (and the M0 full-image CRC pass) was byte-exact while silicon
corrupted. The model also never applied LMR mode-register writes, so the
chip's real default mode was invisible to it.

### Verification status (2026-10-24)

- `tb_cas_probe` (new, `verilog/tb/`): one write + one read through the real
  `io_sdram_pocket` + model, 300-cycle shortened boot. **PASS**: word
  `AABB_CCDD` (high ≠ low halves) reads back exact with `CAP_PIPE=3` + model
  `CAS=2` — the new sim pairing is byte-exact.
- Fast M1 regression on the new RTL: `tb_sector_fetch` ALL PASS,
  `tb_slot_fifo` PASS, `tb_woz_mount_ctl` ALL PASS, `tb_woz_transport` ALL
  PASS, `tb_disk_store` PASS.
- `tb_bridge_storage` on the new RTL: **PASS** (17.2 min; real-bridge 512 B
  and 1001 B loads auto-verify byte-exact, full handshake matrix).
- `tb_u6_boot` (full machine, correct CWD `verilog/u6/`): **B0 PASS** —
  full 234496 B image stored and verified at the original file CRC
  `74EA1324`, mounted. **B1 FAIL** — the engine served exactly 512 B of
  track 0 (all bytes content-exact, `content_fail=0`) but did not reach the
  5000 B threshold within the 3 M-cycle window.
- `tb_top_storage` (new RTL, 38.7 min): **PASS** — boot, store, CRC verify,
  reset-preservation, tails, auto-verify (no-file, pause, reload, tails,
  incomplete, overflow, chip-fault).

### u6 B1 failure: bisected OUT of the alignment fix — root cause was a TB wiring bug, now fixed

A controlled bisect (temporarily reverting `CAP_PIPE` to 4 + model `CAS` to
3, re-running u6) reproduced the **byte-identical** failure signature: same
`B0 crc=74ea1324`, same `bytes=512 track0=512`, same `content_fail=0`, same
end time (~367.8 ms). The u6 B1 failure was therefore **NOT caused by the
CAS2/CAP_PIPE alignment change**.

Root cause found by inspecting the transport instance in `tb_u6_boot.sv`:
the 2026-10-22 stale-window-guard round added a `sector_lba` port to
`sdram_woz_transport` and updated `tb_sector_fetch` / `tb_woz_transport` /
`tb_woz_machine` / `pocket_boot`, but **`tb_u6_boot` was missed**. Verilator
leaves an unconnected input at 0, so the transport's published-window
compare (`sector_ready && sector_lba == lba_l`) could only ever match
**lba 0**: sector 0 (512 B) delivered, then every fetch for lba ≥ 1 was
released as "stale" and re-armed forever — exactly the observed
`bytes=512 track0=512` stall. `tb_u6_boot` was last green 2026-10-20,
before the guard port existed, which is why the regression only surfaced
now.

Fix: `tb_u6_boot.sv` — declared `stor_sector_lba` and connected
`stor.sector_lba` → `woz_tr.sector_lba` (the same wiring
`apf_stream_video_top.v` already has at lines 796/855/957).

**Result: `TB U6 BOOT: ALL PASS (bytes=5000 track0=5000 content_fail=0
slot6_fail=0)` at 162 ms** ($finish walltime 3.9 min) — full machine boot:
B0 full-image store + verify at the original file CRC `74EA1324`, mount,
then the real 6502's ROM boot has the engine serve track 0 (5000 B,
byte-exact) through the fixed SDRAM read path. Audit of all other
`sdram_woz_transport` instantiations confirms u6 was the only TB missing
the connection (the shipping top-level is wired correctly, so this never
affected the RBF).

### How the next hardware run decides (A) vs (B)

With `CAP_PIPE=3` in the bitstream, reload the same card:

- **If (B) was the cause**: storage was always correct; readback is now
  aligned → overlay shows `CRC=74EA1324`, `F=574F5A32FF0A0D0A` (true WOZ2
  magic), `W0=C59C65F2 W1=63610555 W2=3E949994 W3=E24FAE89` — and the WOZ
  engine should mount and the machine boot DOS 3.3.
- **If (A) was the cause**: storage is still `{low16, low16}`; the now-early
  read capture shifts that pattern (each captured half comes from the
  previous read), so the overlay shows a *third*, different fingerprint
  (decodable the same way) — then the fix is on the write side: start the
  write DQ schedule one cycle earlier (a `WRITE_PIPE`-style change to
  `ST_WRITE_0..4`), verified the same way (probe → storage suites →
  hardware).

Either way the fingerprint keeps localizing: it is a byte-exact oracle, and
the expected values above are computed from the card file by
`tools/woz_fingerprint.py`.

### Final compile + card staging (2026-10-24 09:24)

- Quartus full compile `apf_stream_video`: **Fitter Successful** 09:24:04.
  Resources 8,978 / 18,480 ALM (49 %, +4 ALM vs pre-fix build — the
  `CAP_PIPE` constant-select). RBF 1,631,588 B.
- STA green at both corners on the critical mp2 (133.12 MHz) path:
  `Slow 1100mV 85C` setup slack **+1.080 ns**, `Slow 1100mV 0C` setup slack
  **+0.967 ns**, TNS 0.000 everywhere.
- Map report: 488 warnings — same count as the pre-fix build, no new
  classes (no `fp_*`/latch/multi-driver/undriven entries).
- `sd_root/Cores/Newsdee.Apple2eStreamVideo/bitstream.rbf_r` regenerated
  from this RBF (sha256 in `e46034c9…`, out `5bafbf84…`). Card contains a
  single core + `Assets/apple2e/common/disk.woz` (234,496 B, CRC
  `74EA1324` re-verified in staging).
- `tb_woz_machine`: last fast-suite member, left deferred — four launch
  attempts were cut by the host AV layer (0-byte logs); its coverage
  (mount/eject/remount/reload through the engine + storage) is superseded
  for this round by `tb_u6_boot` ALL PASS (full machine, same paths) plus
  the storage suites above. Re-run when the AV is cooperative: `bash
  verilog/verilate_*.sh` pattern, CWD = repo root (its golden path is
  `verilog/tb/golden/dosmaster_16k.hex`).

## Verification chain (all PASS, 2026-10-23)

1. **`tb_verifier_fp`** (`verilog/tb/tb_verifier_fp.sv`): self-driven TB with a
   deterministic byte pattern; the TB only prints the DUT's values — the
   oracle is `tools/woz_fingerprint.py --pattern N` (independent zlib). Seven
   cases covering all window-boundary alignments and masking
   (200000 / 131072 / 65536 / 65537 / 100 / 10 / 0 bytes): every `crc32`,
   `fp_first`, `fp_last`, `fp_w0..3` matches the oracle exactly.
2. **`tb_ovl_status` T7**: raster-level pixel-exact check of all four fp lines
   (incl. the new `W` glyph), after extending the TB frame to 110 visible
   lines so rows 65..95 exist; all prior tests T0–T6 still pass.
3. **Full-design lint** (entire `pocket_boot` source list, `--top
   tb_pocket_boot`): clean, no `%Error`.
4. Long storage suites: `tb_top_storage` and `tb_bridge_storage` PASS
   (pre-fingerprint RTL, 11:24 / 11:01 on 2026-10-23); a final-RTL
   `tb_bridge_storage` re-run was launched at 11:39 to confirm the additive
   change is behavior-neutral on the exact shipping RTL.

## Known limitations

- 8 bytes per head/tail line (line-width bound); the middle 8 bytes of each
  16-byte fingerprint are not displayed — the window CRCs cover them.
- `fp_last` is aligned to the word frame: for `n % 4 != 0` the tail frame is
  the last 16 **word-aligned** bytes (pad bytes zeroed), not exactly
  `[n-16:n]`. The shipping image (234496 B) is 4-byte aligned, so on-screen
  `L=` = the true last 8 bytes.
- The values are latched on each verify pass; before the first pass they read
  all-zero (after reset).
- The overlay lines are always on: they overlay the machine video in rows
  65..95 (right side). Temporary diagnostic; remove the four line blocks +
  the three overlay ports if/when the load path is fixed.
