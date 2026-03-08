<#
.SYNOPSIS
    Generates autounattend.xml from config.ps1 and the template.

.DESCRIPTION
    Loads Setup/config.ps1 if it exists, then prompts for any
    value that is missing or empty. Writes all collected values
    back to config.ps1 so the file stays up to date.
    Finally substitutes %%PLACEHOLDERS%% in autounattend.template.xml
    and writes the finished autounattend.xml to the repo root.

    Run this every time you prepare a USB drive.

.NOTES
    Requires PowerShell 5.1+ (Windows) or pwsh (macOS/Linux).
    On macOS: brew install powershell  then: pwsh ./Build-USB.ps1
#>

$ErrorActionPreference = "Stop"
$ScriptDir  = $PSScriptRoot
$ConfigFile = Join-Path $ScriptDir "Setup\config.ps1"

# Unblock all files in the repo folder — Windows flags files cloned
# from Git or copied from USB as potentially unsafe.
Get-ChildItem -Path $ScriptDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "============================================"
Write-Host "     win11AutomadeSetup — Build USB"
Write-Host "============================================"
Write-Host ""

# --------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------

# Prompt only if $Current is blank. Shows current value as hint.
function Prompt-Value {
    param(
        [string]$Label,
        [string]$Current,
        [string]$Default = "",
        [string]$Note    = ""
    )
    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }

    $hint = if (-not [string]::IsNullOrWhiteSpace($Default)) { " (default: $Default)" } else { " (optional — leave blank to prompt during Setup)" }
    if ($Note) { Write-Host "  > $Note" -ForegroundColor DarkGray }

    $val = Read-Host "  $Label$hint"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

# Same as Prompt-Value but re-prompts until something is entered when required.
function Prompt-Secret {
    param(
        [string]$Label,
        [string]$Current,
        [string]$Note     = "",
        [bool]  $Required = $false
    )
    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }

    if ($Note) { Write-Host "  > $Note" -ForegroundColor DarkGray }
    $hint = if ($Required) { " (required)" } else { " (optional — leave blank to prompt during Setup)" }

    while ($true) {
        $val = Read-Host "  $Label$hint"
        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($val)) { return $val }
        Write-Host "  This field is required — please enter a value." -ForegroundColor Yellow
    }
}

# Prompt for a yes/no boolean.
function Prompt-Bool {
    param([string]$Label, [bool]$Current)
    # Booleans always have a value so just return what config says,
    # but if the config file was never written this will be $false by default.
    $currentStr = if ($Current) { "y" } else { "n" }
    $val = Read-Host "  $Label (y/N, current: $currentStr)"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Current }
    return ($val -ieq 'y')
}

# --------------------------------------------------------------
# Load existing config.ps1 if present
# --------------------------------------------------------------
$Config_Organization       = ""
$Config_WindowsEdition     = ""
$Config_Timezone           = ""
$Config_ITAdminUsername    = ""
$Config_ITAdminDisplayName = ""
$Config_ITAdminPassword    = ""
$Config_PackageFile        = ""
$Config_WifiSSID           = ""
$Config_WifiPassword       = ""
$Config_TailscaleAuthKey   = ""
$Config_ComputerName       = ""
$Config_NewUsername        = ""
$Config_NewFullName        = ""
$Config_NewPassword        = ""
$Config_NewUserIsAdmin     = $false

if (Test-Path $ConfigFile) {
    . $ConfigFile
    Write-Host "[OK] Loaded existing config.ps1"
} else {
    $ExampleFile = Join-Path $ScriptDir "Setup\config.example.ps1"
    if (-not (Test-Path $ExampleFile)) {
        Write-Error "config.example.ps1 not found at: $ExampleFile"
        exit 1
    }
    Copy-Item -Path $ExampleFile -Destination $ConfigFile
    . $ConfigFile
    Write-Host "[OK] Created config.ps1 from config.example.ps1"
}
Write-Host ""

# --------------------------------------------------------------
# Collect all values — prompt for anything missing
# --------------------------------------------------------------

