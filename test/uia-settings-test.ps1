# Settings + close-button test (ASCII only, works on locked desktop via UIA)
# Flow: show canvas -> open settings (child process, modal-safe) ->
#       change hotkey to Ctrl+Shift+D -> verify json+trace -> revert to Alt+Q ->
#       verify -> close button X -> app exits cleanly -> relaunch resident.
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
public static class W2 {
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
  $cb = [W2+EnumProc]{ param($h, $l)
    $w = 0
    [void][W2]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $script:jdpid) {
      $t = New-Object System.Text.StringBuilder 128
      [void][W2]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq "JieDraw") { $script:target = $h }
    }
    return $true
  }
  [void][W2]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:target
}

function Find-SettingsElement([int]$procId) {
  # 该模态 ToolWindow 不在 UIA 桌面子级树中（ControlView 不列它），
  # 因此走 Win32 EnumWindows 拿 HWND，再 FromHandle 直取 UIA 元素
  $script:settingsHwnd = [IntPtr]::Zero
  $title = [char]0x6377 + [char]0x753B + " " + [char]0x8BBE + [char]0x7F6E  # 捷画 设置
  $cb = [W2+EnumProc]{ param($h, $l)
    $w = 0
    [void][W2]::GetWindowThreadProcessId($h, [ref]$w)
    if ($w -eq $procId) {
      $t = New-Object System.Text.StringBuilder 128
      [void][W2]::GetWindowText($h, $t, 128)
      if ($t.ToString() -eq $title) { $script:settingsHwnd = $h }
    }
    return $true
  }
  [void][W2]::EnumWindows($cb, [IntPtr]::Zero)
  if ($script:settingsHwnd -eq [IntPtr]::Zero) { return $null }
  return [System.Windows.Automation.AutomationElement]::FromHandle($script:settingsHwnd)
}

function Set-HotkeyViaUi([int]$procId, [string]$spec) {
  # open settings via child process (modal dialog blocks its invoker, not us)
  Start-Process powershell -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\invoke-btn.ps1",
    "-ProcId", $procId, "-ButtonId", "btnSettings") -WindowStyle Hidden

  $win = $null
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $win = Find-SettingsElement $procId
    if ($win -ne $null) { break }
  }
  if ($win -eq $null) { throw "settings window not found" }

  $boxCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "hotkeyBox")
  $box = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $boxCond)
  if ($box -eq $null) { throw "hotkeyBox not found" }
  ($box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($spec)

  $okCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnOk")
  $okBtn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCond)
  ($okBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
  Start-Sleep -Milliseconds 500
}

function Get-SettingsJson {
  Get-Content (Join-Path $env:APPDATA "JieDraw\settings.json") -Raw
}

# --- 1. ensure resident
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) {
  Start-Process -FilePath $Exe
  Start-Sleep -Milliseconds 2000
}
$proc = Get-Process JieDraw | Select-Object -First 1
$h = Find-CanvasHwnd
if ($h -eq [IntPtr]::Zero) { throw "FAIL 1: canvas not found" }
if (-not [W2]::IsWindowVisible($h)) { [void][W2]::PostMessage($h, 0x0312, [IntPtr]1, [IntPtr]0); Start-Sleep -Milliseconds 700 }
Write-Host "OK 1: app resident, canvas shown"

# --- 2. change hotkey to Ctrl+Shift+D
Set-HotkeyViaUi $proc.Id "Ctrl+Shift+D"
$json = Get-SettingsJson
# JSON 可能把 + 转义为 \u002B，两种形式都接受
if ($json -notmatch '"Hotkey":\s*"Ctrl(?:\+|\\u002B)Shift(?:\+|\\u002B)D"') { throw "FAIL 2: settings.json not updated: $json" }
$trace = Get-Content (Join-Path $env:APPDATA "JieDraw\trace.log") -Raw
if ($trace -notmatch "hotkey changed to Ctrl\+Shift\+D") { throw "FAIL 2: trace.log missing registration line" }
Write-Host "OK 2: hotkey changed to Ctrl+Shift+D (json + trace verified)"

# --- 3. hotkey pipeline still toggles after re-register
[void][W2]::PostMessage($h, 0x0312, [IntPtr]1, [IntPtr]0)
Start-Sleep -Milliseconds 500
if ([W2]::IsWindowVisible($h)) { throw "FAIL 3: toggle broken after re-register" }
[void][W2]::PostMessage($h, 0x0312, [IntPtr]1, [IntPtr]0)
Start-Sleep -Milliseconds 500
if (-not [W2]::IsWindowVisible($h)) { throw "FAIL 3: re-show broken" }
Write-Host "OK 3: toggle pipeline works after re-register"

# --- 4. revert to Alt+Q
Set-HotkeyViaUi $proc.Id "Alt+Q"
$json = Get-SettingsJson
if ($json -notmatch '"Hotkey":\s*"Alt(?:\+|\\u002B)Q"') { throw "FAIL 4: revert failed: $json" }
Write-Host "OK 4: hotkey reverted to Alt+Q"

# --- 4b. disable hotkey (empty save)
Set-HotkeyViaUi $proc.Id ""
$json = Get-SettingsJson
if ($json -notmatch '"Hotkey":\s*""') { throw "FAIL 4b: disable failed: $json" }
$trace = Get-Content (Join-Path $env:APPDATA "JieDraw\trace.log") -Raw
if ($trace -notmatch "hotkey disabled") { throw "FAIL 4b: trace missing 'hotkey disabled'" }
Write-Host "OK 4b: hotkey disabled (empty save)"

# --- 4c. re-enable Alt+Q
Set-HotkeyViaUi $proc.Id "Alt+Q"
$json = Get-SettingsJson
if ($json -notmatch '"Hotkey":\s*"Alt(?:\+|\\u002B)Q"') { throw "FAIL 4c: re-enable failed: $json" }
Write-Host "OK 4c: hotkey re-enabled (Alt+Q)"

# --- 5. close button X exits the app
Start-Process powershell -ArgumentList @(
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\invoke-btn.ps1",
  "-ProcId", $proc.Id, "-ButtonId", "btnClose") -WindowStyle Hidden
$exited = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 250
  if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { $exited = $true; break }
}
if (-not $exited) { throw "FAIL 5: X button did not exit the app" }
Write-Host "OK 5: X button exited app cleanly"

# --- 6. relaunch resident for the user
Start-Process -FilePath $Exe
Start-Sleep -Milliseconds 1500
if ((Get-Process JieDraw -ErrorAction SilentlyContinue) -eq $null) { throw "FAIL 6: relaunch failed" }
Write-Host "OK 6: app relaunched resident"

Write-Host "SETTINGS/CLOSE ALL PASS"
