# Selection tools E2E (ASCII only). Needs UNLOCKED desktop for mouse parts.
# 1 single-row toolbar layout  2 erase-size-no-jump  3 rect marquee select -> copy/paste
# 4 click select with Ctrl+add  5 undo restores  6 resident.
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
public static class S {
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
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int L; public int T; public int R; public int B; }
}
"@
[void][S]::SetProcessDPIAware()   # unify all coordinates to physical pixels

function Find-CanvasHwnd {
  $script:target = [IntPtr]::Zero
  $script:jdpid = (Get-Process JieDraw -ErrorAction SilentlyContinue | Select-Object -First 1).Id
  if ($script:jdpid -eq $null) { return [IntPtr]::Zero }
  $cb = [S+EnumProc]{ param($h, $l)
    $w = 0
    [void][S]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][S]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][S]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

function Toggle([IntPtr]$hwnd) { [void][S]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }

function Invoke-Btn([IntPtr]$hwnd, [string]$id) {
  $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
  $b = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($b -eq $null) { throw "element $id not found" }
  return $b
}

function Select-Chip([IntPtr]$hwnd, [string]$chipId) {
  # global real click at chip center with state verification + retry
  $el = Invoke-Btn $hwnd $chipId
  $pat = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $r = $el.Current.BoundingRectangle
    [void][S]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 180
    [S]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [S]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 450
    if ($pat.Current.IsSelected) { return }
  }
  throw "chip $chipId not selected after 3 real clicks"
}

function Click-At([int]$x, [int]$y) {
  [void][S]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 150
  [S]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [S]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 450
}

function Ctrl-Click-At([int]$x, [int]$y) {
  [S]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)      # Ctrl down
  Start-Sleep -Milliseconds 120
  [void][S]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 150
  [S]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [S]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 450
  [S]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)      # Ctrl up
  Start-Sleep -Milliseconds 150
}

function Draw-Line([int]$x0, [int]$y, [int]$len) {
  [void][S]::SetCursorPos($x0, $y)
  Start-Sleep -Milliseconds 130
  [S]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 20; $i++) {
    [void][S]::SetCursorPos($x0 + $i * [int]($len / 20), $y)
    Start-Sleep -Milliseconds 10
  }
  [S]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500   # let the 300ms undo burst commit
}

function Draw-Wave([int]$x0, [int]$y, [int]$len, [double]$amp) {
  [void][S]::SetCursorPos($x0, $y)
  Start-Sleep -Milliseconds 130
  [S]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 30; $i++) {
    [void][S]::SetCursorPos($x0 + $i * [int]($len / 30), $y + [int]([System.Math]::Sin($i / 3.0) * $amp))
    Start-Sleep -Milliseconds 10
  }
  [S]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}

