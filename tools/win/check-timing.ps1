# check-timing.ps1 -- the timing verdict of an existing output_files\*.sta.rpt,
# same rule as tools\build-573.ps1: any negative number in the Multicorner
# Timing Analysis Summary fails. Exit 1 on failure.
#   powershell -ExecutionPolicy Bypass -File tools\win\check-timing.ps1 [-Sta path]
param([string]$Sta = "output_files\Konami_System_573.sta.rpt")
$mc = Select-String -Path $Sta -Pattern '^; Multicorner Timing Analysis Summary' | Select-Object -First 1
if (-not $mc) { Write-Host "no Multicorner Timing Analysis Summary in $Sta"; exit 2 }
$lines = Get-Content $Sta
$neg = @()
for ($i = $mc.LineNumber + 3; $i -lt $lines.Count; $i++) {
  $l = $lines[$i]
  if ($l -notmatch '^;') { break }
  $cols = $l.Split(';') | ForEach-Object { $_.Trim() }
  for ($c = 2; $c -lt $cols.Count; $c++) {
    if ($cols[$c] -match '^-\d') { $neg += $l.Trim(); break }
  }
}
$wc = Select-String -Path $Sta -Pattern '^; Worst-case Slack' | Select-Object -First 1
if ($wc) { $wc.Line.Trim() }
if ($neg.Count -gt 0) { "TIMING NOT MET:"; $neg | ForEach-Object { "  " + $_ }; exit 1 }
"all corners non-negative (multicorner summary)"; exit 0
