@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-ipatool.ps1" %*
exit /b %ERRORLEVEL%
