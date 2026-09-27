$ErrorActionPreference = 'Stop'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath 'Five-Hour Limit, Get Lost!.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    [IO.File]::Delete($shortcutPath)
    Write-Host "Desktop shortcut removed: $shortcutPath"
} else {
    Write-Host 'Desktop shortcut was not found.'
}
