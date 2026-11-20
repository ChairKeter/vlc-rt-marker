<#
.SYNOPSIS
    Uninstall VLC RT Marker for the current user.

.DESCRIPTION
    Reverses what install.ps1 did, and only that:

      * stops the watcher process this project started
      * removes %APPDATA%\vlc\lua\intf\rt-rc.lua
      * removes %APPDATA%\vlc\rt-marker\
      * removes %APPDATA%\vlc\rt-launch.cmd
      * reverts ONLY the two vlcrc keys this project owns
        (extraintf, lua-intf) - every other VLC setting is left untouched

    The vlcrc backup taken at install time is NOT restored wholesale, because the
    user may have changed unrelated VLC settings since then.

.PARAMETER Force
    Do not ask for confirmation.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$appdata    = $env:APPDATA
$luaIntfDir = Join-Path $appdata 'vlc\lua\intf'
$rtDir      = Join-Path $appdata 'vlc\rt-marker'
$launcher   = Join-Path $appdata 'vlc\rt-launch.cmd'
$vlcrc      = Join-Path $appdata 'vlc\vlcrc'
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Head($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Item($t, $color = 'Gray') { Write-Host "  $t" -ForegroundColor $color }

Write-Host 'VLC RT Marker - uninstall' -ForegroundColor Green

if (-not $Force) {
    $answer = Read-Host 'Remove the marker from this user account? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; return }
}

# ------------------------------------------------------------- stop watcher --
Write-Head 'stop watcher'

$watchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*rt-marker*vlc-rt-marker.ps1*' })
if ($watchers.Count -eq 0) {
    Write-Item 'no watcher process running'
} else {
    foreach ($w in $watchers) {
        try { Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop; Write-Item "stopped pid $($w.ProcessId)" }
        catch { Write-Item "could not stop pid $($w.ProcessId): $($_.Exception.Message)" 'Yellow' }
    }
}

# VLC must be closed before editing vlcrc (it rewrites the file on exit).
$vlc = Get-Process vlc -ErrorAction SilentlyContinue
if ($vlc) {
    Write-Item 'VLC is running - closing it so vlcrc edits stick' 'Yellow'
    $vlc | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# ------------------------------------------------------------------ files ---
Write-Head 'remove files'

$targets = @(
    (Join-Path $luaIntfDir 'rt-rc.lua'),
    $launcher,
    (Join-Path $rtDir 'vlc-rt-marker.ps1'),
    (Join-Path $rtDir 'rt-launch.vbs'),
    (Join-Path $rtDir 'start-hidden.vbs'),   # legacy name from <= v0.9 installs
    (Join-Path $rtDir 'keys.json'),
    (Join-Path $rtDir 'port.txt'),
    (Join-Path $rtDir 'selftest.ps1')
)
foreach ($p in $targets) {
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-Item "removed $p" }
}
if (Test-Path $rtDir) {
    $left = @(Get-ChildItem $rtDir -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Remove-Item $rtDir -Force; Write-Item "removed $rtDir" }
    else { Write-Item "$rtDir kept (contains unrelated files: $($left.Name -join ', '))" 'Yellow' }
}

# ------------------------------------------------------------------ vlcrc ---
Write-Head 'revert vlcrc keys'

if (-not (Test-Path $vlcrc)) {
    Write-Item "vlcrc not found: $vlcrc (nothing to revert)" 'Yellow'
} else {
    Copy-Item $vlcrc "$vlcrc.bak-uninstall-$stamp" -Force
    $text = [System.IO.File]::ReadAllText($vlcrc, [System.Text.Encoding]::UTF8)
    $before = $text

    # extraintf: only touch it when it still points at our value.
    if ($text -match '(?m)^extraintf\s*=\s*luaintf\s*$') {
        $text = [regex]::Replace($text, '(?m)^extraintf\s*=\s*luaintf\s*$', '#extraintf=', 1)
        Write-Item 'extraintf: luaintf -> disabled'
    } else {
        Write-Item 'extraintf: not ours (left as is)' 'Yellow'
    }

    # lua-intf: same rule.
    if ($text -match '(?m)^lua-intf\s*=\s*rt-rc\s*$') {
        $text = [regex]::Replace($text, '(?m)^lua-intf\s*=\s*rt-rc\s*$', '#lua-intf=dummy', 1)
        Write-Item 'lua-intf: rt-rc -> disabled'
    } else {
        Write-Item 'lua-intf: not ours (left as is)' 'Yellow'
    }

    if ($text -ne $before) {
        [System.IO.File]::WriteAllText($vlcrc, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Item 'vlcrc written'
    } else {
        Write-Item 'vlcrc unchanged'
    }

    Write-Item 'note: qt-privacy-ask / qt-updates-notif were set to 0 at install and are NOT reverted.' 'Yellow'
}

Write-Host ''
Write-Host 'Uninstalled.' -ForegroundColor Green
Write-Host 'VLC will fall back to its built-in rc interface being disabled; restart VLC to apply.'
