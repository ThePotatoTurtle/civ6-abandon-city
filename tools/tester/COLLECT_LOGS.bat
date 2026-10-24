@echo off
cd /d "%~dp0"
echo Collecting logs...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_tester.ps1" -Mode collect
echo.
pause