Write-Host "--- autounattend.xml settings (required for USB build) ---"
Write-Host ""

$Config_Organization = Prompt-Value `
    -Label   "Organization name" `
    -Current $Config_Organization

$Config_WindowsEdition = Prompt-Value `
    -Label   "Windows edition" `
    -Current $Config_WindowsEdition `
    -Default "Windows 11 Pro" `
    -Note    "Options: 'Windows 11 Home', 'Windows 11 Pro', 'Windows 11 Enterprise'"

$Config_Timezone = Prompt-Value `
    -Label   "Timezone" `
    -Current $Config_Timezone `
    -Default "Eastern Standard Time" `
    -Note    "Run 'Get-TimeZone -ListAvailable' on Windows to see all options"

$Config_ITAdminUsername = Prompt-Value `
    -Label   "IT admin username" `
    -Current $Config_ITAdminUsername `
    -Default "ITAdmin"

$Config_ITAdminDisplayName = Prompt-Value `
    -Label   "IT admin display name" `
    -Current $Config_ITAdminDisplayName `
    -Default "IT Admin"

$Config_ITAdminPassword = Prompt-Secret `
    -Label    "IT admin password (hidden)" `
    -Current  $Config_ITAdminPassword `
    -Note     "Temporary password — rotate it after provisioning" `
    -Required $true

Write-Host ""
Write-Host "--- Setup.ps1 settings (optional — blank = prompted during setup) ---"
Write-Host ""

$Config_PackageFile = Prompt-Value `
    -Label   "Package file name" `
    -Current $Config_PackageFile `
    -Default "packages.json"

$Config_WifiSSID = Prompt-Value `
    -Label   "WiFi SSID" `
    -Current $Config_WifiSSID `
    -Note    "Company WiFi network name — leave blank to skip WiFi setup"

if (-not [string]::IsNullOrWhiteSpace($Config_WifiSSID)) {
    $Config_WifiPassword = Prompt-Secret `
        -Label   "WiFi password" `
        -Current $Config_WifiPassword
}

$Config_TailscaleAuthKey = Prompt-Secret `
    -Label   "Tailscale auth key" `
    -Current $Config_TailscaleAuthKey `
    -Note    "Generate at: https://login.tailscale.com/admin/settings/keys"

$Config_ComputerName = Prompt-Value `
    -Label   "Computer name" `
    -Current $Config_ComputerName `
    -Note    "Max 15 chars, letters/numbers/hyphens only"

$Config_NewUsername = Prompt-Value `
    -Label   "End user username" `
    -Current $Config_NewUsername

$Config_NewFullName = Prompt-Value `
    -Label   "End user full name" `
    -Current $Config_NewFullName

$Config_NewPassword = Prompt-Secret `
    -Label   "End user password (hidden)" `
    -Current $Config_NewPassword

if (-not [string]::IsNullOrWhiteSpace($Config_NewUsername)) {
    $Config_NewUserIsAdmin = Prompt-Bool `
        -Label   "Make end user an Administrator?" `
        -Current $Config_NewUserIsAdmin
}

Write-Host ""

# --------------------------------------------------------------
# Write all values back to config.ps1
# --------------------------------------------------------------

# Escape single quotes in string values for safe embedding in PS1
function Escape-PS1String { param([string]$s); return $s -replace "'", "''" }

$adminBoolStr = if ($Config_NewUserIsAdmin) { '$true' } else { '$false' }

$configContent = @"
# ==============================================================
# config.ps1 — Local provisioning configuration
# Generated by Build-USB.ps1 — do not commit this file
# ==============================================================

# --- autounattend.xml settings --------------------------------
`$Config_Organization       = '$(Escape-PS1String $Config_Organization)'
`$Config_WindowsEdition     = '$(Escape-PS1String $Config_WindowsEdition)'
`$Config_Timezone           = '$(Escape-PS1String $Config_Timezone)'
`$Config_ITAdminUsername    = '$(Escape-PS1String $Config_ITAdminUsername)'
`$Config_ITAdminDisplayName = '$(Escape-PS1String $Config_ITAdminDisplayName)'
`$Config_ITAdminPassword    = '$(Escape-PS1String $Config_ITAdminPassword)'

