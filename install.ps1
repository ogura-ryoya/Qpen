# Qpen インストーラー（「Qpen をインストール」から実行される）
# 隣の Qpen.ps1 を %LOCALAPPDATA%\Qpen にコピーして起動する。画面を出さずに動くので、失敗はメッセージで知らせる
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# 裏に隠れないよう、最前面の見えないウィンドウを親にして表示する
function Show-Error($message) {
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    $owner.Show()
    $owner.Activate()
    [void][System.Windows.Forms.MessageBox]::Show($owner, $message, 'Qpen のインストール',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    $owner.Dispose()
}

try {
    $source = Join-Path $PSScriptRoot 'Qpen.ps1'
    if (-not (Test-Path $source)) {
        throw "Qpen.ps1 が見つからない。ダウンロードした ZIP を展開し、展開したフォルダの中で実行する。"
    }
    $dir = Join-Path $env:LOCALAPPDATA 'Qpen'
    $ps1 = Join-Path $dir 'Qpen.ps1'

    # 動いている Qpen を止めてから上書きする
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*\Qpen.ps1*' })
    foreach ($p in $running) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $source $ps1 -Force
    Unblock-File $ps1
    New-Item -ItemType File -Force (Join-Path $dir 'installed.flag') | Out-Null

    # 起動の知らせ（QpenReady）を 60 秒待つ。-Wait は起動した Qpen の終了まで待ってしまうので WaitForExit を使う
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\QpenReady')
    [void]$ready.Reset()
    (Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"").WaitForExit()
    if (-not $ready.WaitOne(60000)) {
        throw 'Qpen を起動できなかった。PC を再起動してから、もう一度インストールする。'
    }
} catch {
    try { Add-Content (Join-Path $env:LOCALAPPDATA 'Qpen\log.txt') "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] インストールに失敗した: $_" -Encoding UTF8 } catch {}
    Show-Error "インストールに失敗した。`n`n$($_.Exception.Message)"
    exit 1
}
