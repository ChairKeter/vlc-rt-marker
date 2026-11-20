<#
    selftest.ps1  ——  连通性自检：确认 VLC 的 RC 接口可用、能读时间、能跳转

    用法（VLC 正在播放任意音视频时）：
      powershell -ExecutionPolicy Bypass -File .\selftest.ps1
      powershell -ExecutionPolicy Bypass -File .\selftest.ps1 -SeekTest
#>
[CmdletBinding()]
param(
    [string]$RcHost = '127.0.0.1',
    [int]   $RcPort = 4212,
    [switch]$SeekTest,
    [int]   $SeekTo = 5
)

$ErrorActionPreference = 'Stop'

$tcp = $null
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect($RcHost, $RcPort, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(1000)) { throw "连接超时" }
    $tcp.EndConnect($iar)
} catch {
    Write-Host "[X] 连不上 ${RcHost}:${RcPort} —— $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "排查顺序：" -ForegroundColor Yellow
    Write-Host "  1) 是否已运行 install.ps1（或带 --extraintf rc 启动 VLC）"
    Write-Host "  2) 配置后是否彻底退出并重开了 VLC"
    Write-Host "  3) 是否有另一个程序占用 4212 端口："
    Write-Host "     Get-NetTCPConnection -State Listen -LocalPort $RcPort"
    exit 1
}

$stream = $tcp.GetStream()
$buf = New-Object byte[] 8192

function Send([string]$cmd) {
    $b = [System.Text.Encoding]::UTF8.GetBytes("$cmd`n")
    $stream.Write($b, 0, $b.Length); $stream.Flush()
    Start-Sleep -Milliseconds 200
    $ms = New-Object System.IO.MemoryStream
    $stream.ReadTimeout = 600
    try {
        while ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
    } catch { }
    return ([System.Text.Encoding]::UTF8.GetString($ms.ToArray())) -replace "`r", ''
}

function Last-Number([string]$text) {
    $nums = @($text -split "`n" | Where-Object { $_ -match '^\s*-?\d+\s*$' })
    if ($nums.Count -eq 0) { return $null }
    return [int]$nums[-1].Trim()
}

Write-Host "[OK] 已连接 ${RcHost}:${RcPort}" -ForegroundColor Green

$timeText = Send 'get_time'
$time = Last-Number $timeText
$lenText = Send 'get_length'
$len  = Last-Number $lenText

Write-Host ("音乐/视频长度 : {0}" -f $(if ($null -ne $len) { "$len 秒" } else { '未知' }))
Write-Host ("当前播放位置 : {0}" -f $(if ($null -ne $time) { "$time 秒" } else { '读不到（可能未在播放）' }))

$status = Send 'status'
$uri = $null
if ($status -match 'new\s+input\s*:\s*(.+?)\s*\)\s*$') { $uri = $Matches[1] }
Write-Host ("当前媒体     : {0}" -f $(if ($uri) { $uri } else { '（status 未给出，可能已缓存过）' }))

if ($null -ne $len -and $len -le 0) {
    Write-Host ""
    Write-Host "[!] 没有正在播放的媒体，先放一个音频/视频再测。" -ForegroundColor Yellow
    $tcp.Close()
    exit 2
}

if ($SeekTest) {
    Write-Host ""
    Write-Host "== 跳转测试 ==" -ForegroundColor Cyan
    Write-Host (Send ("seek {0}" -f $SeekTo)).Trim()
    Start-Sleep -Milliseconds 800
    $after = Last-Number (Send 'get_time')
    Write-Host ("跳转后位置 : {0} 秒  (目标 {1})" -f $after, $SeekTo)
    if ($after -ne $null -and [math]::Abs($after - $SeekTo) -le 2) {
        Write-Host "[OK] 跳转正常" -ForegroundColor Green
    } else {
        Write-Host "[X] 跳转结果异常" -ForegroundColor Red
    }
}

$stream.Close(); $tcp.Close()
Write-Host ""
Write-Host "自检结束。" -ForegroundColor Green
