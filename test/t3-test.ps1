# Tier3 features E2E (ASCII only). Needs UNLOCKED desktop for mouse parts.
# 1 screen annotate layer: fullscreen overlay + toolbar, draw, passthrough bit, screen capture, exit
# 2 installer script: per-user install/-AutoStart/uninstall
# 3 update check via file:// update.json (log assertion)
# 4 icon assets present
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
public static class T3 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int nIndex);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int L; public int T; public int R; public int B; }
}
"@
[void][T3]::SetProcessDPIAware()
[void][T3]::SetProcessDPIAware()

function Find-HwndByTitle([int]$procId, [string]$title) {
  $script:t3h = [IntPtr]::Zero
  $cb = [T3+EnumProc]{ param($h, $l)
    $w = 0
    [void][T3]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][T3]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:t3h = $h }
    }
    return $true
  }
  [void][T3]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:t3h
}
function Wait-Hwnd([int]$procId, [string]$title, [bool]$want = $true) {
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 200
    $h = Find-HwndByTitle $procId $title
    if ($want -and $h -ne [IntPtr]::Zero) { return $h }
    if (-not $want -and $h -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
  }
  if ($want) { throw "window [$title] not found" }
  throw "window [$title] still present"
}
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
function Find-ButtonByName([IntPtr]$hwnd, [string]$name) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, $name)))
  $b = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($b -eq $null) { throw "button [$name] not found" }
  return $b
}
function Invoke-Name([IntPtr]$hwnd, [string]$name) {
  (Find-ButtonByName $hwnd $name).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 500
}
function Drag([int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  [void][T3]::SetCursorPos($x0, $y0)
  Start-Sleep -Milliseconds 180
  [T3]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 20; $i++) {
    [void][T3]::SetCursorPos($x0 + [int](($x1 - $x0) * $i / 20), $y0 + [int](($y1 - $y0) * $i / 20))
    Start-Sleep -Milliseconds 16
  }
  [T3]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
function Toggle([IntPtr]$hwnd) { [void][T3]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }

# unicode name strings (script stays ASCII)
$annoTitle  = [string][char]0x6377 + [char]0x753B + " " + [char]0x5C4F + [char]0x5E55 + [char]0x6279 + [char]0x6CE8  # 捷画 屏幕批注
$toolTitle  = [string][char]0x6377 + [char]0x753B + " " + [char]0x6279 + [char]0x6CE8 + [char]0x5DE5 + [char]0x5177  # JieDraw AnnotateTool
$nmPassthru = [string][char]0x7A7F + [char]0x900F   # pass-through
$nmDraw     = [string][char]0x7ED8 + [char]0x5236   # draw
$nmShot     = [string][char]0x6574 + [char]0x5C4F + [char]0x622A + [char]0x56FE  # full-screen screenshot
$nmExit     = [string][char]0xE8BB                  # X glyph

# --- 1. launch + open annotate layer
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2000
}
$proc = Get-Process JieDraw | Select-Object -First 1
$h = Find-HwndByTitle $proc.Id "JieDraw"
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas hwnd missing" }
if (-not [T3]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }  # 隐藏窗口的 UIA 树找不到按钮，先唤出
Press $h "btnAnnotate"
$anno = Wait-Hwnd $proc.Id $annoTitle $true
$tool = Wait-Hwnd $proc.Id $toolTitle $true
$r = New-Object T3+RECT
[void][T3]::GetWindowRect($anno, [ref]$r)
$vsW = [T3]::GetSystemMetrics(78); $vsH = [T3]::GetSystemMetrics(79)
if ((($r.R - $r.L) -lt $vsW * 0.9) -or (($r.B - $r.T) -lt $vsH * 0.9)) {
  throw "FAIL 1: annotate window not fullscreen ($($r.R - $r.L)x$($r.B - $r.T) vs $vsW x $vsH)"
}
Write-Host "OK 1: annotate overlay fullscreen + toolbar visible"

# --- 2. draw a stroke on screen (topmost overlay receives real mouse)
Drag 200 420 700 480

# --- 3. passthrough toggle via toolbar (UIA Invoke on Button raises real Click)
Invoke-Name $tool $nmPassthru
Start-Sleep -Milliseconds 400
$ex = [T3]::GetWindowLong($anno, -20)
if (($ex -band 0x20) -ne 0x20) { throw "FAIL 3: WS_EX_TRANSPARENT not set after passthrough on" }
Write-Host "OK 3a: passthrough ON (WS_EX_TRANSPARENT set)"
Invoke-Name $tool $nmDraw
Start-Sleep -Milliseconds 400
$ex2 = [T3]::GetWindowLong($anno, -20)
if (($ex2 -band 0x20) -eq 0x20) { throw "FAIL 3: WS_EX_TRANSPARENT still set after back to draw" }
Write-Host "OK 3b: passthrough OFF restored"

