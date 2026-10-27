# 自動のテスト。ファイルの決まり、更新の確かめ方、ログの書き方を試す。
# 更新の確かめ方とログは、本体から $checkUpdate と Write-Log を取り出し、ネットの代わりに手元の文字を返して動かす。
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1（失敗があれば終了コード 1）
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$main = (Get-ChildItem $root -Filter *.ps1 | Where-Object Name -notin 'install.ps1', 'setup.ps1' | Select-Object -First 1).FullName
$script:failures = 0

function Check($name, [scriptblock]$test) {
    try { $ok = & $test } catch { $ok = $false; $name += " ($_)" }
    if ($ok) { Write-Host "OK $name" } else { Write-Host "NG $name"; $script:failures++ }
}

# ---- ファイルの決まり ----
# *.ps1 は BOM 付き（無いと日本語が化ける）。改行は LF でも CRLF でも動く
foreach ($f in Get-ChildItem $root, $PSScriptRoot, (Join-Path $root 'tools'), (Join-Path $root '.github\scripts') -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.ps1') {
    $name = $f.FullName.Substring($root.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Check "$($name): UTF-8 BOM 付き" { $bom }
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    Check "$($name): 構文エラーが無い" { $errors.Count -eq 0 }
}
Check '$Version の書き方' { [IO.File]::ReadAllText($main) -match "(?m)^\`$Version\s*=\s*'\d+\.\d+\.\d+'" }

$ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)

# C# の部分がコンパイルできる（別のプロセスで。同じ型を二度読み込めないため）
$cs = $ast.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '(?m)^using System;' }, $true).Value
Check 'C# の部分がコンパイルできる' {
    $csFile = Join-Path $env:TEMP "test-cs-$PID.cs"  # コマンドの長さに収まらないのでファイルで渡す
    [IO.File]::WriteAllText($csFile, $cs)
    try {
        $out = powershell -NoProfile -Command {
            param($path)
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition ([IO.File]::ReadAllText($path))
            'compiled'
        } -args $csFile 2>&1
    } finally { Remove-Item $csFile -ErrorAction SilentlyContinue }
    "$out" -match 'compiled'
}
# $X = $X のような、自分を入れるだけの代入が無い(置きかえの間違いで中身が空になり、通知などで止まる)
Check '自分を入れるだけの代入が無い' {
    $self = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $n.Right.Extent.Text }, $true))
    if ($self.Count) { throw "$($self[0].Extent.StartLineNumber) 行目: $($self[0].Extent.Text)" }
    $true
}
# メニューやタイマーの中のエラーは trap に届かないので、受け手が要る
Check 'メニューやタイマーのエラーを受ける' { [IO.File]::ReadAllText($main) -match 'add_ThreadException' }

# 起動の知らせの待ち方: 知らせが来たか、先に終わったか、来なかったか
$waitReady = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-Ready' }, $true).Extent.Text
. ([scriptblock]::Create($waitReady))
$event = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset)
$running = [pscustomobject]@{ HasExited = $false }
$exited = [pscustomobject]@{ HasExited = $true }
Check '起動の知らせが来たら ready' { [void]$event.Set(); (Wait-Ready $event $running 2000) -eq 'ready' }
Check '知らせを出して終わったら ready' { (Wait-Ready $event $exited 2000) -eq 'ready' }
[void]$event.Reset()
Check '知らせの前に終わったら待たずに exited' { $t = Get-Date; ((Wait-Ready $event $exited 10000) -eq 'exited') -and ((Get-Date) - $t).TotalSeconds -lt 2 }
Check '来ないまま時間が過ぎたら timeout' { (Wait-Ready $event $running 1000) -eq 'timeout' }
$event.Dispose()

$checkUpdate = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$checkUpdate' }, $true).Right.Expression.ScriptBlock.GetScriptBlock()
$writeLog = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-Log' }, $true).Extent.Text

# ---- 更新の確かめ方 ----
# $served が配っている版の中身。$null なら通信の失敗にする
$script:served = $null
function Invoke-RestMethod { if ($null -eq $script:served) { throw '通信の失敗' }; [pscustomobject]@{ tag_name = 'v0.0.0' } }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
    if ($null -eq $script:served) { throw '通信の失敗' }
    [IO.File]::WriteAllText($OutFile, $script:served, (New-Object Text.UTF8Encoding $true))
}
function Serve($version) { $script:served = "`$Version = '$version'`r`nWrite-Host 'テスト'`r`n" }
# 見つかった版を返し、無ければ 空。1つ目の引数（リポジトリ名）はまねた通信では使わない
function Find-Update($current, $skip = '', $manual = $false) {
    $r = & $checkUpdate 'test' $current $skip $manual
    if ($r) { $r.Version } else { '' }
}

