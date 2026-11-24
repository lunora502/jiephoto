# Watch for desktop unlock, then run the E2E test once (ASCII only)
# Unlock signal: LockApp.exe (lock screen UI) terminates after unlock.
param(
  [string]$OutFile = "$PSScriptRoot\..\test-out\watch-result.txt"
)
$ErrorActionPreference = "Continue"
$deadline = (Get-Date).AddHours(8)

Set-Content -Path $OutFile -Value ("watch started " + (Get-Date))

while ((Get-Date) -lt $deadline) {
  $lockApp = Get-Process LockApp -ErrorAction SilentlyContinue
  if ($lockApp -eq $null) {
    Add-Content -Path $OutFile -Value ("unlock detected " + (Get-Date))
    Start-Sleep -Seconds 12   # let the session settle
    $p = Start-Process powershell -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\e2e-test.ps1"
    ) -Wait -PassThru -WindowStyle Hidden
    Add-Content -Path $OutFile -Value ("e2e exit code: " + $p.ExitCode)
    Add-Content -Path $OutFile -Value ("finished " + (Get-Date))
    exit $p.ExitCode
  }
  Start-Sleep -Seconds 20
}
Add-Content -Path $OutFile -Value "WATCH TIMEOUT: never unlocked within 8h"
exit 1
