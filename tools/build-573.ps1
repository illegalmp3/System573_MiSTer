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
  [string]$Quartus = "C:\intelFPGA_lite\17.0\quartus\bin64",
  # -Crt builds the analog/CRT-only variant: uncomments the MISTER_DEBUG_NOHDMI
  # macro in the qsf for THIS compile only, then restores the file. Removes the
  # HDMI scaler (~2,256 ALM / ~25 DSP) and, more importantly, takes the binding
  # timing path with it -- pll_hdmi owns the +0.006 ns path, and the next-worst
  # setup is ~+0.505 ns. Omit the switch for a normal HDMI-capable build.
  [switch]$Crt,
  # -SynthOnly runs Analysis & Synthesis alone (~10 min) and prints its ALM estimate and
  # the per-entity table head, so an area change is measured before anyone waits ~55 min
  # for a fit (2026-10-24: every HDMI fit since 2026-10-20 sat at 99.8-100% LABs).
  [switch]$SynthOnly
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

# --- optional CRT-only variant: toggle the qsf macro, always restore ----------
$qsf       = "$REV.qsf"
$qsfBackup = $null
if ($Crt) {
  $marker = 'set_global_assignment -name VERILOG_MACRO "MISTER_DEBUG_NOHDMI=1"'
  $lines  = Get-Content $qsf
  if (-not ($lines -match [regex]::Escape($marker))) {
    Write-Host "Could not find the NOHDMI macro line in $qsf." -ForegroundColor Red
    Write-Host "Look for the S573_CRT_MACRO marker comment; the line may have been renamed."
    exit 2
  }
  $qsfBackup = "$qsf.prebuild"
  Copy-Item $qsf $qsfBackup -Force
  ($lines | ForEach-Object { if ($_ -eq "#$marker") { $marker } else { $_ } }) | Set-Content $qsf
  Write-Host "== CRT-only build: HDMI scaler REMOVED (MISTER_DEBUG_NOHDMI) ==" -ForegroundColor Yellow
  Write-Host "   no HDMI output; Direct Video forced on. Keep a known-good HDMI rbf." -ForegroundColor Yellow
  Write-Host ""
}
try {

Write-Host "== tree ==" -ForegroundColor Cyan
try { git log --oneline -1 } catch { }
Write-Host ""

# Clear the previous run's reports and bitstream first. A seed loop that copied
# output_files after a run that never started (rc -196608, missing script) archived the
# PREVIOUS seed's summaries under the new seed's name -- the identical "results" in
# local/builds/gfdm-r1-seed8..12 and gfdm-r2-seed1/2/6/7 are copies, not runs.
Get-ChildItem output_files -Include *.rpt,*.summary,*.rbf,*.sof -Recurse -ErrorAction SilentlyContinue |
  Remove-Item -Force -ErrorAction SilentlyContinue

if ($SynthOnly) {
  Write-Host "== analysis & synthesis only ==" -ForegroundColor Cyan
  $start = Get-Date
  & (Join-Path $Quartus "quartus_map.exe") --read_settings_files=on --write_settings_files=off $REV -c $REV
  $rc = $LASTEXITCODE
  $elapsed = [int]((Get-Date) - $start).TotalSeconds
  Write-Host "== synthesis rc=$rc ($elapsed s) ==" -ForegroundColor Cyan
  $ms = "output_files\$REV.map.summary"
  if (Test-Path $ms) { Get-Content $ms | ForEach-Object { "  " + $_ } }
  $map = "output_files\$REV.map.rpt"
  if (Test-Path $map) {
    Select-String -Path $map -Pattern '^Warning \(10030\):' |
      Where-Object { $_.Line -match 'File: .*[\\/]rtl[\\/]' } |
      ForEach-Object { "  UNDRIVEN: " + ($_.Line -replace ' File: .*$', '') }
  }
  if ($rc -ne 0) { exit 1 } else { exit 0 }
}

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
  # The multicorner summary is the verdict: one "Worst-case Slack" row over every
  # corner, then a row per clock. A negative number in ANY numeric column
  # (setup/hold/recovery/removal/min-pulse) fails the build.
  # (Until 2026-09-18 this looked for lines BEGINNING with a negative number,
  # which no row of this report ever does -- so every build was reported as
  # "all corners non-negative", including one with 283 endpoints at -1.7 ns.
  # Read the report, not the script's opinion of it.)
  $mc = Select-String -Path $sta -Pattern '^; Multicorner Timing Analysis Summary' | Select-Object -First 1
  $neg = @()
  if ($mc) {
    $lines = Get-Content $sta
    for ($i = $mc.LineNumber + 3; $i -lt $lines.Count; $i++) {
      $l = $lines[$i]
      if ($l -notmatch '^;') { break }
      $cols = $l.Split(';') | ForEach-Object { $_.Trim() }
      for ($c = 2; $c -lt $cols.Count; $c++) {
        if ($cols[$c] -match '^-\d') { $neg += ("{0}: {1}" -f $cols[1], $l.Trim()); break }
      }
    }
  } else {
    Write-Host "  (no Multicorner Timing Analysis Summary in $sta -- cannot judge timing)" -ForegroundColor Red
    $failed = $true
  }
  $wc = Select-String -Path $sta -Pattern '^; Worst-case Slack' | Select-Object -First 1
  if ($wc) { "    " + $wc.Line.Trim() }
  if ($neg.Count -gt 0) {
    Write-Host "  TIMING NOT MET:" -ForegroundColor Red
    $neg | Select-Object -First 12 | ForEach-Object { "    " + $_ }
    Write-Host ""
    Write-Host "  A .rbf built from this will load and misbehave. Do not ship it." -ForegroundColor Red
    Write-Host "  Failing paths: quartus_sta -t tools\timing_triage.tcl" -ForegroundColor Red
    $failed = $true
  } else {
    Write-Host "    all corners non-negative (multicorner summary)" -ForegroundColor Green
  }
}

# UNDRIVEN NETS in our own RTL. Quartus ties a net with no driver to 0 and
# carries on with a WARNING (10030) buried among ~20,000 others. 2026-09-28 job
# 130: emu.sv never assigned the flash saver's xtra_wr_ack, the boot LOAD stalled
# on the cassette block, the CPU stayed in reset and the cabinet showed a black
# screen with a working OSD. The top level is not simulated, so this is the only
# place that mistake can be caught before the card. Any 10030 whose file is under
# rtl/ fails the build; psx/ and sys/ carry a few known ones of their own.
$map = "output_files\$REV.map.rpt"
if (Test-Path $map) {
  $und = Select-String -Path $map -Pattern '^Warning \(10030\):' |
    Where-Object { $_.Line -match 'File: .*[\\/]rtl[\\/]' }
  if ($und) {
    Write-Host ""
    Write-Host "  UNDRIVEN NETS in rtl/ (Quartus tied them to 0):" -ForegroundColor Red
    $und | ForEach-Object { "    " + ($_.Line -replace ' File: .*$', '') }
    Write-Host "  A .rbf built from this has a wire you forgot. Do not ship it." -ForegroundColor Red
    $failed = $true
  } else {
    Write-Host "  undriven nets in rtl/: none" -ForegroundColor Green
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

}
finally {
  # restore the qsf whatever happened, so a failed or interrupted CRT build never
  # leaves the project silently switched to a no-HDMI configuration.
  if ($qsfBackup -and (Test-Path $qsfBackup)) {
    Move-Item $qsfBackup $qsf -Force
    Write-Host ""
    Write-Host "   ($qsf restored to its committed state)" -ForegroundColor DarkGray
  }
}

if ($failed) { exit 1 } else { exit 0 }
