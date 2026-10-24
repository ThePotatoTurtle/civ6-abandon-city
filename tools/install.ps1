<#
.SYNOPSIS
  Abandon Cities install script: static checks -> mirror ABN\ into the game's Mods folder -> optional log tail.

.DESCRIPTION
  Default:     runs tools\check_all.py on ABN\ (and ABN_Dev\ with -Dev); aborts on errors unless -Force;
               then robocopy /MIR ABN\ -> <Mods>\ABN (and ABN_Dev\ -> <Mods>\ABN_Dev with -Dev).
  -DevOnly:    checks and installs ONLY ABN_Dev\ (the dev tools); <Mods>\ABN is not touched.
  -Uninstall:  removes ONLY the local copy <Mods>\ABN; <Mods>\ABN_Dev stays.
  Installing and -Uninstall refuse to run while Civilization VI is running (the game locks and caches
  mod files).
  -Watch:      after installing, tails Lua.log live, filtered to ABN lines and Lua errors.
               Start it after the game's main menu is up: the game recreates Lua.log at launch
               (the tail re-attaches when the file is recreated). Lua.log is buffered while playing;
               some output only appears after exiting to the menu or desktop.
  -WatchOnly:  tail without checking/installing.
  -CheckLogs:  only scan Database.log, Modding.log, Lua.log and UserInterface.log of the last run for
               ABN-related errors (tools\check_logs.py); exit code 1 if any.
  -Force:      install even when the static checks fail. -SkipChecks skips them. -Strict makes warnings fail.
  First run asks for the Civ VI Mods and Logs folders (auto-detected, Enter accepts) and saves them in
  tools\install.local.json (gitignored); later runs ask "Use these? [Y/n]". -Reconfigure asks again.
  -ModsDir / -LogsDir skip the prompts for this run (and are not saved).
  Mirroring deletes files in the target that no longer exist in the source; the target folders are ABN-owned.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\install.ps1
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Uninstall
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Force -Src D:\other\ABN
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$DevOnly,
    [switch]$Uninstall,
    [switch]$Watch,
    [switch]$WatchOnly,
    [switch]$CheckLogs,
    [switch]$Force,
    [switch]$SkipChecks,
    [switch]$Strict,
    [string]$Src,
    [string]$DevSrc,
    [string]$ModsDir,       # default: asked (detected from Documents, incl. OneDrive), then saved in tools\install.local.json
    [string]$LogsDir,       # default: asked (detected under %LOCALAPPDATA%), then saved
    [switch]$Reconfigure,   # ask for the Civ VI paths again even if saved
    [string]$Python = "python",
    [string]$Pattern = "ABN|Runtime Error|Syntax Error|stack traceback"
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ToolsDir
if (-not $Src)    { $Src    = Join-Path $ProjectDir "ABN" }
if (-not $DevSrc) { $DevSrc = Join-Path $ProjectDir "ABN_Dev" }
$ConfigFile = Join-Path $ToolsDir "install.local.json"

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

