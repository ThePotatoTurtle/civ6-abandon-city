<#
.SYNOPSIS
  Builds the spike tester package: dist\ABN_SpikeTest_<devversion>\ and dist\ABN_SpikeTest_<devversion>.zip

.DESCRIPTION
  Contents: ABN_Dev\ (exactly the files its modinfo lists), ABN\ if it exists, install_tester.ps1,
  INSTALL.bat, UNINSTALL.bat, COLLECT_LOGS.bat and README_TESTER.md (sources in tools\tester\).
  The version comes from the ABN_Dev modinfo name ("... v0.0.0.1"). dist\ is gitignored.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\package_tester.ps1
#>
[CmdletBinding()]
param(
    [string]$DistDir
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ToolsDir
$TesterSrc = Join-Path $ToolsDir "tester"
if (-not $DistDir) { $DistDir = Join-Path $ProjectDir "dist" }

function Copy-ModFolder([string]$srcDir, [string]$dstDir, [string[]]$relFiles) {
    foreach ($rel in $relFiles) {
        $from = Join-Path $srcDir $rel
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "listed file missing: $from" }
        $to = Join-Path $dstDir $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
        Copy-Item -LiteralPath $from -Destination $to -Force
        if ((Get-FileHash -LiteralPath $from).Hash -ne (Get-FileHash -LiteralPath $to).Hash) { throw "copy differs: $rel" }
    }
}

function Get-RelFiles([string]$dir) {
    $root = (Resolve-Path -LiteralPath $dir).Path.TrimEnd('\')
    Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -notmatch '\.bak$|~$|^Thumbs\.db$' } |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) }
}

# --- dev tools: exactly what the modinfo lists
$devDir = Join-Path $ProjectDir "ABN_Dev"
$modinfo = Join-Path $devDir "ABN_Dev.modinfo"
if (-not (Test-Path -LiteralPath $modinfo)) { throw "not found: $modinfo" }
[xml]$xml = Get-Content -LiteralPath $modinfo -Raw -Encoding UTF8
$name = [string]$xml.Mod.Properties.Name
if ($name -notmatch 'v(\d+(\.\d+)+)') { throw "no version (vX.Y.Z) in the modinfo name: $name" }
$version = $Matches[1]
$listed = @($xml.SelectNodes('/Mod/Files/File') | ForEach-Object { $_.InnerText.Trim() -replace '/', '\' })
if ($listed.Count -eq 0) { throw "modinfo lists no files" }
$listed = @("ABN_Dev.modinfo") + $listed

$pkgName = "ABN_SpikeTest_$version"
$pkgDir = Join-Path $DistDir $pkgName
$zipPath = Join-Path $DistDir "$pkgName.zip"
if (Test-Path -LiteralPath $pkgDir) { Remove-Item -LiteralPath $pkgDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null

Copy-ModFolder $devDir (Join-Path $pkgDir "ABN_Dev") $listed

# --- main mod, once it exists
$abnDir = Join-Path $ProjectDir "ABN"
if (Test-Path -LiteralPath $abnDir -PathType Container) {
    Copy-ModFolder $abnDir (Join-Path $pkgDir "ABN") @(Get-RelFiles $abnDir)
    Write-Host "Included ABN\"
} else {
    Write-Host "ABN\ does not exist yet: package has the dev tools only"
}

# --- tester scripts and docs (CRLF so Notepad and cmd are happy)
foreach ($f in "install_tester.ps1", "INSTALL.bat", "UNINSTALL.bat", "COLLECT_LOGS.bat", "README_TESTER.md") {
    $src = Join-Path $TesterSrc $f
    if (-not (Test-Path -LiteralPath $src)) { throw "missing tester file: $src" }
    $text = (Get-Content -LiteralPath $src -Raw -Encoding UTF8) -replace "`r`n", "`n" -replace "`n", "`r`n"
    $enc = if ($f -like "*.ps1") { New-Object System.Text.UTF8Encoding($true) } else { New-Object System.Text.UTF8Encoding($false) }
    [IO.File]::WriteAllText((Join-Path $pkgDir $f), $text, $enc)
}

# --- zip with forward-slash entry names
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path -LiteralPath $pkgDir).Path.TrimEnd('\')
$za = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
        $entry = $pkgName + "/" + ($_.FullName.Substring($root.Length + 1) -replace '\\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $_.FullName, $entry)
    }
} finally { $za.Dispose() }

Write-Host ""
Write-Host "Package folder: $pkgDir" -ForegroundColor Green
Write-Host "Package zip:    $zipPath" -ForegroundColor Green
$zr = [IO.Compression.ZipFile]::OpenRead($zipPath)
try { $zr.Entries | ForEach-Object { Write-Host ("  {0,8}  {1}" -f $_.Length, $_.FullName) } } finally { $zr.Dispose() }
exit 0
