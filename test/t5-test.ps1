# Wake-shortcut feature E2E (ASCII only, input-free - works under lock screen)
# 1 startup ensures Start Menu .lnk (target=/show args, Ctrl+Alt+Q hotkey, exe path)
# 2 cold launch with /show shows canvas immediately
# 3 second instance with /show activates existing & exits
# 4 settings toggle off removes .lnk; on recreates
# 5 autostart stays OFF by default (no HKCU Run entry)
param(
  [string]$Exe = "$PSScriptRoot\..\src\JieDraw\bin\Release\net8.0-windows\win-x64\publish\JieDraw.exe"
)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class T5 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
"@

function Find-HwndByTitle([int]$procId, [string]$title) {
  $script:th = [IntPtr]::Zero
  $cb = [T5+EnumProc]{ param($h, $l)
    $w = 0
    [void][T5]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][T5]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:th = $h }
    }
    return $true
  }
  [void][T5]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:th
}
function Invoke-ChildBtn([int]$procId, [string]$buttonId) {
  Start-Process powershell -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\invoke-btn.ps1",
    "-ProcId", $procId, "-ButtonId", $buttonId) -WindowStyle Hidden
}

$runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$programsDir = [Environment]::GetFolderPath("Programs")   # user Start Menu\Programs
$lnkTitle = [string][char]0x6377 + [char]0x753B + " JieDraw.lnk"
$lnk = Join-Path $programsDir $lnkTitle
$settingsTitle = [string][char]0x6377 + [char]0x753B + " " + [char]0x8BBE + [char]0x7F6E

# hygiene: no autostart by default
Remove-ItemProperty $runPath -Name "JieDraw" -ErrorAction SilentlyContinue
if (Test-Path $lnk) { Remove-Item $lnk -Force }

# --- 1. startup ensures the wake shortcut
Stop-Process -Name JieDraw -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
Start-Process -FilePath $Exe
Start-Sleep -Milliseconds 2500
if (-not (Test-Path $lnk)) { throw "FAIL 1: wake .lnk not created at $lnk" }
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
if ($sc.Arguments -ne "/show") { throw "FAIL 1: .lnk Arguments=[$($sc.Arguments)] expect /show" }
# WSH normalizes modifier order (reads back "Alt+Ctrl+Q"); compare as sorted token sets
$got = (@($sc.Hotkey -split '\+') | Sort-Object) -join '+'
$want = (@("Ctrl", "Alt", "Q") | Sort-Object) -join '+'
if ($got -ne $want) { throw "FAIL 1: .lnk Hotkey=[$($sc.Hotkey)] expect Ctrl+Alt+Q" }
if ($sc.TargetPath -notlike "*JieDraw.exe") { throw "FAIL 1: .lnk TargetPath=[$($sc.TargetPath)]" }
Write-Host "OK 1: wake shortcut ensured (target /show, Ctrl+Alt+Q)"
$proc = Get-Process JieDraw | Select-Object -First 1

# --- 2. cold launch with /show shows canvas immediately
$h = Find-HwndByTitle $proc.Id "JieDraw"
if ($h -ne [IntPtr]::Zero -and [T5]::IsWindowVisible($h)) { [void][T5]::PostMessage($h, 0x0312, [IntPtr]1, [IntPtr]0); Start-Sleep -Milliseconds 600 }  # normalize to hidden
Stop-Process -Name JieDraw -Force
Start-Sleep -Milliseconds 900
Start-Process -FilePath $Exe -ArgumentList "/show"
Start-Sleep -Milliseconds 2500
$proc2 = Get-Process JieDraw | Select-Object -First 1
$h2 = Find-HwndByTitle $proc2.Id "JieDraw"
if ($h2 -eq [IntPtr]::Zero) { throw "FAIL 2: canvas hwnd missing after /show launch" }
if (-not [T5]::IsWindowVisible($h2)) { throw "FAIL 2: /show did not show canvas on cold launch" }
Write-Host "OK 2: /show cold launch shows canvas immediately"

# --- 3. second instance with /show activates existing and exits
[void][T5]::PostMessage($h2, 0x0312, [IntPtr]1, [IntPtr]0); Start-Sleep -Milliseconds 600   # hide
Start-Process -FilePath $Exe -ArgumentList "/show"
Start-Sleep -Milliseconds 1800
$procs = @(Get-Process JieDraw -ErrorAction SilentlyContinue)
if ($procs.Count -ne 1) { throw "FAIL 3: second instance did not exit ($($procs.Count))" }
$h3 = Find-HwndByTitle $procs[0].Id "JieDraw"
if ($h3 -eq [IntPtr]::Zero -or -not [T5]::IsWindowVisible($h3)) { throw "FAIL 3: existing canvas not activated" }
Write-Host "OK 3: second /show launch activated existing instance"
$proc = $procs[0]

# --- 4. settings toggle: off removes .lnk, on recreates
Invoke-ChildBtn $proc.Id "btnSettings"
$sh = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 150; $sh = Find-HwndByTitle $proc.Id $settingsTitle; if ($sh -ne [IntPtr]::Zero) { break } }
if ($sh -eq [IntPtr]::Zero) { throw "FAIL 4: settings window not found" }
$sEl = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
$chk = $sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "chkWake")))
$tg = $chk.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
if ($tg.Current.ToggleState -ne "On") { $tg.Toggle() }
$tg.Toggle()   # off
($sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnOk")))).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 800
if (Test-Path $lnk) { throw "FAIL 4: .lnk not removed after toggle off" }
Write-Host "OK 4a: toggle off removed wake shortcut"

Invoke-ChildBtn $proc.Id "btnSettings"
$sh = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 150; $sh = Find-HwndByTitle $proc.Id $settingsTitle; if ($sh -ne [IntPtr]::Zero) { break } }
$sEl = [System.Windows.Automation.AutomationElement]::FromHandle($sh)
$chk = $sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "chkWake")))
$tg = $chk.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
$tg.Toggle()   # on
($sEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnOk")))).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 800
if (-not (Test-Path $lnk)) { throw "FAIL 4: .lnk not recreated after toggle on" }
Write-Host "OK 4b: toggle on recreated wake shortcut"

# --- 5. autostart stays OFF by default
$run = Get-ItemProperty $runPath -ErrorAction SilentlyContinue
if ($run.JieDraw) { throw "FAIL 5: HKCU Run entry exists without user opt-in" }
Write-Host "OK 5: autostart stays OFF by default (wake shortcut carries the hotkey)"

Write-Host "WAKE-SHORTCUT ALL PASS"
