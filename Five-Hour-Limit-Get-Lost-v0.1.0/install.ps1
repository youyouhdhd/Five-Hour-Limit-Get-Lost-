$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appPath = Join-Path $projectRoot 'CodexQueueCN.ps1'
$iconPath = Join-Path $projectRoot 'five_hour_limit_icon.ico'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $appPath)) { throw "找不到程序文件：$appPath" }
if (-not (Test-Path -LiteralPath $iconPath)) { throw "找不到图标文件：$iconPath" }
if ([string]::IsNullOrWhiteSpace($desktopPath)) { throw '找不到当前用户的桌面目录' }

$shortcutPath = Join-Path $desktopPath 'Five-Hour Limit, Get Lost!.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $appPath + '"'
$shortcut.WorkingDirectory = $projectRoot
$shortcut.Description = 'Five-Hour Limit, Get Lost! — local Codex monitor'
$shortcut.IconLocation = "$iconPath,0"
$shortcut.Save()

Write-Host "Desktop shortcut created: $shortcutPath"
