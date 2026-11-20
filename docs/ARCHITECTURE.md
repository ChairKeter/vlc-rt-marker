# Architecture

How VLC RT Marker works, why it is built this way, and what was ruled out.

Verified on: Windows 11, VLC 3.0.23 and 3.0.24 (Vetinari), Windows PowerShell 5.1.

---

## 1. Constraints that shaped the design

### 1.1 VLC extensions cannot handle keys

The Lua extension API (`plugins/lua/liblua_plugin.dll`) exposes only these callbacks:

```
activate  deactivate  menu  trigger_menu
input_changed  meta_changed  playing_changed
widget  dialog
```

There is no key/hotkey/shortcut registration, and no timer. The only action-related
symbol is `vlc_actions_get_id`, which lets a script *trigger* a built-in action — the
opposite direction of what we need.

### 1.2 The hotkey page cannot host plugin actions

`Preferences → Hotkeys` is a closed list of built-in actions (113 `key-*` entries in
`vlcrc`). Third-party code cannot add an entry.

Built-in *playlist bookmarks* (`key-set-bookmark1..10` = `Ctrl+F1..F10`,
`key-play-bookmark1..10` = `F1..F10`) look close but are not usable:

- they live in memory for the whole session, are not written to `vlcrc`, and are not
  per-file — switching media does not reset them;
- on 3.0.23 neither `Ctrl+F1` nor `F1` reacted (synthetic `Space` did react through the
  same injection path, so the keys did arrive — the bookmark actions themselves did not fire).

### 1.3 VLC 3 loads exactly one extra interface

`extraintf` accepts a list syntactically, but only one module is used:

| `vlcrc` value | Result in `-vvv` log |
|---|---|
| `extraintf=rc,luaintf` | `looking for interface module matching "rc,luaintf,none"` → only `oldrc` loads |
| `extraintf=rc:luaintf` | only `rc` loads |
| `--extraintf rc --extraintf luaintf` | last one wins, only `luaintf` |

So `rc` and a Lua interface are mutually exclusive. This is the pivot of the whole design.

### 1.4 Extension scripts are not loaded at startup

A probe that wrote a log line at the top level of
`%APPDATA%\vlc\lua\extensions\*.lua` produced nothing when VLC started — extensions are
loaded lazily when the Extensions menu is built. Extensions therefore cannot be used for
autostart.

### 1.5 Conclusions

- VLC startup hook ⇒ must be a **Lua interface script** (`extraintf=luaintf`).
- That consumes the single extra-interface slot ⇒ **we must implement our own control
  channel** instead of relying on VLC's `rc` module.
- Keys ⇒ must be read **outside** VLC.

---

## 2. Final architecture

```
┌─────────────────────────── VLC process ───────────────────────────┐
│  extraintf=luaintf, lua-intf=rt-rc                                │
│                                                                   │
│  rt-rc.lua  (top-level code runs at startup)                      │
│    ├─ resolve port: port.txt → VLC_RT_PORT → 4212                 │
│    ├─ vlc.net.listen_tcp("127.0.0.1", PORT)                       │
│    ├─ spawn %APPDATA%\vlc\rt-launch.cmd   (only after listen OK)  │
│    └─ loop: poll(listener) → accept → serve_client                │
│              commands: get_time get_length seek status            │
│                        play_next add quit                         │
└───────────────────────────────────────────────────────────────────┘
              ▲ 100% loopback, newline-delimited text
              │
┌─────────────┴──────────── hidden PowerShell process ───────────────┐
│  vlc-rt-marker.ps1                                                 │
│    ├─ GetAsyncKeyState poll (40 ms) for save/jump keys             │
│    ├─ GetForegroundWindow + GetWindowThreadProcessId → is it vlc?  │
│    ├─ on R: get_time + get_length → store seconds (double) + uri   │
│    ├─ on T: get_time (flush events) → uri check → seek <sec>       │
│    ├─ heartbeat get_time every 1.5 s (surfaces media changes)      │
│    ├─ single instance mutex  Local\vlc-rt-marker                   │
│    └─ exits 8 s after vlc.exe disappears                           │
└────────────────────────────────────────────────────────────────────┘
```

Command line actually used:

```
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
               -WindowStyle Hidden -File %APPDATA%\vlc\rt-marker\vlc-rt-marker.ps1
```

### 2.1 Launch chain

