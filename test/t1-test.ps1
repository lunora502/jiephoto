# Tier1 features E2E (ASCII only). Needs UNLOCKED desktop for mouse parts.
# 1 draft persistence (draw -> hide -> restart -> stroke restored)
# 2 Del deletes selection / Ctrl+A select all
# 3 log rotation (1.1MB -> truncated)
# 4 save dir UI (set temp dir -> Ctrl+S -> PNG there)
param(
  [string]$Exe = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\win-x64\publish\JieDraw.exe",
  [string]$OutDir = "$PSScriptRoot\..\test-out"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class T1 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][T1]::SetProcessDPIAware()

function Find-CanvasHwnd {
  $script:target = [IntPtr]::Zero
  $script:jdpid = (Get-Process JieDraw -ErrorAction SilentlyContinue | Select-Object -First 1).Id
  if ($script:jdpid -eq $null) { return [IntPtr]::Zero }
  $cb = [T1+EnumProc]{ param($h, $l)
    $w = 0
    [void][T1]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][T1]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][T1]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}
function Toggle([IntPtr]$hwnd) { [void][T1]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }
function El([IntPtr]$hwnd, [string]$id) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
  $b = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($b -eq $null) { throw "element $id not found" }
  return $b
}
function Press([IntPtr]$hwnd, [string]$id) {
  (El $hwnd $id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Status([IntPtr]$hwnd) { (El $hwnd "statusText").Current.Name }
function Draw-Line([IntPtr]$hwnd, [int]$x0, [int]$y, [int]$len) {
  [void][T1]::SetCursorPos($x0, $y)
  Start-Sleep -Milliseconds 140
  [T1]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 20; $i++) { [void][T1]::SetCursorPos($x0 + $i * [int]($len / 20), $y); Start-Sleep -Milliseconds 10 }
  [T1]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
function Key-Tap([byte]$vk) {
  [T1]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 50
  [T1]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
}
function Combo([byte]$mod, [byte]$vk) {
  [T1]::keybd_event($mod, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
  [T1]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 50
  [T1]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
  [T1]::keybd_event($mod, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 120
}
function Count-InkPixels([string]$png) {
  $bmp = New-Object System.Drawing.Bitmap($png)
  $count = 0
  $stepX = [System.Math]::Max(1, [int]($bmp.Width / 300))
  $stepY = [System.Math]::Max(1, [int]($bmp.Height / 300))
  for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
    for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.R -lt 235 -or $c.G -lt 235 -or $c.B -lt 235) { $count++ }
    }
  }
  $bmp.Dispose(); return $count
}
function Save-ViaButton([IntPtr]$hwnd) {
  Press $hwnd "btnSave"
  Start-Sleep -Milliseconds 1400
  $dir = $script:saveDir
  if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "JieDraw" }
  return (Get-ChildItem $dir -Filter *.png | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
function Show-Canvas {
  $h = Find-CanvasHwnd
  if ($h -eq [IntPtr]::Zero) { throw "canvas hwnd not found" }
  if (-not [T1]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }
  [void][T1]::SetWindowPos($h, [IntPtr]::Zero, 150, 120, 1050, 720, 0x0004)
  Start-Sleep -Milliseconds 400
  return $h
}
function Invoke-SettingsAsync([int]$procId) {
  Start-Process powershell -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\invoke-btn.ps1",
    "-ProcId", $procId, "-ButtonId", "btnSettings") -WindowStyle Hidden
}
function Find-SettingsHwnd([int]$procId) {
  $title = [char]0x6377 + [char]0x753B + " " + [char]0x8BBE + [char]0x7F6E
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $sh = Find-HwndByTitle $procId $title
    if ($sh -ne [IntPtr]::Zero) { return $sh }
  }
  throw "settings window not found"
}
function Find-HwndByTitle([int]$procId, [string]$title) {
  $script:t2 = [IntPtr]::Zero
  $cb = [T1+EnumProc]{ param($h, $l)
    $w = 0
    [void][T1]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][T1]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:t2 = $h }
    }
    return $true
  }
  [void][T1]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:t2
}

$script:saveDir = ""
$draftPath = Join-Path $env:APPDATA "JieDraw\draft.isf"
if (Test-Path $draftPath) { Remove-Item $draftPath -Force }

