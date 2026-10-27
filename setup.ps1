# Qpen のインストーラー（Qpen-setup.cmd）の中で最初に動く。.cmd に埋め込まれた install.ps1・Qpen.ps1 を一時フォルダに書き出し、install.ps1 を動かす
# .cmd の場所は環境変数 QPEN_SETUP_FILE で受け取る。画面を出さずに動くので、失敗は画面で知らせる（install.ps1 が自分で知らせたもの（終了コード 3）は重ねない）
# .cmd は .github/scripts/build-setup.ps1 が作る
$AppName = 'Qpen'
$ErrorActionPreference = 'Stop'
# 置いた場所のフォルダを握らないよう、作業フォルダをユーザーのフォルダにする
Set-Location $env:USERPROFILE
[Environment]::CurrentDirectory = $env:USERPROFILE
$tempLog = Join-Path $env:TEMP "$AppName-setup.log"
$reportedExitCode = 3  # install.ps1 が自分で失敗を知らせて終わったときの終了コード

function Write-Log($text) {
    try { Add-Content $tempLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] インストーラー: $($text -replace '\s*\r?\n\s*', ' | ')" -Encoding UTF8 } catch {}
}
# 裏に隠れないよう、最前面の見えないウィンドウを親にして表示する
function Show-Message($message, $icon = 'Error') {
    # 自動のテスト用: 環境変数 SETUP_NO_UI=1 なら画面を出さず、ログに残すだけにする
    if ($env:SETUP_NO_UI -eq '1') { Write-Log "画面の知らせ（省略）: $message"; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        # 画面の拡大率に合わせて、くっきり表示する。できなくても文字がぼやけるだけ
        try {
            Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace SetupBoot
            [void][SetupBoot.Dpi]::SetProcessDPIAware()
        } catch {}
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
        $owner.Show()
        $owner.Activate()
        [void][System.Windows.Forms.MessageBox]::Show($owner, $message, "$AppName のインストール", 'OK', $icon)
        $owner.Dispose()
    } catch { Write-Log "画面を出せなかった: $_" }
}
$hint = "理由は $tempLog と %LOCALAPPDATA%\$AppName\log.txt に残した。ウイルス対策ソフトに止められたときは、README の「インストール」にある別の入れ方を試す。"

# .cmd の「:: payload 名前 Base64」の行から、install.ps1 と Qpen.ps1 を元のバイト列のまま $dir に書き出す
function Expand-Payload($cmdText, $dir) {
    foreach ($name in 'install.ps1', 'Qpen.ps1') {
        $m = [regex]::Match($cmdText, "(?m)^:: payload $([regex]::Escape($name)) ([A-Za-z0-9+/=]+)\r?$")
        if (-not $m.Success) { throw "$name が埋め込まれていない" }
        [IO.File]::WriteAllBytes((Join-Path $dir $name), [Convert]::FromBase64String($m.Groups[1].Value))
    }
}

# 続けて開いたとき、2 つのインストールがぶつからないようにする（あとから開いた方は知らせて終わる）
$mutex = New-Object System.Threading.Mutex($false, "Local\$($AppName)Setup")
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Write-Log 'もう進んでいるので終わる'
    Show-Message "$AppName のインストールはもう進んでいる。通知が出るまで少し待つ。" 'Information'
    exit 0
}

$work = $null
$code = 1
try {
    try {
        $setupFile = $env:QPEN_SETUP_FILE
        if (-not $setupFile -or -not (Test-Path -LiteralPath $setupFile)) { throw "インストーラーのファイルが見つからない（$setupFile）" }
        $work = Join-Path $env:TEMP "$AppName-setup-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
        New-Item -ItemType Directory $work | Out-Null
        Expand-Payload ([IO.File]::ReadAllText($setupFile, [Text.Encoding]::ASCII)) $work
        Write-Log "取り出した 元=$setupFile 先=$work"
        # -Wait は install.ps1 が起動した常駐の Qpen まで待ってしまうので、install.ps1 のプロセスだけを待つ
        $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -WorkingDirectory $env:USERPROFILE `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $work 'install.ps1')`""
        $null = $p.Handle  # 終了コードを読めるよう控える
    } catch {
        Write-Log "失敗: $_ $($_.InvocationInfo.PositionMessage)"
        Show-Message "インストールを始められなかった。`n`n$($_.Exception.Message)`n`n$hint"
        exit 1
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    Write-Log "install.ps1 の終了コード=$code"
    # install.ps1 が自分で知らせられずに止まった（構文エラー、スクリプトの禁止など）
    if ($code -ne 0 -and $code -ne $reportedExitCode) {
        Show-Message "インストールに失敗した（終了コード $code）。会社の PC などで PowerShell スクリプトの実行が禁止されていると入れられない。`n`n$hint"
    }
} finally {
    if ($work) {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { Write-Log "一時フォルダを消せなかった: $_" }
    }
    $mutex.ReleaseMutex()
}
exit $code
