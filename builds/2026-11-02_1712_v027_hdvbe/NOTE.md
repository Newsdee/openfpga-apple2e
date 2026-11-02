# Build 2026-11-02 1712 - v0.2.7 HDV big-endian bridge fix

## Root cause (closed)
The HDV (deferload, 0x0180 target-read path) DMA is BIG-ENDIAN (first file byte
in word[31:24], per bridge_endian_little = 0). hdv_bridge.sv was unpacking the
host word as LITTLE-endian (hdv_ram[byte0] = data[7:0]), so every 4-byte group
arrived byte-reversed -> corrupt block 0 -> garbage bootstrap. Symptom: Total
Replay "NO FILE RTSTRP.APPLE", Nox Archaist crash into the Apple monitor at
$C541. The sim masked it: its emulated host hardcoded LE, agreeing with the
(wrong) LE unpack.

The 0x0082 setup-load path (WOZ disk, joy2key profile) is LITTLE-endian and
works; only the 0x0180 path was the BE outlier. Fix touches only the 0x0180
path (hdv_bridge.sv); 0x0082 paths untouched.

## Change
- src/fpga/core/hdv_bridge.sv: host DMA write unpack + 0x0184 readout -> big-endian.
- verilog/pocket_boot/pocket_main.cpp: HDV hex gen -> !le (BE), sim now faithful.
- verilog/hdv_bridge/tb_hdv_bridge.sv: fake host writes BE words.

## Verification
- tb_hdv_bridge: 7/7 PASS.
- offline transform: BE host word + BE bridge unpack = file order (Nox block 0 exact).
- pocket_boot sim: builds clean.
- Hardware (2026-11-02): BOTH HDVs boot - Total Replay launcher (519 GAMES) and
  Nox Archaist title screen. N climbs past block 0 (observed N=46), M=1, F=0, E=0.

## Compile (owner-run, apf_stream_video, 5CEBA4F23C8, Quartus 17.0.2 Lite)
- map: Successful. fit: Successful, ALM 12,869/18,480 (70%), regs 14219, pins 224/224.
- sta: TNS 0.000 (all), min hold slack 0.103 ns.
- asm: Successful, 0 errors (1 benign 18236 processor hint).

## Artifacts
- apf_stream_video.rbf  sha256 2fb5540b0abb6d62552fad653cbba6b5ccfa65b4657f8c9c73577e3db96d2196
- bitstream.rbf_r       sha256 e779f970dd06caf66842dec60ef4d664f03adf415fc4038ecbcce5c872db1a51

## Open (minor, non-blocking)
- Transient "NO FILE" appears during HDV boot but the HDV still boots. Benign if
  F=0/E=0 (launcher's own optional-file probe). Confirm F/E on the NO FILE frame;
  if F=1 or E!=0, chase a bridge/host fault.
