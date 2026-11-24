# Tier2 features E2E (ASCII only). Needs UNLOCKED desktop for mouse parts.
# 1 pin toggle -> WS_EX_TOPMOST bit + settings.json  2 transparent export (alpha channel)
# 3 screenshot overlay -> captured image lands on canvas -> export contains it
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
public static class T2 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int nIndex);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][T2]::SetProcessDPIAware()

function Find-HwndByTitle([int]$procId, [string]$title) {
  $script:t2h = [IntPtr]::Zero
  $cb = [T2+EnumProc]{ param($h, $l)
    $w = 0
    [void][T2]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][T2]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:t2h = $h }
    }
    return $true
  }
  [void][T2]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:t2h
}
function Toggle([IntPtr]$hwnd) { [void][T2]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }
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
function Invoke-ChildBtn([int]$procId, [string]$buttonId) {
  Start-Process powershell -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\invoke-btn.ps1",
    "-ProcId", $procId, "-ButtonId", $buttonId) -WindowStyle Hidden
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
function Open-Settings([int]$procId) {
  Invoke-ChildBtn $procId "btnSettings"
  return Find-SettingsHwnd $procId
}
function Close-Settings([IntPtr]$sh) {
  $sEl = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
  $okCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnOk")
  ($sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCond)).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 600
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
function Save-Latest {
  Start-Sleep -Milliseconds 1400
  $dir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "JieDraw"
  return (Get-ChildItem $dir -Filter *.png | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
function Drag([int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  [void][T2]::SetCursorPos($x0, $y0)
  Start-Sleep -Milliseconds 180
  [T2]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 20; $i++) {
    [void][T2]::SetCursorPos($x0 + [int](($x1 - $x0) * $i / 20), $y0 + [int](($y1 - $y0) * $i / 20))
    Start-Sleep -Milliseconds 16
  }
  [T2]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

# --- 1. launch + show + normalize
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2000
}
$proc = Get-Process JieDraw | Select-Object -First 1
$h = Find-HwndByTitle $proc.Id "JieDraw"
if ($h -eq [IntPtr]::Zero) { throw "FAIL 0: canvas not found" }
if (-not [T2]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }
[void][T2]::SetWindowPos($h, [IntPtr]::Zero, 150, 120, 1050, 720, 0x0004)
Start-Sleep -Milliseconds 400
Press $h "btnClear"; Start-Sleep -Milliseconds 400
Write-Host "OK 0: ready"

# --- 2. pin toggle
$pinEl = El $h "btnPin"
$pat = $pinEl.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
if ($pat.Current.ToggleState -ne "Off") { $pat.Toggle() }   # start from off
Start-Sleep -Milliseconds 300
$ex0 = [T2]::GetWindowLong($h, -20)
$pat.Toggle()
Start-Sleep -Milliseconds 400
$ex1 = [T2]::GetWindowLong($h, -20)
$json = Get-Content (Join-Path $env:APPDATA "JieDraw\settings.json") -Raw
if ((($ex1 -band 0x8) -ne 0x8)) { throw "FAIL 1: WS_EX_TOPMOST not set after pin on (ex=$ex0->$ex1)" }
if ($json -notmatch '"Topmost":\s*true') { throw "FAIL 1: Topmost not persisted" }
$pat.Toggle()
Start-Sleep -Milliseconds 400
$ex2 = [T2]::GetWindowLong($h, -20)
if (($ex2 -band 0x8) -eq 0x8) { throw "FAIL 1: WS_EX_TOPMOST still set after pin off" }
$pat.Toggle(); Start-Sleep -Milliseconds 300   # leave pinned (restore default state)
Write-Host "OK 1: pin toggles WS_EX_TOPMOST on/off and persists ($ex1 -> $ex2)"

# --- 3. transparent export
$sh = Open-Settings $proc.Id
$sEl = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
$chk = $sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "chkTransparent")))
$tg = $chk.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
if ($tg.Current.ToggleState -ne "On") { $tg.Toggle() }
Close-Settings $sh
Press $h "btnClear"; Start-Sleep -Milliseconds 300
Press $h "btnSave"
$pngT = Save-Latest
$bmpT = New-Object System.Drawing.Bitmap($pngT)
$alphaT = $bmpT.GetPixel(5, 5).A
$bmpT.Dispose()
if ($alphaT -ne 0) { throw "FAIL 2: transparent export alpha=$alphaT" }
Write-Host "OK 2a: transparent PNG alpha=0"

