# v$VERSION が未リリースなら、前回のタグ以降のコミットメッセージをリリースノートにしてリリースを作り、インストーラー Qpen-setup.cmd を添付する
# 日本語を Windows PowerShell 5.1 で扱うため、このファイルは UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$tag = "v$env:VERSION"
# 作れなければリリースを作らずに失敗させる（インストーラーの無いリリースを最新にしない）
$setupFile = Join-Path $env:RUNNER_TEMP 'Qpen-setup.cmd'
& (Join-Path $PSScriptRoot 'build-setup.ps1') -Setup 'setup.ps1' -Install 'install.ps1' -Main 'Qpen.ps1' -Out $setupFile

# リリースにインストーラーが無ければ付ける（前の実行が添付の途中で失敗したときも、やり直しで直る）
function Add-SetupAsset {
    $view = gh release view $tag --json assets | Out-String
    if ($LASTEXITCODE -ne 0) { throw "$tag の添付を調べられなかった" }
    # 上げきれなかった添付（state が uploaded でないもの）は、付いていないと見て上げ直す
    if (@((ConvertFrom-Json $view).assets | Where-Object { $_.name -eq 'Qpen-setup.cmd' -and $_.state -eq 'uploaded' }).Count -gt 0) { Write-Host "$tag には Qpen-setup.cmd が付いている"; return }
    gh release upload $tag $setupFile --clobber
    if ($LASTEXITCODE -ne 0) { throw "$tag に Qpen-setup.cmd を付けられなかった" }
    Write-Host "$tag に Qpen-setup.cmd を付けた"
}

$list = gh release list --limit 1000 --json tagName,isDraft | Out-String
if ($LASTEXITCODE -ne 0) { throw 'リリースの一覧を取得できなかった' }
$all = ConvertFrom-Json $list
$release = $all | Where-Object { $_.tagName -eq $tag } | Select-Object -First 1
# 下書きが別のコミットで作られていたら（版を上げずに中身を変えてプッシュした）、消して今のコミットで作り直す
# そのまま公開すると、インストーラーの中身とタグの中身（自動更新で届くもの）が食い違う
if ($release -and $release.isDraft) {
    $target = (gh release view $tag --json targetCommitish | Out-String | ConvertFrom-Json).targetCommitish
    if ($LASTEXITCODE -ne 0) { throw "$tag の下書きを調べられなかった" }
    if ($target -ne $env:GITHUB_SHA) {
        gh release delete $tag --yes
        if ($LASTEXITCODE -ne 0) { throw "$tag の古い下書きを消せなかった" }
        Write-Host "$tag の下書きは別のコミット($target)で作られていたので消した"
        $release = $null
    }
}
# 下書き（リリースの途中で止まったもの）はまだ届いていないので、リリース済みと数えない
if ($release -and -not $release.isDraft) {
    # 使う人に届くファイルが変わったのに版が同じなら、上げ忘れなので失敗させる（緑のままだと届かないことに気づけない）
    $changed = @(git diff --name-only $tag HEAD -- 'Qpen.ps1' 'install.ps1' 'setup.ps1' '.github/scripts/build-setup.ps1')
    if ($LASTEXITCODE -ne 0) { throw "$tag との違いを調べられなかった" }
    if ($changed.Count -gt 0) { throw "$tag はリリース済みなのに、使う人に届くファイルが変わっている（$($changed -join '、')）。`$Version を上げる" }
    Write-Host "$tag はリリース済み"
    Add-SetupAsset
    exit 0
}
# 添付を付ける途中で止まると、gh は下書きのまま残す。添付を付けてから公開する（公開しないと、使う人に届かない）
if ($release) {
    Write-Host "$tag は下書きのまま残っている"
    Add-SetupAsset
    gh release edit $tag --draft=false --latest
    if ($LASTEXITCODE -ne 0) { throw "$tag の下書きを公開できなかった" }
    Write-Host "$tag の下書きを公開した"
    exit 0
}

[Console]::OutputEncoding = [Text.Encoding]::UTF8  # 日本語のコミットメッセージを文字化けさせない
$previous = @(git tag --merged HEAD --list 'v*' --sort=-v:refname) | Select-Object -First 1
$range = if ($previous) { "$previous..HEAD" } else { 'HEAD' }
# 使う人に関係ないもの(AI 向けのルール・テスト・リリースの仕組み)だけを変えたコミットは載せない
$lines = @(git log $range --no-merges --format='- %s' -- . ':(exclude)CLAUDE.md' ':(exclude)tests' ':(exclude).github')
if ($lines.Count -eq 0) { $lines = @('- 変更なし') }
$notesFile = Join-Path $env:RUNNER_TEMP 'notes.md'
[IO.File]::WriteAllText($notesFile, ($lines -join "`n"), (New-Object Text.UTF8Encoding $false))

gh release create $tag $setupFile --target $env:GITHUB_SHA --title "Qpen $tag" --notes-file $notesFile --latest
if ($LASTEXITCODE -ne 0) { throw 'リリースを作れなかった' }
Write-Host "$tag をリリースした"
Add-SetupAsset
