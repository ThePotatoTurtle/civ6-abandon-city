<#
.SYNOPSIS
  Abandon City install script: static checks -> mirror ABN\ into the game's Mods folder -> optional log tail.

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
    [string]$ModsDir = "C:\Users\goldf\OneDrive\OneNote\My Games\Sid Meier's Civilization VI\Mods",
    [string]$LogsDir = (Join-Path $env:LOCALAPPDATA "Firaxis Games\Sid Meier's Civilization VI\Logs"),
    [string]$Python = "python",
    [string]$Pattern = "ABN|Runtime Error|Syntax Error|stack traceback"
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ToolsDir
if (-not $Src)    { $Src    = Join-Path $ProjectDir "ABN" }
if (-not $DevSrc) { $DevSrc = Join-Path $ProjectDir "ABN_Dev" }

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
        Write-Host "Removed the local copy of Abandon City: $localAbn" -ForegroundColor Green
    } else {
        Write-Host "No local copy of Abandon City in $ModsDir (nothing to remove)."
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