# --- 1. draft persistence
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2000
}
$h = Show-Canvas
$proc = Get-Process JieDraw | Select-Object -First 1
$ink = (El $h "inkCanvas").Current.BoundingRectangle
$cx = [int]($ink.X + $ink.Width / 2); $cy = [int]($ink.Y + $ink.Height / 2)
Press $h "btnClear"; Start-Sleep -Milliseconds 400
Draw-Line $h ($cx - 140) ($cy) 300
Toggle $h; Start-Sleep -Milliseconds 700   # hide -> draft saved
if (-not (Test-Path $draftPath)) { throw "FAIL 1: draft.isf not written" }
Stop-Process -Name JieDraw -Force; Start-Sleep -Milliseconds 900
Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2200
$h = Show-Canvas
$png = Save-ViaButton $h
$restored = Count-InkPixels $png
if ($restored -lt 80) { throw "FAIL 1: draft not restored after restart (ink=$restored)" }
Write-Host "OK 1: draft persisted across restart (ink=$restored)"

# --- 2. Ctrl+A select all + Del delete
Press $h "btnClear"; Start-Sleep -Milliseconds 400
Draw-Line $h ($cx - 140) ($cy - 50) 300
Draw-Line $h ($cx - 140) ($cy + 50) 300
# Ctrl+A works in any mode (auto-switches to lasso to present the selection)
# Ctrl+A anywhere (works in any mode; switches to select)
[void][T1]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 100
Combo 0x11 0x41   # Ctrl+A
Start-Sleep -Milliseconds 600
$st = Status $h
if ($st -notmatch [char]0x5168 + [char]0x9009) { throw "FAIL 2: Ctrl+A status=[$st]" }
Key-Tap 0x2E   # Delete
Start-Sleep -Milliseconds 500
$png2 = Save-ViaButton $h
$left = Count-InkPixels $png2
if ($left -gt 30) { throw "FAIL 2: Del did not delete selection (ink=$left)" }
Write-Host "OK 2: Ctrl+A select all + Del deleted everything (status=[$st], ink=$left)"

# --- 3. log rotation
Stop-Process -Name JieDraw -Force; Start-Sleep -Milliseconds 800
$log = Join-Path $env:APPDATA "JieDraw\trace.log"
$garbage = ("x" * 200 + "`r`n") * 5500   # ~1.1MB
Set-Content -Path $log -Value $garbage -Encoding ASCII
Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2500
$size = (Get-Item $log).Length
if ($size -gt 1.1MB) { throw "FAIL 3: trace.log not rotated (size=$size)" }
Write-Host ("OK 3: log rotated, size=" + [int]($size / 1024) + "KB")
$h = Show-Canvas

# --- 4. save dir via settings UI
$proc = Get-Process JieDraw | Select-Object -First 1
$tempDir = Join-Path $env:TEMP ("JieDraw-test-" + [guid]::NewGuid().ToString("N").Substring(0, 6))
Invoke-SettingsAsync $proc.Id
$sh = Find-SettingsHwnd $proc.Id
$sEl = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
$boxCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "saveDirBox")
$box = $sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $boxCond)
($box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($tempDir)
$okCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnOk")
($sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCond)).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 600
$script:saveDir = $tempDir
$png4 = Save-ViaButton $h
if ($png4 -notlike "$tempDir*") { throw "FAIL 4: PNG not in custom dir ($png4)" }
if (-not (Test-Path $png4)) { throw "FAIL 4: PNG missing at $png4" }
Write-Host "OK 4: custom save dir works ($png4)"

# --- cleanup: reset saveDir via json, remove draft, restart resident fresh
Stop-Process -Name JieDraw -Force; Start-Sleep -Milliseconds 800
$sj = Join-Path $env:APPDATA "JieDraw\settings.json"
(Get-Content $sj -Raw) -replace '"SaveDir":\s*"[^"]*"', '"SaveDir": ""' | Set-Content $sj -Encoding UTF8
Remove-Item $draftPath -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 1800
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL cleanup: relaunch" }
Write-Host "CLEANUP: saveDir reset, draft cleared, app resident"
Write-Host "TIER1 ALL PASS"
