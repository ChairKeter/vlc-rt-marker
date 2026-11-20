# VLC RT Marker

**Remember a playback position, jump back to it — with two keys, inside VLC, on Windows.**

Press <kbd>R</kbd> to save the current playback position, press <kbd>T</kbd> to jump back to it.
Switching media clears the saved point automatically, so you never jump into the wrong file.

```
R  →  save   (0:09.501)
T  →  seek   (0:09.501)
```

No daemon tray icon, no service, no scheduled task, no registry changes, no admin rights.

[中文说明](README.zh-CN.md)

---

## Why this exists

VLC 3 has no built-in "set a marker and jump back" hotkey:

- **Extensions** (`View → Extensions`) expose no keyboard API at all — the callback set is
  `activate / deactivate / menu / trigger_menu / input_changed / meta_changed / playing_changed`,
  nothing for keys, and no timer.
- The **hotkey page** in preferences only lists built-in actions; plugin actions cannot be
  registered there.
- The built-in **playlist bookmarks** (`Ctrl+F1` / `F1`) are session-wide memory, are not
  per-file, and did not respond in our tests on 3.0.23.

So the keys have to come from outside VLC, while the position/seek work stays inside it.

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 (x64) |
| VLC | **3.x** — verified on **3.0.23 and 3.0.24**. VLC 4.x: **not supported** (script API changed) |
| PowerShell | 5.1 (built into Windows) — no extra modules |
| Rights | none — everything is per-user under `%APPDATA%` |

Compatibility status:

| Environment | Status |
|---|---|
| Windows 10 | expected to work, not verified by the maintainer |
| Windows 11 | verified (build 22000+) |
| VLC 3.0.23 | **verified** (development platform) |
| VLC 3.0.24 | **verified** (in-place upgrade from 3.0.23, same config) |
| other VLC 3.x | expected to work — `vlc.net`, `vlc.var`, `vlc.input` are stable APIs in 3.x |
| VLC 4.x | **unsupported** |
| Portable VLC | manual mode — see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## Install

1. Download and unpack a release (or clone this repo).
2. **Start VLC once, then close it** — this creates `%APPDATA%\vlc\vlcrc`.
3. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File installer\install.ps1
   ```

4. Open VLC, play something, press <kbd>R</kbd> then <kbd>T</kbd>.

The installer prints every file it writes and every `vlcrc` key it changes, and it keeps a
timestamped backup next to `vlcrc`.

## Usage

| Key | Action |
|---|---|
| <kbd>R</kbd> | save the current position (overwrites the previous point) |
| <kbd>T</kbd> | jump back to the saved point — no-op (and a log line) if nothing is saved |

Keys only act while the **VLC window is in the foreground**, so typing `R`/`T` in other
applications is unaffected.

## Configuration

`%APPDATA%\vlc\rt-marker\keys.json`

```json
{
  "save": "R",
  "jump": "T",
  "tips": false
}
```

- `save` / `jump` — `A`–`Z`, `0`–`9`, `F1`–`F12`, `NUMPAD0`–`NUMPAD9`, `SPACE`, `ENTER`, `TAB`,
  `BACKSPACE`, `CAPSLOCK`, `INSERT`, `DELETE`, `HOME`, `END`, `PAGEUP`, `PAGEDOWN`, arrow keys,
  and `; / \ [ ] ' , . - =`
- `tips` — `false` keeps everything in the log file, `true` shows a tray balloon as well

`%APPDATA%\vlc\rt-marker\port.txt` sets the loopback control port (default `4212`); change it with
`install.ps1 -Port <n>` if something else already uses that port.

Restart VLC after editing either file.

## Logs

```
%TEMP%\vlc-rt-marker.log    watcher: key events, save/jump, connection state
%TEMP%\rt-rc.log            Lua side: commands received, media changes, listen status
```

## How it works

```
VLC  (vlcrc: extraintf=luaintf, lua-intf=rt-rc)
 └─ rt-rc.lua  — runs inside VLC at startup
      ├─ listens on 127.0.0.1:4212  (vlc.net.listen_tcp + accept/poll/recv)
      ├─ answers: get_time / get_length / seek <sec> / status / play_next / add
      └─ spawns the hidden watcher once the listener is up

vlc-rt-marker.ps1  — hidden PowerShell process
      ├─ polls R/T with GetAsyncKeyState (only when vlc.exe is foreground)
      ├─ asks the Lua server for the position, seeks on command
      └─ exits ~8 s after vlc.exe disappears
```

VLC 3 loads **one** `extraintf` module, so the Lua interface owns that slot and implements the
small RC subset the watcher needs. Details, dead ends and the API verification log are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File installer\uninstall.ps1
```

It stops the watcher, deletes the files this project installed, and reverts **only**
`extraintf` and `lua-intf` in `vlcrc` (other VLC settings are never touched).

## Security & privacy

See [SECURITY.md](SECURITY.md). Short version: loopback only, no telemetry, no autostart,
no service, no registry, no elevation; the helper process only exists while VLC is running.

## Repository layout

```
src/          rt-rc.lua · vlc-rt-marker.ps1 · rt-launch.vbs · keys.json
installer/    install.ps1 · uninstall.ps1 · selftest.ps1
docs/         ARCHITECTURE.md · TROUBLESHOOTING.md · AUDIT.md
.github/      issue templates · syntax-check workflow
```

## License

MIT — see [LICENSE](LICENSE).
