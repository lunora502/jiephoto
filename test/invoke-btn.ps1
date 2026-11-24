# Invoke a button inside JieDraw's main window from a separate process
# (used for buttons that open modal dialogs, which would block the caller).
param([int]$ProcId, [string]$ButtonId)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement
$pidCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcId)
$windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
foreach ($w in $windows) {
  if ($w.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $w.Current.Name -eq "JieDraw") {
    $idCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $ButtonId)
    $btn = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $idCond)
    if ($btn -ne $null) {
      ($btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
      exit 0
    }
  }
}
exit 1
