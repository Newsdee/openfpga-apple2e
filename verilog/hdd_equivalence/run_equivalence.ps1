# HDD (hdd.vhd -> hdd.v) VHDL/Verilog equivalence runner.
#
# Golden:  golden/hdd.vhd (documented shim of the original hdd.vhd for GHDL 6
#           case-construct strictness - see its header) + ORIGINAL hdd_rom.vhd
# Candidate: apple2e-pocket/src/fpga/core/hdd.v (+ hdd_rom.v) via Verilator
# Both TBs run the identical stimulus schedule and emit per-cycle CSV traces;
# this script compares field-by-field and enforces coverage gates.
#
# Prerequisites: C:\msys64\ucrt64\bin\ghdl.exe, verilator_bin.exe,
# mingw32-make.exe, sh.exe (see module_tests/disk_ii in the verilog repo).

param([switch]$CompareOnly)

$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$misterRtl   = 'E:\MiSTer\Apple-II_FPGAdev\Apple-II_MiSTer\rtl'
$portRoot    = "$here\..\..\src\fpga\core"
$ghdl        = 'C:\msys64\ucrt64\bin\ghdl.exe'
$verilator   = 'C:\msys64\ucrt64\bin\verilator_bin.exe'
$build       = Join-Path $here 'build'

New-Item -ItemType Directory -Force -Path $build | Out-Null
Remove-Item -ErrorAction SilentlyContinue (Join-Path $build 'work-*')
Set-Location $here

# --- 0. ROM copy integrity (the Verilator DUT reads rtl/roms/hddrom.hex
#      relative to CWD; it must be byte-identical to the shipping copy)
$hexShipping = "$here\..\..\src\fpga\rtl\roms\hddrom.hex"
$hexLocal    = "$here\rtl\roms\hddrom.hex"
$h1 = (Get-FileHash $hexShipping -Algorithm SHA256).Hash
$h2 = (Get-FileHash $hexLocal -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw "hddrom.hex copies diverge: $h1 vs $h2" }
Write-Output "hddrom.hex copy OK (sha256 $h1)"

if (-not $CompareOnly) {
    # --- 1. Golden: GHDL against the (shimmed) ORIGINAL VHDL. hdd_rom.vhd
    #      must be analyzed first (hdd.vhd's port map references work.hdd_rom).
    & $ghdl -a --std=08 --workdir=$build "$misterRtl\hdd_rom.vhd" "$here\golden\hdd.vhd" "$here\hdd_vhdl_tb.vhd"
    if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed" }
    & $ghdl -e --std=08 --workdir=$build hdd_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e failed" }
    & $ghdl -r --std=08 --workdir=$build hdd_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -r failed" }

    # --- 2. Candidate: Verilator
    $env:PATH = "C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;$env:PATH"
    $env:TMP = $env:TEMP = $env:TMPDIR = 'C:\msys64\tmp'
    $env:VERILATOR_ROOT = 'C:/msys64/ucrt64/share/verilator'
    $env:SHELL = 'C:\msys64\usr\bin\sh'
    Remove-Item -ErrorAction SilentlyContinue (Join-Path $build 'obj') -Recurse
    & $verilator --binary --timing -Wno-fatal --Mdir (Join-Path $build 'obj') -sv "$here\hdd_verilog_tb.sv" "$portRoot\hdd.v" "$portRoot\hdd_rom.v" "$here\..\stubs\altsyncram_sim.v"
    if ($LASTEXITCODE -ne 0) { throw "verilator failed" }
    & (Join-Path $build 'obj\Vhdd_verilog_tb.exe')
    if ($LASTEXITCODE -ne 0) { throw "verilator tb run failed" }
}

# --- 3. Compare
$vhdlRows    = @(Import-Csv (Join-Path $build 'vhdl_trace.csv'))
$verilogRows = @(Import-Csv (Join-Path $build 'verilog_trace.csv'))

if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "row count mismatch: vhdl=$($vhdlRows.Count) verilog=$($verilogRows.Count)"
}

$columns = @('CYCLE','RESET','IO_SELECT','DEVICE_SELECT','RD','A_LOW','D_IN','D_OUT','SECTOR',
             'HDD_READ','HDD_WRITE','MOUNTED','PROTECT','RAM_ADDR','RAM_WE','RAM_DI','RAM_DO')

$comparedFields = 0
$ignoredMetavalues = 0
$mismatches = New-Object System.Collections.Generic.List[string]

for ($r = 0; $r -lt $vhdlRows.Count; $r++) {
    foreach ($col in $columns) {
        # Trim: the Verilator $fwrite space-pads values to argument width.
        # PSCustomObject needs dot notation, not ['col'] indexing.
        # The VHDL side prints std_logic with quotes ('0'/'1'/'U'); strip
        # them so both sides compare on bare values.
        $v = ([string]$vhdlRows[$r].$col).Trim().Trim("'")
        $u = ([string]$verilogRows[$r].$col).Trim().Trim("'")
        if ($v -match "^[UXWX-]$" -or $v -eq '-1' -or $v -match "^[UWXZ]" -or $v -match "^'[UXWZ]'$") {
            $ignoredMetavalues++
            continue
        }
        if ($v -ne $u) {
            if ($mismatches.Count -lt 20) {
                $mismatches.Add("row $($vhdlRows[$r].CYCLE) col ${col}: vhdl=$v verilog=$u")
            }
        }
        $comparedFields++
    }
}

