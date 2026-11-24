@echo off
rem Usage: Build-ISO.cmd   (asks for client and stock ISO)  - run as Administrator
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-ISO.ps1" %*
pause