Serve '1.6.0'; Check '新しい版を受け取る' { (Find-Update '1.5.0') -eq '1.6.0' }
Serve '1.5.0'; Check '同じ版は受け取らない' { (Find-Update '1.5.0') -eq '' }
Serve '1.4.0'; Check '古い版は受け取らない' { (Find-Update '1.5.0') -eq '' }
Serve '1.10.0'; Check '版を数として比べる（1.10.0 > 1.9.0）' { (Find-Update '1.9.0') -eq '1.10.0' }
Serve '1.6.0'; Check '飛ばす版は自動では受け取らない' { (Find-Update '1.5.0' '1.6.0') -eq '' }
Serve '1.6.0'; Check '飛ばす版も手動なら受け取る' { (Find-Update '1.5.0' '1.6.0' $true) -eq '1.6.0' }
$script:served = "`$Version = '9.0.0'`r`nif ( {`r`n"; Check '構文の壊れた版はエラーにする' { try { Find-Update '1.5.0'; $false } catch { $true } }
$script:served = "Write-Host 'テスト'`r`n"; Check '版の書かれていないものはエラーにする' { try { Find-Update '1.5.0'; $false } catch { $true } }
$script:served = $null; Check '通信の失敗はエラーにする' { try { Find-Update '1.5.0'; $false } catch { $true } }
# 本体そのもの（版だけ上げたもの）を配ったとき、版を読み取れる（本体の $Version の書き方と、更新の確かめ方がずれていない）
$script:served = [IO.File]::ReadAllText($main) -replace "(?m)^(\`$Version\s*=\s*)'[^']*'", "`${1}'99.0.0'"
Check '本体を配ったとき版を読み取れる' { (Find-Update '1.0.0') -eq '99.0.0' }
Serve '1.6.0'; Check '受け取った版は中身で返し、TEMP に残さない' {
    $r = & $checkUpdate 'test' '1.5.0' '' $false
    $r.Text -match "'1\.6\.0'" -and -not (Get-ChildItem $env:TEMP -Filter '*-update.ps1' | Where-Object LastWriteTime -gt (Get-Date).AddSeconds(-10))
}

# ---- ログ ----
$appDir = Join-Path $env:TEMP "test-log-$PID"
New-Item -ItemType Directory -Force $appDir | Out-Null
$logFile = Join-Path $appDir 'log.txt'
. ([scriptblock]::Create($writeLog))
try {
    Write-Log "1行目`r`n2行目"
    Check 'ログは改行を | にして1行で書く' { (Get-Content $logFile -Encoding UTF8 -Tail 1) -match "\[$PID\] 1行目 \| 2行目$" }
    [IO.File]::WriteAllText($logFile, ('x' * 110KB))
    Write-Log '回したあと'
    Check 'ログは 100KB を超えたら log.old.txt に回す' { (Test-Path (Join-Path $appDir 'log.old.txt')) -and (Get-Item $logFile).Length -lt 1KB }
} finally { Remove-Item $appDir -Recurse -Force }
# アンインストールで消したあとに書いても、フォルダを作り直さない
Write-Log 'アンインストールのあと'
Check 'アンインストールのあとログでフォルダを作り直さない' { -not (Test-Path $appDir) }

