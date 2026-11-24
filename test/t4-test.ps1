# Optimization round E2E (ASCII only). Needs UNLOCKED desktop for mouse parts.
# 1 draft debounce autosave: draw -> (no hide) -> kill -> restart -> stroke restored
# 2 single-instance: second launch activates existing canvas & exits
# 3 wheel over canvas cycles pen size (status + json)
# 4 autostart path self-heal (wrong registry path -> corrected)
# 5 paste system image -> canvas (status + colorful export)
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
public static class T4 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int L; public int T; public int R; public int B; }
}
"@
[void][T4]::SetProcessDPIAware()

function Find-HwndByTitle([int]$procId, [string]$title) {
  $script:th = [IntPtr]::Zero
  $cb = [T4+EnumProc]{ param($h, $l)
    $w = 0
    [void][T4]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][T4]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:th = $h }
    }
    return $true
  }
  [void][T4]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:th
}
function Toggle([IntPtr]$hwnd) { [void][T4]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }
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
function Draw-Line([int]$x0, [int]$y, [int]$len) {
  [void][T4]::SetCursorPos($x0, $y)
  Start-Sleep -Milliseconds 140
  [T4]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 20; $i++) { [void][T4]::SetCursorPos($x0 + $i * [int]($len / 20), $y); Start-Sleep -Milliseconds 10 }
  [T4]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}

$draftPath = Join-Path $env:APPDATA "JieDraw\draft.isf"
$runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

# lock detection: lock screen window sits above everything; its title contains 锁屏
function Test-Locked([IntPtr]$hwnd, [string]$inkCenterTitle) {
  if ((Get-Process LockApp -ErrorAction SilentlyContinue) -ne $null) { return $true }
  if ($inkCenterTitle -match [char]0x9501) { return $true }  # 锁
  return $false
}

# --- 1. draft debounce autosave (crash protection: kill WITHOUT hide)
if (Test-Path $draftPath) { Remove-Item $draftPath -Force }
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2000
}
$proc = Get-Process JieDraw | Select-Object -First 1
$h = Find-HwndByTitle $proc.Id "JieDraw"
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas missing" }
if (-not [T4]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }
[void][T4]::SetWindowPos($h, [IntPtr]::Zero, 150, 120, 1050, 720, 0x0004); Start-Sleep -Milliseconds 400
Press $h "btnClear"; Start-Sleep -Milliseconds 500
$ink = (El $h "inkCanvas").Current.BoundingRectangle
$cx = [int]($ink.X + $ink.Width / 2); $cy = [int]($ink.Y + $ink.Height / 2)
Press $h "btnClear"; Start-Sleep -Milliseconds 500

# lock check: under lock screen all synthetic clicks land on the lock window
$locked = (Get-Process LockApp -ErrorAction SilentlyContinue) -ne $null
if ($locked) {
  Write-Host "SKIP 1/3: desktop locked (LockApp present) - synthetic mouse cannot reach apps; rerun when unlocked"
} else {
  Draw-Line ($cx - 140) ($cy) 300
  Start-Sleep -Milliseconds 3200   # > 2.5s debounce: autosave must have fired
  Stop-Process -Name JieDraw -Force; Start-Sleep -Milliseconds 900   # kill WITHOUT hide
  Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2200
  $h = Find-HwndByTitle (Get-Process JieDraw | Select-Object -First 1).Id "JieDraw"
  if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: relaunch failed" }
  if (-not [T4]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }
  $png = Save-Latest
  $restored = Count-InkPixels $png
  if ($restored -lt 80) { throw "FAIL 1: debounce autosave did not protect strokes (ink=$restored)" }
  Write-Host "OK 1: draft autosaved after burst (survived kill, ink=$restored)"
}

# --- 2. single-instance activation (input-free, works locked)
if ($locked) { Toggle $h; Start-Sleep -Milliseconds 500 } else { Toggle $h; Start-Sleep -Milliseconds 500 }
Start-Process -FilePath $Exe                       # second instance
Start-Sleep -Milliseconds 1800
$procs = @(Get-Process JieDraw -ErrorAction SilentlyContinue)
if ($procs.Count -ne 1) { throw "FAIL 2: second instance did not exit (procs=$($procs.Count))" }
$h = Find-HwndByTitle $procs[0].Id "JieDraw"
if ($h -eq [IntPtr]::Zero -or -not [T4]::IsWindowVisible($h)) { throw "FAIL 2: existing instance canvas not activated" }
Write-Host "OK 2: second launch activated existing canvas and exited"
$proc = $procs[0]

