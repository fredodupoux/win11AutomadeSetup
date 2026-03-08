<#
.SYNOPSIS
    Generates autounattend.xml from config.ps1 and the template.

.DESCRIPTION
    Reads Setup/config.ps1, substitutes all %%PLACEHOLDERS%% in
    autounattend.template.xml, and writes the final autounattend.xml
    to the repo root — ready to copy to the USB drive.

    Run this every time you change config.ps1 before preparing a USB.

.NOTES
    Requires PowerShell 5.1+ (Windows) or pwsh (macOS/Linux).
    On macOS: brew install powershell, then run: pwsh Build-USB.ps1
#>

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# --------------------------------------------------------------
# Load config.ps1
# --------------------------------------------------------------
$ConfigFile = Join-Path $ScriptDir "Setup\config.ps1"
if (-not (Test-Path $ConfigFile)) {
    Write-Error "config.ps1 not found at: $ConfigFile`nCopy config.example.ps1 to config.ps1 and fill in your values."
    exit 1
}

# Initialize all variables with defaults before dot-sourcing
# so missing entries in config.ps1 don't cause errors
$Config_Organization       = ""
$Config_WindowsEdition     = "Windows 11 Pro"
$Config_Timezone           = "Eastern Standard Time"
$Config_ITAdminUsername    = "ITAdmin"
$Config_ITAdminDisplayName = "IT Admin"
$Config_ITAdminPassword    = ""
$Config_PackageFile        = ""
$Config_TailscaleAuthKey   = ""
$Config_ComputerName       = ""
$Config_NewUsername        = ""
$Config_NewFullName        = ""
$Config_NewPassword        = ""
$Config_NewUserIsAdmin     = $false

. $ConfigFile
Write-Host "[OK] Loaded config.ps1"

# --------------------------------------------------------------
# Prompt for any missing required values
# --------------------------------------------------------------
Write-Host ""

function Read-Required {
    param([string]$Prompt, [string]$Current)
    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }
    do { $val = Read-Host $Prompt } while ([string]::IsNullOrWhiteSpace($val))
    return $val
}

function Read-RequiredSecret {
    param([string]$Prompt, [string]$Current)
    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }
    do {
        $secure = Read-Host $Prompt -AsSecureString
        $val = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    } while ([string]::IsNullOrWhiteSpace($val))
    return $val
}

function Read-WithDefault {
    param([string]$Prompt, [string]$Current, [string]$Default)
    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }
    $val = Read-Host "$Prompt (default: $Default)"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

$Config_Organization       = Read-Required      "Organization name"                         $Config_Organization
$Config_WindowsEdition     = Read-WithDefault   "Windows edition"                           $Config_WindowsEdition     "Windows 11 Pro"
$Config_Timezone           = Read-WithDefault   "Timezone"                                  $Config_Timezone           "Eastern Standard Time"
$Config_ITAdminUsername    = Read-WithDefault   "IT admin username"                         $Config_ITAdminUsername    "ITAdmin"
$Config_ITAdminDisplayName = Read-WithDefault   "IT admin display name"                     $Config_ITAdminDisplayName "IT Admin"
$Config_ITAdminPassword    = Read-RequiredSecret "IT admin password (hidden)"               $Config_ITAdminPassword

Write-Host ""

# --------------------------------------------------------------
# Read template and substitute placeholders
# --------------------------------------------------------------
$TemplatePath = Join-Path $ScriptDir "autounattend.template.xml"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found: $TemplatePath"
    exit 1
}

$xml = Get-Content -Path $TemplatePath -Raw -Encoding UTF8

$xml = $xml -replace '%%ORGANIZATION%%',    $Config_Organization
$xml = $xml -replace '%%WINDOWS_EDITION%%', $Config_WindowsEdition
$xml = $xml -replace '%%TIMEZONE%%',        $Config_Timezone
$xml = $xml -replace '%%ITADMIN_USERNAME%%', $Config_ITAdminUsername
$xml = $xml -replace '%%ITADMIN_DISPLAY%%', $Config_ITAdminDisplayName
$xml = $xml -replace '%%ITADMIN_PASSWORD%%', $Config_ITAdminPassword

# Clear password from memory
$Config_ITAdminPassword = $null
[System.GC]::Collect()

# --------------------------------------------------------------
# Write autounattend.xml
# --------------------------------------------------------------
$OutputPath = Join-Path $ScriptDir "autounattend.xml"
[System.IO.File]::WriteAllText($OutputPath, $xml, [System.Text.Encoding]::UTF8)

Write-Host "[OK] Generated: autounattend.xml"
Write-Host ""

# --------------------------------------------------------------
# Summary
# --------------------------------------------------------------
Write-Host "============================================"
Write-Host "  autounattend.xml ready"
Write-Host "============================================"
Write-Host "  Organization  : $Config_Organization"
Write-Host "  Windows       : $Config_WindowsEdition"
Write-Host "  Timezone      : $Config_Timezone"
Write-Host "  IT Admin user : $Config_ITAdminUsername"
Write-Host "  IT Admin pass : (set)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Write Windows 11 ISO to USB with Rufus (GPT/UEFI)"
Write-Host "  2. Copy autounattend.xml  --> USB root\"
Write-Host "  3. Copy Setup\            --> USB root\Setup\"
Write-Host "  4. Boot target machine from USB"
Write-Host ""
Write-Host "WARNING: autounattend.xml contains a plain-text password."
Write-Host "Delete it from the USB after provisioning is complete." -ForegroundColor Yellow
