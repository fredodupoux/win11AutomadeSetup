@echo off
rem Run from the OOBE screen: press Shift+F10, then type  D:\Setup\Provision-OOBE.cmd
rem (replace D: with the USB drive letter - "wmic logicaldisk get name,volumename" lists them)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Provision-OOBE.ps1" %*
if errorlevel 1 pause
