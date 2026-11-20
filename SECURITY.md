# Security Policy

## Scope

VLC RT Marker is a local helper for VLC on Windows. It is not a service and it
does not run when VLC is closed.

What it does on your machine:

- Reads two keys (`R` / `T`) with `GetAsyncKeyState`, and only acts when the
  foreground window belongs to `vlc.exe`.
- Runs a TCP listener bound to `127.0.0.1` only (default port 4212). Nothing is
  exposed to other hosts.
- Starts a hidden PowerShell process from a Lua script inside VLC, and that
  process exits within ~8 seconds after VLC is gone.
- Writes logs to `%TEMP%\vlc-rt-marker.log` and `%TEMP%\rt-rc.log`.

What it does **not** do:

- no Windows service, no scheduled task, no registry writes
- no autostart entry
- no outbound network connections, no telemetry, no analytics
- no elevation / administrator rights

Files it writes (all reversible with `installer\uninstall.ps1`):

```
%APPDATA%\vlc\lua\intf\rt-rc.lua
%APPDATA%\vlc\rt-marker\          (watcher + keys.json + port.txt)
%APPDATA%\vlc\rt-launch.cmd
%APPDATA%\vlc\vlcrc               (4 keys, backup kept next to it)
```

## Reporting a vulnerability

Open a private security advisory on GitHub (Security -> Report a vulnerability)
or email the maintainer listed in the repository profile. Please include:

- affected version (see CHANGELOG.md)
- VLC version and Windows build
- steps to reproduce
- relevant lines from the two log files

Do not open a public issue for anything that could be exploited before a fix is
available.