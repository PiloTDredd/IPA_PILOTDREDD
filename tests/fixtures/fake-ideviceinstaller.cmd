@echo off
rem Fake ideviceinstaller: successful install. FAKE_INSTALL_LOG - call log.
rem FAKE_DEVICE_FLAKY=<file> - the first call fails with "No device found" (like a device that briefly disconnected).
rem "list": XML with iTunesMetadata (fake-device-apps.xml). FAKE_APPS_FORMAT=text - XML not supported, text output;
rem FAKE_APPS_FORMAT=garbage - unrecognized output.
if defined FAKE_INSTALL_LOG echo %*>>"%FAKE_INSTALL_LOG%"
set _list=
set _xml=
set _uninst=
for %%a in (%*) do (
  if "%%~a"=="list" set _list=1
  if "%%~a"=="--xml" set _xml=1
  if "%%~a"=="uninstall" set _uninst=1
)
if "%FAKE_MUX_ERROR%"=="always" (echo Could not connect to lockdownd: Mux error. Exiting.& exit /b 1)
if defined _list goto list
if defined _uninst goto uninstall
rem FAKE_MUX_ERROR=always - Wi-Fi device asleep (lockdownd "Mux error"); FAKE_MUX_ONCE=<file> - only the first call.
if defined FAKE_MUX_ONCE if not exist "%FAKE_MUX_ONCE%" (
  echo mux>"%FAKE_MUX_ONCE%"
  echo Could not connect to lockdownd: Mux error. Exiting.
  exit /b 1
)
if defined FAKE_DEVICE_FLAKY if not exist "%FAKE_DEVICE_FLAKY%" (
  echo flaky>"%FAKE_DEVICE_FLAKY%"
  echo No device found with udid 00008110-000A1B2C3D4E5F60.
  exit /b 255
)
echo Install: CreatingStagingDirectory (5%%)
echo Install: InstallComplete (100%%)
echo Install: Complete
exit /b 0
:list
if "%FAKE_APPS_FORMAT%"=="garbage" (echo Something unexpected& exit /b 0)
if "%FAKE_APPS_FORMAT%"=="text" if defined _xml (echo ERROR: Unknown option --xml& exit /b 1)
if "%FAKE_APPS_FORMAT%"=="text" (type "%~dp0fake-device-apps.txt"& exit /b 0)
type "%~dp0fake-device-apps.xml"
exit /b 0
:uninstall
rem FAKE_UNINSTALL_FAIL=1 - the app is not on the device.
if "%FAKE_UNINSTALL_FAIL%"=="1" (echo ERROR: Uninstall failed: ApplicationVerificationFailed& exit /b 0)
echo Uninstall: RemovingApplication (50%%)
echo Uninstall: Complete
exit /b 0
