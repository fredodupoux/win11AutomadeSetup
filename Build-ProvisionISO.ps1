<#
.SYNOPSIS
    Builds a small data ISO with the OOBE provisioning files, to mount as
    virtual media (IP KVM, VM) on PCs that already have Windows 11 at OOBE.

.DESCRIPTION
    This is NOT a Windows installer. Windows boots from its own disk as
    usual; the ISO just shows up as a DVD drive. At the OOBE screen:
        Shift + F10   then   D:\RUN 3      (3 = PC number -> <prefix>-03)

    Contents:
        RUN.cmd, README.txt
        Setup\  Setup.ps1, Provision-OOBE.ps1/.cmd, <package file>, config.ps1,
                installers.json and Autologon.exe (if present)
    Only Setup\config.ps1 is included - other clients' config-*.ps1 are not.

    The ISO contains plain-text passwords from config.ps1. *.iso is gitignored.

.NOTES
    macOS: pwsh ./Build-ProvisionISO.ps1   (uses hdiutil)
    Windows: needs oscdimg.exe (Windows ADK Deployment Tools) on PATH.
#>
param(
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$SetupDir = Join-Path $Root 'Setup'
$Config   = Join-Path $SetupDir 'config.ps1'

if (-not (Test-Path $Config)) { throw "Setup/config.ps1 not found - run Build-USB.ps1 or create it first." }

$Config_Organization = ''; $Config_PackageFile = ''; $Config_ComputerName = ''
. $Config
if (-not $Config_PackageFile) { $Config_PackageFile = 'packages.json' }
$Org = if ($Config_Organization) { $Config_Organization } else { 'Provision' }
if (-not $OutFile) { $OutFile = Join-Path $Root "$Org-Provision.iso" }

# --- stage ------------------------------------------------------------
$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ("provision-iso-" + [guid]::NewGuid().ToString('N'))
$StageSetup = Join-Path $Stage 'Setup'
New-Item -ItemType Directory -Path $StageSetup -Force | Out-Null

$Files = @('Setup.ps1', 'Provision-OOBE.ps1', 'Provision-OOBE.cmd', $Config_PackageFile, 'config.ps1')
foreach ($f in $Files) {
    $src = Join-Path $SetupDir $f
    if (-not (Test-Path $src)) { throw "Missing Setup/$f" }
    Copy-Item $src $StageSetup
}
foreach ($f in @('installers.json', 'Autologon.exe')) {
    $src = Join-Path $SetupDir $f
    if (Test-Path $src) { Copy-Item $src $StageSetup } else { Write-Warning "Optional Setup/$f not found - not included" }
}

function Write-Crlf([string]$Path, [string]$Text) {
    $Text = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# cmd.exe wants CRLF line endings
Get-ChildItem $StageSetup -Filter *.cmd | ForEach-Object {
    Write-Crlf $_.FullName ([System.IO.File]::ReadAllText($_.FullName))
}

Write-Crlf (Join-Path $Stage 'RUN.cmd') @'
@echo off
rem Usage at the OOBE screen (Shift+F10):  D:\RUN <PC number>     e.g.  D:\RUN 3
call "%~d0\Setup\Provision-OOBE.cmd" %*
'@

$example = if ($Config_ComputerName -match '^(.*?)(\d+)$') { "$($Matches[1])$('3'.PadLeft($Matches[2].Length,'0'))" } else { '<name>' }
Write-Crlf (Join-Path $Stage 'README.txt') @"
$Org - Windows 11 OOBE provisioning (no reinstall)

1. Power on the PC with this ISO mounted. Let Windows boot from its disk to the setup (OOBE) screen.
2. Press Shift+F10 to open a command prompt.
3. Type:  D:\RUN 3        (3 = this PC's number -> $example)
   If D: is not the DVD drive, try E:\RUN 3
4. The PC reboots and finishes on its own (accounts, WiFi, apps, Action1, updates),
   then reboots again to the login screen. Unmount the ISO after the first reboot.
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
# Windows reads ISO9660 only from CD devices: mount it in the KVM as CD-ROM,
# not as a flash drive ("The volume does not contain a recognized file system").
Write-Host "[OK] $OutFile   (mount as CD-ROM / DVD)"
Write-Host "     Next computer name pattern: $Config_ComputerName   (at OOBE: Shift+F10 -> D:\RUN <number>)"
Write-Host "WARNING: the ISO contains plain-text passwords from config.ps1 - keep it private." -ForegroundColor Yellow
