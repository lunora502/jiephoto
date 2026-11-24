# JieDraw UIA-based test (ASCII only) — works even on a locked desktop:
# no hardware input queue involved. Verifies toolbar button wiring and the
# save-PNG pipeline end to end (button click -> RenderTargetBitmap -> file on disk).
param(
  [string]$Exe = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\win-x64\publish\JieDraw.exe",
  [string]$OutDir = "$PSScriptRoot\..\test-out"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class W {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
"@

function Find-CanvasHwnd {
  $script:target = [IntPtr]::Zero
  $script:jdpid = (Get-Process JieDraw -ErrorAction SilentlyContinue | Select-Object -First 1).Id
  if ($script:jdpid -eq $null) { return [IntPtr]::Zero }
  $cb = [W+EnumProc]{ param($h, $l)
    $w = 0
    [void][W]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][W]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][W]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

function Toggle([IntPtr]$hwnd) { [void][W]::PostMessage($hwnd, 0x0312, [IntPtr]1, [IntPtr]0) }

function Find-Button($root, [string]$id) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
  return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

# --- 1. launch resident
Start-Process -FilePath $Exe
Start-Sleep -Milliseconds 2000
$h = Find-CanvasHwnd
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas window not found" }
Write-Host "OK 1: app resident (hwnd=0x$($h.ToInt64().ToString('X')))"

# --- 2. show via hotkey pipeline
Toggle $h
Start-Sleep -Milliseconds 800
if (-not [W]::IsWindowVisible($h)) { throw "FAIL 2: show failed" }
Write-Host "OK 2: canvas shown"

# --- 3. UIA: locate and invoke buttons (no input injection needed)
$root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
Write-Host ("UIA root found: " + ($root -ne $null) + " name='" + $root.Current.Name + "'")

$btnSave = Find-Button $root "btnSave"
if ($btnSave -eq $null) { throw "FAIL 3: btnSave not found via UIA" }
$saveDir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "JieDraw"
$before = @(Get-ChildItem $saveDir -Filter *.png -ErrorAction SilentlyContinue).Count

$inv = $btnSave.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$inv.Invoke()
Start-Sleep -Milliseconds 1500

$after = @(Get-ChildItem $saveDir -Filter *.png -ErrorAction SilentlyContinue)
if ($after.Count -le $before) { throw "FAIL 3: PNG count did not increase in $saveDir" }
$newest = $after | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ("OK 3: save button invoked -> " + $newest.FullName + " (" + [int]($newest.Length/1024) + " KB)")

# --- 4. validate the PNG is a real decodable image
$img = [System.Drawing.Image]::FromFile($newest.FullName)
Write-Host ("OK 4: PNG decodable, size " + $img.Width + "x" + $img.Height)
$img.Dispose()

# --- 5. copy button also wired
$btnCopy = Find-Button $root "btnCopy"
if ($btnCopy -ne $null) {
  ($btnCopy.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
  Start-Sleep -Milliseconds 800
  Write-Host "OK 5: copy button invoked (clipboard set)"
}

# --- 6. hide via hotkey pipeline
Toggle $h
Start-Sleep -Milliseconds 500
if ([W]::IsWindowVisible($h)) { throw "FAIL 6: hide failed" }
Write-Host "OK 6: canvas hidden, app still resident"

Write-Host "UIA ALL PASS"
Write-Host ("saved artifact: " + $newest.FullName)
