# Build 2026-10-31 16:40 — v0.2.7 "faultprop" (HDV read-only, HD boot bring-up)

Owner-compiled `apf_stream_video` (Quartus 17.0.2 Lite, 5CEBA4F23C8).
Carries the post-expert-review changes; see
`docs/REVIEW_RESULTS_HDV_PRODOS_CRASH_2026-10-30.md`.

## Contents vs the previous build (2026-10-30_1159_v027_bootmedia)

1. **HD fetch-fault propagation** (closes the two silent-corruption paths the
   expert review found):
   - `hdv_bridge.sv`: new `bridge_err` output — a 15×74a-cycle hold pulse on a
     **dropped fetch** (mounted-desync: hdd committed, bridge did not) or a
     **fetch timeout** (`FETCH_TO`, default ~3.6 s).
   - `hdd.v`: new `bridge_fault` input — forces `reg_status <= 8'h01` when
     pulsed (2FF-synced from the bridge in the top). **C0F1 now reports a
     failed fetch** instead of the stale optimistic `00` from the C0F0
     execute. Donor semantics preserved (equivalence re-verified, port tied
     off in the TB).
2. **Boot Media = Floppy write-path gate** (was missing in the 11:59 build —
   lost in a failed edit batch): `hdd.IO_SELECT`/`DEVICE_SELECT` ×
   `~hd_off_m`, so C0F0 writes cannot arm a stray 0x0180 fetch while the ROM
   believes slot 7 is empty. No-op in HDD/Both mode.
3. **On-screen `HD=` debug line moved on-screen** (`sdram_status_overlay.v`
   X0=460→424): the 10 s post-reset window now shows
   `HD=S F=F E=E N=NN W=W` in full — S=bridge state, F=timeout fault,
   E=last host err, N=completed 0x0180 fetches, W=6502 stalled.
4. (Carried from the 11:59 build: `Boot Media` option, HD-off-bus gating for
   Floppy mode, OSK Reset cold boot, T5 timeout + fetch counter.)

## Compile (owner-run, 16:40)

- Fitter: Successful. ALM 12,511 / 18,480 (68 %), registers 14,071,
  pins 224/224, RAM 1,550,364 bits (49 %).
- Timing: all constraints met (min slack 0.164 ns; the four clock groups at
  1.033 / 2.186 / 10.363 / 31.359 ns slack, worst per-group 0.164).
- Delta vs 11:59 build: ALM +13 (12,498 → 12,511) — the fault-propagation
  path + write gate; as expected.

## Simulation gates (all green, this tree)

- `tb_hdv_bridge`: **7/7 PASS** — T1 single fetch exact · **T6 two consecutive
  fetches byte-exact** (new; the ProDOS-load shape) · T2 PROTECT · T3
  NO_DEVICE · **T7 desync drop → C0F1 reads 1** (new) · T4 write walk exact ·
  T5 timeout releases CPU + fault latch + **C0F1 reads 1** (extended) + clean
  fetch recovers.
- `hdd_equivalence` (GHDL golden vs Verilator candidate): **PASS** at the exact
  known-good result (rows=7600 fields=128397 ignored_metavalues=803
  hdd_read=5 hdd_write=5; all 8 coverage gates).
- `pocket_boot` full machine: **SMOKE BOOT OK** (frames=10 crc=74EA1324 mt=1).

## Artifacts (SHA-256)

| file | sha256 |
|---|---|
| `apf_stream_video.rbf` | `ff633a72ae69866cf230623cad708da7d70793e773696065b98d2173c45a0d27` |
| `bitstream.rbf_r` | `52ec47c1656b2f6af2214048fc99de7c22e4713ccb1037502a03fdb936f69eb7` |
| `core.json` | `401ea0334d8f7dea86d15f21c42505ae7c8c10088cb0169418fde3e1dac3c1fe` |
| `interact.json` | `78081feef976efae6c6de37b0a04a1f739077ed2c6647dc371d49b1ad462230d` |

Staged: `sd_root/Cores/Newsdee.Apple2e/` (bitstream.rbf_r + interact.json
copied together — option ID/address interpretation must match).

## Hardware test plan (this build)

1. Copy `sd_root/Cores/Newsdee.Apple2e/` → card `Cores/`, reboot the Pocket.
2. Verify the keyboard latch is clean (OSK stray chars can leave bytes in it —
   the image's `$0819` key-held test reads exactly that).
3. Select the HDV in the Hard Disk slot; `Boot Media = HDD`; OSK **Reset**
   (true cold boot); **photograph the 10 s window** — read
   `HD=S F=F E=E N=NN W=W`:
   - `N=1` → only block 0 was fetched; the second fetch never armed/dropped
     (now also visible via C0F1 = 1 in the driver's error path).
   - `N` large → transport proven on silicon; the crash moves downstream
     (data integrity / ProDOS-machine behavior) → do the `$0800` dump below.
   - `E≠0` → host rejected a repeated 0x0180 (host-side limit, not RTL).
   - `N` frozen after ~3.6 s stall → the timeout path fired (now reported in
     C0F1 as well).
4. At the monitor after a C700G crash, dump `$0800` (check early — the ProDOS
   loader may overwrite it); first line must be:
   `01 8A 48 D8 8D 82 C0 8D 0E C0 8D 0C C0 8D 00 C0`
   then `8D 02 C0 8D 04 C0 8D 08 C0 AD 00 C0 C9 D3 F0 04`.
5. `Boot Media = Floppy` + HDV still selected → the floppy MUST boot (the
   write-path gate makes this safe now).
