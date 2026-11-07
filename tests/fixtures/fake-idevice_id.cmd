@echo off
rem Fake idevice_id: one USB device. FAKE_NO_DEVICE=1 - no devices.
rem FAKE_WIFI_DEVICE=1 - one more device via Wi-Fi (-n); =both - the USB device is also visible via Wi-Fi ("UDID (Network)").
if defined FAKE_NO_DEVICE exit /b 0
if "%~1"=="-l" (echo 00008110-000A1B2C3D4E5F60& exit /b 0)
if "%~1"=="-n" goto network
echo Test iPhone
exit /b 0
:network
if "%FAKE_WIFI_DEVICE%"=="1" echo 00008030-00112233445566AA
if "%FAKE_WIFI_DEVICE%"=="both" echo 00008110-000A1B2C3D4E5F60 (Network)
exit /b 0
