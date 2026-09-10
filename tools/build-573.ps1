# ---------------------------------------------------------------------------
# build-573.ps1 -- compile the Konami System 573 core on Windows.
#
#   powershell -ExecutionPolicy Bypass -File tools\build-573.ps1 -Root C:\dev\System573_MiSTer
#
# Adapted from build-psx.ps1 (psx-cloud-build). Same reason for existing: a bare
# `quartus_sh --flow compile` exits 0 on a design that does NOT meet timing, and
# a MiSTer bitstream that misses timing loads and then misbehaves in ways that
# look exactly like RTL bugs. This parses the timing report and fails loudly.
#
# Two things it checks that the PSX version does not:
#   * that psx_patches/ have been applied (the vendored core is useless without
#     them, and nothing on Windows can run the bash applier);
#   * the fitter's LAB occupancy, which is this design's real constraint.
# ---------------------------------------------------------------------------
param(
  [string]$Root    = ".",
  [string]$Quartus = "C:\intelFPGA_lite\17.0\quartus\bin64"
)

$ErrorActionPreference = "Stop"
$REV = "Konami_System_573"

$sh = Join-Path $Quartus "quartus_sh.exe"
if (-not (Test-Path $sh)) {
  Write-Host "quartus_sh.exe not found at $Quartus" -ForegroundColor Red
  Write-Host "Pass -Quartus <path to quartus\bin64> if you installed elsewhere."
  exit 2
}

Set-Location $Root
if (-not (Test-Path "$REV.qpf")) {
  Write-Host "No $REV.qpf here. Pass -Root <path to the System573_MiSTer tree>." -ForegroundColor Red
  exit 2
}

# --- the vendored core must be patched before it means anything -------------
# 0025 removes the IIR_filter instance from psx/sys/audio_out.v, so its presence
# is a reliable "patches not applied" tell.
if (-not (Test-Path "psx\rtl")) {
  Write-Host "psx/ is empty -- the PlayStation core submodule is not populated." -ForegroundColor Red
  exit 2
}
if (Select-String -Path "psx\sys\audio_out.v" -Pattern "IIR_filter" -Quiet) {
  Write-Host "psx_patches/ have NOT been applied to psx/." -ForegroundColor Red
  Write-Host "Run this on the Mac (or in Git Bash) before copying the tree over:"
  Write-Host "    tools/apply_psx_patches.sh"
  exit 2
}

Write-Host "== tree ==" -ForegroundColor Cyan
try { git log --oneline -1 } catch { }
Write-Host ""

Write-Host "== compiling (20-40 min) ==" -ForegroundColor Cyan
$start = Get-Date
& $sh --flow compile "$REV.qpf"
$rc = $LASTEXITCODE
$elapsed = [int]((Get-Date) - $start).TotalSeconds

if ($rc -ne 0) {
  Write-Host ""
  Write-Host "COMPILE FAILED. The errors, in order:" -ForegroundColor Red
  Get-ChildItem output_files\*.rpt -ErrorAction SilentlyContinue |
    Select-String -Pattern "^Error" | Select-Object -First 40 |
    ForEach-Object { "  " + $_.Line }
  exit 1
}

Write-Host ""
Write-Host "== results ($elapsed s) ==" -ForegroundColor Cyan

$fit = "output_files\$REV.fit.rpt"
$sta = "output_files\$REV.sta.rpt"
$failed = $false

if (Test-Path $fit) {
  Select-String -Path $fit -Pattern "Logic utilization|ALMs needed|Total LABs|Total registers|Total block memory bits|Total DSP" |
    Select-Object -First 8 | ForEach-Object { "  " + $_.Line.Trim() }

  # LAB occupancy is what actually breaks this design: routing congestion at
  # ~99% LABs, not a global resource shortage. Worth seeing every build.
  # Allow thousands separators in BOTH captures. An earlier version used (\d+)
  # for the first, which stops at the comma in "4,188 / 4,191": the engine then
  # matched "188 / 4,191" and printed 4.5% for a design at 100%. Wrong in the
  # reassuring direction, on the one number that explains this design's fits.
  $labs = Select-String -Path $fit -Pattern "Total LABs" | Select-Object -First 1
  if ($labs -and $labs.Line -match "([\d,]+)\s*/\s*([\d,]+)") {
    $used = [int]($matches[1] -replace ',','')
    $tot  = [int]($matches[2] -replace ',','')
    $pct  = [math]::Round(100.0 * $used / $tot, 1)
    if ($pct -ge 98) {
      Write-Host "  LABs $used/$tot = $pct% -- AT THE CONGESTION WALL; added logic risks the fit" -ForegroundColor Yellow
    } else {
      Write-Host "  LABs $used/$tot = $pct%" -ForegroundColor Green
    }
  }

  # Savestate entities: present means Quartus did NOT prune them.
  Write-Host ""
  Write-Host "  savestate entities (Resource Utilization by Entity):"
  # Anchor on the entity table's hierarchy cell. A bare "savestates|statemanager"
  # grep returns pages of Physical Synthesis "Modified" and router-duplication
  # chatter and never shows an area figure.
  $ss = Select-String -Path $fit -Pattern "^\s*;\s+\|(savestates|statemanager):" | Select-Object -First 4
  if ($ss) {
    $ss | ForEach-Object {
      $f = $_.Line.Split(';') | ForEach-Object { $_.Trim() }
      "    {0,-26} ALMs {1,-16} comb {2,-14} reg {3}" -f $f[1], $f[2], $f[7], $f[8]
    }
  } else {
    Write-Host '    (no entity row matched; pull by hand with:)'
    Write-Host '    findstr /C:"|savestates:isavestates|" output_files\Konami_System_573.fit.rpt'
  }
}

if (Test-Path $sta) {
  Write-Host ""
  Write-Host "  timing:"
  $neg = Select-String -Path $sta -Pattern '^\s*;\s*-\d'
  if ($neg) {
    Write-Host "  TIMING NOT MET:" -ForegroundColor Red
    $neg | Select-Object -First 12 | ForEach-Object { "    " + $_.Line.Trim() }
    Write-Host ""
    Write-Host "  A .rbf built from this will load and misbehave. Do not ship it." -ForegroundColor Red
    $failed = $true
  } else {
    Write-Host "    all corners non-negative" -ForegroundColor Green
  }
}

$rbf = Get-ChildItem output_files\*.rbf -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ""
if ($rbf) {
  "  bitstream: {0}  ({1:N1} MB)" -f $rbf.FullName, ($rbf.Length / 1MB)
  Write-Host "  Copy it to the DE10-Nano SD card and load it from the MiSTer menu."
} else {
  Write-Host "  No .rbf produced -- check GENERATE_RBF_FILE in $REV.qsf" -ForegroundColor Red
  $failed = $true
}

if ($failed) { exit 1 } else { exit 0 }
