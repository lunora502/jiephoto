# JieDraw smoke test (ASCII only, Windows PowerShell 5.1+)
# Verifies: resident launch -> canvas show/hide via WM_HOTKEY (app pipeline) ->
#           synthetic ink stroke -> visibility toggling. Real global hotkey is
#           verified separately by a human Alt+Q press.
param(
  [string]$Exe = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\JieDraw.exe",
  [string]$OutDir = "$PSScriptRoot\..\test-out",
  [switch]$KeepRunning
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class U {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct POINT { public int X; public int Y; }
  public struct RECT { public int L; public int T; public int R; public int B; }
}
"@

function Screenshot([string]$path) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

function Find-CanvasHwnd {
  $script:target = [IntPtr]::Zero
  $script:jdpid = (Get-Process JieDraw -ErrorAction SilentlyContinue | Select-Object -First 1).Id
  if ($script:jdpid -eq $null) { return [IntPtr]::Zero }
  $cb = [U+EnumProc]{ param($h, $l)
    $w = 0
    [void][U]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][U]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][U]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

function Toggle-ViaHotkey([IntPtr]$hwnd) {
  # WM_HOTKEY(0x0312), wParam=Id(1) — 与 WndProc 判定一致，直入热键处理管线
  [void][U]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0)
}

function Visible([IntPtr]$hwnd) { [U]::IsWindowVisible($hwnd) }

# --- 0. input injection capability probe
[U]::SetCursorPos(300, 300) | Out-Null
Start-Sleep -Milliseconds 150
$p = New-Object U+POINT
[void][U]::GetCursorPos([ref]$p)
$injection = ($p.X -eq 300 -and $p.Y -eq 300)
Write-Host ("input injection available: " + $injection)

# --- 1. launch resident
Start-Process -FilePath $Exe
Start-Sleep -Milliseconds 1800
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL 1: process not running" }
$h = Find-CanvasHwnd
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas window not found" }
if (Visible $h) { throw "FAIL 1: window should be hidden at startup" }
Write-Host "OK 1: resident, canvas hidden"

# --- 2. hotkey pipeline -> show
Toggle-ViaHotkey $h
Start-Sleep -Milliseconds 800
if (-not (Visible $h)) { throw "FAIL 2: window not visible after WM_HOTKEY" }
Write-Host "OK 2: hotkey pipeline showed canvas"
Screenshot "$OutDir\1-shown.png"

# --- 3. synthetic stroke (only if injection works)
if ($injection) {
  $r = New-Object U+RECT
  [void][U]::GetWindowRect($h, [ref]$r)
  $cx = [int](($r.L + $r.R) / 2); $cy = [int](($r.T + $r.B) / 2) + 20
  [void][U]::SetCursorPos($cx - 180, $cy)
  Start-Sleep -Milliseconds 150
  [U]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
  for ($i = 0; $i -le 60; $i++) {
    $x = $cx - 180 + $i * 6
    $y = $cy + [int]([System.Math]::Sin($i / 5.0) * 40)
    [void][U]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 12
  }
  [U]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
  Start-Sleep -Milliseconds 300
  Screenshot "$OutDir\2-drawn.png"
  Write-Host "OK 3: synthetic stroke drawn"
} else {
  Write-Host "SKIP 3: input injection unavailable in this environment"
}

# --- 4. hotkey pipeline -> hide
Toggle-ViaHotkey $h
Start-Sleep -Milliseconds 500
if (Visible $h) { throw "FAIL 4: window still visible after second WM_HOTKEY" }
Write-Host "OK 4: hotkey pipeline hid canvas"

# --- 5. re-show for manual hotkey/save verification
Toggle-ViaHotkey $h
Start-Sleep -Milliseconds 500
if (-not (Visible $h)) { throw "FAIL 5: re-show failed" }
Screenshot "$OutDir\3-reshown.png"
Write-Host "OK 5: re-shown"

if ($KeepRunning) {
  Write-Host "APP LEFT RUNNING for manual Alt+Q / drawing / Ctrl+S verification."
} else {
  Stop-Process -Name JieDraw -Force -ErrorAction SilentlyContinue
  Write-Host "ALL PASS (pipeline)"
}