# --- Setup.ps1 settings ---------------------------------------
`$Config_PackageFile        = '$(Escape-PS1String $Config_PackageFile)'
`$Config_WifiSSID           = '$(Escape-PS1String $Config_WifiSSID)'
`$Config_WifiPassword       = '$(Escape-PS1String $Config_WifiPassword)'
`$Config_TailscaleAuthKey   = '$(Escape-PS1String $Config_TailscaleAuthKey)'
`$Config_ComputerName       = '$(Escape-PS1String $Config_ComputerName)'
`$Config_NewUsername        = '$(Escape-PS1String $Config_NewUsername)'
`$Config_NewFullName        = '$(Escape-PS1String $Config_NewFullName)'
`$Config_NewPassword        = '$(Escape-PS1String $Config_NewPassword)'
`$Config_NewUserIsAdmin     = $adminBoolStr
"@

[System.IO.File]::WriteAllText($ConfigFile, $configContent, [System.Text.Encoding]::UTF8)
Write-Host "[OK] config.ps1 updated"

# --------------------------------------------------------------
# Generate autounattend.xml from template
# --------------------------------------------------------------
$TemplatePath = Join-Path $ScriptDir "autounattend.template.xml"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found: $TemplatePath"
    exit 1
}

$xml = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
$xml = $xml -replace '%%ORGANIZATION%%',     $Config_Organization
$xml = $xml -replace '%%WINDOWS_EDITION%%',  $Config_WindowsEdition
$xml = $xml -replace '%%TIMEZONE%%',         $Config_Timezone
$xml = $xml -replace '%%ITADMIN_USERNAME%%',  $Config_ITAdminUsername
$xml = $xml -replace '%%ITADMIN_DISPLAY%%',  $Config_ITAdminDisplayName
$xml = $xml -replace '%%ITADMIN_PASSWORD%%',  $Config_ITAdminPassword

# Clear password from memory
$Config_ITAdminPassword = $null
$Config_NewPassword     = $null
[System.GC]::Collect()

$OutputPath = Join-Path $ScriptDir "autounattend.xml"
[System.IO.File]::WriteAllText($OutputPath, $xml, [System.Text.Encoding]::UTF8)
Write-Host "[OK] autounattend.xml generated"
Write-Host ""

# --------------------------------------------------------------
# Summary
# --------------------------------------------------------------
Write-Host "============================================"
Write-Host "  Build complete"
Write-Host "============================================"
Write-Host "  Organization  : $Config_Organization"
Write-Host "  Windows       : $Config_WindowsEdition"
Write-Host "  Timezone      : $Config_Timezone"
Write-Host "  IT Admin user : $Config_ITAdminUsername"
Write-Host "  IT Admin pass : (set)"
Write-Host "  Computer name : $(if ($Config_ComputerName) { $Config_ComputerName } else { '(will prompt during setup)' })"
Write-Host "  End user      : $(if ($Config_NewUsername) { $Config_NewUsername } else { '(will prompt during setup)' })"
Write-Host "  WiFi SSID     : $(if ($Config_WifiSSID) { $Config_WifiSSID } else { '(skipped)' })"
Write-Host "  Tailscale     : $(if ($Config_TailscaleAuthKey) { '(set)' } else { '(will prompt during setup)' })"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Write Windows 11 ISO to USB with Rufus (GPT / UEFI)"
Write-Host "  2. Copy autounattend.xml --> USB root\"
Write-Host "  3. Copy Setup\           --> USB root\Setup\"
Write-Host "  4. Boot target machine from USB"
Write-Host ""
Write-Host "WARNING: autounattend.xml contains a plain-text password." -ForegroundColor Yellow
Write-Host "Delete it from the USB after provisioning is complete." -ForegroundColor Yellow
