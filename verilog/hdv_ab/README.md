# hdv_ab — A/B differential harness for the HDV host read path

**Purpose.** Regression oracle for the HDV (Smartport HD) host read path.
It compares two `hdv_bridge` implementations — **Build A** = the
silicon-proven flip-flop sector array (extracted from `b5a3881`, the 0.4.1
tree) vs **Build B** = the working tree's `hdv_bridge.sv` — through the
*shipping* host read path and the *real* APF peripheral, with identical
data, transactions, and scoreboard. The two trees may differ ONLY in
`hdv_bridge.sv`; everything else is byte-identical (provenance-gated).

Created 2026-11-21 to diagnose the M10K lane-RAM roll-1/2/3 HDV write
corruption. It found the systematic bug (the M10K tree over-shifted the
host read stream by exactly one word — a same-strobe double latch on
`hdv_ram_word_ww_q`), the fix was applied, and the fixed tree now matches
the FF tree byte-for-byte here. Any future change to the HDV read path
(lane RAMs, prime stage, OOR handling, PMP, mux arm) should be re-verified
with this harness before a shipping-clean roll.

## What it models (faithfully, no shortcuts)

- **The real `io_bridge_peripheral`** (port-split wrapper, body verbatim —
  see below), driving the real SPI protocol the Pocket host uses:
  one SS pulse → 4 address bytes (2 bits/edge, MSB-first, spiclk rising) →
  3-cycle prime delay (`read_cnt`) → **sample** `pmp_rd_data` → assert
  `pmp_rd` for one cycle → 16 rising-edge data TX → wait `spis_done`.
  Because the sample happens *before* the strobe, the word delivered for
  host read N is what the core's port held in the gap after read N-1's
  strobe — the framework-documented one-word prime.
- **The shipping `0x01F01xxx` HDV mux arm verbatim** (combinational
  `hdv_ram_word` select). The `core_bridge_cmd` command-window register is
  deliberately NOT in the path: only `0xF8xxxxxx` reads go through it.
- **The real `hdd.v`** with a fake 6502 (ported from `tb_hdv_bridge.sv`):
  C0F8 sector writes run the DUT's `walk_out` + the `0x0184` DMA arm for
  real, C0F0/C0F6/C0F7 for mount/unit/execute.
- **The framework scoreboard, exactly**: 129 host reads at words
  0..128 (the 129th is the OOR read), discard sample 0 (the prime), verify
  all 128 retained words against the tag pattern, require exactly 129
  `bridge_rd` strobes (no tail reads), and report the **first** wrong word
  (index, decoded tag index, offset `k`) plus the full `k` histogram.
- **Burst matrix** (identical in both builds): COLD-88 (first write after
  reset), WARM-88, WARM-32, WARM-16. The PMP needs ~30+ cycles between the
  end of a data TX and the next SS; 88 is the framework's documented worst
  case, 16 tests the turnaround floor.

The DUT module name is `hdv_bridge` in both builds, so this is **two
builds + a transcript diff**, not one two-DUT bench.

## Files

| file | role |
|---|---|
| `tb_hdv_ab.sv` | the A/B bench (DUT + real PMP + real hdd.v + host engine + scoreboard). `STAGE_PROBE` localparam (default 0) dumps the DUT's host-facing output at every PMP sample/strobe — how the root cause was found; set it to 1 to re-measure stages. |
| `run_hdv_ab.sh` | build+run both builds, provenance gate, wrapper verbatim gate, verdict. |
| `ibs_phy_gen.pl` | generates `work/ibs_phy_split.v` from the shipping `io_bridge_peripheral.v` (port split + TX restructure, body otherwise verbatim). |
| `tb_pmp_probe.sv` | minimal standalone isolation test: can the port-split PMP complete ONE read TX at all in this Verilator build? |
| `work/`, `rtl/`, `obj_*/` | generated (DUT extracts, wrapper, ROM copy, Verilator objects) — throwaway, gitignored. |
| `transcript_A.log` / `transcript_B.log` | the two run transcripts (diffed for the verdict). |

## The Verilator 5.050 ≥4-NBA-site bug (and the port-split workaround)

**Why the PMP cannot be simulated in a two-state simulator as-is:**
its three phy lines are `inout` ports driven by the TX state machine from
**five NBA sites each** (`ST_SIDLE`, `ST_SEND_N`, `ST_SEND_0`, `ST_SEND_1`,
`ST_SEND_2` in one `always @(posedge clk)`). Verilator 5.050 `--timing`
compiles any `reg` with **≥4 NBA sites in one clocked process** into a
**latched OR of "strong drivers" with no validity** — once any site
drives the line High (first `ST_SEND_N`), the output **sticks High
forever**. The PMP state machine keeps running normally; only the port
output is frozen. Symptom: the first host read ever captured hangs
(watchdog), after exactly one cclk posedge and zero negedges. It affects
*internal* regs too, not just ports. (Signals with ≤3 NBA sites, e.g.
`pmp_rd`/`pmp_wr`/`pmp_addr_valid`, compile to last-NBA-wins and are fine.)

**The workaround** (simulation-only, in the generated wrapper — the
shipping RTL is never touched):