# ---- 自動起動の切り替え ----
# 本体から関数を取り出し、一時フォルダの印とショートカットで動かす（ショートカットを作る処理は偽物）
foreach ($fn in 'Test-Autostart', 'Set-Autostart', 'Restore-Autostart') {
    . ([scriptblock]::Create($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true).Extent.Text))
}
$autoDir = Join-Path $env:TEMP "test-autostart-$PID"
$noAutostartFlag = Join-Path $autoDir 'no-autostart.flag'
$startupLnk = Join-Path $autoDir 'Qpen.lnk'
$script:shortcutFails = $false
function New-Shortcut($path) { if ($script:shortcutFails) { throw '作れない' }; [IO.File]::WriteAllText($path, 'lnk') }
function Write-Log($text) {}
# 印もショートカットも無い状態から、$on の状態にする
function Reset-Autostart($on) {
    Remove-Item $autoDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $autoDir | Out-Null
    if ($on) { [IO.File]::WriteAllText($startupLnk, 'lnk') } else { [IO.File]::WriteAllText($noAutostartFlag, '') }
    $script:shortcutFails = $false
}
function Get-AutostartState { "flag=$(Test-Path $noAutostartFlag -PathType Leaf) lnk=$(Test-Path $startupLnk)" }
try {
    Reset-Autostart $true
    Check '印が無ければ自動起動はオン' { Test-Autostart }
    Check 'オフにすると印ができてショートカットが消える' { ($null -eq (Set-Autostart $false)) -and (Get-AutostartState) -eq 'flag=True lnk=False' -and -not (Test-Autostart) }
    Check 'オンにすると印が消えてショートカットができる' { ($null -eq (Set-Autostart $true)) -and (Get-AutostartState) -eq 'flag=False lnk=True' -and (Test-Autostart) }
    Reset-Autostart $true; Remove-Item $startupLnk
    Check 'オフにするときショートカットが元から無くても成功' { ($null -eq (Set-Autostart $false)) -and (Get-AutostartState) -eq 'flag=True lnk=False' }
    Reset-Autostart $true; Remove-Item $startupLnk
    $savedLnk = $startupLnk; $startupLnk = Join-Path $autoDir '無いフォルダ\Qpen.lnk'
    try {
        Check 'オフにするときスタートアップのフォルダが無くても成功' { ($null -eq (Set-Autostart $false)) -and (Test-Path $noAutostartFlag -PathType Leaf) }
        Check '起動時、オフでスタートアップのフォルダが無くても止まらない' { Restore-Autostart }
    } finally { $startupLnk = $savedLnk }
    Reset-Autostart $false; Remove-Item $noAutostartFlag
    Check 'オンにするとき印が元から無くても成功' { ($null -eq (Set-Autostart $true)) -and (Get-AutostartState) -eq 'flag=False lnk=True' }

    Reset-Autostart $true; New-Item -ItemType Directory $noAutostartFlag | Out-Null
    Check 'オフで印を書けなければ失敗を返し、何も変えない' { (Set-Autostart $false) -and (Test-Path $startupLnk) -and -not (Test-Path $noAutostartFlag -PathType Leaf) }
    Reset-Autostart $true
    $lock = [IO.File]::Open($startupLnk, 'Open', 'Read', 'None')
    try { Check 'オフでショートカットを消せなければ印を消して元のオンに戻す' { (Set-Autostart $false) -and (Get-AutostartState) -eq 'flag=False lnk=True' } } finally { $lock.Dispose() }
    Reset-Autostart $false
    $lock = [IO.File]::Open($noAutostartFlag, 'Open', 'Read', 'None')
    try { Check 'オンで印を消せなければ失敗を返し、何も変えない' { (Set-Autostart $true) -and (Get-AutostartState) -eq 'flag=True lnk=False' } } finally { $lock.Dispose() }
    Reset-Autostart $false; $script:shortcutFails = $true
    Check 'オンでショートカットを作れなければ印を戻して元のオフに戻す' { (Set-Autostart $true) -and (Get-AutostartState) -eq 'flag=True lnk=False' }

    Reset-Autostart $false; [IO.File]::WriteAllText($startupLnk, 'lnk')
    Check '起動時、オフならショートカットを作らず、残りを消す' { (Restore-Autostart) -and (Get-AutostartState) -eq 'flag=True lnk=False' }
    Reset-Autostart $true; Remove-Item $startupLnk
    Check '起動時、オンならショートカットを作る' { (Restore-Autostart) -and (Get-AutostartState) -eq 'flag=False lnk=True' }
    Reset-Autostart $true; $script:shortcutFails = $true
    Check '起動時、オンで作れなければ失敗を返す' { -not (Restore-Autostart) }
} finally { Remove-Item $autoDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---- メニュー ----
$mainText = [IO.File]::ReadAllText($main, [Text.Encoding]::UTF8)
Check 'メニューに更新履歴を見る・サインイン時に起動・終了がある' { $mainText -match "'更新履歴を見る'" -and $mainText -match "'サインイン時に起動'" -and $mainText -match "'終了'" }
Check 'メニューに GitHub を開く・終了（自動起動も解除）が無い' { $mainText -notmatch 'GitHub を開く' -and $mainText -notmatch '終了（自動起動も解除）' }
Check '更新履歴を見るは Releases を開く' { $mainText -match 'Start-Process "https://github\.com/\$Repo/releases"' }

# ---- インストール（install.ps1） ----
$installText = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'), [Text.Encoding]::UTF8)
Check 'install.ps1 は自動起動の設定を消さない' { $installText -notmatch 'no-autostart' }
Check 'install.ps1 は Qpen-setup.cmd の話をし、ZIP・「Qpen をインストール」の話が無い' {
    $installText -match 'Qpen-setup\.cmd' -and $installText -notmatch 'ZIP' -and $installText -notmatch '「Qpen をインストール」'
}
Check 'install.ps1 は自分で知らせたら exit 3' { $installText -match '(?m)^\s*exit 3\b' -and $installText -notmatch '(?m)^\s*exit 1\b' }
Check 'install.ps1 は Qpen をインストール先を作業フォルダにして起動する' { $installText -match 'Start-Process[^\r\n]*-WorkingDirectory \$dir' }
Check 'run.ps1 は本体として Qpen.ps1 を選ぶ' { (Split-Path $main -Leaf) -eq 'Qpen.ps1' }

# ---- インストーラー（build-setup.ps1 で作る Qpen-setup.cmd） ----
$buildSetup = Join-Path $root '.github\scripts\build-setup.ps1'
$setupPath = Join-Path $root 'setup.ps1'
$setupWork = Join-Path $env:TEMP "test-setup-$PID"
$setupLog = Join-Path $env:TEMP 'Qpen-setup.log'
function Get-SetupTemp { @(Get-ChildItem $env:TEMP -Directory -Filter 'Qpen-setup-*' -ErrorAction SilentlyContinue) }
# にせの install.ps1 を埋め込んで作る。にせは、動いた場所・隣の Qpen.ps1 の有無を $mark に書き、$code で終わる
function New-FakeSetup($out, $code) {
    $mark = Join-Path $setupWork "mark-$code.txt"
    $fake = Join-Path $setupWork "fake-install-$code.ps1"
    [IO.File]::WriteAllText($fake, "[IO.File]::WriteAllText('$mark', `"`$PSScriptRoot|`$(Test-Path (Join-Path `$PSScriptRoot 'Qpen.ps1'))`")`r`nexit $code`r`n", (New-Object Text.UTF8Encoding $true))
    New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
    & $buildSetup -Setup $setupPath -Install $fake -Main $main -Out $out
    $mark
}
# SETUP_WAIT=1・SETUP_NO_UI=1 で cmd から動かし、終了コードと、その間に足されたログを返す
function Invoke-Setup($path) {
    $before = if (Test-Path $setupLog) { (Get-Item $setupLog).Length } else { 0 }
    $saved = $env:SETUP_WAIT, $env:SETUP_NO_UI
    $env:SETUP_WAIT = '1'; $env:SETUP_NO_UI = '1'
    try {
        # ダブルクリックと同じく、置いた場所を作業フォルダにして動かす
        $p = Start-Process cmd.exe -ArgumentList "/c `"`"$path`"`"" -PassThru -WindowStyle Hidden -WorkingDirectory (Split-Path $path)
        if (-not $p.WaitForExit(120000)) { $p.Kill(); $code = -999 } else { $code = $p.ExitCode }
    } finally { $env:SETUP_WAIT, $env:SETUP_NO_UI = $saved }
    $log = ''
    if (Test-Path $setupLog) {
        $bytes = [IO.File]::ReadAllBytes($setupLog)
        $log = [Text.Encoding]::UTF8.GetString($bytes, $before, $bytes.Length - $before)
    }
    [pscustomobject]@{ Code = $code; Log = $log }
}
New-Item -ItemType Directory -Force $setupWork | Out-Null
try {
    # 本物の install.ps1・Qpen.ps1 を埋め込んだもの（動かさずに中身だけ見る）
    $realCmd = Join-Path $setupWork 'real\Qpen-setup.cmd'
    New-Item -ItemType Directory -Force (Split-Path $realCmd) | Out-Null
    & $buildSetup -Setup $setupPath -Install (Join-Path $root 'install.ps1') -Main $main -Out $realCmd
    $cmdBytes = [IO.File]::ReadAllBytes($realCmd)
    $cmdText = [Text.Encoding]::ASCII.GetString($cmdBytes)
    $batch = @($cmdText -split "`r`n" | Where-Object { $_ -and $_ -notmatch '^:: payload ' })
    Check 'インストーラーは ASCII だけ・改行 CRLF' { -not ($cmdBytes | Where-Object { $_ -gt 0x7F }) -and $cmdText -notmatch "[^`r]`n" }
    Check 'インストーラーのバッチ: 場所は環境変数に入れるだけ、遅延展開を切る、ふだんは start と conhost --headless、SETUP_WAIT のときだけ直接' {
        $f0 = @($batch | Where-Object { $_ -match '%~f0' })
        $f0.Count -eq 1 -and $f0[0] -ceq 'set "QPEN_SETUP_FILE=%~f0"' -and ($batch -contains 'setlocal DisableDelayedExpansion') -and
            @($batch | Where-Object { $_ -match '^start "" "%SystemRoot%\\System32\\conhost\.exe" --headless powershell\.exe ' }).Count -eq 1 -and
            @($batch | Where-Object { $_ -match '^if "%SETUP_WAIT%"=="1" powershell\.exe ' }).Count -eq 1
    }
    Check 'インストーラー: バッチと同じ取り出し方で、setup.ps1 とバイト単位で同じ' {
        $rx = [regex]::Match(@($batch | Where-Object { $_ -match '^start ' })[0], "Match\(\`$t,'([^']+)'\)").Groups[1].Value
        $m = [regex]::Match($cmdText, $rx)
        $rx -ne '' -and $m.Success -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($setupPath)) -ceq $m.Groups[1].Value
    }
    $setupAst = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$null, [ref]$null)
    Check 'インストーラー: Expand-Payload で書き出した install.ps1・Qpen.ps1 が元とバイト単位で同じ' {
        . ([scriptblock]::Create($setupAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Expand-Payload' }, $true).Extent.Text))
        $x = Join-Path $setupWork 'expand'; New-Item -ItemType Directory -Force $x | Out-Null
        Expand-Payload $cmdText $x
        -not @('install.ps1', 'Qpen.ps1' | Where-Object {
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $x $_))) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $_)))
        }).Count
    }

    # にせの install.ps1 で動かす（変わった文字を含む場所に置く）
    $odd = Join-Path $setupWork "s1 テスト 'a&b' 100% (x)\Qpen-setup (1).cmd"
    $mark0 = New-FakeSetup $odd 0
    $tempBefore = (Get-SetupTemp).Count
    $r0 = Invoke-Setup $odd
    Check 'インストーラー: 変わった文字の場所でも、一時フォルダの中で隣に Qpen.ps1 がある状態で install.ps1 を動かし、0 を返す' {
        $m = if (Test-Path $mark0) { [IO.File]::ReadAllText($mark0) } else { '' }
        $r0.Code -eq 0 -and $m -match '\\Qpen-setup-[^\\|]+\|True$'
    }
    Check 'インストーラー: 終わったら一時フォルダが残らない' { (Get-SetupTemp).Count -le $tempBefore }
    $cmd3 = Join-Path $setupWork 's3\Qpen-setup.cmd'; [void](New-FakeSetup $cmd3 3)
    $r3 = Invoke-Setup $cmd3
    Check 'インストーラー: install.ps1 が自分で知らせた（3）ときは重ねて知らせない' { $r3.Code -eq 3 -and $r3.Log -notmatch '画面の知らせ' -and (Get-SetupTemp).Count -le $tempBefore }
    $cmd1 = Join-Path $setupWork 's1b\Qpen-setup.cmd'; [void](New-FakeSetup $cmd1 1)
    $r1 = Invoke-Setup $cmd1
    Check 'インストーラー: install.ps1 が知らせずに止まった（1）ときは知らせる' { $r1.Code -eq 1 -and $r1.Log -match '画面の知らせ（省略）: インストールに失敗した' -and (Get-SetupTemp).Count -le $tempBefore }
    # 埋め込みが壊れている → install.ps1 の前で失敗し、知らせる
    $cmdX = Join-Path $setupWork 'sx\Qpen-setup.cmd'; $markX = New-FakeSetup $cmdX 5
    [IO.File]::WriteAllText($cmdX, [regex]::Replace([IO.File]::ReadAllText($cmdX), '(?m)^(:: payload install\.ps1 )\S+', '${1}!!!'), [Text.Encoding]::ASCII)
    $rX = Invoke-Setup $cmdX
    Check 'インストーラー: 取り出せないときは、install.ps1 を動かさず 1 で終わり、始められなかったと知らせる' {
        $rX.Code -eq 1 -and $rX.Log -match '画面の知らせ（省略）: インストールを始められなかった' -and -not (Test-Path $markX) -and (Get-SetupTemp).Count -le $tempBefore
    }
    # 続けて開いたとき（テストが排他を握る）
    $cmdB = Join-Path $setupWork 'sb\Qpen-setup.cmd'; $markB = New-FakeSetup $cmdB 7
    $hold = New-Object Threading.Mutex($false, 'Local\QpenSetup')
    if (-not $hold.WaitOne(0)) { throw '排他を取れない' }
    try { $rB = Invoke-Setup $cmdB } finally { $hold.ReleaseMutex(); $hold.Dispose() }
    Check 'インストーラー: 続けて開いたときは、もう進んでいると知らせて、何もせずに 0 で終わる' { $rB.Code -eq 0 -and $rB.Log -match 'もう進んでいる' -and -not (Test-Path $markB) }
} catch { Write-Host "NG インストーラーのテストが途中で止まった ($_)"; $script:failures++ } finally { Remove-Item $setupWork -Recurse -Force -ErrorAction SilentlyContinue }

