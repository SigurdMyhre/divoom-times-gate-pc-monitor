# Boots the "divoom" Android emulator with packet capture on, so the Divoom app's LAN traffic to the
# Times Gate can be inspected afterwards (see analyse-capture.ps1).
#   .\capture-app-traffic.ps1            start emulator + capture to E:\AndroidSdk\capture\<timestamp>.pcap
# Requires the Android SDK at E:\AndroidSdk with the "divoom" AVD (see README "Reverse engineering the app").
param([string]$Sdk = 'E:\AndroidSdk', [string]$Avd = 'divoom')

$env:ANDROID_HOME = $Sdk; $env:ANDROID_SDK_ROOT = $Sdk
$dir = Join-Path $Sdk 'capture'; New-Item -ItemType Directory -Force $dir | Out-Null
$pcap = Join-Path $dir ("{0:yyyyMMdd-HHmmss}.pcap" -f (Get-Date))
"Capturing to $pcap"
# -tcpdump records everything the virtual phone sends/receives; -netdelay/-netspeed none = no throttling.
& "$Sdk\emulator\emulator.exe" -avd $Avd -tcpdump $pcap -netdelay none -netspeed full -no-snapshot-load -gpu auto