# --- 4. full-screen shot with ink baked in
Invoke-Name $tool $nmShot
Start-Sleep -Milliseconds 1500
$pics = Join-Path ([Environment]::GetFolderPath("MyPictures")) "JieDraw"
$shot = Get-ChildItem $pics -Filter "JieDraw_Screen_*.png" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($shot -eq $null) { throw "FAIL 4: no JieDraw_Screen_*.png produced" }
if ($shot.Length -lt 100KB) { throw "FAIL 4: screen capture suspiciously small ($($shot.Length) bytes)" }
$bmp = New-Object System.Drawing.Bitmap($shot.FullName)
$inkPixels = 0
$step = [Math]::Max(1, [int]($bmp.Width / 400))
for ($x = 150; $x -lt 750; $x += $step) {
  for ($y = 400; $y -lt 520; $y += $step) {
    $c = $bmp.GetPixel($x, $y)
    if ($c.B -gt 150 -and $c.R -lt 160 -and $c.G -gt 90 -and $c.G -lt 220) { $inkPixels++ }
  }
}
$bmp.Dispose()
if ($inkPixels -lt 3) { throw "FAIL 4: drawn blue stroke not found in screen capture (hits=$inkPixels)" }
Write-Host ("OK 4: screen capture contains ink (" + $shot.Name + ", stroke hits=$inkPixels)")

# --- 5. exit via toolbar X
Invoke-Name $tool $nmExit
Wait-Hwnd $proc.Id $annoTitle $false
Wait-Hwnd $proc.Id $toolTitle $false
Write-Host "OK 5: annotate layer + toolbar closed"

# --- 6. installer script (temp target, no shortcuts)
$instTarget = Join-Path $env:TEMP ("JieDraw-inst-" + [guid]::NewGuid().ToString("N").Substring(0, 6))
$runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\installer\install.ps1" -Target $instTarget -NoShortcuts -AutoStart | Out-Null
if (-not (Test-Path (Join-Path $instTarget "JieDraw.exe"))) { throw "FAIL 6: installer did not copy exe" }
$run = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
if (-not $run.JieDraw) { throw "FAIL 6: installer did not register autostart" }
Write-Host "OK 6a: installer copied files + registered autostart"
powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\installer\uninstall.ps1" -Target $instTarget | Out-Null
if (Test-Path (Join-Path $instTarget "JieDraw.exe")) { throw "FAIL 6: uninstall left files" }
$run2 = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
if ($run2.JieDraw) { throw "FAIL 6: uninstall left autostart" }
Write-Host "OK 6b: uninstall cleaned files + autostart"

# --- 7. update check via file://
$updDir = Join-Path $env:TEMP ("JieDraw-upd-" + [guid]::NewGuid().ToString("N").Substring(0, 6))
New-Item -ItemType Directory -Force -Path $updDir | Out-Null
Set-Content (Join-Path $updDir "update.json") -Value '{"Version":"99.0.0","Url":"https://example.com/jiedraw"}' -Encoding ASCII
Stop-Process -Name JieDraw -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800
$sj = Join-Path $env:APPDATA "JieDraw\settings.json"
(Get-Content $sj -Raw) -replace '"UpdateUrl":\s*"[^"]*"', ('"UpdateUrl": "file:///' + ($updDir -replace '\\', '/') + '/update.json"') | Set-Content $sj -Encoding UTF8
Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 3000
$trace = Get-Content (Join-Path $env:APPDATA "JieDraw\trace.log") -Raw
if ($trace -notmatch "update available: 99") { throw "FAIL 7: update check did not report new version" }
Write-Host "OK 7: update check reported 99.0.0 via file://"

# cleanup: reset UpdateUrl, restart resident
Stop-Process -Name JieDraw -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800
(Get-Content $sj -Raw) -replace '"UpdateUrl":\s*"[^"]*"', '"UpdateUrl": ""' | Set-Content $sj -Encoding UTF8
Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 1800
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL cleanup: relaunch" }

# --- 8. icon assets
if (-not (Test-Path "$PSScriptRoot\..\src\JieDraw\Assets\icon.ico")) { throw "FAIL 8: icon.ico missing" }
if (-not (Test-Path "$PSScriptRoot\..\src\JieDraw\Assets\icon-256.png")) { throw "FAIL 8: icon-256.png missing" }
Write-Host "OK 8: icon assets present"

Write-Host "TIER3 ALL PASS"
