' Launch vlc-rt-marker.ps1 with no console window. Double-click to run.
Option Explicit
Dim sh, fso, here, ps1, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "vlc-rt-marker.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "vlc-rt-marker.ps1 not found in:" & vbCrLf & here, 16, "VLC R/T Marker"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
