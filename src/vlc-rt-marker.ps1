<#
    vlc-rt-marker.ps1  ——  VLC 播放器 "R/T 时间标记"

    功能
      R  = 保存当前播放时间（再按覆盖上一次）
      T  = 跳回上次保存的时间；没有保存点就不跳，只提示
      新音频/视频 = 保存点自动清空（VLC 的 "new input" 事件实时判定）
      只有 VLC 是前台窗口时按键才生效；不吞键，不影响其它软件

    原理
      VLC 自带 RC 接口（--extraintf rc --rc-host 127.0.0.1:4212），
      纯文本 TCP：get_time 读秒、seek N 绝对跳转、new input 事件通知换片。
      本脚本常驻后台，轮询 R/T 按键并复用一条 RC 连接。

    用法
      wscript start-hidden.vbs                                无窗口后台运行
      powershell -ExecutionPolicy Bypass -File vlc-rt-marker.ps1
#>
[CmdletBinding()]
param(
    [string]$RcHost = '127.0.0.1',
    [int]   $RcPort = 0,   # 0 = read from %APPDATA%\vlc\rt-marker\port.txt (fallback 4212)
    [int]   $PollMs = 40,
    [string]$SaveKey = '',
    [string]$JumpKey = '',
    [int]   $ExitAfterMissing = 8,
    [int]   $ConnectTimeout = 30,
    [switch]$StayAlive,
    [switch]$GlobalKeys,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# 端口：显式参数 > port.txt > 4212（与 rt-rc.lua 保持一致）
if ($RcPort -le 0) {
    $RcPort = 4212
    $portFile = Join-Path $env:APPDATA 'vlc\rt-marker\port.txt'
    if (Test-Path -LiteralPath $portFile) {
        $raw = (Get-Content -LiteralPath $portFile -TotalCount 1 -ErrorAction SilentlyContinue)
        $n = 0
        if ([int]::TryParse(("$raw").Trim(), [ref]$n) -and $n -gt 0 -and $n -lt 65536) { $RcPort = $n }
    }
}

# ---------------------------------------------------------------- Win32 -----
if (-not ('VlcRtNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VlcRtNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
'@
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------ log -----
$script:LogPath = Join-Path $env:TEMP 'vlc-rt-marker.log'
function Write-Log([string]$m) {
    try {
        Add-Content -Path $script:LogPath -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
    } catch { }
}

# --------------------------------------------------------------- notify -----
$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon    = [System.Drawing.SystemIcons]::Application
$script:Notify.Visible = $true
$script:Notify.Text    = 'VLC R/T 标记（R=保存  T=跳转）'

$script:Quiet    = $false
$script:LastTip = ''
$script:LastTipAt = [datetime]::MinValue
function Show-Tip {
    param([string]$Message)
    Write-Log "TIP  $Message"
    if ($script:Quiet) { return }
    if ($Message -eq $script:LastTip -and ((Get-Date) - $script:LastTipAt).TotalSeconds -lt 3) { return }
    $script:LastTip = $Message
    $script:LastTipAt = Get-Date
    try {
        $script:Notify.ShowBalloonTip(1200, 'VLC R/T 标记', $Message, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

# ----------------------------------------------------------------- state ----
$script:Tcp           = $null
$script:Stream        = $null
$script:RxText        = ''
$script:Buf           = New-Object byte[] 8192
$script:Numeric       = New-Object System.Collections.Generic.List[double]
$script:CurrentUri    = $null
$script:SavedSeconds  = $null
$script:SavedUri      = $null
$script:WarnedDown    = $false
$script:NeedSeed      = $false
$script:NextBeat      = [datetime]::MinValue
$script:NextRetry     = [datetime]::MinValue
$script:FirstFailAt   = [datetime]::MinValue

# pid -> 是否 VLC（缓存，避免每次 Get-Process）
$script:PidCache = @{}

# ------------------------------------------------------------- formatting ---
function Format-Time {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $h = [int][math]::Floor($Seconds / 3600)
    $m = [int][math]::Floor(($Seconds % 3600) / 60)
    $s = $Seconds % 60
    if ($h -gt 0) { return ('{0}:{1:00}:{2:00.000}' -f $h, $m, $s) }
    return ('{0}:{1:00.000}' -f $m, $s)
}

function Get-DisplayName {
    param([string]$Uri)
    if (-not $Uri) { return '当前媒体' }
    try {
        $u = [System.Uri]$Uri
        if ($u.IsFile) { return [System.IO.Path]::GetFileName($u.LocalPath) }
        $s = [System.Uri]::UnescapeDataString($Uri)
        $leaf = ($s -split '[\\/]')[-1]
        if ($leaf) { return $leaf }
    } catch { }
    return '当前媒体'
}

# ------------------------------------------------------------------- RC -----
function Close-Rc {
    try { if ($script:Stream) { $script:Stream.Close() } } catch { }
    try { if ($script:Tcp) { $script:Tcp.Close() } } catch { }
    $script:Stream = $null
    $script:Tcp    = $null
    $script:RxText = ''
    $script:Numeric.Clear()
}

function Connect-Rc {
    Close-Rc
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $t.NoDelay = $true
        $iar = $t.BeginConnect($RcHost, $RcPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(700)) { $t.Close(); return $false }
        $t.EndConnect($iar)
        $script:Tcp    = $t
        $script:Stream = $t.GetStream()
        $script:NeedSeed = $true
        Write-Log "connected to RC ${RcHost}:${RcPort}"
        return $true
    } catch {
        Close-Rc
        return $false
    }
}

function Set-CurrentUri {
    param([string]$Uri)
    if (-not $Uri) { return }
    if ($Uri -eq $script:CurrentUri) { return }
    $script:CurrentUri = $Uri
    if ($null -ne $script:SavedSeconds -and $script:SavedUri -ne $Uri) {
        $script:SavedSeconds = $null
        $script:SavedUri     = $null
        Show-Tip ("已切换到新素材，保存点已清空：{0}" -f (Get-DisplayName $Uri))
    }
    Write-Log "current uri => $Uri"
}

function Handle-Line {
    param([string]$Line)
    if ($Line -match '^\s*(-?\d+(?:\.\d+)?)\s*$') {
        $script:Numeric.Add([double]$Matches[1])
        return
    }
    if ($Line -match 'new\s+input\s*:\s*(.+?)\s*\)\s*$') {
        Set-CurrentUri $Matches[1].Trim()
        return
    }
}

function Read-Available {
    if (-not $script:Stream) { return }
    try {
        while ($script:Stream.DataAvailable) {
            $n = $script:Stream.Read($script:Buf, 0, $script:Buf.Length)
            if ($n -le 0) { break }
            $script:RxText += [System.Text.Encoding]::UTF8.GetString($script:Buf, 0, $n)
        }
    } catch {
        Write-Log "read failed: $($_.Exception.Message)"
        Close-Rc
        return
    }
    while ($true) {
        $i = $script:RxText.IndexOf("`n")
        if ($i -lt 0) { break }
        $line = $script:RxText.Substring(0, $i).TrimEnd("`r")
        $script:RxText = $script:RxText.Substring($i + 1)
        Handle-Line $line
    }
}

function Send-Rc {
    param([string]$Command)
    if (-not $script:Stream) { return $false }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Command`n")
        $script:Stream.Write($bytes, 0, $bytes.Length)
        $script:Stream.Flush()
        Write-Log ">> $Command"
        return $true
    } catch {
        Write-Log "send failed: $($_.Exception.Message)"
        Close-Rc
        return $false
    }
}

# 发命令并等一个纯数字回复（毫秒级超时）
function Send-RcNumber {
    param([string]$Command, [int]$TimeoutMs = 250)
    $script:Numeric.Clear()
    if (-not (Send-Rc $Command)) { return $null }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Read-Available
        if ($script:Numeric.Count -gt 0) { return $script:Numeric[0] }
        if (-not $script:Stream) { return $null }
        Start-Sleep -Milliseconds 5
    }
    return $null
}

function Test-VlcForeground {
    if ($GlobalKeys) { return $true }
    $hWnd = [VlcRtNative]::GetForegroundWindow()
    if ($hWnd -eq [IntPtr]::Zero) { return $false }
    $procId = 0
    [void][VlcRtNative]::GetWindowThreadProcessId($hWnd, [ref]$procId)
    if ($procId -eq 0) { return $false }
    if ($script:PidCache.ContainsKey($procId)) { return $script:PidCache[$procId] }
    $isVlc = $false
    try {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p) { $isVlc = ($p.ProcessName -like '*vlc*') }
    } catch { }
    if ($script:PidCache.Count -gt 512) { $script:PidCache.Clear() }
    $script:PidCache[$procId] = $isVlc
    return $isVlc
}

# ------------------------------------------------------- key config ------
$script:SpecialVk = @{
    'SPACE'=0x20; 'ENTER'=0x0D; 'TAB'=0x09; 'BACKSPACE'=0x08; 'CAPSLOCK'=0x14
    'INSERT'=0x2D; 'DELETE'=0x2E; 'HOME'=0x24; 'END'=0x23
    'PAGEUP'=0x21; 'PAGEDOWN'=0x22; 'UP'=0x26; 'DOWN'=0x28; 'LEFT'=0x25; 'RIGHT'=0x27
    ';'=0xBA; '/'=0xBF; '`'=0xC0; '['=0xDB; '\'=0xDC; ']'=0xDD; "'"=0xDE
    ','=0xBC; '.'=0xBE; '-'=0xBD; '='=0xBB
}

function Get-VkFromName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $n = $name.Trim().ToUpperInvariant()
    if ($n -match '^[A-Z]$') { return (0x41 + ([int][char]$n - [int][char]'A')) }
    if ($n -match '^[0-9]$') { return (0x30 + [int]$n) }
    if ($n -match '^F([1-9]|1[0-2])$') { return (0x6F + [int]$Matches[1]) }
    if ($n -match '^NUMPAD([0-9])$') { return (0x60 + [int]$Matches[1]) }
    if ($script:SpecialVk.ContainsKey($n)) { return $script:SpecialVk[$n] }
    return $null
}

# keys.json 可写在脚本同目录，或用 -SaveKey / -JumpKey 参数覆盖。例：{"save":"R","jump":"T"}
function Get-KeyBinding {
    $saveName = 'R'; $jumpName = 'T'; $tips = $true
    $cfgPath = Join-Path $PSScriptRoot 'keys.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.save) { $saveName = [string]$cfg.save }
            if ($cfg.jump) { $jumpName = [string]$cfg.jump }
            if ($cfg.PSObject.Properties.Name -contains 'tips') { $tips = [bool]$cfg.tips }
        } catch {
            Write-Log "keys.json 解析失败，回退默认 R/T：$($_.Exception.Message)"
        }
    }
    if ($SaveKey) { $saveName = $SaveKey }
    if ($JumpKey) { $jumpName = $JumpKey }

    $vkSave = Get-VkFromName $saveName
    $vkJump = Get-VkFromName $jumpName
    if ($null -eq $vkSave) { Write-Log "无法识别的保存键 '$saveName'，回退 R"; $saveName = 'R'; $vkSave = 0x52 }
    if ($null -eq $vkJump) { Write-Log "无法识别的跳转键 '$jumpName'，回退 T"; $jumpName = 'T'; $vkJump = 0x54 }
    return @{ SaveVk = $vkSave; JumpVk = $vkJump; SaveName = $saveName.ToUpperInvariant(); JumpName = $jumpName.ToUpperInvariant(); Tips = $tips }
}

# ------------------------------------------------------------------ main ----
# 单实例：VLC 快速重启时可能瞬间拉起两个守护，后到的那个直接退出
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\vlc-rt-marker')
if (-not $script:Mutex.WaitOne(0)) {
    Write-Log '已有守护在运行，本实例退出'
    exit 0
}

$script:LastVlcSeen = Get-Date
Write-Log '=== start ==='
$kb = Get-KeyBinding
$script:Quiet = ($Quiet.IsPresent -or (-not $kb.Tips))
if ($script:Quiet) {
    $script:Notify.Visible = $false
    Write-Log '提示气泡已关闭（只写日志）'
}
Show-Tip "已启动：$($kb.SaveName) 保存时间，$($kb.JumpName) 跳回保存点"
Write-Log "按键：保存=$($kb.SaveName) 跳转=$($kb.JumpName)"

$keyR = $kb.SaveVk
$keyT = $kb.JumpVk
$rWasDown = $false
$tWasDown = $false

try {
    while ($true) {
        Start-Sleep -Milliseconds $PollMs

        # --- VLC 生命周期：VLC 不在了就自行退出（由 VLC 启动时拉起，跟着 VLC 结束）---
        $vlcAlive = @(Get-Process vlc -ErrorAction SilentlyContinue).Count -gt 0
        if ($vlcAlive) {
            $script:LastVlcSeen = Get-Date
        } elseif (-not $StayAlive -and ((Get-Date) - $script:LastVlcSeen).TotalSeconds -ge $ExitAfterMissing) {
            Write-Log "VLC 已退出 ${ExitAfterMissing}s，守护结束"
            break
        }

        # --- 连接维护 ---
        if (-not $script:Stream) {
            if ((Get-Date) -lt $script:NextRetry) { continue }
            if (-not (Connect-Rc)) {
                $script:NextRetry = (Get-Date).AddSeconds(1)
                if ($script:FirstFailAt -eq [datetime]::MinValue) { $script:FirstFailAt = Get-Date }
                elseif (((Get-Date) - $script:FirstFailAt).TotalSeconds -ge $ConnectTimeout) {
                    Write-Log "连续 ${ConnectTimeout}s 连不上 ${RcHost}:${RcPort}（端口被占用或 Lua 接口未加载），守护退出"
                    break
                }
                if (-not $script:WarnedDown) {
                    $script:WarnedDown = $true
                    if ($vlcAlive) {
                        Show-Tip "连不上 VLC RC 接口 (${RcHost}:${RcPort})：请彻底退出并重开 VLC（先跑一次 install.ps1）"
                    } else {
                        Show-Tip 'VLC 没在运行，打开 VLC 会自动接上'
                    }
                }
                continue
            }
            $script:FirstFailAt = [datetime]::MinValue
            if ($script:WarnedDown) { Show-Tip '已连上 VLC：R 保存，T 跳回' }
            $script:WarnedDown = $false
        }
        Read-Available

        # --- 刚连上：先问一次 status，拿到当前播放项 ---
        if ($script:NeedSeed) {
            Send-Rc 'status' | Out-Null
            $seedEnd = (Get-Date).AddMilliseconds(180)
            while ((Get-Date) -lt $seedEnd) {
                Read-Available
                if (-not $script:Stream) { break }
                Start-Sleep -Milliseconds 10
            }
            $script:NeedSeed = $false
            Write-Log "seed done, uri=$($script:CurrentUri)"
        }

        # --- 心跳：VLC 在前台时偶尔摸一下，顺便把换片事件刷出来 ---
        if ((Get-Date) -ge $script:NextBeat) {
            $script:NextBeat = (Get-Date).AddMilliseconds(1500)
            if (Test-VlcForeground) {
                [void](Send-RcNumber 'get_time' 150)
            }
        }

        # --- 按键 ---
        $rDown = (([VlcRtNative]::GetAsyncKeyState($keyR)) -band 0x8000) -ne 0
        $tDown = (([VlcRtNative]::GetAsyncKeyState($keyT)) -band 0x8000) -ne 0
        $rEdge = $rDown -and (-not $rWasDown)
        $tEdge = $tDown -and (-not $tWasDown)
        $rWasDown = $rDown
        $tWasDown = $tDown

        if (-not ($rEdge -or $tEdge)) { continue }
        if (-not (Test-VlcForeground)) { continue }

        # --- R：保存 ---
        if ($rEdge) {
            $sec = Send-RcNumber 'get_time'
            if ($null -eq $sec) {
                Show-Tip '读取播放时间失败（VLC 可能未在播放）'
                continue
            }
            $len = Send-RcNumber 'get_length'
            if ($null -eq $len -or $len -le 0) {
                Show-Tip '当前没有正在播放的媒体'
                continue
            }
            $script:SavedSeconds = $sec
            $script:SavedUri     = $script:CurrentUri
            Show-Tip ("已保存 {0}  [{1}]" -f (Format-Time $sec), (Get-DisplayName $script:CurrentUri))
            continue
        }

        # --- T：跳转 ---
        if ($tEdge) {
            # 先摸一次 get_time：把 VLC 积压的换片事件刷出来，确保按当前文件判断
            [void](Send-RcNumber 'get_time' 150)

            if ($null -eq $script:SavedSeconds) {
                Show-Tip '还没有保存点，先按 R 保存一个'
                continue
            }
            if ($null -ne $script:SavedUri -and $null -ne $script:CurrentUri -and $script:SavedUri -ne $script:CurrentUri) {
                $script:SavedSeconds = $null
                $script:SavedUri     = $null
                Show-Tip '已换片，保存点已失效'
                continue
            }
            $seekArg = [string]::Format([cultureinfo]::InvariantCulture, "{0:0.000}", $script:SavedSeconds)
            if (Send-Rc ("seek {0}" -f $seekArg)) {
                Read-Available
                Show-Tip ("跳转到 {0}" -f (Format-Time $script:SavedSeconds))
            } else {
                Show-Tip '跳转失败：VLC 连接已断开'
            }
            continue
        }
    }
}
finally {
    Write-Log '=== exit ==='
    Close-Rc
    try {
        $script:Notify.Visible = $false
        $script:Notify.Dispose()
    } catch { }
}
