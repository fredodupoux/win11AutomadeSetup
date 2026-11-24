<#
.SYNOPSIS
    PROVISIONING-ONLY ISO: a small data ISO for PCs that already have
    Windows 11 and are sitting at the OOBE (setup) screen. No reinstall.

.DESCRIPTION
    Not a Windows installer. Windows boots from its own disk as usual; the
    ISO shows up as a DVD drive. Mount it on the IP KVM as CD-ROM (not
    flash drive). At the OOBE screen:
        Shift + F10   then   D:\RUN 3      (3 = PC number -> <prefix>-03)

    Output: dist\<client>\<ORG>-Provision.iso
        RUN.cmd, README.txt, Setup\ (generic scripts + this client's files only)

    The ISO contains plain-text passwords from the client's config.ps1.

.EXAMPLE
    pwsh ./Build-ProvisionISO.ps1 -Client safitek

.NOTES
    macOS: uses hdiutil.  Windows: needs oscdimg.exe (Windows ADK Deployment Tools) on PATH.
#>
param(
    [string]$Client = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Build-Common.ps1')

$ClientDir  = Resolve-Client -Client $Client
$ClientName = Split-Path $ClientDir -Leaf

$Config_Organization = ''; $Config_ComputerName = ''
. (Join-Path $ClientDir 'config.ps1')
$Org     = if ($Config_Organization) { $Config_Organization -replace '[^A-Za-z0-9_-]', '' } else { $ClientName }
$OutDir  = Join-Path $DistRoot $ClientName
$OutFile = Join-Path $OutDir "$Org-Provision.iso"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# --- stage ------------------------------------------------------------
$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ("provision-iso-" + [guid]::NewGuid().ToString('N'))
New-SetupFolder -ClientDir $ClientDir -Destination (Join-Path $Stage 'Setup')

Write-CrlfFile (Join-Path $Stage 'RUN.cmd') @'
@echo off
rem Usage at the OOBE screen (Shift+F10):  D:\RUN <PC number>     e.g.  D:\RUN 3
call "%~d0\Setup\Provision-OOBE.cmd" %*
'@

$example = if ($Config_ComputerName -match '^(.*?)(\d+)$') { "$($Matches[1])$('3'.PadLeft($Matches[2].Length,'0'))" } else { '<name>' }
Write-CrlfFile (Join-Path $Stage 'README.txt') @"
$Org - Windows 11 OOBE provisioning (no reinstall)

1. Power on the PC with this ISO mounted AS CD-ROM. Let Windows boot from its disk to the setup (OOBE) screen.
2. Press Shift+F10 to open a command prompt.
3. Type:  D:\RUN 3        (3 = this PC's number -> $example)
   If D: is not the DVD drive, try E:\RUN 3
4. The PC reboots and finishes on its own (accounts, WiFi, apps, Action1, updates),
   then reboots again to the sign-in screen. Unmount the ISO after the first reboot.
"@

# --- build --------------------------------------------------------------
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

if ($IsMacOS) {
    & hdiutil makehybrid -iso -joliet -default-volume-name 'PROVISION' -o $OutFile $Stage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "hdiutil failed ($LASTEXITCODE)" }
} else {
    $oscdimg = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if (-not $oscdimg) { throw "oscdimg.exe not found. Install the Windows ADK Deployment Tools, or build on macOS." }
    & $oscdimg.Source -u2 -lPROVISION $Stage $OutFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)" }
}

Remove-Item $Stage -Recurse -Force
Write-Host "[OK] $OutFile   (mount as CD-ROM / DVD)"
Write-Host "     Name pattern: $Config_ComputerName   (at OOBE: Shift+F10 -> D:\RUN <number>)"
Write-Host "WARNING: the ISO contains plain-text passwords from config.ps1 - keep it private." -ForegroundColor Yellow
