release/
=======

Release artifacts are built, not committed.

To produce the zip for a GitHub release:

    powershell -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0

Output lands here as vlc-rt-marker-v<version>-portable.zip plus its .sha256 file.
The zip contains:

    install.ps1
    uninstall.ps1
    selftest.ps1
    rt-rc.lua
    vlc-rt-marker.ps1
    rt-launch.vbs
    keys.json
    INSTALL.txt
    README.md