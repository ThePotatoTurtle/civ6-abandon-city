@echo off
cd /d "%~dp0"
echo Uninstalling...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_tester.ps1" -Mode uninstall
echo.
pause
