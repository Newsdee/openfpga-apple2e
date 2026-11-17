$ErrorActionPreference = 'SilentlyContinue'
function Samp($baud, $ms) {
  $p = New-Object System.IO.Ports.SerialPort 'COM4', $baud, 'None', 8, 'One'
  try { $p.Open() } catch { Write-Output ('{0} baud: OPEN FAILED: {1}' -f $baud, $_.Exception.Message); return }
  $p.ReadTimeout = 100
  Write-Output ('{0} baud: opened' -f $baud)
  Start-Sleep -Milliseconds 100
  $b = New-Object byte[] 16384
  $n = 0
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    try { $n += $p.Read($b, $n, [Math]::Min(16384 - $n, 512)) } catch { break }
  }
  $p.Close()
  if ($n -eq 0) { Write-Output ('{0} baud: 0 bytes in {1}ms' -f $baud, $ms); return }
  $top = $b[0..($n-1)] | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 |
       ForEach-Object { '{0}:{1}' -f ('{0:X2}' -f $_.Name), $_.Count }
  $hex = (($b[0..([Math]::Min(31, $n-1))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
  Write-Output ('{0} baud: {1} bytes | top {2} | first32: {3}' -f $baud, $n, ($top -join ' '), $hex)
}
'COM4 probe (PuTTY must be closed)'
Samp 115200 500
Samp 116015 500
Samp 57600 500
Samp 230400 500
Samp 9600 400
