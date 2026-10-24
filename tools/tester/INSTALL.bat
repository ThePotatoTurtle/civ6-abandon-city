@echo off
cd /d "%~dp0"
echo Installing...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_tester.ps1" -Mode install
echo.
pause
