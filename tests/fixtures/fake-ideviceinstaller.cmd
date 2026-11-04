@echo off
rem Fake ideviceinstaller: successful install. FAKE_INSTALL_LOG - call log.
rem FAKE_DEVICE_FLAKY=<file> - the first call fails with "No device found" (like a device that briefly disconnected).
if defined FAKE_INSTALL_LOG echo %*>>"%FAKE_INSTALL_LOG%"
if defined FAKE_DEVICE_FLAKY if not exist "%FAKE_DEVICE_FLAKY%" (
  echo flaky>"%FAKE_DEVICE_FLAKY%"
  echo No device found with udid 00008110-000A1B2C3D4E5F60.
  exit /b 255
)
echo Install: CreatingStagingDirectory (5%%)
echo Install: InstallComplete (100%%)
echo Install: Complete
exit /b 0