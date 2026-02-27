@echo off
:: Win11Migrator - Double-click launcher
:: Requests admin elevation and launches the PowerShell GUI

:: Check for admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Launch the main script
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Migrator.ps1"
popd
pause
