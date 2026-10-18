# Qpen インストーラー（「Qpen をインストール」ショートカットから実行される）
# このファイルと同じフォルダの Qpen.ps1 を %LOCALAPPDATA%\Qpen にコピーし、自動起動を登録して起動する。
# Qpen が動いている場合は止めてから上書きする。成功したときの通知は Qpen 本体が起動時に出す。
# 画面を出さずに動くので、失敗したときはメッセージを表示して知らせる。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# 画面を出さずに動いているので、ほかのウィンドウの裏に隠れないよう、最前面の見えない親ウィンドウを付けて表示する
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
        throw "Qpen.ps1 が見つかりません。ダウンロードした ZIP を展開してから、展開したフォルダの中で実行してください。"
    }
    $dir = Join-Path $env:LOCALAPPDATA 'Qpen'
    $ps1 = Join-Path $dir 'Qpen.ps1'

    # 動いている Qpen を止め、完全に終わるまで待つ（上書きするため。どこから起動したものでも止める）
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

    # Qpen は起動できると QpenReady を知らせてくる。最大 60 秒待って、来なければ失敗として知らせる
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\QpenReady')
    [void]$ready.Reset()

    # Qpen.ps1 は自動起動のショートカットを作り、このプロセスから切り離して自分を起動し直す
    # （-Wait ではなく WaitForExit を使う。-Wait だと切り離した Qpen の終了まで待ってしまう）
    (Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"").WaitForExit()

    if (-not $ready.WaitOne(60000)) {
        throw 'Qpen を起動できませんでした。PC を再起動してから、もう一度インストールしてください。'
    }
} catch {
    Show-Error "インストールに失敗しました。`n`n$($_.Exception.Message)"
    exit 1
}
