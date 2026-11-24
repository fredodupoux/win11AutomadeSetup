@echo off
rem Usage: Build-ISO.cmd <client>     e.g.  Build-ISO.cmd safitek   (prompts if omitted)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-ISO.ps1" %*
pause