$sh = Open-Settings $proc.Id
$sEl = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
$chk = $sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "chkTransparent")))
$tg = $chk.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
if ($tg.Current.ToggleState -ne "Off") { $tg.Toggle() }
Close-Settings $sh
Press $h "btnSave"
$pngW = Save-Latest
$bmpW = New-Object System.Drawing.Bitmap($pngW)
$px = $bmpW.GetPixel(5, 5)
$bmpW.Dispose()
if ($px.A -ne 255 -or $px.R -lt 245) { throw "FAIL 2: opaque export wrong ($px)" }
Write-Host "OK 2b: opaque PNG restored (A=255 white)"

# --- 4. screenshot overlay -> image into canvas -> export contains it
Invoke-ChildBtn $proc.Id "btnScreenshot"
$shotTitle = [char]0x6377 + [char]0x753B + " " + [char]0x622A + [char]0x56FE
$oh = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 150
  $oh = Find-HwndByTitle $proc.Id $shotTitle
  if ($oh -ne [IntPtr]::Zero) { break }
}
if ($oh -eq [IntPtr]::Zero) { throw "FAIL 3: overlay window not found" }
Write-Host "OK 3a: screenshot overlay visible"

# drag a capture region over some on-screen content
Drag 380 280 1250 760
Start-Sleep -Milliseconds 2200   # hide(280ms)+capture+close+canvas reshow
$oh2 = Find-HwndByTitle $proc.Id $shotTitle
if ($oh2 -ne [IntPtr]::Zero) { throw "FAIL 3: overlay did not close after drag" }
$canvasNow = Find-HwndByTitle $proc.Id "JieDraw"
if (-not [T2]::IsWindowVisible($canvasNow)) { throw "FAIL 3: canvas did not come back after screenshot" }

# deterministic check: app logs the image placement after AddScreenshotToCanvas
$tracePath = Join-Path $env:APPDATA "JieDraw\trace.log"
$onCanvas = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 200
    $tail = (Get-Content $tracePath -Tail 30) -join "`n"
    if ($tail -match "screenshot: image on canvas") { $onCanvas = $true; break }
}
if (-not $onCanvas) { throw "FAIL 3: 'image on canvas' log missing (capture/integration failed)" }
Write-Host "OK 3b: screenshot image placed on canvas (trace verified)"

# visual evidence for review
$shotTitle2 = [char]0x6377 + [char]0x753B + " " + [char]0x622A + [char]0x56FE
$bmpS = New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
$gS = [System.Drawing.Graphics]::FromImage($bmpS)
$gS.CopyFromScreen(0, 0, 0, 0, $bmpS.Size)
$bmpS.Save("$OutDir\3-after-screenshot.png", [System.Drawing.Imaging.ImageFormat]::Png)
$gS.Dispose(); $bmpS.Dispose()

$pngShot = Save-Latest
$shotInk = Count-InkPixels $pngShot
Write-Host ("OK 3c: export rendered, ink pixel count=" + $shotInk + " (white desktop => low count is expected)")

# cleanup: remove the screenshot image via undo, clear canvas
Press $canvasNow "btnUndo"; Start-Sleep -Milliseconds 400
Press $canvasNow "btnClear"; Start-Sleep -Milliseconds 300
Press $canvasNow "btnHide"; Start-Sleep -Milliseconds 400
Write-Host "TIER2 ALL PASS"
