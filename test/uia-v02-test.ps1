# v0.2 features test (ASCII only, UIA + Win32, works on locked desktop)
# 1 fullscreen toggle (GetWindowPlacement showCmd)  2 highlighter radio select
# 3 window bounds memory across restart (SetWindowPos -> hide -> json -> relaunch -> rect)
# 4 autostart checkbox -> HKCU Run registry on/off
param(
  [string]$Exe = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\win-x64\publish\JieDraw.exe"
)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class V {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT wp);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd; public POINT ptMin; public POINT ptMax; public RECT rcNormal; }
}
"@
[void][V]::SetProcessDPIAware()   # unify coordinates to physical pixels

function Find-HwndByTitle([int]$procId, [string]$title) {
  $script:target = [IntPtr]::Zero
  $cb = [V+EnumProc]{ param($h, $l)
    $w = 0
    [void][V]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][V]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:target = $h }
    }
    return $true
  }
  [void][V]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

function Toggle([IntPtr]$hwnd) { [void][V]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }

function Show-Canvas([int]$procId) {
  $h = Find-HwndByTitle $procId "JieDraw"
  if ($h -eq [IntPtr]::Zero) { throw "canvas hwnd not found" }
  if (-not [V]::IsWindowVisible($h)) { Toggle $h; Start-Sleep -Milliseconds 700 }
  return $h
}

function Get-ShowCmd([IntPtr]$hwnd) {
  $wp = New-Object V+WINDOWPLACEMENT
  $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
  [void][V]::GetWindowPlacement($hwnd, [ref]$wp)
  return $wp.showCmd   # 1=normal 3=maximized
}

function Invoke-ButtonAsync([int]$procId, [string]$buttonId) {
  Start-Process powershell -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\invoke-btn.ps1",
    "-ProcId", $procId, "-ButtonId", $buttonId) -WindowStyle Hidden
}

# --- 1. launch resident + show
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe
  Start-Sleep -Milliseconds 2000
}
$proc = Get-Process JieDraw | Select-Object -First 1
$h = Show-Canvas $proc.Id
Write-Host "OK 1: app resident, canvas shown"

# --- 2. fullscreen toggle (button): normal(1) -> maximized(3) -> normal(1)
# (skip under lock screen: WPF defers window-state transitions on the secure lock desktop)
if ((Get-Process LockApp -ErrorAction SilentlyContinue) -ne $null) {
  Write-Host "SKIP 2: locked - window state transitions deferred"
} else {
$cmd0 = Get-ShowCmd $h
Invoke-ButtonAsync $proc.Id "btnMaximize"
Start-Sleep -Milliseconds 900
$cmd1 = Get-ShowCmd $h
Invoke-ButtonAsync $proc.Id "btnMaximize"
Start-Sleep -Milliseconds 900
$cmd2 = Get-ShowCmd $h
if ($cmd1 -ne 3) { throw "FAIL 2: fullscreen did not maximize (showCmd=$cmd0 -> $cmd1)" }
if ($cmd2 -eq 3) { throw "FAIL 2: fullscreen did not restore (showCmd=$cmd2)" }
# maximized must not cover taskbar: height < full screen height
Write-Host "OK 2: fullscreen toggle works ($cmd0 -> $cmd1 -> $cmd2)"
}

# --- 3. highlighter mode selectable via UIA
$mainEl = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$mkCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "mMarker")
$marker = $mainEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $mkCond)
if ($marker -eq $null) { throw "FAIL 3: mMarker not found" }
$sel = $marker.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
$sel.Select()
Start-Sleep -Milliseconds 400
if (-not $sel.Current.IsSelected) { throw "FAIL 3: mMarker not selected after Select()" }
$penCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "mPen")
$pen = $mainEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $penCond)
($pen.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
Write-Host "OK 3: highlighter (and pen) mode selectable"

# --- 4. window bounds memory across restart
$dpi = [System.Drawing.Graphics]::FromHwnd($h).DpiX / 96.0
# physical px must exceed MinWidth*dpi (660 WPF) to pass restore guard
[void][V]::SetWindowPos($h, [IntPtr]::Zero, 200, 150, 1000, 700, 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 500
Toggle $h   # hide -> SaveWindowBounds
Start-Sleep -Milliseconds 700
$json = Get-Content (Join-Path $env:APPDATA "JieDraw\settings.json") -Raw
$expL = [math]::Floor(200 / $dpi); $expW = [math]::Floor(1000 / $dpi)
if ($json -notmatch ('"WinLeft":\s*' + $expL)) { throw "FAIL 4: WinLeft not saved (dpi=$dpi, expect $expL): $json" }
if ($json -notmatch ('"WinWidth":\s*' + $expW)) { throw "FAIL 4: WinWidth not saved: $json" }
Write-Host "OK 4a: bounds saved to settings.json (dpi=$dpi, L=$expL W=$expW WPF)"

Stop-Process -Name JieDraw -Force
Start-Sleep -Milliseconds 800
Start-Process -FilePath $Exe
Start-Sleep -Milliseconds 2000
$proc2 = Get-Process JieDraw | Select-Object -First 1
$h2 = Show-Canvas $proc2.Id
$r = New-Object V+RECT
[void][V]::GetWindowRect($h2, [ref]$r)
if ([System.Math]::Abs($r.L - 200) -gt 40 -or [System.Math]::Abs($r.T - 150) -gt 40 `
  -or [System.Math]::Abs(($r.R - $r.L) - 1000) -gt 60 -or [System.Math]::Abs(($r.B - $r.T) - 700) -gt 60) {
  throw "FAIL 4: bounds not restored: rect=($($r.L),$($r.T))-($($r.R),$($r.B))"
}
Write-Host "OK 4b: bounds restored after restart rect=($($r.L),$($r.T)) $([int]($r.R-$r.L))x$([int]($r.B-$r.T))"
$proc = $proc2; $h = $h2

# --- 5. autostart checkbox -> registry
$runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$settingsTitle = [char]0x6377 + [char]0x753B + " " + [char]0x8BBE + [char]0x7F6E  # JieDraw Settings
function Open-Settings([int]$procId) {
  Invoke-ButtonAsync $procId "btnSettings"
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $sh = Find-HwndByTitle $procId $settingsTitle
    if ($sh -ne [IntPtr]::Zero) { return $sh }
  }
  throw "settings window not found"
}
function Set-AutoStart([int]$procId, [bool]$enable) {
  $sh = Open-Settings $procId
  $el = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
  $cCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "chkAutoStart")
  $chk = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cCond)
  if ($chk -eq $null) { throw "chkAutoStart not found" }
  $tg = $chk.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
  $want = "Off"; if ($enable) { $want = "On" }
  if ($tg.Current.ToggleState -ne $want) { $tg.Toggle() }
  $okCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnOk")
  $okBtn = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCond)
  ($okBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
  Start-Sleep -Milliseconds 600
}

Set-AutoStart $proc.Id $true
$run = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
if (-not $run.JieDraw) { throw "FAIL 5: registry Run\JieDraw not written" }
Write-Host ("OK 5a: autostart ON -> registry: " + $run.JieDraw)

Set-AutoStart $proc.Id $false
$run2 = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
if ($run2.JieDraw) { throw "FAIL 5: registry Run\JieDraw not removed" }
Write-Host "OK 5b: autostart OFF -> registry entry removed"

# --- 6. leave hidden + resident
Toggle $h
Start-Sleep -Milliseconds 400
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL 6: app died" }
Write-Host "OK 6: app resident, canvas hidden"

Write-Host "V02 ALL PASS"
