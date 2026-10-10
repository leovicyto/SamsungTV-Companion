@echo off
:: SamsungTV-Companion - double-click to uninstall (asks for administrator rights)
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
set "SCRIPT=%ProgramData%\SamsungTV-Companion\Uninstall.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0src\Uninstall.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
echo.
pause