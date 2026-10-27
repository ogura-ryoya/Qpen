# インストーラー Qpen-setup.cmd を作る。リリースのとき（create-release.ps1）とテストで使う
# 先頭のバッチが、埋め込んだ setup.ps1 を取り出して PowerShell で動かす。setup.ps1 が install.ps1・Qpen.ps1 を取り出して入れる
# cmd が読めるよう、全体を ASCII（BOM なし）・改行 CRLF にする。日本語を含むファイルは Base64 で埋め込む
# 日本語を Windows PowerShell 5.1 で扱うため、このファイルは UTF-8 BOM 付きで保存する
param(
    [Parameter(Mandatory)][string]$Setup,
    [Parameter(Mandatory)][string]$Install,
    [Parameter(Mandatory)][string]$Main,
    [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'

# 埋め込んだ setup.ps1 を取り出して動かす（場所は環境変数で受け取り、コマンドの文字列には入れない）
# 取り出せないとき（壊れたファイル）は、空のまま動かさずに終了コード 1 で終わる（日本語の知らせは setup.ps1 の中でしか出せない）
$boot = '$t=[IO.File]::ReadAllText($env:QPEN_SETUP_FILE);$m=[regex]::Match($t,''(?m)^:: payload setup\.ps1 (\S+)'');if(-not $m.Success){exit 1};' +
    '& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value)).TrimStart([char]0xFEFF)))'
$ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$boot`""
$lines = @(
    '@echo off'
    'rem Qpen installer: double-click to install Qpen and start it. https://github.com/ogura-ryoya/Qpen'
    # 遅延展開が既定で有効な PC でも、場所の ! が崩れないようにする
    'setlocal DisableDelayedExpansion'
    'set "QPEN_SETUP_FILE=%~f0"'
    # テスト用: SETUP_WAIT=1 なら、終わるまで待って終了コードを返す（conhost は終了コードを返さないので通さない）
    # 同じ行の %errorlevel% は動かす前に展開されてしまうので、call で動かしたあとに展開する
    "if `"%SETUP_WAIT%`"==`"1`" $ps & call exit /b %%errorlevel%%"
    # ふだんは画面なしで起動し、待たずに閉じる
    "start `"`" `"%SystemRoot%\System32\conhost.exe`" --headless $ps"
    'exit /b 0'
)
foreach ($p in @(@('setup.ps1', $Setup), @('install.ps1', $Install), @('Qpen.ps1', $Main))) {
    $path = $ExecutionContext.SessionState.Path.GetResolvedProviderPathFromPSPath($p[1], [ref]$null)[0]
    $lines += ":: payload $($p[0]) $([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)))"
}
$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
[IO.File]::WriteAllText($outPath, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
