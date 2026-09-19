# ---------------------------------------------------------------------------
# jobrunner.ps1 -- run job files dropped into local\jobs\queue, one at a time.
#
#   powershell -ExecutionPolicy Bypass -File tools\win\jobrunner.ps1
#
# WHY. All work on this project now happens on this Windows PC, and the session
# driving it can read and write files in this folder but has no shell here. This
# runner is that shell, with a paper trail: every job is a file you can read
# before it runs, and every job leaves its full output next to it.
#
#   local\jobs\queue\NNN-name.cmd   -> run with cmd.exe (Windows side: Quartus, git)
#   local\jobs\queue\NNN-name.ps1   -> run with powershell.exe
#   local\jobs\queue\NNN-name.sh    -> run in WSL as root, from the project dir
#                                      (Linux side: Icarus/NVC sims, firmware build)
#
# Jobs run in name order, one at a time. When a job ends its script is moved to
# local\jobs\done\ together with NAME.log (stdout+stderr) and NAME.rc (exit code).
# A job file that ends in .hold is left alone (write it as .hold, rename when
# complete, so a half-written job never runs).
#
# Ctrl-C stops the runner; a running job is not killed (Quartus builds are long).
# local\ is git-ignored, so nothing here ends up in a commit.
# ---------------------------------------------------------------------------
param(
  [string]$Root   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
  [string]$Distro = "Ubuntu-24.04",
  [int]$PollSeconds = 2
)

$ErrorActionPreference = "Continue"
$queue = Join-Path $Root "local\jobs\queue"
$done  = Join-Path $Root "local\jobs\done"
New-Item -ItemType Directory -Force -Path $queue, $done | Out-Null

# the project dir as WSL sees it: C:\Users\ricky\... -> /mnt/c/Users/ricky/...
function To-WslPath([string]$p) {
  $p = (Resolve-Path $p).Path
  $drive = $p.Substring(0,1).ToLower()
  $rest  = $p.Substring(2) -replace '\\','/'
  return "/mnt/$drive$rest"
}
$wslRoot = To-WslPath $Root

Write-Host "== jobrunner: root $Root" -ForegroundColor Cyan
Write-Host "   queue  $queue"
Write-Host "   done   $done"
Write-Host "   WSL    $Distro  ($wslRoot)"
Write-Host "   waiting for jobs (Ctrl-C to stop)" -ForegroundColor DarkGray

while ($true) {
  $job = Get-ChildItem -Path $queue -File |
         Where-Object { $_.Extension -in ".cmd", ".ps1", ".sh" } |
         Sort-Object Name | Select-Object -First 1
  if (-not $job) { Start-Sleep -Seconds $PollSeconds; continue }

  $name = [System.IO.Path]::GetFileNameWithoutExtension($job.Name)
  $log  = Join-Path $done "$name.log"
  $rcf  = Join-Path $done "$name.rc"
  $t0   = Get-Date
  Write-Host ("== {0}  START {1}" -f $t0.ToString("HH:mm:ss"), $job.Name) -ForegroundColor Yellow

  # header so a log is self-describing even when read days later
  "### job $($job.Name) started $($t0.ToString('yyyy-MM-dd HH:mm:ss'))" | Set-Content -Path $log -Encoding UTF8

  $rc = -1
  try {
    switch ($job.Extension) {
      ".cmd" {
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$($job.FullName)`"" `
               -WorkingDirectory $Root -NoNewWindow -Wait -PassThru `
               -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
        $rc = $p.ExitCode
      }
      ".ps1" {
        $p = Start-Process -FilePath "powershell.exe" `
               -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($job.FullName)`"" `
               -WorkingDirectory $Root -NoNewWindow -Wait -PassThru `
               -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
        $rc = $p.ExitCode
      }
      ".sh" {
        # root inside WSL needs no password; the job starts in the project dir.
        # tr strips CRLF in case the job was written with Windows line endings.
        $wslJob = To-WslPath $job.FullName
        $cmd = "cd '$wslRoot' && tr -d '\r' < '$wslJob' > /tmp/job.sh && bash /tmp/job.sh"
        $p = Start-Process -FilePath "wsl.exe" `
               -ArgumentList "-d", $Distro, "-u", "root", "--", "bash", "-lc", "`"$cmd`"" `
               -WorkingDirectory $Root -NoNewWindow -Wait -PassThru `
               -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
        $rc = $p.ExitCode
      }
    }
  } catch {
    "### runner error: $_" | Add-Content -Path $log
    $rc = 999
  }

  # merge stdout/stderr into the single log, in that order
  foreach ($part in @("$log.out", "$log.err")) {
    if (Test-Path $part) {
      if ($part.EndsWith(".err")) { "### stderr:" | Add-Content -Path $log }
      Get-Content $part -ErrorAction SilentlyContinue | Add-Content -Path $log
      Remove-Item $part -ErrorAction SilentlyContinue
    }
  }
  $t1 = Get-Date
  "### job $($job.Name) ended $($t1.ToString('yyyy-MM-dd HH:mm:ss')) rc=$rc elapsed=$([int]($t1-$t0).TotalSeconds)s" | Add-Content -Path $log
  Set-Content -Path $rcf -Value $rc
  Move-Item -Path $job.FullName -Destination (Join-Path $done $job.Name) -Force
  $color = if ($rc -eq 0) { "Green" } else { "Red" }
  Write-Host ("== {0}  END   {1}  rc={2}  ({3}s)" -f $t1.ToString("HH:mm:ss"), $job.Name, $rc, [int]($t1-$t0).TotalSeconds) -ForegroundColor $color
}
