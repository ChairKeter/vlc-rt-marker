# Pre-release audit (v1.0.0)

Audit performed on the working project before publishing, with the actual files (not from
the design description). Environment: Windows 11, VLC 3.0.23, Windows PowerShell 5.1.

Legend: **FIX** = changed during this audit · **OK** = verified, no change needed ·
**NOTE** = documented limitation.

---

## A01 Project structure

| Check | Result |
|---|---|
| Every source file present | OK — `rt-rc.lua`, `vlc-rt-marker.ps1`, `rt-launch.vbs`, `keys.json` |
| Mixed content in one folder | **FIX** — sources, installers, docs and obsolete experiments were all in one directory. Reorganised into `src/`, `installer/`, `docs/`, `.github/` |
| Obsolete files | **FIX** — `rt-watch.ps1`, `rt-watch-hidden.vbs`, `run-vlc-with-rc.bat` (scheduled-task fallback, superseded) dropped from the repo |
| Duplicate packaged zip in repo | **FIX** — release artifacts are built, not committed (`release/` is git-ignored) |

## A02 Lua interface (`src/rt-rc.lua`)

| Check | Result |
|---|---|
| Listener bound to loopback only | OK — `127.0.0.1`, never `0.0.0.0` |
| Port hard-coded | **FIX** — now resolved as `port.txt` → `VLC_RT_PORT` → `4212` |
| Port clash handling | **FIX** — listen is attempted **first**; on failure it logs the reason and does **not** spawn the watcher (previously the watcher could start against a dead server) |
| Length detection bug | **FIX** — the old heuristic (`value > 1000` ⇒ microseconds) would have truncated multi-hour media. Now: input variable (µs) first, then `item:duration()` (s) |
| Debug logging noise | **FIX** — probe lines (uri method probes, poll counters) removed; timestamps added |
| Errors contained | OK — every VLC API call is wrapped in `pcall`, main loop wrapped in `xpcall` + `debug.traceback` |
| Client disconnect handled | OK — `recv` returning `nil` closes the session and returns to accept |
| Single client at a time | NOTE — same as VLC's own RC interface; documented |

## A03 Watcher (`src/vlc-rt-marker.ps1`)

| Check | Result |
|---|---|
| Keys swallowed globally | OK — uses `GetAsyncKeyState` polling, not `RegisterHotKey` |
| Foreground check | OK — `GetForegroundWindow` + `GetWindowThreadProcessId`, cached per pid |
| Zombie when the control port is dead | **FIX** — new `-ConnectTimeout` (default 30 s): if VLC is alive but the channel never comes up, the process exits with a log line |
| Exits with VLC | OK — `-ExitAfterMissing` (default 8 s) |
| Double start (VLC restart race) | OK — `Local\vlc-rt-marker` mutex, second instance exits |
| Port source | **FIX** — reads the same `port.txt` as the Lua side (`-RcPort 0` = auto) |
| Resource release | OK — `finally` block closes the socket and disposes the tray icon |
| Input handling | OK — `[double]` parsing, millisecond precision, invariant-culture `seek` formatting |
| Logging | OK — no key content beyond configured keys; no personal data |

## A04 Launch chain (cmd → vbs → ps1)

| Check | Result |
|---|---|
| Non-ASCII path safety | OK — launcher lives under `%APPDATA%\vlc`, `.cmd`/`.vbs` are ASCII-only |
| `.vbs` / `.cmd` encoding | OK — no BOM (BOM breaks Windows Script Host with `800A0408`) |
| PowerShell window flashes | OK — `WScript.Shell.Run …, 0` + `-WindowStyle Hidden` |
| Quoting with spaces in path | **FIX** — all three layers quote the path; `%APPDATA%` has no spaces but user folders may |
| Failure when files are missing | OK — `.vbs` shows a message box; Lua logs `spawn skipped: launcher not found` |

## A05 Installer (`installer/install.ps1`)

| Check | Result |
|---|---|
| Source layout | **FIX** — works both from the repo (`../src`) and from a flat unpacked folder |
| VLC running during install | OK — stops VLC first (it rewrites `vlcrc` on exit) |
| `vlcrc` not found (never ran VLC) | OK — aborts with instructions |
| vlcrc encoding preserved | OK — UTF-8 BOM + LF kept byte-faithful; the file is backed up first |
| Port already in use | **FIX** — warns before touching anything |
| VLC 4.x | **FIX** — detects major version and warns |
| Re-running the installer | OK — idempotent; an existing `keys.json` is preserved (user edits survive) |
| Failure part-way | NOTE — files are copied before `vlcrc` is edited, so a partial run leaves either a clean state or an unused file; uninstall cleans both |