function Invoke-Python([string[]]$argList) {
    # Out-Host keeps python's output out of the function's return value
    & $Python @argList | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-LogCheck {
    Write-Step "Scanning logs in $LogsDir"
    $code = Invoke-Python @((Join-Path $ToolsDir "check_logs.py"), "--logs", $LogsDir, "--tail", "5")
    return $code
}

function Invoke-Mirror([string]$from, [string]$to) {
    if (-not (Test-Path -LiteralPath $from -PathType Container)) { throw "source folder not found: $from" }
    if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) { throw "Mods folder not found: $ModsDir" }
    # safety: only ever mirror into <ModsDir>\<same leaf name as the source>
    $leaf = Split-Path -Leaf $from
    $expected = Join-Path $ModsDir $leaf
    if ((Resolve-Path -LiteralPath $ModsDir).Path.TrimEnd('\') -ne (Split-Path -Parent $expected).TrimEnd('\')) { throw "refusing to mirror outside $ModsDir" }
    if ($to -ne $expected) { throw "refusing to mirror to $to (expected $expected)" }
    if ($leaf -notmatch '^ABN') { throw "refusing to mirror a folder that is not ABN-owned: $leaf" }
    Write-Step "Mirroring $from -> $to"
    & robocopy $from $to /MIR /NFL /NDL /NJH /NP /R:2 /W:1 /XF "*.bak" "*~" "Thumbs.db" | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
    Write-Host "robocopy ok (exit $rc)"
    $global:LASTEXITCODE = 0
}

function Start-LuaLogWatch {
    $log = Join-Path $LogsDir "Lua.log"
    Write-Step "Watching $log  (filter: $Pattern)  Ctrl+C to stop"
    Write-Host "Note: start this after the main menu is up; Lua.log is buffered while playing." -ForegroundColor DarkGray
    while ($true) {
        while (-not (Test-Path -LiteralPath $log)) { Start-Sleep -Milliseconds 500 }
        $created = (Get-Item -LiteralPath $log).CreationTime
        $job = Start-Job -ScriptBlock {
            param($path, $pat)
            Get-Content -LiteralPath $path -Wait -Tail 0 | Where-Object { $_ -match $pat }
        } -ArgumentList $log, $Pattern
        try {
            while ($true) {
                Receive-Job $job | ForEach-Object {
                    if ($_ -match 'Runtime Error|Syntax Error|stack traceback|ERROR') { Write-Host $_ -ForegroundColor Red }
                    else { Write-Host $_ }
                }
                Start-Sleep -Milliseconds 300
                # game relaunch recreates the file: re-attach
                if (-not (Test-Path -LiteralPath $log)) { break }
                if ((Get-Item -LiteralPath $log).CreationTime -ne $created) { Write-Host "-- Lua.log recreated, re-attaching" -ForegroundColor DarkGray; break }
                if ($job.State -ne 'Running') { break }
            }
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- modes
$paths = Resolve-CivPaths $ConfigFile $ModsDir $LogsDir ([bool]$Reconfigure)
$ModsDir = $paths.ModsDir
$LogsDir = $paths.LogsDir
if ($CheckLogs) {
    $code = Invoke-LogCheck
    exit $code
}
if ($WatchOnly) {
    Start-LuaLogWatch
    exit 0
}

# 0. the game must not be running while its Mods folder changes
$game = Get-Process -Name "CivilizationVI*" -ErrorAction SilentlyContinue
if ($game) {
    Write-Host "Civilization VI is running ($($game[0].ProcessName)). Quit the game, then run this again." -ForegroundColor Red
    exit 3
}
if ($Uninstall) {
    # only <Mods>\<leaf of ABN\>, never anything else (ABN_Dev stays)
    $leaf = Split-Path -Leaf $Src
    if ($leaf -ne "ABN") { throw "refusing to remove $leaf (only the ABN folder is removed)" }
    $localAbn = Join-Path $ModsDir $leaf
    if (Test-Path -LiteralPath $localAbn -PathType Container) {
        Remove-Item -LiteralPath $localAbn -Recurse -Force
        Write-Host "Removed the local copy of Abandon Cities: $localAbn" -ForegroundColor Green
    } else {
        Write-Host "No local copy of Abandon Cities in $ModsDir (nothing to remove)."
    }
    Write-Host "The dev tools (ABN_Dev) stay."
    exit 0
}
# 1. static checks
if (-not $SkipChecks) {
    $roots = @($Src)
    if (-not (Test-Path -LiteralPath $Src -PathType Container) -and -not $DevOnly) { Write-Host "Source folder not found: $Src" -ForegroundColor Red; exit 2 }
    if ($Dev) { $roots += $DevSrc }
    if ($DevOnly) { $roots = @($DevSrc) }
    Write-Step ("Static checks: " + ($roots -join ", "))
    $argList = @((Join-Path $ToolsDir "check_all.py")) + $roots + @("--no-checklist")
    if ($Strict) { $argList += "--strict" }
    $code = Invoke-Python $argList
    if ($code -ne 0) {
        if ($Force) {
            Write-Host "Checks FAILED (exit $code) - continuing because of -Force" -ForegroundColor Yellow
        } else {
            Write-Host "Checks FAILED (exit $code) - not installing. Fix the errors or rerun with -Force." -ForegroundColor Red
            exit $code
        }
    }
} else {
    Write-Host "Skipping static checks (-SkipChecks)" -ForegroundColor Yellow
}

# 2. mirror (-DevOnly: the dev tools only)
if (-not $DevOnly) { Invoke-Mirror $Src (Join-Path $ModsDir (Split-Path -Leaf $Src)) }
if ($Dev -or $DevOnly) { Invoke-Mirror $DevSrc (Join-Path $ModsDir (Split-Path -Leaf $DevSrc)) }
Write-Host ""
Write-Host "Installed. Enable the mod(s) in Additional Content, start/load a game, then run:" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs"

# 3. watch
if ($Watch) { Start-LuaLogWatch }
exit 0
