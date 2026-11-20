<#
.SYNOPSIS
    Build the portable release zip for a given version.

.DESCRIPTION
    Collects the payload that a user actually needs, writes INSTALL.txt, zips it into
    release\vlc-rt-marker-v<version>-portable.zip and emits a .sha256 file next to it.

    The zip is intentionally flat: install.ps1 / uninstall.ps1 / selftest.ps1 sit next to
    the sources, which is the layout install.ps1 also accepts (it falls back to its own
    directory when ..\src does not exist).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir  = Join-Path $root 'release'
$stage   = Join-Path ([System.IO.Path]::GetTempPath()) ("vlc-rt-marker-" + [guid]::NewGuid().ToString('N'))
$zipName = "vlc-rt-marker-v$Version-portable.zip"
$zipPath = Join-Path $outDir $zipName

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
New-Item -ItemType Directory -Path $stage | Out-Null

try {
    # payload
    Copy-Item (Join-Path $root 'installer\install.ps1')   $stage -Force
    Copy-Item (Join-Path $root 'installer\uninstall.ps1') $stage -Force
    Copy-Item (Join-Path $root 'installer\selftest.ps1')  $stage -Force
    Copy-Item (Join-Path $root 'src\rt-rc.lua')           $stage -Force
    Copy-Item (Join-Path $root 'src\vlc-rt-marker.ps1')   $stage -Force
    Copy-Item (Join-Path $root 'src\rt-launch.vbs')       $stage -Force
    Copy-Item (Join-Path $root 'src\keys.json')           $stage -Force
    Copy-Item (Join-Path $root 'README.md')               $stage -Force
    Copy-Item (Join-Path $root 'LICENSE')                 $stage -Force

    $install = @"
VLC RT Marker v$Version - quick start
=====================================

Requirements: Windows 10/11, VLC 3.x (verified on 3.0.23). No admin rights needed.

1. Start VLC once, then close it   (this creates %APPDATA%\vlc\vlcrc)
2. Right-click install.ps1 -> "Run with PowerShell"
   or:  powershell -ExecutionPolicy Bypass -File install.ps1
3. Open VLC, play something, press R to save, T to jump back.

Config:  %APPDATA%\vlc\rt-marker\keys.json   (save / jump / tips)
Port:    %APPDATA%\vlc\rt-marker\port.txt    (default 4212)
Logs:    %TEMP%\vlc-rt-marker.log  and  %TEMP%\rt-rc.log

Uninstall:
    powershell -ExecutionPolicy Bypass -File uninstall.ps1

Full documentation: see the GitHub repository (README.md, docs/).
"@
    [System.IO.File]::WriteAllText((Join-Path $stage 'INSTALL.txt'), $install, (New-Object System.Text.UTF8Encoding($true)))

    # sanity: the three must-have files
    foreach ($n in @('install.ps1', 'rt-rc.lua', 'vlc-rt-marker.ps1', 'rt-launch.vbs')) {
        if (-not (Test-Path (Join-Path $stage $n))) { throw "payload incomplete: $n" }
    }

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal

    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    $sha  = "$hash  $zipName"
    [System.IO.File]::WriteAllText("$zipPath.sha256", $sha + "`n", (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ""
    Write-Host "built: $zipPath" -ForegroundColor Green
    Write-Host ("size : {0:N1} KB" -f ((Get-Item $zipPath).Length / 1KB))
    Write-Host "sha256:"
    Write-Host "  $hash"
    Write-Host ""
    Write-Host "paste the hash into the release notes:"
    Write-Host "  $sha"
}
finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
