Option Explicit

Dim shell, fso, root, app, powershellExe, commandLine
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
app = fso.BuildPath(root, "CodexQueueCN.ps1")
powershellExe = fso.BuildPath(shell.ExpandEnvironmentStrings("%WINDIR%"), "System32\WindowsPowerShell\v1.0\powershell.exe")
commandLine = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & app & """"

shell.Run """" & powershellExe & """ " & commandLine, 0, False
