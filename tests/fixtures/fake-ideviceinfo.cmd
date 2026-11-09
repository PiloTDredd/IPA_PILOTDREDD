@echo off
rem Fake ideviceinfo: "-n -u UDID" - the Wi-Fi iPad, otherwise the USB iPhone; "-q com.apple.disk_usage" - storage.
if "%~1"=="-q" goto disk
if "%~1"=="-n" if "%~2"=="-q" goto disknet
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
:disk
echo AmountDataAvailable: 41200000000
echo AmountDataReserved: 209715200
echo TotalDataAvailable: 41409715200
echo TotalDataCapacity: 121000000000
echo TotalDiskCapacity: 128000000000
exit /b 0
:disknet
echo AmountDataAvailable: 20000000000
echo TotalDiskCapacity: 64000000000
exit /b 0