## A06 Uninstaller (`installer/uninstall.ps1`)

| Check | Result |
|---|---|
| Existed before | **FIX** — it did not exist; written in this audit |
| Whole-file `vlcrc` restore | **FIX** — deliberately *not* used (it would discard everything the user changed in VLC since installing). Only `extraintf` and `lua-intf` are reverted, and only when they still hold this project's values |
| Stops the watcher | OK — matches by command line, not by name |
| Legacy leftovers | **FIX** — also removes the old `start-hidden.vbs` from pre-rename installs |
| Unrelated files in `rt-marker\` | OK — directory removed only when empty |
| Confirmation | OK — interactive by default, `-Force` for scripting |

## A07 Security

| Check | Result |
|---|---|
| Listening scope | OK — `127.0.0.1` only; verified with `Get-NetTCPConnection` |
| Outbound network | OK — no HTTP/DNS/socket out, no telemetry |
| Autostart persistence | OK — no service, no scheduled task, no `Run` key, no startup folder entry |
| Registry writes | OK — none (only reads `HKLM\SOFTWARE\VideoLAN\VLC` to locate `vlc.exe`) |
| Elevation | OK — everything under `%APPDATA%`, `installer` refuses nothing but never needs admin |
| Key capture | OK — polls two configured VK codes; does not log other keystrokes |
| Log contents | OK — file paths and times only |
| Documented for users | **FIX** — `SECURITY.md` added, plus a section in the README |

## A08 Compatibility

| Check | Result |
|---|---|
| VLC 3.0.23 | OK — full end-to-end, all four behaviours verified |
| VLC 3.0.24 | OK — verified after an in-place upgrade (same `vlcrc`, same script, no reinstall needed) |
| Other VLC 3.x | NOTE — expected to work; APIs used (`vlc.net`, `vlc.var`, `vlc.input`, `vlc.playlist`) are 3.x-stable, but only 3.0.23 was tested |
| VLC 4.x | NOTE — unsupported, installer warns |
| Windows 10 | NOTE — not verified by the maintainer |
| Portable VLC | NOTE — manual mode documented (no `%APPDATA%\vlc\vlcrc`) |
| Non-ASCII install path | OK — payload is copied to `%APPDATA%` before use |
| Lua 5.1 quirks | OK — no `table.pack`, no `unpack`, no `goto`; `should_die()` avoided at top level |

## A09 Documentation

| Check | Result |
|---|---|
| README for a first-time visitor | **FIX** — rewritten, English + `README.zh-CN.md`, compatibility matrix, security summary |
| Architecture / rationale | **FIX** — `docs/ARCHITECTURE.md` (constraints, protocol, rejected approaches, API facts) |
| Troubleshooting | **FIX** — `docs/TROUBLESHOOTING.md` (symptom-driven, includes portable VLC and bug-report collection) |
| Security policy | **FIX** — `SECURITY.md` |
| Changelog | **FIX** — `CHANGELOG.md` |
| Personal data in published files | OK — sources contain no user paths; the internal investigation report stayed out of the repo |

## A10 Release readiness

| Check | Result |
|---|---|
| License | **FIX** — MIT (`LICENSE`) |
| `.gitignore` | **FIX** — ignores logs, backups, `vlcrc*`, build output |
| Issue templates | **FIX** — bug report + feature request |
| CI | **FIX** — `.github/workflows/ci.yml`: PowerShell parse check, Lua syntax check, BOM/encoding check |
| Release artifact | **FIX** — reproducible zip + SHA256 |

---

## Scenario tests executed during the audit

| Scenario | Result |
|---|---|
| Fresh install | OK |
| Re-install over an existing install | OK — `keys.json` kept, `vlcrc` re-patched |
| Install while VLC is running | OK — installer closes VLC first |
| Port 4212 occupied by another program | OK — `listen FAILED`, watcher **not** started, no zombie |
| Custom port (`-Port 4213`) | OK — `port.txt` honoured by both Lua and watcher; 4213 listening, 4212 free |
| Uninstall | OK — files removed, `vlcrc` keys reverted, no process/port left |
| Uninstall then re-install | OK — returns to a working state |
| Playback → R → T | OK — `已保存 0:09.501` → `seek 9.501` |
| Media switch → T | OK — save point dropped, jump refused |
| VLC closed | OK — listener gone, watcher exits within 8 s |

## Known limitations carried into v1.0.0

1. Keys only work while the VLC window is focused (by design).
2. One save point per session (the most recent `R`).
3. Live streams report length `0`, so saving is refused.
4. Only one control client at a time (same as VLC's own RC interface).
5. VLC 4.x is not supported.
