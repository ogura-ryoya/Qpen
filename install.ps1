# Qpen インストーラー（install.cmd から実行される）
# このファイルと同じフォルダの Qpen.ps1 を %LOCALAPPDATA%\Qpen にコピーし、自動起動を登録して起動する。
# Qpen が動いている場合は止めてから上書きする。完了の通知は Qpen 本体が起動時に出す。
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'Qpen'
$ps1 = Join-Path $dir 'Qpen.ps1'

# 動いている Qpen を止める（上書きするため）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\Qpen\Qpen.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Qpen.ps1') $ps1 -Force
Unblock-File $ps1
New-Item -ItemType File -Force (Join-Path $dir 'installed.flag') | Out-Null

# Qpen.ps1 は自動起動のショートカットを作り、このコンソールから切り離して自分を起動し直す
# （-Wait ではなく WaitForExit を使う。-Wait だと切り離した Qpen の終了まで待ってしまう）
(Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"").WaitForExit()
