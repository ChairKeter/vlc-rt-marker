# Troubleshooting

Check the two logs first — they explain almost everything:

```
%TEMP%\vlc-rt-marker.log    watcher (PowerShell)
%TEMP%\rt-rc.log            Lua interface inside VLC
```

Quick health check while VLC is playing something:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 4212
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*rt-marker*vlc-rt-marker.ps1*' }
```

Both should return one row.

---

## Nothing happens when I press R / T

1. `rt-rc.log` has no `client connected` → the watcher never started.
   - does `%APPDATA%\vlc\lua\intf\rt-rc.lua` exist?
   - does `%APPDATA%\vlc\rt-launch.cmd` exist, and does the path inside it exist?
   - re-run `installer\install.ps1`.
2. `rt-rc.log` has `client connected` but keys do nothing:
   - is the VLC window focused? Keys only work with VLC in the foreground.
   - check `keys.json` (`save` / `jump`) and restart VLC.
3. `vlc-rt-marker.log` says `连不上 VLC RC 接口` → port mismatch or listener not up.
   - compare `port.txt`, the `listening on 127.0.0.1:<port>` line, and the watcher's
     `connected to RC 127.0.0.1:<port>` line.

## VLC starts but `rt-rc.log` is empty or missing

- `vlcrc` was not applied. Check:

  ```powershell
  Select-String -Path "$env:APPDATA\vlc\vlcrc" -Pattern '^extraintf=|^lua-intf='
  ```

  Expected: `extraintf=luaintf` and `lua-intf=rt-rc`.
- VLC was running while `vlcrc` was edited → VLC rewrote it on exit. Close VLC, run the
  installer again.
- The Lua script has a syntax error → start VLC from a console with
  `vlc.exe -vvv` and look for `lua interface error`.

## `listen FAILED ... Cannot listen on 127.0.0.1:4212`

Another program owns the port.

```powershell
Get-NetTCPConnection -State Listen -LocalPort 4212 | Select-Object OwningProcess
Get-Process -Id <pid>
```

Either free it, or install on a different port:

```powershell
powershell -ExecutionPolicy Bypass -File installer\install.ps1 -Port 4213
```

When listening fails the watcher is deliberately **not** started, so a port clash cannot leave
a zombie process behind.

## T jumps, but to the wrong place

- The saved point belongs to another file. The watcher drops it when the media URI changes;
  look for `已切换到新素材` / `input ->` in the logs.
- Variable frame rate / damaged files can make VLC land on the nearest keyframe.
- Live streams have no length — `get_length` returns `0` and saving is refused by design.

## Tray balloon appears / does not appear

`keys.json` → `"tips": true|false`. `false` (default) sends everything to the log only.

## Antivirus or SmartScreen complains

The visible behaviours are: a hidden PowerShell started by VLC, `GetAsyncKeyState` polling,
and a loopback TCP listener. All are documented in [SECURITY.md](../SECURITY.md). If your
policy forbids hidden PowerShell, run the watcher manually in a console instead:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:APPDATA\vlc\rt-marker\vlc-rt-marker.ps1"
```

and remove the spawn block from `rt-rc.lua` (or set `LAUNCHER` to a non-existent path) so VLC
does not start it.

## Portable VLC

Portable builds keep their configuration next to `vlc.exe` and never create
`%APPDATA%\vlc\vlcrc`, so `install.ps1` aborts with a clear message. Manual setup:

1. Copy `src\rt-rc.lua` to `<VLC folder>\lua\intf\rt-rc.lua` (or to the `lua\intf` folder of
   the portable data directory).
2. Create `%APPDATA%\vlc\rt-marker\` and copy `vlc-rt-marker.ps1`, `rt-launch.vbs`,
   `keys.json` into it.
3. Create `%APPDATA%\vlc\rt-launch.cmd` containing
   `wscript.exe "<path to rt-launch.vbs>"`.
4. Start VLC with:

   ```
   vlc.exe --extraintf luaintf --lua-intf rt-rc "your-file"
   ```

   Make a shortcut so you do not have to type it every time.

## Uninstalling did not restore my VLC settings

`uninstall.ps1` reverts only `extraintf` and `lua-intf`, and only when they still hold this
project's values. `qt-privacy-ask` and `qt-updates-notif` (set to `0` at install to stop
first-run dialogs from stealing focus) are intentionally left alone. To go back to the exact
pre-install state, restore a backup:

```powershell
Get-ChildItem "$env:APPDATA\vlc" -Filter 'vlcrc.bak-*' | Sort-Object LastWriteTime -Descending
Copy-Item "$env:APPDATA\vlc\vlcrc.bak-<stamp>" "$env:APPDATA\vlc\vlcrc" -Force
```

That also reverts anything you changed in VLC after installing, so use it deliberately.

## Collecting information for a bug report

```powershell
$env:APPDATA
(Get-Item "$env:APPDATA\vlc\vlcrc").LastWriteTime
Select-String -Path "$env:APPDATA\vlc\vlcrc" -Pattern '^extraintf=|^lua-intf='
Get-ChildItem "$env:APPDATA\vlc\lua\intf", "$env:APPDATA\vlc\rt-marker"
Get-Content "$env:TEMP\rt-rc.log" -Tail 50
Get-Content "$env:TEMP\vlc-rt-marker.log" -Tail 50
```

Attach the two log tails plus your Windows build and VLC version.