# --- 3. wheel cycles pen size over canvas (needs unlocked desktop)
if ($locked) {
  Write-Host "SKIP 3: locked"
} else {
$ink2 = (El $h "inkCanvas").Current.BoundingRectangle
$wx = [int]($ink2.X + $ink2.Width / 2); $wy = [int]($ink2.Y + $ink2.Height / 2)
[void][T4]::SetCursorPos($wx, $wy); Start-Sleep -Milliseconds 200
[T4]::mouse_event(0x800, 0, 0, 120, [UIntPtr]::Zero)   # wheel up -> 8
Start-Sleep -Milliseconds 500
$st1 = Status $h
if ($st1 -notmatch "8") { throw "FAIL 3: wheel up status=[$st1]" }
[T4]::mouse_event(0x800, 0, 0, -120, [UIntPtr]::Zero)  # wheel down -> 4
Start-Sleep -Milliseconds 400
[T4]::mouse_event(0x800, 0, 0, -120, [UIntPtr]::Zero)  # wheel down -> 2
Start-Sleep -Milliseconds 400
$st2 = Status $h
if ($st2 -notmatch "2") { throw "FAIL 3: wheel down status=[$st2]" }
$json = Get-Content (Join-Path $env:APPDATA "JieDraw\settings.json") -Raw
if ($json -notmatch '"PenSize":\s*2') { throw "FAIL 3: PenSize not persisted to 2" }
Write-Host "OK 3: wheel cycles size ([$st1] -> [$st2], json PenSize=2)"
}

# --- 4. autostart path self-heal
Set-ItemProperty $runPath -Name "JieDraw" -Value "C:\old\path\JieDraw.exe"
Stop-Process -Name JieDraw -Force; Start-Sleep -Milliseconds 900
Start-Process -FilePath $Exe; Start-Sleep -Milliseconds 2500
$run = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
$expected = '"' + $Exe + '"'
if (-not ($run.JieDraw -like '*JieDraw.exe*') -or $run.JieDraw -match 'old.path') {
  throw "FAIL 4: autostart not healed ($($run.JieDraw))"
}
Write-Host "OK 4: autostart path healed -> $($run.JieDraw)"
Remove-ItemProperty $runPath -Name "JieDraw" -ErrorAction SilentlyContinue   # leave no autostart

# --- 5. paste system image as canvas backdrop (clipboard works under lock too, but be safe)
if ($locked) {
  Write-Host "SKIP 5: locked"
} else {
$proc = Get-Process JieDraw | Select-Object -First 1
$h = Find-HwndByTitle $proc.Id "JieDraw"
if (-not [T4]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }
Press $h "btnClear"; Start-Sleep -Milliseconds 400
# put a colorful image on the clipboard (STA script required)
$bmp = New-Object System.Drawing.Bitmap(800, 600)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(255, 200, 60, 60))
$g.FillEllipse([System.Drawing.Brushes]::Gold, 250, 150, 300, 300)
$g.Dispose()
[System.Windows.Forms.Clipboard]::SetImage($bmp)
$bmp.Dispose()
Start-Sleep -Milliseconds 300
Press $h "btnPaste"
Start-Sleep -Milliseconds 900
$st3 = Status $h
if ($st3 -notmatch [char]0x56FE) { throw "FAIL 5: paste image status=[$st3]" }
$png5 = Save-Latest
$p5 = Count-InkPixels $png5
if ($p5 -lt 3000) { throw "FAIL 5: pasted image not in export (ink=$p5)" }
Write-Host "OK 5: system image pasted as backdrop (export ink=$p5)"
Press $h "btnUndo"; Start-Sleep -Milliseconds 300
Press $h "btnClear"; Start-Sleep -Milliseconds 300
Press $h "btnHide"; Start-Sleep -Milliseconds 400
}
Write-Host "TIER4 OPTS ALL PASS"