1. **Port split:** the three `inout` phy ports become
   `input ..._in` / `output wire ..._out` pairs, so a two-state sim can
   model the one-driver-at-a-time SPI bus (host drives during its
   transactions, PMP drives during TX; each side's RX samples the net).
2. **Single-NBA TX drivers:** the TX state machine's five in-branch
   assignments are replaced by a **combinational next-value** per state
   (`always @(*)`, `case(spis)`), then **one NBA each** into internal
   `phy_sp*_q` regs, with `assign phy_sp*_out = phy_sp*_q`.
   Cycle-identical: `ST_SEND_1`/`ST_SEND_3` assigned *no* line values in
   the original (hold = current value), so the `_n` block holds the `_q`
   value there.
3. **RX side unchanged:** `posedge phy_spiclk_in`, latches on
   `{phy_spimosi_in, phy_spimiso_in}` (spimosi is the **upper** bit of
   each 2-bit pair).

`run_hdv_ab.sh` re-verifies the transformation on every run: after
stripping the `_in/_out/_q/_n` suffixes and comment/structural lines, any
remaining differing line that does not reference a `phy_sp*` port or the
module name is FATAL ("wrapper OK: body verbatim" is required).

**Rule of thumb for any future clocked Verilog in this toolchain:** keep
each reg to **≤3 NBA sites per clocked process**; if you need more,
compute the next value combinationally first and write it with one NBA.
When in doubt, run `tb_pmp_probe.sv` — it fails exactly at the stuck-line
signature if the bug is back.

## Run commands

From an MSYS2 UCRT64 shell (the script sets PATH/VERILATOR_ROOT/make-shim
itself; ucrt64 verilator + g++ + `C:/msys64/tmp` writable are required):

```sh
cd E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket/verilog/hdv_ab
bash run_hdv_ab.sh        # provenance + wrapper checks, build A & B, run, verdict
bash run_hdv_ab.sh clean  # wipe obj_*/work/rtl/transcripts
```

Standalone PMP isolation probe (regression test for the NBA bug / any
future PMP change):

```sh
export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
/c/msys64/ucrt64/bin/verilator_bin.exe --binary --timing -Wno-fatal --Mdir obj_probe \
    -sv tb_pmp_probe.sv work/ibs_phy_split.v ../../src/fpga/apf/common.v
make -C obj_probe -f Vtb_pmp_probe.mk Vtb_pmp_probe   # needs the make.exe shim on PATH
./obj_probe/Vtb_pmp_probe.exe                        # expect: PROBE PASS (0x112233a8)
```

## Expected output (known-good, post-2026-11-21 read-stage fix)

```
provenance OK: shared files identical between b5a3881 and 87e05b7
wrapper OK: body verbatim (phy port split + documented TX restructure)
BURST B0 COLD-88: PASS (128/128 retained words exact, 129 strobes, wrcnt=129 oobcnt=1)
BURST B1 WARM-88: PASS (128/128 retained words exact, 129 strobes, wrcnt=129 oobcnt=1)
BURST B2 WARM-32: PASS (128/128 retained words exact, 129 strobes, wrcnt=129 oobcnt=1)
BURST B3 WARM-16: PASS (128/128 retained words exact, 129 strobes, wrcnt=129 oobcnt=1)
ALL BURSTS PASS IN BOTH BUILDS
TRANSCRIPTS IDENTICAL: the fixed M10K tree and the FF tree are byte-identical in sim
HDV AB COMPLETE (transcripts: transcript_A.log / transcript_B.log)
```

(Build B's four PASS lines appear after Build A's; the shown block is one
build's. "TRANSCRIPTS IDENTICAL" means Build B's hdv_bridge is
functionally indistinguishable from the silicon-proven FF tree — the
desired state after the fix.)

**Reading a failure:** `FIRST WRONG WORD j=... got ... want ... (tag N,
offset k=±m)` plus the `khist` histogram. A **uniform** `k` across all
128 words (the historical roll-3 signature was uniform k=−1; the roll-1/2
prime=0 tree showed k=+1 in the fixed-phase standard TB) = a
**stage-count/latency** bug in the read path. A **non-uniform** k or
garbage words = data-path (lane addressing, walk_in, gather) bug. A hung
build (watchdog after `PROBE start`/burst start, one cclk posedge, zero
negedges) = the ≥4-NBA-site stuck-line bug — run `tb_pmp_probe.sv` first.

## Gotchas

- **Build B = the working tree's `hdv_bridge.sv`.** To A/B a specific
  commit instead, `git show <commit>:src/fpga/core/hdv_bridge.sv >
  work/hdv_bridge_b.sv` and re-run (or point the script's `cp` there).
- **Provenance gate:** the run script FATALs if `hdd.v` / `hdd_rom.v` /
  `common.v` / `io_bridge_peripheral.v` / `altsyncram_sim.v` differ between
  `b5a3881` and `87e05b7`. If you change any of those in the tree, update
  the commit pair in `run_hdv_ab.sh` so the A/B assumption stays true.
- **ROM:** `hdd_rom.v`'s `$readmemh` is CWD-relative; the script copies
  `src/fpga/rtl/roms/hddrom.hex` to `./rtl/roms/` and runs the exes from
  this directory.
- **Tag pattern is byte-indexed, not word-indexed:** the machine writes
  `tagb(i)` per byte, so retained word `j` must equal
  `0xC0DE(4j+2)(4j+3)` (e.g. word 1 = `0xC0DE0607`). A word-indexed
  expectation (the naive `0xC0DEjjjj`) is a scoreboard bug, not a DUT bug.
- **`STAGE_PROBE=1`** makes the run very chatty (one line per sample and
  per strobe); it is off by default.
- **What this harness does NOT prove:** absolute kept-stream alignment on
  silicon. The Pocket host samples the DUT port at a placement-dependent
  phase on its own clock; this bench samples at a fixed phase (the real
  PMP protocol, but one fixed relationship). A shipping-clean Standard
  Fit roll + three-way HW test (explicit HDV write) remains the shipping
  gate; this harness is the authoritative *sim* check that the two trees
  are functionally identical.
