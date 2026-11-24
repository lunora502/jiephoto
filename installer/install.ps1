# JieDraw installer (per-user, no admin required) — ASCII only
# Copies publish output to %LOCALAPPDATA%\JieDraw, creates shortcuts,
# optionally registers autostart, optionally launches.
param(
  [string]$Source = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\win-x64\publish",
  [string]$Target = "$env:LOCALAPPDATA\JieDraw",
  [switch]$AutoStart,
  [switch]$NoShortcuts,
  [switch]$Launch
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $Source "JieDraw.exe"))) { throw "publish output not found at $Source (build first: dotnet publish)" }

New-Item -ItemType Directory -Force -Path $Target | Out-Null
Copy-Item "$Source\*" $Target -Force
Write-Host "installed to $Target"

if (-not $NoShortcuts) {
  $ws = New-Object -ComObject WScript.Shell
  $desktop = [Environment]::GetFolderPath("Desktop")
  $lnk = $ws.CreateShortcut((Join-Path $desktop "捷画 JieDraw.lnk"))
  $lnk.TargetPath = (Join-Path $Target "JieDraw.exe")
  $lnk.WorkingDirectory = $Target
  $lnk.Save()
  $startMenu = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
  $lnk2 = $ws.CreateShortcut((Join-Path $startMenu "捷画 JieDraw.lnk"))
  $lnk2.TargetPath = (Join-Path $Target "JieDraw.exe")
  $lnk2.WorkingDirectory = $Target
  $lnk2.Save()
  Write-Host "shortcuts created (desktop + start menu)"
}

if ($AutoStart) {
  Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "JieDraw" -Value "`"$Target\JieDraw.exe`""
  Write-Host "autostart registered"
}

if ($Launch) { Start-Process (Join-Path $Target "JieDraw.exe") }
Write-Host "INSTALL DONE"
