# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-11-20

### Changed
- Compatibility: VLC **3.0.24** verified alongside 3.0.23. An in-place upgrade from
  3.0.23 kept the existing `vlcrc` and the installed script working without a reinstall.
- Documentation updated accordingly (README, README.zh-CN, ARCHITECTURE, AUDIT).

### Verified on 3.0.24
- `rt-rc.lua` still loads via `extraintf=luaintf`, listener comes up on 127.0.0.1:4212,
  watcher is spawned and connects.
- `R` → `已保存 0:13.151`, `T` → `seek 13.151` → `跳转到 0:13.151`.
## [1.0.0] - 2026-11-20

First public release.

### Added
- `R` saves the current playback position, `T` jumps back to it (millisecond precision).
- Automatic save-point reset when the media changes (URI-based detection).
- `rt-rc.lua`: Lua interface script that runs inside VLC, listens on `127.0.0.1:4212`
  and implements the RC subset the watcher needs.
- Watcher starts automatically with VLC and exits ~8 s after VLC closes.
- `keys.json` configuration (`save` / `jump` / `tips`).
- `port.txt` configuration plus `install.ps1 -Port` for port conflicts.
- `installer\uninstall.ps1`, which reverts only the two `vlcrc` keys this project owns.
- `installer\selftest.ps1` for a quick channel/seek check.
- Documentation: bilingual README, `docs/ARCHITECTURE.md`, `docs/TROUBLESHOOTING.md`,
  `docs/AUDIT.md`, `SECURITY.md`.
- CI: PowerShell parse check, Lua syntax check, encoding (BOM) check.

### Fixed
- Port clash left a watcher retrying forever; the watcher is now not started when the
  listener fails, and gives up after `-ConnectTimeout` seconds.
- Length detection no longer misreads long media (previous heuristic treated any value
  above 1000 as microseconds).
- Installer preserves an existing `keys.json` (user edits survive re-install).
- Uninstaller also cleans up the pre-rename `start-hidden.vbs`.

### Notes
- Verified on Windows 11 with VLC 3.0.23. VLC 4.x is not supported.
- The watcher only reacts while the VLC window is focused.

## [0.9.0] - unreleased (internal)

- Prototype using VLC's built-in `rc` interface and a scheduled-task fallback.
  Replaced in 1.0.0 by the Lua-interface design; kept here only as history.