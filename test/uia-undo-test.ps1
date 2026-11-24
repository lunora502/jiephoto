# Undo E2E test (ASCII only). Requires UNLOCKED desktop (real mouse injection).
# 1 toolbar buttons visible (overflow fix)  2 draw 2 strokes -> save PNG has ink
# 3 undo -> save PNG blank  4 redo -> PNG has ink again.
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
public static class U3 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int L; public int T; public int R; public int B; }
}
"@
[void][U3]::SetProcessDPIAware()   # unify coordinates to physical pixels

function Find-CanvasHwnd {
  $script:target = [IntPtr]::Zero
  $script:jdpid = (Get-Process JieDraw -ErrorAction SilentlyContinue | Select-Object -First 1).Id
  if ($script:jdpid -eq $null) { return [IntPtr]::Zero }
  $cb = [U3+EnumProc]{ param($h, $l)
    $w = 0
    [void][U3]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][U3]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][U3]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

function Toggle([IntPtr]$hwnd) { [void][U3]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }

function Invoke-Btn([IntPtr]$hwnd, [string]$id) {
  $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
  $btn = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($btn -eq $null) { throw "button $id not found" }
  ($btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
  return $btn
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
  $bmp.Dispose()
  return $count
}

# --- 1. launch + show
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe
  Start-Sleep -Milliseconds 2000
}
$h = Find-CanvasHwnd
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas not found" }
if (-not [U3]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }

# --- 1b. toolbar overflow fix: window control buttons must be inside window & on-screen
$el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$wr = New-Object U3+RECT
[void][U3]::GetWindowRect($h, [ref]$wr)
$screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
foreach ($id in @("btnMaximize", "btnSettings", "btnHide", "btnClose")) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
  $b = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($b -eq $null) { throw "FAIL 1b: $id not found" }
  $r = $b.Current.BoundingRectangle
  if ($r.IsEmpty) { throw "FAIL 1b: $id has empty rect" }
  if ([int]$r.Right -gt $wr.R + 2 -or [int]$r.X -lt $wr.L - 2 -or [int]$r.Right -gt $screenW) {
    throw "FAIL 1b: $id outside window/screen: winR=$($wr.R) btnR=$([int]$r.Right) screenW=$screenW"
  }
}
Write-Host "OK 1: canvas shown; fullscreen/settings/hide/close buttons visible inside window"

# --- 2. draw 2 strokes with real mouse
$r2 = New-Object U3+RECT
[void][U3]::GetWindowRect($h, [ref]$r2)
$cx = [int](($r2.L + $r2.R) / 2); $cy = [int](($r2.T + $r2.B) / 2)
function Draw-Wave([int]$x0, [int]$y0, [int]$len, [double]$amp) {
  [void][U3]::SetCursorPos($x0, $y0)
  Start-Sleep -Milliseconds 130
  [U3]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 40; $i++) {
    [void][U3]::SetCursorPos($x0 + $i * [int]($len / 40), $y0 + [int]([System.Math]::Sin($i / 4.0) * $amp))
    Start-Sleep -Milliseconds 12
  }
  [U3]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 450   # over the 300ms merge quiet period, each stroke = one undo unit
}
Draw-Wave ($cx - 180) ($cy - 30) 360 35
Draw-Wave ($cx - 180) ($cy + 60) 360 25

Invoke-Btn $h "btnSave" | Out-Null
Start-Sleep -Milliseconds 1500
$pics = Join-Path ([Environment]::GetFolderPath("MyPictures")) "JieDraw"
$png1 = (Get-ChildItem $pics -Filter *.png | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$ink1 = Count-InkPixels $png1
if ($ink1 -lt 200) { throw "FAIL 2: strokes not drawn or not saved (ink pixels=$ink1) - desktop locked?" }
Write-Host "OK 2: 2 strokes drawn, PNG ink pixels=$ink1 ($png1)"

# --- 3. undo twice -> canvas should be blank
Invoke-Btn $h "btnUndo" | Out-Null; Start-Sleep -Milliseconds 450
Invoke-Btn $h "btnUndo" | Out-Null; Start-Sleep -Milliseconds 600
Invoke-Btn $h "btnSave" | Out-Null
Start-Sleep -Milliseconds 1500
$png2 = (Get-ChildItem $pics -Filter *.png | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$ink2 = Count-InkPixels $png2
if ($ink2 -gt 40) { throw "FAIL 3: undo did not clear canvas (ink pixels=$ink2)" }
Write-Host "OK 3: undo x2 cleared canvas (ink pixels=$ink2)"

# --- 4. redo once -> one stroke back
Invoke-Btn $h "btnRedo" | Out-Null
Start-Sleep -Milliseconds 500
Invoke-Btn $h "btnSave" | Out-Null
Start-Sleep -Milliseconds 1500
$png3 = (Get-ChildItem $pics -Filter *.png | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$ink3 = Count-InkPixels $png3
if ($ink3 -lt 100) { throw "FAIL 4: redo did not restore stroke (ink pixels=$ink3)" }
Write-Host "OK 4: redo restored a stroke (ink pixels=$ink3)"

# --- 5. hide + stay resident
Toggle $h
Start-Sleep -Milliseconds 400
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL 5: app died" }
Write-Host "OK 5: app resident, canvas hidden"
Write-Host "UNDO E2E ALL PASS"
