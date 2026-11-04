@echo off
rem Фейковый idevice_id: одно устройство.
if "%~1"=="-l" (echo 00008110-000A1B2C3D4E5F60& exit /b 0)
echo Test iPhone
exit /b 0
