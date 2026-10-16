# Qpen installer (run by install.cmd)
# Copies Qpen.ps1 next to this file to %LOCALAPPDATA%\Qpen, registers autostart, and starts Qpen.
# If Qpen is already running it is stopped and replaced. Qpen shows an "installed" notification on start.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'Qpen'
$ps1 = Join-Path $dir 'Qpen.ps1'

# Stop a running copy so it can be replaced
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\Qpen\Qpen.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Qpen.ps1') $ps1 -Force
Unblock-File $ps1
New-Item -ItemType File -Force (Join-Path $dir 'installed.flag') | Out-Null

# Qpen.ps1 creates its autostart shortcut and relaunches itself detached from this console
# (WaitForExit, not -Wait: -Wait would also wait for the detached Qpen process)
(Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"").WaitForExit()
