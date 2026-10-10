@echo off
:: SamsungTV-Companion - double-click to uninstall (asks for administrator rights)
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)
set "SCRIPT=%ProgramData%\SamsungTV-Companion\Uninstall.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0src\Uninstall.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
echo.
pause
