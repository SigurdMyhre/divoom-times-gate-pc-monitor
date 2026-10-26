# Registers two scheduled tasks that run at your logon:
#   "Divoom LHM"   - LibreHardwareMonitor, elevated (CPU temperature needs admin), no UAC prompt
#   "Divoom pcmon" - pcmon.ps1 in a hidden window, 20 s later
# Must itself run elevated (registering a highest-privilege task requires admin).
#   .\install-autostart.ps1              install (or re-install) and start pcmon now
#   .\install-autostart.ps1 -Uninstall   remove both tasks
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$names = 'Divoom LHM', 'Divoom pcmon'
foreach ($n in $names) { if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $n -Confirm:$false } }
if ($Uninstall) { 'Removed.'; return }

$lhm = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter LibreHardwareMonitor.exe | Select-Object -First 1 -ExpandProperty FullName
if (-not $lhm) { throw 'LibreHardwareMonitor.exe not found under the winget packages folder.' }
$pcmon = Join-Path $PSScriptRoot 'pcmon.ps1'
$user = "$env:USERDOMAIN\$env:USERNAME"

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

$t1 = New-ScheduledTaskTrigger -AtLogOn -User $user
$a1 = New-ScheduledTaskAction -Execute $lhm -WorkingDirectory (Split-Path $lhm)
Register-ScheduledTask -TaskName $names[0] -Action $a1 -Trigger $t1 -Settings $settings -User $user -RunLevel Highest -Force | Out-Null

$t2 = New-ScheduledTaskTrigger -AtLogOn -User $user; $t2.Delay = 'PT20S'
$a2 = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $PSScriptRoot `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$pcmon`""
# S4U = "run whether user is logged on or not" without a stored password: the task gets no desktop
# session, so no console window can appear (Windows Terminal ignores -WindowStyle Hidden otherwise).
$p2 = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName $names[1] -Action $a2 -Trigger $t2 -Settings $settings -Principal $p2 -Force | Out-Null

if (-not (Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue)) { Start-ScheduledTask -TaskName $names[0] }
Start-ScheduledTask -TaskName $names[1]
"Installed. Tasks: $($names -join ', '). pcmon started in the background."