function Marquee-Drag([int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  [void][S]::SetCursorPos($x0, $y0)
  Start-Sleep -Milliseconds 150
  [S]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 15; $i++) {
    [void][S]::SetCursorPos($x0 + [int](($x1 - $x0) * $i / 15), $y0 + [int](($y1 - $y0) * $i / 15))
    Start-Sleep -Milliseconds 14
  }
  [S]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 550
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

function Save-ViaButton([IntPtr]$hwnd) {
  (Invoke-Btn $hwnd "btnSave").GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 1400
  $pics = Join-Path ([Environment]::GetFolderPath("MyPictures")) "JieDraw"
  return (Get-ChildItem $pics -Filter *.png | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Press-Button([IntPtr]$hwnd, [string]$id) {
  (Invoke-Btn $hwnd $id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# --- 1. launch + normalize + clean state
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe
  Start-Sleep -Milliseconds 2000
}
$h = Find-CanvasHwnd
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas not found" }
if (-not [S]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 800 }
[void][S]::SetWindowPos($h, [IntPtr]::Zero, 150, 120, 1050, 720, 0x0004)
Start-Sleep -Milliseconds 500
Set-Clipboard -Value " "
Start-Sleep -Milliseconds 300
Press-Button $h "btnClear"
Start-Sleep -Milliseconds 600

$inkRect = (Invoke-Btn $h "inkCanvas").Current.BoundingRectangle
$cx = [int]($inkRect.X + $inkRect.Width / 2)
$cy = [int]($inkRect.Y + $inkRect.Height / 2)
Write-Host ("OK 1: canvas ready; ink center=({0},{1})" -f $cx, $cy)

# --- 1b. single-row toolbar: all row-2 controls share one Y band and stay inside the window
$wr = New-Object S+RECT
[void][S]::GetWindowRect($h, [ref]$wr)
$row2 = @("cBlack","s1","mPen","mMarker","mErase","mRect","mClick","mLasso","btnCopy","btnPaste","btnSave")
$ys = @(); $maxRight = 0
foreach ($id in $row2) {
  $r = (Invoke-Btn $h $id).Current.BoundingRectangle
  if ($r.IsEmpty) { throw "FAIL 1b: $id empty rect" }
  $ys += [double]$r.Y
  if ($r.Right -gt $maxRight) { $maxRight = $r.Right }
}
$yMin = ($ys | Measure-Object -Minimum).Minimum
$yMax = ($ys | Measure-Object -Maximum).Maximum
if (($yMax - $yMin) -gt 6) { throw "FAIL 1b: row-2 controls span $($yMax - $yMin)px vertically (not one row)" }
if ($maxRight -gt $wr.R + 2) { throw "FAIL 1b: row-2 overflows window (right=$maxRight vs $($wr.R))" }
Write-Host ("OK 1b: tools fit one row (y-span {0:F1}px, right {1:F0} < {2})" -f ($yMax - $yMin), $maxRight, $wr.R)

# --- 2. erase + size click keeps erase mode (bugfix regression)
Select-Chip $h "mErase"
$erasePat = (Invoke-Btn $h "mErase").GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
Select-Chip $h "s3"   # size chip click while erasing (chips share the click mechanism)
$penSel = (Invoke-Btn $h "mPen").GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
if (-not $erasePat.Current.IsSelected) { throw "FAIL 2: size click jumped out of erase" }
if ($penSel) { throw "FAIL 2: pen auto-selected" }
Write-Host "OK 2: size click in erase mode keeps erase mode"

# --- 3. rect marquee select -> copy -> paste -> undo
Select-Chip $h "mPen"
Draw-Wave ($cx - 150) ($cy) 300 30          # one wave stroke at canvas center
$png1 = Save-ViaButton $h
$base = Count-InkPixels $png1
if ($base -lt 80) { throw "FAIL 3: baseline stroke missing (ink=$base) - locked?" }

Select-Chip $h "mRect"
Marquee-Drag ($cx - 200) ($cy - 80) ($cx + 200) ($cy + 80)   # box well around the wave
Press-Button $h "btnCopy"
Start-Sleep -Milliseconds 500
Press-Button $h "btnPaste"
Start-Sleep -Milliseconds 900
$png2 = Save-ViaButton $h
$after = Count-InkPixels $png2
if ($after -le $base * 1.4) { throw "FAIL 3: rect select+paste did not duplicate (ink $base -> $after)" }
Press-Button $h "btnUndo"
Start-Sleep -Milliseconds 600
$png3 = Save-ViaButton $h
$restored = Count-InkPixels $png3
if ($restored -gt $base * 1.25 -or $restored -lt $base * 0.75) { throw "FAIL 3: undo did not restore (ink=$restored vs $base)" }
Write-Host "OK 3: rect marquee select + copy/paste (ink $base -> $after -> $restored)"

# --- 4. click select with Ctrl+click additive
Press-Button $h "btnUndo"   # remove baseline wave -> empty canvas
Start-Sleep -Milliseconds 600
Press-Button $h "btnClear"  # ensure empty
Start-Sleep -Milliseconds 400
Select-Chip $h "mPen"
Draw-Line ($cx - 150) ($cy - 60) 280        # stroke A (straight line at known y)
Draw-Line ($cx - 150) ($cy + 60) 280        # stroke B
$png4 = Save-ViaButton $h
$two = Count-InkPixels $png4
if ($two -lt 120) { throw "FAIL 4: two strokes missing (ink=$two)" }

Select-Chip $h "mClick"
Click-At ($cx - 100) ($cy - 60)             # select stroke A
$st1 = (Invoke-Btn $h "statusText").Current.Name
if ($st1 -notmatch "1") { throw "FAIL 4: click A did not select (status=[$st1])" }
Ctrl-Click-At ($cx - 100) ($cy + 60)        # add stroke B
$st2 = (Invoke-Btn $h "statusText").Current.Name
if ($st2 -notmatch "2") { throw "FAIL 4: ctrl+click B did not add (status=[$st2])" }

Press-Button $h "btnCopy"
Start-Sleep -Milliseconds 500
Press-Button $h "btnClear"                   # canvas empty now...
Start-Sleep -Milliseconds 400
$pngEmpty = Save-ViaButton $h
$empty = Count-InkPixels $pngEmpty
if ($empty -gt 20) { throw "FAIL 4: clear before paste failed (ink=$empty)" }
Press-Button $h "btnPaste"                   # ...so pasted ink must equal the two copied strokes
Start-Sleep -Milliseconds 900
$png5 = Save-ViaButton $h
$twoAfter = Count-InkPixels $png5
# single stroke ~= 0.5x of $two; two strokes land on subpixel positions -> anti-aliased
# edges undercount a bit, so require >= 0.65x to prove BOTH came back (0.5x would be one)
if ($twoAfter -lt $two * 0.65) { throw "FAIL 4: paste did not restore BOTH strokes (ink=$twoAfter vs $two)" }
Write-Host "OK 4: click select + Ctrl additive + paste on empty canvas (status [$st1] -> [$st2], ink $empty -> $twoAfter ~= $two)"

# --- 5. hide + stay resident
Toggle $h
Start-Sleep -Milliseconds 400
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL 5: app died" }
Write-Host "OK 5: app resident, canvas hidden"
Write-Host "SELECT-TOOLS ALL PASS"
