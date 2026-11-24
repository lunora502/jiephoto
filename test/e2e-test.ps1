# JieDraw end-to-end test with REAL keyboard/mouse injection (ASCII only)
# Alt+Q (real global hotkey) -> draw -> Ctrl+S -> verify PNG on disk -> Esc hide.
param(
  [string]$Exe = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\win-x64\publish\JieDraw.exe",
  [string]$OutDir = "$PSScriptRoot\..\test-out"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class K {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public long pad; }
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT { public uint type; public INPUTUNION u; }
  public const uint DOWN = 0x0000;
  public const uint UP = 0x0002;
  public static void Tap(ushort vk, uint flags) {
    var i = new INPUT[1];
    i[0].type = 1;
    i[0].u.ki.wVk = vk;
    i[0].u.ki.dwFlags = flags;
    SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Combo(ushort mod, ushort key) {
    Tap(mod, DOWN); System.Threading.Thread.Sleep(50);
    Tap(key, DOWN); System.Threading.Thread.Sleep(50);
    Tap(key, UP);   System.Threading.Thread.Sleep(50);
    Tap(mod, UP);
  }
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
  $cb = [K+EnumProc]{ param($h, $l)
    $w = 0
    [void][K]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][K]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][K]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

# --- 1. ensure app running
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe
  Start-Sleep -Milliseconds 2000
}
$h = Find-CanvasHwnd
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas window not found" }
if ([K]::IsWindowVisible($h)) { throw "FAIL 1: window should start hidden" }
Write-Host "OK 1: app resident, canvas hidden (hwnd=0x$($h.ToInt64().ToString('X')))"

# --- 2. REAL global hotkey Alt+Q
[K]::Combo(0x12, 0x51)   # Alt + Q
Start-Sleep -Milliseconds 900
if (-not [K]::IsWindowVisible($h)) {
  Screenshot "$OutDir\e2e-fail-altq.png"
  throw "FAIL 2: real Alt+Q did not show canvas (see e2e-fail-altq.png)"
}
Screenshot "$OutDir\e2e-1-shown.png"
Write-Host "OK 2: real Alt+Q showed canvas"

# --- 3. draw two synthetic strokes (different positions)
$r = New-Object K+RECT
[void][K]::GetWindowRect($h, [ref]$r)
$cx = [int](($r.L + $r.R) / 2); $cy = [int](($r.T + $r.B) / 2)
function Draw-Wave([int]$startX, [int]$startY, [int]$len, [double]$amp) {
  [void][K]::SetCursorPos($startX, $startY)
  Start-Sleep -Milliseconds 120
  [K]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  for ($i = 0; $i -le 50; $i++) {
    [void][K]::SetCursorPos($startX + $i * [int]($len / 50), $startY + [int]([System.Math]::Sin($i / 4.0) * $amp))
    Start-Sleep -Milliseconds 10
  }
  [K]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 200
}
Draw-Wave ($cx - 200) ($cy - 40) 400 35
Draw-Wave ($cx - 200) ($cy + 60) 400 25
Screenshot "$OutDir\e2e-2-drawn.png"
Write-Host "OK 3: synthetic strokes drawn"

# --- 4. REAL Ctrl+S -> PNG on disk
[K]::Combo(0x11, 0x53)   # Ctrl + S
Start-Sleep -Milliseconds 1200
$pics = [Environment]::GetFolderPath("MyPictures")
$dir = Join-Path $pics "JieDraw"
$latest = Get-ChildItem $dir -Filter *.png -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest -eq $null) { throw "FAIL 4: no PNG saved in $dir" }
if ((Get-Date) - $latest.LastWriteTime -gt [TimeSpan]::FromMinutes(2)) { throw "FAIL 4: newest PNG is stale: $($latest.FullName)" }
Write-Host ("OK 4: PNG saved -> " + $latest.FullName + " (" + [int]($latest.Length/1024) + " KB)")

# --- 5. Esc hides
[K]::Tap(0x1B, [K]::DOWN); Start-Sleep -Milliseconds 60; [K]::Tap(0x1B, [K]::UP)
Start-Sleep -Milliseconds 600
if ([K]::IsWindowVisible($h)) { throw "FAIL 5: window still visible after Esc" }
Write-Host "OK 5: Esc hid canvas (app still resident)"

Write-Host "E2E ALL PASS"
Write-Host ("artifact: " + $latest.FullName)