if ($mismatches.Count -gt 0) {
    Write-Output "FIRST MISMATCHES:"
    $mismatches | ForEach-Object { Write-Output "  $_" }
    throw "HDD EQUIVALENCE FAIL: $($mismatches.Count) field mismatches"
}

# --- 4. Coverage gates (run against the VHDL trace; the differential check
#        already proved the candidate matches it)
$gates = @{}

# G1: ROM sweep - the ROM readout has two registered stages (hdd_rom dout,
# then D_OUT). The schedule holds IO_SELECT+A=C6FF for c=266..267 (drain),
# so rows 11..265 carry ROM[0..254] and ROM[255] must appear in rows 266..270.
$hexBytes = @([System.IO.File]::ReadAllLines($hexShipping)) | ForEach-Object { [convert]::ToInt32($_, 16) }
$romBad = 0
for ($k = 0; $k -lt 255; $k++) {
    $row = $vhdlRows[11 + $k]
    if ([int]$row.D_OUT -ne $hexBytes[$k]) { $romBad++; if ($romBad -le 3) { Write-Output "  ROM bad at row $($row.CYCLE): dut=$($row.D_OUT) hex=$($hexBytes[$k])" } }
}
$romLastSeen = $false
for ($r = 266; $r -le 270 -and $r -lt $vhdlRows.Count; $r++) {
    if ([int]$vhdlRows[$r].D_OUT -eq $hexBytes[255]) { $romLastSeen = $true }
}
$gates['rom_bytes_ok'] = ($romBad -eq 0) -and $romLastSeen

# G2: command pulses (std_logic columns print quoted: '0'/'1')
$hddReadPulses  = @($vhdlRows | Where-Object { $_.HDD_READ.Trim() -eq "'1'" }).Count
$hddWritePulses = @($vhdlRows | Where-Object { $_.HDD_WRITE.Trim() -eq "'1'" }).Count
$gates['hdd_read_pulses>=2']   = ($hddReadPulses -ge 2)
$gates['hdd_write_pulses>=2']  = ($hddWritePulses -ge 2)

# G3: status codes observed (28 = NO_DEVICE, 2B = PROTECT, 00 = OK)
$gates['no_device_0x28>=6'] = @($vhdlRows | Where-Object { $_.D_OUT.Trim() -eq '40' }).Count -ge 6
$gates['protect_0x2b>=2']   = @($vhdlRows | Where-Object { $_.D_OUT.Trim() -eq '43' }).Count -ge 2

# G4: 512-byte wrap (behaviour level): after VERIFY1's 511st read (D_OUT =
# p(511) at row 2922), the next C0F8 read (VERIFY2 k=0, row 5200) must return
# q(0) - proving sec_addr wrapped 511 -> 0 (if it had stuck at 511 it would
# return q(511)).
$wrapRow = $vhdlRows[5200]
$wrapExpect = (13*0 + 3) % 256
$gates['sec_addr_511_to_0_wrap'] = ([int]$wrapRow.D_OUT -eq $wrapExpect) -and ([int]$vhdlRows[2922].D_OUT -eq ((31*511 + 7) % 256))

# G5: RAMREAD phase - ram_do must be the WALK pattern p(k)=(31k+7) mod 256
$ramBad = 0
for ($k = 0; $k -lt 512; $k++) {
    $row = $vhdlRows[3000 + 2*$k]
    $expect = (31*$k + 7) % 256
    if ([int]$row.RAM_DO -ne $expect -and [string]$row.RAM_DO -ne '-1') { $ramBad++ }
}
$gates['ramread_512_bytes'] = ($ramBad -eq 0)

# G6: VERIFY2 phase - C0F8 reads return the RAMWRITE pattern q(k)=(13k+3) mod 256
$v2Bad = 0
for ($k = 0; $k -lt 512; $k++) {
    $row = $vhdlRows[5200 + 2*$k]
    $expect = (13*$k + 3) % 256
    if ([int]$row.D_OUT -ne $expect) { $v2Bad++ }
}
$gates['verify2_512_bytes'] = ($v2Bad -eq 0)

# G7: metavalue rows must exist (golden starts uninitialized; the skip is for
#     the right reason, not an empty pass)
$gates['metavalues>0'] = ($ignoredMetavalues -gt 0)

$gateOk = $true
foreach ($k in $gates.Keys) {
    Write-Output ("gate {0,-28} {1}" -f $k, $gates[$k])
    if (-not $gates[$k]) { $gateOk = $false }
}

if (-not $gateOk) { throw "HDD EQUIVALENCE FAIL: coverage gate(s) not met" }

Write-Output "HDD EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues hdd_read=$hddReadPulses hdd_write=$hddWritePulses"
