<#
.SYNOPSIS
    Creates a bootable Windows 11 ISO with autounattend.xml and Setup/ baked in.

.DESCRIPTION
    Takes a stock Windows 11 ISO, mounts it, injects autounattend.xml and the
    Setup/ folder, then repacks into a new bootable UDF ISO using oscdimg from
    the Windows ADK. Output is suitable for KVM/QEMU, Ventoy, or Rufus/dd to USB.

.NOTES
    Requirements:
      - Must be run as Administrator (mounting ISO requires elevation)
      - Windows ADK with "Deployment Tools" installed
        https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
      - Run Build-USB.ps1 first to generate autounattend.xml and config.ps1

    WARNING: The output ISO embeds autounattend.xml which contains a plain-text
    password. Treat it as a credential file - do not share or store insecurely.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

Write-Host ""
Write-Host "============================================"
Write-Host "    win11AutomadeSetup - Build ISO"
Write-Host "============================================"
Write-Host ""

# ---------------------------------------------------------------
# Locate oscdimg.exe (part of Windows ADK - Deployment Tools)
# ---------------------------------------------------------------
$OscdimgPath = @(
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $OscdimgPath) {
    Write-Error @"
oscdimg.exe not found. Install the Windows ADK (Deployment Tools component):
  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
"@
    exit 1
}
Write-Host "[OK] oscdimg: $OscdimgPath"

# ---------------------------------------------------------------
# Verify prerequisites
# ---------------------------------------------------------------
$AutounattendFile = Join-Path $ScriptDir "autounattend.xml"
if (-not (Test-Path $AutounattendFile)) {
    Write-Error "autounattend.xml not found. Run Build-USB.ps1 first to generate it."
    exit 1
}

$SetupFolder = Join-Path $ScriptDir "Setup"
if (-not (Test-Path $SetupFolder)) {
    Write-Error "Setup\ folder not found at: $SetupFolder"
    exit 1
}

Write-Host "[OK] autounattend.xml found"
Write-Host "[OK] Setup\ folder found"
Write-Host ""

# ---------------------------------------------------------------
# Prompt for source ISO
# ---------------------------------------------------------------
$SourceIso = Read-Host "Path to stock Windows 11 ISO"
$SourceIso = $SourceIso.Trim('"')
if (-not (Test-Path $SourceIso)) {
    Write-Error "ISO not found: $SourceIso"
    exit 1
}
$SourceIso = (Resolve-Path $SourceIso).Path

# ---------------------------------------------------------------
# Determine output ISO name from computer name in autounattend.xml
# ---------------------------------------------------------------
$xmlContent   = Get-Content $AutounattendFile -Raw -Encoding UTF8
$computerName = if ($xmlContent -match '<ComputerName>([^<]+)</ComputerName>') { $Matches[1] } else { "WIN11" }
$defaultName  = "Win11-$computerName.iso"
$outputName   = Read-Host "Output ISO filename (default: $defaultName)"
if ([string]::IsNullOrWhiteSpace($outputName)) { $outputName = $defaultName }
$OutputIso = Join-Path $ScriptDir $outputName

Write-Host ""

# ---------------------------------------------------------------
# Working directory - use system root to avoid spaces in path
# which can break oscdimg's -bootdata argument
# ---------------------------------------------------------------
$WorkDir = "C:\win11iso_$(Get-Random)"
New-Item -ItemType Directory -Path $WorkDir | Out-Null

$mountedIso = $false
try {
    # --- Mount source ISO ---
    Write-Host "Mounting source ISO..."
    $mount       = Mount-DiskImage -ImagePath $SourceIso -PassThru
    $mountedIso  = $true
    $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
    Write-Host "[OK] Mounted at $driveLetter"

    # --- Copy ISO contents ---
    Write-Host "Copying ISO contents (this may take a moment)..."
    Copy-Item -Path "$driveLetter\*" -Destination $WorkDir -Recurse -Force
    Write-Host "[OK] ISO contents copied"

    # --- Dismount ---
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    $mountedIso = $false
    Write-Host "[OK] ISO dismounted"

    # --- Inject autounattend.xml ---
    Copy-Item -Path $AutounattendFile -Destination "$WorkDir\autounattend.xml" -Force
    Write-Host "[OK] autounattend.xml injected"

    # --- Inject Setup/ folder ---
    $destSetup = Join-Path $WorkDir "Setup"
    if (Test-Path $destSetup) { Remove-Item $destSetup -Recurse -Force }
    Copy-Item -Path $SetupFolder -Destination $destSetup -Recurse -Force
    Write-Host "[OK] Setup\ folder injected"
    Write-Host ""

    # --- Locate boot sector files ---
    $EtfsBoot = Join-Path $WorkDir "boot\etfsboot.com"
    $EfiBoot  = Join-Path $WorkDir "efi\microsoft\boot\efisys.bin"

    if (-not (Test-Path $EtfsBoot)) {
        Write-Error "Boot file not found: $EtfsBoot - source ISO may be corrupt or unsupported."
        exit 1
    }
    if (-not (Test-Path $EfiBoot)) {
        Write-Error "EFI boot file not found: $EfiBoot - source ISO may be corrupt or unsupported."
        exit 1
    }

    # --- Build ISO with oscdimg ---
    # -m           ignore maximum size limit
    # -o           optimize storage (single-instance duplicate files)
    # -u2          UDF 2.01 file system
    # -udfver102   UDF version 1.02 (standard for Windows ISOs)
    # -bootdata    dual boot sectors: BIOS (etfsboot) + UEFI (efisys)
    Write-Host "Building ISO..."
    $bootData = "2#p0,e,b$EtfsBoot#pEF,e,b$EfiBoot"
    & $OscdimgPath -m -o -u2 -udfver102 "-bootdata:$bootData" $WorkDir $OutputIso

    if ($LASTEXITCODE -ne 0) {
        Write-Error "oscdimg failed with exit code $LASTEXITCODE"
        exit 1
    }

    $sizeMB = [math]::Round((Get-Item $OutputIso).Length / 1MB)
    Write-Host ""
    Write-Host "[OK] ISO created: $OutputIso ($sizeMB MB)"

} finally {
    if ($mountedIso) {
        Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path $WorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
Write-Host ""
Write-Host "============================================"
Write-Host "  ISO build complete"
Write-Host "============================================"
Write-Host "  File : $OutputIso"
Write-Host "  Size : $sizeMB MB"
Write-Host ""
Write-Host "Usage:"
Write-Host "  KVM/QEMU : attach as a CD-ROM drive and boot"
Write-Host "  Ventoy   : copy ISO to Ventoy USB (autounattend.xml is baked in)"
Write-Host "  USB      : write with Rufus (GPT / UEFI, ISO image mode)"
Write-Host ""
Write-Host "WARNING: This ISO contains autounattend.xml with a plain-text password." -ForegroundColor Yellow
Write-Host "Do not share or store it in an insecure location." -ForegroundColor Yellow
Write-Host "Delete it after provisioning is complete." -ForegroundColor Yellow