# ---- リリースの仕組み ----
$workflow = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\release.yml'), [Text.Encoding]::UTF8)
$cr = [IO.File]::ReadAllText((Join-Path $root '.github\scripts\create-release.ps1'), [Text.Encoding]::UTF8)
Check 'リポジトリに .lnk が無い' { -not (Get-ChildItem $root -Filter *.lnk) }
Check 'release.yml: 対象に *.lnk が無く、setup.ps1 がある' { $workflow -notmatch '\*\.lnk' -and $workflow -match '(?m)^\s+- setup\.ps1\s*$' }
Check 'create-release.ps1: リリースの前に build-setup.ps1 で作り、gh release create に Qpen-setup.cmd を渡す' {
    $b = $cr.IndexOf('build-setup.ps1'); $c = $cr.IndexOf('gh release create')
    $b -ge 0 -and $c -gt $b -and $cr -match 'gh release create [^\r\n]*\$setupFile' -and $cr -match "Qpen-setup\.cmd"
}
Check 'create-release.ps1: 添付が付いていなければ付け直す（リリース済み・下書き・新規のどれでも）' {
    $cr -match 'function Add-SetupAsset' -and $cr -match 'gh release upload \$tag \$setupFile --clobber' -and
        $cr -match "\`$_\.name -eq 'Qpen-setup\.cmd' -and \`$_\.state -eq 'uploaded'" -and ([regex]::Matches($cr, '(?m)^\s*Add-SetupAsset\s*$')).Count -ge 3
}
Check 'create-release.ps1: 下書きは添付を付けてから公開し、別のコミットの下書きは作り直す' {
    $cr.IndexOf('gh release edit $tag --draft=false --latest') -gt $cr.IndexOf('Add-SetupAsset', $cr.IndexOf('if ($release) {')) -and $cr -match 'targetCommitish' -and $cr -match 'gh release delete \$tag --yes'
}
Check 'create-release.ps1: リリース済みの判定で下書きを数えず、上げ忘れの対象に setup.ps1 と build-setup.ps1 があり *.lnk が無い' {
    $cr -match 'isDraft' -and $cr -match "git diff --name-only \`$tag HEAD -- 'Qpen\.ps1' 'install\.ps1' 'setup\.ps1' '\.github/scripts/build-setup\.ps1'" -and $cr -notmatch '\*\.lnk'
}


# ---- ツールごとのテスト（tests\<本体の名前>.ps1 があれば読み込む。$main・$ast・Check を使える） ----
$own = Join-Path $PSScriptRoot (Split-Path $main -Leaf)
if (Test-Path $own) { . $own }

Write-Host "`n失敗 $script:failures 件"
exit [int]($script:failures -gt 0)
