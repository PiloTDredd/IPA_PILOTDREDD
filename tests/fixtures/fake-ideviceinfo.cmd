@echo off
rem Fake ideviceinfo: "-n -u UDID" - the Wi-Fi iPad, otherwise the USB iPhone.
if "%~1"=="-n" goto network
echo DeviceName: Test iPhone
echo ProductType: iPhone15,2
echo ProductVersion: 17.5
echo DeviceClass: iPhone
exit /b 0
:network
echo DeviceName: Test iPad
echo ProductType: iPad13,1
echo ProductVersion: 16.7
echo DeviceClass: iPad
exit /b 0
