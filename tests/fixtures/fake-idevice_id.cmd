@echo off
rem Fake idevice_id: one USB device. FAKE_NO_DEVICE=1 - no devices.
if defined FAKE_NO_DEVICE exit /b 0
if "%~1"=="-l" (echo 00008110-000A1B2C3D4E5F60& exit /b 0)
if "%~1"=="-n" exit /b 0
echo Test iPhone
exit /b 0