```
VLC start
 └─ rt-rc.lua
      └─ os.execute('cmd /c "%APPDATA%\vlc\rt-launch.cmd"')
            └─ wscript.exe "%APPDATA%\vlc\rt-marker\rt-launch.vbs"
                  └─ powershell.exe … -WindowStyle Hidden -File vlc-rt-marker.ps1
```

`rt-launch.cmd` exists only because `os.execute` goes through `cmd`, and the folder holding
the real scripts may contain non-ASCII characters. The `.cmd` and `.vbs` live under
`%APPDATA%\vlc\…`, which is always ASCII.

### 2.2 Protocol (subset of VLC's RC)

| Command | Reply |
|---|---|
| `get_time` | `12.345\n` (seconds, 3 decimals) |
| `get_length` | `210\n` (seconds; `0` when nothing is playing) |
| `seek 12.345` | `seek: returned 0 (no error)\n` |
| `status` | `status change: ( new input: <uri> )\n` |
| `play_next` / `add <url>` | `ok\n` |

Before replying to `get_time` / `status`, the server compares the current item URI with the
last one sent; if it changed it emits

```
status change: ( new input: file:///… )
```

The watcher treats that line as "media changed" and drops the saved point. Because VLC's own
event queue is not pushed to clients, this piggybacks on the next command — the watcher polls
every 1.5 s while VLC is in the foreground, so a reset lands within ~1.5 s.

### 2.3 Reading state inside VLC

| Need | API | Note |
|---|---|---|
| position | `vlc.var.get(vlc.object.input(), "time")` | microseconds; divide by 1e6 |
| length | `vlc.var.get(input, "length")`, fallback `vlc.input.item():duration()` | `vlc.input.length()` **does not exist** in 3.x |
| seek | `vlc.var.set(input, "time", sec * 1e6)` | |
| current media | `vlc.input.item():uri()` | most reliable of three fallbacks tried |
| listening | `l=vlc.net.listen_tcp(host, port)` → `l:fds()`, `l:accept()` | `accept` is a method on the listener object |

`vlc.net` also exposes `poll`, `recv`, `send`, `close`, and the `POLLIN/OUT/ERR/HUP/NVAL`
constants. There is **no** global `vlc.net.accept` — that was the wrong assumption in an
early prototype.

### 2.4 Environment quirks worth remembering

- VLC's Lua is **5.1**: no `table.pack`, no `table.unpack`, no `goto`.
- Lua interface scripts: the **top level executes**, but `main()` is never called.
- `vlc.misc.should_die()` returns true in the top-level context, so
  `while not vlc.misc.should_die() do … end` exits immediately. Use `while true` plus
  `xpcall`.
- `io.open` uses the Windows ANSI code page: UTF-8 bytes in the script cannot address a path
  containing non-ASCII characters. Hence the ASCII launcher under `%APPDATA%`.
- `vlc.net.recv` returns `nil` when the peer closes — that is the disconnect signal.
- VLC rewrites `vlcrc` on exit; edit it only while VLC is closed.

---

## 3. Rejected approaches

| Approach | Why it failed |
|---|---|
| Pure Lua extension with hotkeys | no key API, no timer |
| Extension for autostart | extensions are lazy-loaded, nothing runs at startup |
| Hotkey page binding | closed list of built-in actions |
| Built-in bookmarks as R/T | session-scoped, not per-file, no reaction on 3.0.23 |
| Keep `rc` module and add `luaintf` | only one `extraintf` slot |
| `host` module service loop (`host:listen_tcp`, `status_callbacks`) | `listen_tcp` blocks unpredictably, callbacks never fire, `accept_and_select` never returns, `h.cmds` is nil |
| Windows scheduled task polling | worked as a fallback, but up to 60 s delay; removed after the Lua route worked |
| `Register-ScheduledTask` | access denied without elevation (`schtasks /create` worked) |

---

## 4. Why the process model is safe

- the watcher exists only while VLC exists (self-exit after 8 s without `vlc.exe`);
- listening socket is bound to `127.0.0.1`, never `0.0.0.0`;
- no outbound connections, no telemetry;
- no service, no scheduled task, no registry, no elevation;
- keys are polled with `GetAsyncKeyState`, **not** `RegisterHotKey`, so no key is swallowed
  and other applications keep working normally;
- everything installed lives under `%APPDATA%\vlc\…` and is removed by `uninstall.ps1`.
