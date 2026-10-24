<#
.SYNOPSIS
  Abandon Cities spike test: install, uninstall or collect logs. No Python needed.

.DESCRIPTION
  -Mode install    (default) copies the mod folder(s) next to this script into the Civ VI Mods folder.
  -Mode uninstall  removes those folders from the Mods folder again.
  -Mode collect    zips Lua.log, Modding.log, Database.log and UserInterface.log from the Logs folder
                   into a timestamped zip on the Desktop, to send back.
  All modes refuse to run while Civilization VI is running.
  The first run asks for the Mods and Logs folders (auto-detected, Enter accepts) and saves them in
  install_tester.config.json next to this script. -Reconfigure asks again.
  Normally you start this through INSTALL.bat, UNINSTALL.bat or COLLECT_LOGS.bat.
#>
[CmdletBinding()]
param(
    [ValidateSet("install", "uninstall", "collect")]
    [string]$Mode = "install",
    [string]$ModsDir,
    [string]$LogsDir,
    [string]$OutDir,          # where collect puts the zip (default: Desktop)
    [switch]$Reconfigure
)

$ErrorActionPreference = "Stop"
$PkgDir = $PSScriptRoot
$ConfigFile = Join-Path $PkgDir "install_tester.config.json"

# files that came in a downloaded zip carry a "blocked" mark; clear it for the package's own files
try { Get-ChildItem -LiteralPath $PkgDir -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }

# ---------------------------------------------------------------- Civ VI paths: detect, prompt, validate, save
function Get-CivDefaults {
    $game = "My Games\Sid Meier's Civilization VI"
    $docs = New-Object System.Collections.Generic.List[string]
    $docs.Add([Environment]::GetFolderPath('MyDocuments'))
    foreach ($v in 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') {
        $p = [Environment]::GetEnvironmentVariable($v)
        if ($p) { $docs.Add((Join-Path $p 'Documents')) }
    }
    if ($env:USERPROFILE) {
        $docs.Add((Join-Path $env:USERPROFILE 'Documents'))
        Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
            ForEach-Object { $docs.Add((Join-Path $_.FullName 'Documents')) }
    }
    $mods = $null
    foreach ($d in $docs) {
        if ($d -and (Test-Path -LiteralPath (Join-Path $d $game) -PathType Container)) { $mods = Join-Path $d "$game\Mods"; break }
    }
    if (-not $mods) { $mods = Join-Path $docs[0] "$game\Mods" }
    $logsBase = $env:LOCALAPPDATA
    if (-not $logsBase) { $logsBase = Join-Path $env:USERPROFILE "AppData\Local" }
    return @{ ModsDir = $mods; LogsDir = (Join-Path $logsBase "Firaxis Games\Sid Meier's Civilization VI\Logs") }
}

function Read-WithDefault([string]$label, [string]$default) {
    $a = Read-Host "$label`n  [$default]  (Enter = accept, or type another path)"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim().Trim('"')
}

function Confirm-YesNo([string]$question, [bool]$defaultYes) {
    $hint = if ($defaultYes) { "[Y/n]" } else { "[y/N]" }
    $a = Read-Host "$question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $defaultYes }
    return ($a.Trim() -match '^(y|yes)$')
}

function Test-ModsDirOk([string]$path) {
    # the parent "Sid Meier's Civilization VI" folder must exist; Mods itself is created after confirming
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) { Write-Host "  Please give a full path (like C:\...)." -ForegroundColor Yellow; return $false }
    $parent = Split-Path -Parent $path.TrimEnd('\')
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        Write-Host "  Not found: $parent" -ForegroundColor Yellow
        Write-Host "  The Mods folder must sit inside the game's user folder (Sid Meier's Civilization VI). Start the game once if it does not exist yet." -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        if (-not (Confirm-YesNo "  The Mods folder does not exist yet. Create it?" $true)) { return $false }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $true
}

function Test-LogsDirOk([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) { Write-Host "  Please give a full path (like C:\...)." -ForegroundColor Yellow; return $false }
    if (Test-Path -LiteralPath $path -PathType Container) { return $true }
    Write-Host "  Not found: $path" -ForegroundColor Yellow
    return (Confirm-YesNo "  The game creates this folder when it first runs. Use it anyway?" $false)
}

function Resolve-CivPaths([string]$cfgFile, [string]$mods, [string]$logs, [bool]$reconfigure) {
    # explicit parameters win and are never saved; otherwise saved config; otherwise prompts
    if ($mods -and $logs) { return @{ ModsDir = $mods; LogsDir = $logs } }
    $saved = $null
    if ((-not $reconfigure) -and (Test-Path -LiteralPath $cfgFile)) {
        try { $saved = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json } catch { $saved = $null }
        if ($saved -and (-not $saved.ModsDir -or -not $saved.LogsDir)) { $saved = $null }
    }
    if ($saved) {
        Write-Host ""
        Write-Host "Saved Civilization VI paths ($cfgFile):"
        Write-Host "  Mods folder: $($saved.ModsDir)"
        Write-Host "  Logs folder: $($saved.LogsDir)"
        if (Confirm-YesNo "Use these?" $true) {
            $m = if ($mods) { $mods } else { [string]$saved.ModsDir }
            $l = if ($logs) { $logs } else { [string]$saved.LogsDir }
            return @{ ModsDir = $m; LogsDir = $l }
        }
    }
    $def = Get-CivDefaults
    Write-Host ""
    Write-Host "Where is Civilization VI's user data? (Documents may live inside OneDrive.)"
    $m = $mods
    if (-not $m) {
        for ($i = 0; $i -lt 5 -and -not $m; $i++) {
            $c = Read-WithDefault "Civ VI Mods folder:" $def.ModsDir
            if (Test-ModsDirOk $c) { $m = $c }
        }
        if (-not $m) { throw "No valid Mods folder given." }
    }
    $l = $logs
    if (-not $l) {
        for ($i = 0; $i -lt 5 -and -not $l; $i++) {
            $c = Read-WithDefault "Civ VI Logs folder:" $def.LogsDir
            if (Test-LogsDirOk $c) { $l = $c }
        }
        if (-not $l) { throw "No valid Logs folder given." }
    }
    if (-not $mods -and -not $logs) {
        @{ ModsDir = $m; LogsDir = $l } | ConvertTo-Json | Set-Content -LiteralPath $cfgFile -Encoding UTF8
        Write-Host "Saved to $cfgFile (use -Reconfigure to change)." -ForegroundColor DarkGray
    }
    return @{ ModsDir = $m; LogsDir = $l }
}

