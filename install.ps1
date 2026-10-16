# Qpen installer
#   irm https://raw.githubusercontent.com/ogura-ryoya/Qpen/main/install.ps1 | iex
# Installs to %LOCALAPPDATA%\Qpen, registers autostart, and starts Qpen.
# Qpen itself shows a "installed" notification on first start (no console output needed).
& {
    $ErrorActionPreference = 'Stop'
    $repo = 'https://raw.githubusercontent.com/ogura-ryoya/Qpen/main'
    $dir = Join-Path $env:LOCALAPPDATA 'Qpen'
    $ps1 = Join-Path $dir 'Qpen.ps1'

    # Stop a running copy so it can be replaced
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*\Qpen\Qpen.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

    New-Item -ItemType Directory -Force $dir | Out-Null
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Qpen.ps1' }
    if ($local -and (Test-Path $local)) {
        Copy-Item $local $ps1 -Force
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "$repo/Qpen.ps1" -OutFile $ps1 -UseBasicParsing
    }
    Unblock-File $ps1
    New-Item -ItemType File -Force (Join-Path $dir 'installed.flag') | Out-Null

    # Qpen.ps1 creates its autostart shortcut and relaunches itself detached from this console
    # (WaitForExit, not -Wait: -Wait would also wait for the detached Qpen process)
    (Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"").WaitForExit()
}
