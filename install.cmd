@echo off
chcp 65001 >nul
rem ダブルクリックで Qpen をインストールする。
rem install.ps1 を画面に出さずに実行し、この画面はすぐ閉じる。完了すると Qpen が通知を出す。
start "" "%WINDIR%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
