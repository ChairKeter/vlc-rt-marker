<#
.SYNOPSIS
    Install VLC RT Marker for the current user.

.DESCRIPTION
    Copies the Lua interface script and the hidden watcher, then enables them in
    VLC's user configuration (vlcrc). No administrator rights, no service, no
    scheduled task, no registry changes.

    What gets written:
      %APPDATA%\vlc\lua\intf\rt-rc.lua     Lua interface script loaded by VLC
      %APPDATA%\vlc\rt-marker\             watcher (ps1 / vbs / keys.json)
      %APPDATA%\vlc\rt-launch.cmd          launcher used by the Lua script
      %APPDATA%\vlc\vlcrc                  extraintf / lua-intf / privacy / update keys

.PARAMETER Port
    Loopback control port (default 4212).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 4212
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoSrc = Join-Path (Split-Path $here) 'src'
$srcDir  = if (Test-Path (Join-Path $repoSrc 'rt-rc.lua')) { $repoSrc } else { $here }

$appdata    = $env:APPDATA
$luaIntfDir = Join-Path $appdata 'vlc\lua\intf'
$rtDir      = Join-Path $appdata 'vlc\rt-marker'
$launcher   = Join-Path $appdata 'vlc\rt-launch.cmd'
$vlcrc      = Join-Path $appdata 'vlc\vlcrc'
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Head($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Item($t, $color = 'Gray') { Write-Host "  $t" -ForegroundColor $color }

Write-Host "VLC RT Marker - install" -ForegroundColor Green
Write-Item "source: $srcDir"

# ---------------------------------------------------------------- preflight --
Write-Head 'preflight'

$vlcExe = $null
try {
    $dir = (Get-ItemProperty 'HKLM:\SOFTWARE\VideoLAN\VLC' -ErrorAction Stop).InstallDir
    if ($dir -and (Test-Path (Join-Path $dir 'vlc.exe'))) { $vlcExe = Join-Path $dir 'vlc.exe' }
} catch { }
if (-not $vlcExe) {
    $g = Get-ChildItem 'C:\Program Files*\VideoLAN\VLC\vlc.exe', 'C:\Program Files\VideoLAN\VLC\vlc.exe' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($g) { $vlcExe = $g.FullName }
}
if ($vlcExe) {
    $ver = (Get-Item $vlcExe).VersionInfo.ProductVersion
    Write-Item "VLC: $vlcExe (version $ver)"
    if ($ver -match '^\s*(\d+)' -and [int]$Matches[1] -ge 4) {
        Write-Item 'WARNING: VLC 4.x detected. This project targets VLC 3.x and was verified on 3.0.23.' 'Yellow'
    }
} else {
    Write-Item 'VLC installation not found in the registry (portable VLC?). See docs/TROUBLESHOOTING.md.' 'Yellow'
}

if (-not (Test-Path $vlcrc)) {
    throw @"
vlcrc not found: $vlcrc

  * Normal install: run VLC once, close it, then run this script again.
  * Portable VLC: it keeps its config next to vlc.exe. Use the manual setup
    described in docs/TROUBLESHOOTING.md instead of this script.
"@
}

$inUse = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($inUse) {
    Write-Item "WARNING: TCP port $Port is already in use (pid $($inUse[0].OwningProcess))." 'Yellow'
    Write-Item '         The marker will not start; free the port or pass -Port <other>.' 'Yellow'
}

$vlc = Get-Process vlc -ErrorAction SilentlyContinue
if ($vlc) {
    Write-Item 'VLC is running - closing it (VLC rewrites vlcrc on exit).' 'Yellow'
    $vlc | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# ------------------------------------------------------------ copy payload --
Write-Head 'install files'

if (-not (Test-Path $luaIntfDir)) { New-Item -ItemType Directory -Path $luaIntfDir -Force | Out-Null }
if (-not (Test-Path $rtDir))      { New-Item -ItemType Directory -Path $rtDir      -Force | Out-Null }

$need = @('rt-rc.lua', 'vlc-rt-marker.ps1', 'rt-launch.vbs')
foreach ($n in $need) {
    if (-not (Test-Path (Join-Path $srcDir $n))) { throw "missing source file: $n" }
}

Copy-Item (Join-Path $srcDir 'rt-rc.lua')         (Join-Path $luaIntfDir 'rt-rc.lua') -Force
Copy-Item (Join-Path $srcDir 'vlc-rt-marker.ps1') (Join-Path $rtDir 'vlc-rt-marker.ps1') -Force
Copy-Item (Join-Path $srcDir 'rt-launch.vbs')     (Join-Path $rtDir 'rt-launch.vbs') -Force

# keys.json: keep a user-edited copy
$keysDst = Join-Path $rtDir 'keys.json'
if (Test-Path $keysDst) {
    Write-Item 'keys.json exists - keeping user settings'
} elseif (Test-Path (Join-Path $srcDir 'keys.json')) {
    Copy-Item (Join-Path $srcDir 'keys.json') $keysDst -Force
    Write-Item 'keys.json installed'
}

Write-Item "lua interface: $luaIntfDir\rt-rc.lua"
Write-Item "watcher:       $rtDir"

$launcherBody = "@echo off`r`nwscript.exe `"$(Join-Path $rtDir 'rt-launch.vbs')`"`r`n"
[System.IO.File]::WriteAllText($launcher, $launcherBody, [System.Text.Encoding]::GetEncoding(936))
Write-Item "launcher:      $launcher"

# control port, read by both rt-rc.lua and the watcher
$portFile = Join-Path $rtDir 'port.txt'
[System.IO.File]::WriteAllText($portFile, "$Port`n", [System.Text.Encoding]::ASCII)
Write-Item "control port:  $Port ($portFile)"

# ------------------------------------------------------------- patch vlcrc --
Write-Head 'patch vlcrc'

$bak = "$vlcrc.bak-$stamp"
Copy-Item $vlcrc $bak -Force
Write-Item "backup: $bak"

# vlcrc is UTF-8 with BOM and LF line endings - keep it byte-faithful.
$text = [System.IO.File]::ReadAllText($vlcrc, [System.Text.Encoding]::UTF8)

function Set-VlcrcValue([string]$text, [string]$key, [string]$value, [string[]]$aliases) {
    $names = @($key) + $aliases
    foreach ($n in $names) {
        $pattern = "(?m)^#?\s*$([regex]::Escape($n))\s*=.*$"
        if ($text -match $pattern) {
            return [regex]::Replace($text, $pattern, "$key=$value", 1)
        }
    }
    return $text + "`n$key=$value"
}

$text = Set-VlcrcValue $text 'extraintf' 'luaintf' @()
$text = Set-VlcrcValue $text 'lua-intf'  'rt-rc'   @()
$text = Set-VlcrcValue $text 'qt-privacy-ask'  '0' @()
$text = Set-VlcrcValue $text 'qt-updates-notif' '0' @()

[System.IO.File]::WriteAllText($vlcrc, $text, (New-Object System.Text.UTF8Encoding($true)))
Write-Item 'extraintf=luaintf'
Write-Item 'lua-intf=rt-rc'
Write-Item 'qt-privacy-ask=0, qt-updates-notif=0'

# ----------------------------------------------------------------- verify ---
Write-Head 'verify'

$ok = $true
foreach ($pair in @(
    @{ p = (Join-Path $luaIntfDir 'rt-rc.lua');            what = 'lua interface' },
    @{ p = (Join-Path $rtDir 'vlc-rt-marker.ps1');         what = 'watcher' },
    @{ p = (Join-Path $rtDir 'rt-launch.vbs');             what = 'vbs launcher' },
    @{ p = $launcher;                                      what = 'cmd launcher' }
)) {
    if (Test-Path $pair.p) { Write-Item ("[OK]   {0}" -f $pair.what) 'Green' }
    else { Write-Item ("[MISS] {0}: {1}" -f $pair.what, $pair.p) 'Red'; $ok = $false }
}
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rtDir 'vlc-rt-marker.ps1'), [ref]$null, [ref]$errs)
if ($errs -and $errs.Count) { Write-Item "[FAIL] watcher has $($errs.Count) syntax error(s)" 'Red'; $ok = $false }
else { Write-Item '[OK]   watcher syntax' 'Green' }

Select-String -Path $vlcrc -Pattern '^extraintf=|^lua-intf=' | ForEach-Object { Write-Item ("vlcrc: " + $_.Line) }

Write-Host ""
if ($ok) {
    Write-Host 'Done. Start VLC and try R / T.' -ForegroundColor Green
} else {
    Write-Host 'Finished with problems - see messages above.' -ForegroundColor Red
}
Write-Host ''
Write-Host 'Logs:'
Write-Host "  $env:TEMP\vlc-rt-marker.log"
Write-Host "  $env:TEMP\rt-rc.log"
Write-Host ''
Write-Host 'Uninstall: powershell -ExecutionPolicy Bypass -File uninstall.ps1'
