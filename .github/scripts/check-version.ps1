# リリース用（GitHub Actions から実行される）
# Qpen.ps1 を検証し、中の $Version を GITHUB_OUTPUT の version に書き出す。
# ファイルが壊れている（BOM がない・構文エラー・バージョンが読めない）ときは失敗させ、リリースさせない。
# 日本語のメッセージを Windows PowerShell 5.1 で正しく扱うため、このファイル自体も UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$f = (Resolve-Path 'Qpen.ps1').Path
$bytes = [IO.File]::ReadAllBytes($f)
if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
    throw 'Qpen.ps1 が UTF-8 BOM 付きではありません（Windows PowerShell 5.1 で日本語が文字化けします）'
}

$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "$($_.Extent.StartLineNumber) 行目: $($_.Message)" }
    throw 'Qpen.ps1 に構文エラーがあります'
}

$match = [regex]::Match([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8), "(?m)^\`$Version = '(\d+\.\d+\.\d+)'")
if (-not $match.Success) { throw "Qpen.ps1 に `$Version = 'X.Y.Z' が見つかりません" }

$version = $match.Groups[1].Value
Write-Host "バージョン: $version"
[IO.File]::AppendAllText($env:GITHUB_OUTPUT, "version=$version`n")
