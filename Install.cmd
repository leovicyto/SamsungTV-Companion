@echo off
:: SamsungTV-Companion - double-click to install (asks for administrator rights)
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Install.ps1" %*
echo.
pause
