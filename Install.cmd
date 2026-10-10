@echo off
:: SamsungTV-Companion - double-click to install (asks for administrator rights)
:: "fltmc" only works as administrator. ("net session" is not used: it also fails as administrator
:: when the Server service is disabled, which made this file reopen itself forever.)
fltmc >nul 2>&1
if not errorlevel 1 goto :admin
if "%~1"=="--elevated" (
    echo Administrator rights are required. / Precisa de permissao de administrador.
    pause
    exit /b 1
)
powershell -NoProfile -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c \"\"%~f0\" --elevated\"' -Verb RunAs"
exit /b

:admin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Install.ps1"
echo.
pause