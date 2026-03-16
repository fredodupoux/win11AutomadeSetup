@echo off
setlocal

echo.
echo ============================================
echo      Windows 11 Provisioning - Launcher
echo ============================================
echo.
echo Waiting 5 minutes for system to fully initialize...
echo Press any key to skip the wait and start immediately.
timeout /t 300
echo.

rem Scan all drive letters to find Setup.ps1 on the USB
set SETUP_DRIVE=
for %%D in (C D E F G H I J K L) do (
    if exist "%%D:\Setup\Setup.ps1" (
        set SETUP_DRIVE=%%D
        goto :found
    )
)

echo ERROR: Could not find Setup\Setup.ps1 on any drive.
echo Please run Setup.ps1 manually from the USB drive.
pause
exit /b 1

:found
echo Found provisioning files on drive %SETUP_DRIVE%:\
echo.

rem Set PowerShell execution policy system-wide
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force"

rem Run the provisioning script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SETUP_DRIVE%:\Setup\Setup.ps1"

endlocal
