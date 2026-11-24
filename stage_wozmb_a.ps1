# stage_wozmb_a.ps1 - stage the worktree's freshly compiled build (option A:
# ported controller + guard, 0.4.4 single-block transport) to the build dir,
# worktree sd_root, and K:. ALWAYS converts via rbf2rbf_r.py (per-byte
# bit-reversal) - never a plain .rbf copy (that boots as BRIDGE NOT
# RESPONDING; see builds/2026-11-24_0116_wozmb_burst_045/NOTE.md).
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File stage_wozmb_a.ps1
#         (after a successful quartus_sh --flow compile apf_apple2 in
#          apple2e-pocket-wozmb\src\fpga)
#
# Tags the core 0.4.5a (launcher-visible) so the A/B test bitstreams are
# unambiguous on the hardware.

$ErrorActionPreference = 'Stop'
$ROOT = 'E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket-wozmb'
$PY   = 'C:\msys64\ucrt64\bin\python.exe'
$REV  = 'E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\tools\rbf2rbf_r.py'
$RBF  = "$ROOT\src\fpga\output_files_apple2e\apf_apple2.rbf"
$OUT  = "$ROOT\output_files_apple2e_staged"
$B    = Join-Path $ROOT 'builds\2026-11-24_wozmb_guard_only_A_045'
$S    = "$ROOT\sd_root\Cores\Newsdee.Apple2e"
$K    = 'K:\Cores\Newsdee.Apple2e'

if (-not (Test-Path $RBF)) { Write-Error "no $RBF - compile first (quartus_sh --flow compile apf_apple2)"; exit 1 }

# 1) convert raw .rbf -> APF .rbf_r (bit-reversed)
New-Item -ItemType Directory -Force $OUT | Out-Null
& $PY $REV $RBF "$OUT\bitstream.rbf_r"
if ($LASTEXITCODE -ne 0) { Write-Error 'rbf2rbf_r failed'; exit 1 }

# 2) build dir: bitstream + 9 metadata + compile summaries
New-Item -ItemType Directory -Force $B | Out-Null
Copy-Item "$OUT\bitstream.rbf_r" "$B\bitstream.rbf_r" -Force
Copy-Item $RBF "$B\apf_apple2.rbf" -Force
Copy-Item "$ROOT\src\fpga\output_files_apple2e\apf_apple2.*.summary" $B -Force -ErrorAction SilentlyContinue
foreach ($f in 'core.json','interact.json','audio.json','data.json','icon.bin','input.json','variants.json','video.json') {
    Copy-Item "$S\$f" "$B\$f" -Force
}

# 3) version tag (byte-exact patch of core.json)
$cj = [System.IO.File]::ReadAllText("$B\core.json")
if ($cj -notmatch '"version"\s*:\s*"0\.4\.\d+"') { Write-Error 'no 0.4.x version field in core.json'; exit 1 }
$cj2 = $cj -replace '"version"\s*:\s*"0\.4\.\d+"', ('"version": "0.4.5a"')
[System.IO.File]::WriteAllText("$B\core.json", $cj2)

# 4) stage to worktree sd_root and K:
$FILES = 'bitstream.rbf_r','core.json','interact.json','audio.json','data.json','icon.bin','input.json','variants.json','video.json'
foreach ($f in $FILES) {
    Copy-Item "$B\$f" "$S\$f" -Force
    Copy-Item "$B\$f" "$K\$f" -Force
}

# 5) verify (hash-equality across all three locations)
$ok = $true
foreach ($f in $FILES) {
    $h = @{}
    foreach ($p in @("$B\$f","$S\$f","$K\$f")) {
        $h[$p] = (Get-FileHash $p -Algorithm SHA256).Hash
    }
    $vals = $h.Values | Select-Object -Unique
    if ($vals.Count -ne 1) { Write-Error "HASH MISMATCH $f"; $ok = $false }
}
if (-not $ok) { exit 1 }

$ver = (Select-String -Path "$K\core.json" -Pattern '"version"\s*:\s*"([^"]+)"').Matches[0].Groups[1].Value
$bh  = (Get-FileHash "$K\bitstream.rbf_r" -Algorithm SHA256).Hash
Write-Host "OK: staged 0.4.5a (build A: guard only, 0.4.4 transport) to sd_root + K:"
Write-Host "    core.json version: $ver"
Write-Host "    bitstream sha256 : $bh"
Write-Host 'Next: put the card in the Pocket, power-cycle, select the same disk.'