function Write-Step([string]$msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

function Get-PackageMods {
    # only folders whose name starts with ABN are ever copied or removed
    Get-ChildItem -LiteralPath $PkgDir -Directory | Where-Object { $_.Name -match '^ABN' }
}

# ---------------------------------------------------------------- run
$game = Get-Process -Name "CivilizationVI*" -ErrorAction SilentlyContinue
if ($game) {
    Write-Host "Civilization VI is running. Quit the game completely (to the desktop), then run this again." -ForegroundColor Red
    exit 3
}

$paths = Resolve-CivPaths $ConfigFile $ModsDir $LogsDir ([bool]$Reconfigure)
$ModsDir = $paths.ModsDir
$LogsDir = $paths.LogsDir

switch ($Mode) {
    "install" {
        $mods = @(Get-PackageMods)
        if ($mods.Count -eq 0) { throw "No mod folders (ABN*) found next to this script. Unzip the whole package first." }
        foreach ($m in $mods) {
            $target = Join-Path $ModsDir $m.Name
            if ($m.Name -notmatch '^ABN') { throw "refusing to touch $($m.Name)" }
            Write-Step "Copying $($m.Name) -> $target"
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            Copy-Item -LiteralPath $m.FullName -Destination $target -Recurse -Force
            Write-Host "done"
        }
        Write-Host ""
        Write-Host "Installed." -ForegroundColor Green
        Write-Host "Next steps:"
        Write-Host "  1. Start Civilization VI and open Additional Content (main menu)."
        Write-Host "  2. Enable 'Abandon Cities Spike Tools (testing only)' and Gathering Storm."
        Write-Host "  3. Disable every other mod (Cheat Menu Panel, Simple UI Adjustments, VEF Dev Tools, anything else)."
        Write-Host "  4. Start a NEW game (never load an old save) and follow README_TESTER.md."
    }
    "uninstall" {
        $mods = @(Get-PackageMods)
        if ($mods.Count -eq 0) { throw "No mod folders (ABN*) found next to this script." }
        foreach ($m in $mods) {
            if ($m.Name -notmatch '^ABN') { throw "refusing to touch $($m.Name)" }
            $target = Join-Path $ModsDir $m.Name
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Write-Host "Removed $target" -ForegroundColor Green
            } else {
                Write-Host "Not installed: $target (nothing to remove)"
            }
        }
    }
    "collect" {
        if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) { throw "Logs folder not found: $LogsDir" }
        if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
        if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { throw "Output folder not found: $OutDir" }
        $names = "Lua.log", "Modding.log", "Database.log", "UserInterface.log"
        $found = @($names | ForEach-Object { Join-Path $LogsDir $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($found.Count -eq 0) { throw "None of the log files were found in $LogsDir. Did you play with the game closed to the desktop afterwards?" }
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $zip = Join-Path $OutDir "ABN_SpikeLogs_$stamp.zip"
        $info = Join-Path ([IO.Path]::GetTempPath()) "abn_collect_$stamp.txt"
        $lines = @("Collected: $(Get-Date -Format s)", "Logs folder: $LogsDir", "Mods folder: $ModsDir", "Installed ABN folders:")
        $lines += @(Get-ChildItem -LiteralPath $ModsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^ABN' } | ForEach-Object { "  $($_.Name)" })
        $lines += "Log files:"
        $lines += @($found | ForEach-Object { $i = Get-Item -LiteralPath $_; "  $($i.Name)  $($i.Length) bytes  $($i.LastWriteTime.ToString('s'))" })
        Set-Content -LiteralPath $info -Value $lines -Encoding UTF8
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in $found) {
                # copy first: the game may still hold a lock on a log
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ("abn_" + [IO.Path]::GetFileName($f))
                Copy-Item -LiteralPath $f -Destination $tmp -Force
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $tmp, [IO.Path]::GetFileName($f))
                Remove-Item -LiteralPath $tmp -Force
            }
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $info, "collect_info.txt")
        } finally { $za.Dispose(); Remove-Item -LiteralPath $info -Force -ErrorAction SilentlyContinue }
        Write-Host ""
        Write-Host "Created $zip" -ForegroundColor Green
        Write-Host "Files: $(($found | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"
        Write-Host "Send this zip, your screenshots and the filled-in Result lines."
    }
}
exit 0
