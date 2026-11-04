@echo off
rem Фейковый ideviceinstaller: успешная установка; FAKE_INSTALL_LOG — журнал вызовов.
if defined FAKE_INSTALL_LOG echo %*>>"%FAKE_INSTALL_LOG%"
echo Install: CreatingStagingDirectory (5%%)
echo Install: InstallComplete (100%%)
echo Install: Complete
exit /b 0
