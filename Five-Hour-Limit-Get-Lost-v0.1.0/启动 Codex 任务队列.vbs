Option Explicit
Dim shell, app, cmd
Set shell = CreateObject("WScript.Shell")
app = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\CodexQueueCN.ps1"
cmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File """ & app & """"
shell.Run cmd, 0, False
