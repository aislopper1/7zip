<#
test-smart-extract.ps1 - functional test for the "Smart Extract" feature
added to 7-Zip 26.05 (branch: smart-extract): the -sps console switch and the
"Smart Extract" context-menu command that uses it.

Semantics under test (identical to NanaZip Smart Extract):
  - more than one distinct top-level (root) name in the archive
      -> extract into a subfolder named after the archive
         (archive file name WITHOUT extension)
  - exactly one root name (one file, or one folder with content)
      -> extract in place
  - empty archive -> nothing extracted, no subfolder created
  - -sps- disables smart mode (must behave like stock 7-Zip)
  - no switch at all -> stock 7-Zip behavior must be unchanged

Usage:
  .\test-smart-extract.ps1                      (expects 7zr.exe next to this script)
  .\test-smart-extract.ps1 -SevenZr C:\path\to\7zr.exe

Exit code: 0 = all cases passed, 1 = at least one case failed.
#>
param(
  [string]$SevenZr = (Join-Path $PSScriptRoot '7zr.exe')
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SevenZr)) { throw ('7zr.exe not found: ' + $SevenZr) }
$SevenZr = (Resolve-Path $SevenZr).Path
Write-Output ('Binary under test: ' + $SevenZr)

$tempRoot = $env:TEMP
if (-not (Test-Path $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot | Out-Null }
$ws = Join-Path $tempRoot ('smart-extract-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ws | Out-Null
Write-Output ('Workspace: ' + $ws)

$script:failCount = 0
$script:rows = New-Object System.Collections.Generic.List[object]

function Add-Row([string]$Case, [bool]$Pass, [string]$Detail) {
  $script:rows.Add([pscustomobject]@{
    Case = $Case
    Result = $(if ($Pass) { 'PASS' } else { 'FAIL' })
    Detail = $Detail
  })
  if (-not $Pass) { $script:failCount++ }
}

function New-TestArchive([string]$ArcName, [string[]]$Items) {
  $arcPath = Join-Path $ws $ArcName
  $src = Join-Path $ws ($ArcName + '.src')
  New-Item -ItemType Directory -Path $src -Force | Out-Null
  foreach ($it in $Items) {
    $full = Join-Path $src $it
    $parent = Split-Path $full -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -Path $full -Value ('content of ' + $it)
  }
  Push-Location $src
  try {
    & $SevenZr a -t7z $arcPath @Items | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('archive creation failed for ' + $ArcName + ' (exit ' + $LASTEXITCODE + ')') }
  } finally { Pop-Location }
  return $arcPath
}

function Invoke-Extract([string]$ArcPath, [string]$OutDir, [string[]]$Switches) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
  $output = & $SevenZr x $ArcPath ('-o' + $OutDir) -y @Switches 2>&1
  return @{ Exit = $LASTEXITCODE; Text = ($output -join "`n") }
}

function Test-Case([string]$Id, [string]$Description, [string]$ArcPath, [string[]]$Switches,
                   [string[]]$MustExist, [string[]]$MustNotExist, [bool]$RequireZeroExit = $true) {
  $outDir = Join-Path $ws ('out-' + $Id)
  $r = Invoke-Extract $ArcPath $outDir $Switches
  $problems = @()
  if ($RequireZeroExit -and $r.Exit -ne 0) { $problems += ('exit code ' + $r.Exit) }
  foreach ($p in $MustExist) {
    if (-not (Test-Path (Join-Path $outDir $p))) { $problems += ('missing: ' + $p) }
  }
  foreach ($p in $MustNotExist) {
    if (Test-Path (Join-Path $outDir $p)) { $problems += ('unexpected: ' + $p) }
  }
  $pass = ($problems.Count -eq 0)
  $switch = ($Switches -join ' ')
  if ($switch -eq '') { $switch = '(none)' }
  $detail = if ($pass) { 'as expected' } else { ($problems -join '; ') }
  Add-Row ('[' + $Id + '] ' + $Description + ' {switches: ' + $switch + '}') $pass $detail
}

# ---- case 00: the help text must document the new switch ----
$helpText = (& $SevenZr 2>&1) -join "`n"
Add-Row '[00] console help lists -sps' ($helpText -match '-sps') $(if ($helpText -match '-sps') { 'as expected' } else { '-sps not found in help output' })

# ---- build the test archives (with the binary under test itself) ----
$arcMulti = New-TestArchive 'multi.7z' @('a.txt', 'dir\b.txt')
$arcOne = New-TestArchive 'one.7z' @('dir\b.txt', 'dir\c.txt')
$arcSingle = New-TestArchive 'single.7z' @('solo.txt')
$arcPrefix = New-TestArchive 'prefix.7z' @('dir\b.txt', 'dir2\c.txt')

# a truly EMPTY archive: add one file, then delete it
$arcEmpty = Join-Path $ws 'empty.7z'
$esrc = Join-Path $ws 'empty.7z.src'
New-Item -ItemType Directory -Path $esrc -Force | Out-Null
Set-Content -Path (Join-Path $esrc 'tmp.txt') -Value 'to be deleted'
Push-Location $esrc
try {
  & $SevenZr a -t7z $arcEmpty 'tmp.txt' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'empty-archive setup failed at create (a)' }
  & $SevenZr d $arcEmpty 'tmp.txt' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'empty-archive setup failed at delete (d)' }
} finally { Pop-Location }

# ---- the actual feature cases ----
Test-Case '01' 'multi-root + -sps -> subfolder named after archive' $arcMulti @('-sps') `
  @('multi\a.txt', 'multi\dir\b.txt') @('a.txt', 'dir\b.txt')

Test-Case '02' 'multi-root, no switch -> stock in-place behavior' $arcMulti @() `
  @('a.txt', 'dir\b.txt') @('multi')

Test-Case '03' 'multi-root + -sps- -> smart mode disabled' $arcMulti @('-sps-') `
  @('a.txt', 'dir\b.txt') @('multi')

Test-Case '04' 'single root folder + -sps -> extract in place' $arcOne @('-sps') `
  @('dir\b.txt', 'dir\c.txt') @('one\dir\b.txt', 'one')

Test-Case '05' 'single root file + -sps -> extract in place' $arcSingle @('-sps') `
  @('solo.txt') @('single\solo.txt', 'single')

Test-Case '06' 'empty archive + -sps -> no subfolder, nothing extracted' $arcEmpty @('-sps') `
  @() @('empty', 'tmp.txt') $false

Test-Case '07' 'roots sharing a prefix (dir, dir2) + -sps -> subfolder' $arcPrefix @('-sps') `
  @('prefix\dir\b.txt', 'prefix\dir2\c.txt') @('dir\b.txt')

# ---- summary ----
Write-Output ''
$script:rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
if ($script:failCount -gt 0) {
  Write-Output ('RESULT: ' + $script:failCount + ' case(s) FAILED - workspace kept for inspection: ' + $ws)
  exit 1
}
Write-Output 'RESULT: ALL CASES PASSED'
