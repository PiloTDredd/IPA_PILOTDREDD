@echo off
rem IPA PILOTDREDD — запуск GUI (Windows PowerShell 5.1 + WPF). Консольное окно скрывается после старта.
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0IPA_Dredd.ps1"
