# リリース用（GitHub Actions から実行される）
# 環境変数 VERSION の版がまだリリースされていなければ、vX.Y.Z のタグとリリースを作る。
# リリースノートには README の「更新履歴」のこの版の項目を使う。
# 日本語のメッセージを Windows PowerShell 5.1 で正しく扱うため、このファイル自体も UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$tag = "v$env:VERSION"
$released = @(gh release list --limit 1000 --json tagName --jq '.[].tagName') -contains $tag
if ($LASTEXITCODE -ne 0) { throw 'リリースの一覧を取得できませんでした' }
if ($released) {
    Write-Host "$tag はリリース済みなので、何もしません"
    exit 0
}

$readme = [IO.File]::ReadAllText((Resolve-Path 'README.md').Path, [Text.Encoding]::UTF8)
$section = [regex]::Match($readme, "(?ms)^### $([regex]::Escape($env:VERSION))\s*$\r?\n(.*?)(?=^#{2,3} |\z)")
if (-not $section.Success) { throw "README の更新履歴に「### $env:VERSION」の項目がありません" }
$notesFile = Join-Path $env:RUNNER_TEMP 'notes.md'
[IO.File]::WriteAllText($notesFile, $section.Groups[1].Value.Trim(), (New-Object Text.UTF8Encoding $false))

gh release create $tag --target $env:GITHUB_SHA --title "Qpen $tag" --notes-file $notesFile --latest
if ($LASTEXITCODE -ne 0) { throw 'リリースを作れませんでした' }
Write-Host "$tag をリリースしました"
