# JieDraw uninstaller (removes files, shortcuts, autostart) — ASCII only
param(
  [string]$Target = "$env:LOCALAPPDATA\JieDraw",
  [switch]$KeepFiles
)
$ErrorActionPreference = "Continue"

Stop-Process -Name JieDraw -Force -ErrorAction SilentlyContinue

Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "JieDraw" -ErrorAction SilentlyContinue
Write-Host "autostart removed"

$desktop = [Environment]::GetFolderPath("Desktop")
Remove-Item (Join-Path $desktop "捷画 JieDraw.lnk") -Force -ErrorAction SilentlyContinue
$startMenu = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
Remove-Item (Join-Path $startMenu "捷画 JieDraw.lnk") -Force -ErrorAction SilentlyContinue
Write-Host "shortcuts removed"

if (-not $KeepFiles) {
  Remove-Item $Target -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "files removed from $Target"
}
Write-Host "settings kept at %APPDATA%\JieDraw (delete manually if unwanted)"
Write-Host "UNINSTALL DONE"
