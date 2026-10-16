@echo off
rem Double-click to install Qpen. Runs install.ps1 hidden and closes right away;
rem Qpen shows a notification when it is ready.
start "" "%WINDIR%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
