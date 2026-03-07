#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows 11 Provisioning Script

.DESCRIPTION
    Automates setup of a new Windows 11 computer: application installation,
    VPN connectivity, user account management, security hardening, and cleanup.
    Mirrors the macOS provisioning workflow documented in Provisionning_Guide.md.

.NOTES
    - Must be run as Administrator
    - Designed for Windows 11 (build 22000+)
    - Place this file at C:\Setup\Setup.ps1 so autounattend.xml can launch it
      on first login, or run it manually from any location.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
# PHASE 1: Configuration Collection
# ================================================================

Write-Host "============================================"
Write-Host "     Windows 11 Provisioning Script"
Write-Host "============================================"
Write-Host ""

# 1.1 Package file name
$PackageFile = Read-Host "Enter package file name (default: packages.json)"
if ([string]::IsNullOrWhiteSpace($PackageFile)) { $PackageFile = "packages.json" }

# 1.2 Tailscale auth key (optional, input hidden)
$TailscaleAuthKeySecure = Read-Host "Enter Tailscale auth key (leave empty to skip)" -AsSecureString
$TailscaleAuthKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TailscaleAuthKeySecure)
)

# ================================================================
# PHASE 2: Logging Setup
# ================================================================

$LogFile = "$env:USERPROFILE\win_setup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile

# Restrict log file to owner only (equivalent to chmod 600)
icacls $LogFile /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null

Write-Host "Log file: $LogFile"
Write-Host ""

# ================================================================
# PHASE 3: Pre-flight Checks
# ================================================================

Write-Host "--- Phase 3: Pre-flight Checks ---"

# 3.1 Verify Windows 11
$OSBuild = [System.Environment]::OSVersion.Version.Build
if ($OSBuild -lt 22000) {
    Write-Error "Windows 11 required (build 22000+). Current build: $OSBuild"
    Stop-Transcript
    exit 1
}
Write-Host "[OK] OS: Windows 11 (build $OSBuild)"

# 3.2 Verify running as Administrator
$CurrentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    Stop-Transcript
    exit 1
}
Write-Host "[OK] Running as Administrator"

# 3.3 Verify winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning "winget not found. Attempting to install App Installer..."
    # winget ships with Windows 11 but may need an update on fresh installs
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Error "winget still not available. Install 'App Installer' from the Microsoft Store and re-run."
        Stop-Transcript
        exit 1
    }
}
Write-Host "[OK] winget available"
Write-Host ""

# ================================================================
# PHASE 4: Package Manager Update
# ================================================================

Write-Host "--- Phase 4: Package Manager ---"
Write-Host "Updating winget sources..."
winget source update
Write-Host ""

# ================================================================
# PHASE 5: VPN / Network Setup (Optional)
# ================================================================

Write-Host "--- Phase 5: VPN Setup ---"

if (-not [string]::IsNullOrEmpty($TailscaleAuthKey)) {
    Write-Host "Installing Tailscale..."
    winget install --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements --silent

    # Give the service a moment to start
    Start-Sleep -Seconds 5

    # Find Tailscale executable (location can vary)
    $TailscalePath = @(
        "C:\Program Files\Tailscale\tailscale.exe",
        "C:\Program Files (x86)\Tailscale\tailscale.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($TailscalePath) {
        Write-Host "Authenticating Tailscale..."
        & $TailscalePath up --authkey="$TailscaleAuthKey"
        Write-Host "[OK] Tailscale connected"
    } else {
        Write-Warning "Tailscale installed but executable not found at expected path. Authenticate manually."
    }

    # Clear sensitive variable from memory
    $TailscaleAuthKey = $null
    [System.GC]::Collect()
} else {
    Write-Host "Tailscale: skipped (no auth key provided)"
}
Write-Host ""

# ================================================================
# PHASE 6: Application Installation
# ================================================================

Write-Host "--- Phase 6: Application Installation ---"

$ScriptDir = $PSScriptRoot
$PackagePath = Join-Path $ScriptDir $PackageFile

if (Test-Path $PackagePath) {
    Write-Host "Installing applications from $PackageFile..."
    winget import --import-file $PackagePath --accept-source-agreements --accept-package-agreements
    Write-Host "[OK] Applications installed"
} else {
    Write-Warning "Package file not found: $PackagePath"
    Write-Warning "Skipping application installation. Add '$PackageFile' to the setup folder and re-run if needed."
}
Write-Host ""

# ================================================================
# PHASE 7: User Management
# ================================================================

Write-Host "--- Phase 7: User Management ---"

# Track what was configured for the summary
$ConfiguredITAdmin    = ""
$ConfiguredNewUser    = ""
$RenameRequired       = $false
$NewComputerName      = ""

# ------------------------------------------------------------------
# 7.1 Hide IT Admin Account from login screen
# ------------------------------------------------------------------
$ITAdminUser = Read-Host "Enter IT admin username to hide from login screen (leave empty to skip)"

if (-not [string]::IsNullOrWhiteSpace($ITAdminUser)) {
    $UserExists = Get-LocalUser -Name $ITAdminUser -ErrorAction SilentlyContinue
    if ($UserExists) {
        $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }
        New-ItemProperty -Path $RegPath -Name $ITAdminUser -Value 0 -PropertyType DWORD -Force | Out-Null

        # Hide the home folder from Explorer
        $UserProfile = "C:\Users\$ITAdminUser"
        if (Test-Path $UserProfile) {
            attrib +h "$UserProfile"
        }

        $ConfiguredITAdmin = $ITAdminUser
        Write-Host "[OK] '$ITAdminUser' hidden from login screen"
    } else {
        Write-Warning "User '$ITAdminUser' not found on this machine. Skipping."
    }
}

# ------------------------------------------------------------------
# 7.2 Rename Computer
# ------------------------------------------------------------------
Write-Host ""
Write-Host "Current computer name: $env:COMPUTERNAME"
Write-Host "Naming rules: max 15 characters, letters/numbers/hyphens only, no spaces"
$NewComputerName = Read-Host "Enter new computer name (leave empty to skip)"

if (-not [string]::IsNullOrWhiteSpace($NewComputerName)) {
    # Validate: strip invalid characters to a safe name and warn if changed
    $SanitizedName = $NewComputerName -replace '[^a-zA-Z0-9\-]', '' | ForEach-Object { $_.Substring(0, [Math]::Min($_.Length, 15)) }
    if ($SanitizedName -ne $NewComputerName) {
        Write-Warning "Name sanitized to: $SanitizedName (removed invalid characters / truncated)"
        $NewComputerName = $SanitizedName
    }
    Rename-Computer -NewName $NewComputerName -Force
    $RenameRequired = $true
    Write-Host "[OK] Computer will be renamed to '$NewComputerName' on next restart"
}

# ------------------------------------------------------------------
# 7.3 Create End User Account
# ------------------------------------------------------------------
Write-Host ""
$CreateUser = Read-Host "Create a new end user account? (y/N)"

if ($CreateUser -ieq 'y') {
    $NewUsername = Read-Host "Enter username"
    $NewFullName = Read-Host "Enter full name"

    # Collect and confirm password without echoing it
    $NewPasswordSecure  = Read-Host "Enter password" -AsSecureString
    $NewPasswordConfirm = Read-Host "Confirm password" -AsSecureString

    $Pwd1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPasswordSecure))
    $Pwd2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPasswordConfirm))

    if ($Pwd1 -ne $Pwd2) {
        Write-Warning "Passwords do not match. Skipping user creation."
    } else {
        New-LocalUser `
            -Name          $NewUsername `
            -Password      $NewPasswordSecure `
            -FullName      $NewFullName `
            -Description   "End user account" `
            -PasswordNeverExpires:$false | Out-Null

        $MakeAdmin = Read-Host "Add '$NewUsername' to Administrators group? (y/N)"
        if ($MakeAdmin -ieq 'y') {
            Add-LocalGroupMember -Group "Administrators" -Member $NewUsername
            Write-Host "[OK] '$NewUsername' created and added to Administrators"
        } else {
            Add-LocalGroupMember -Group "Users" -Member $NewUsername
            Write-Host "[OK] '$NewUsername' created as standard user"
        }

        $ConfiguredNewUser = $NewUsername
    }

    # Clear passwords from memory
    $Pwd1 = $null
    $Pwd2 = $null
    [System.GC]::Collect()
}
Write-Host ""

# ================================================================
# PHASE 8: Security Configuration
# ================================================================

Write-Host "--- Phase 8: Security Configuration ---"

# 8.1 Enable Automatic Updates
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $WUPath)) { New-Item -Path $WUPath -Force | Out-Null }
Set-ItemProperty -Path $WUPath -Name "AUOptions"    -Value 4  # 4 = auto download and install
Set-ItemProperty -Path $WUPath -Name "NoAutoUpdate" -Value 0
Write-Host "[OK] Automatic updates: enabled"

# 8.2 Enable Windows Firewall on all profiles
Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True
Write-Host "[OK] Firewall: enabled (Domain / Public / Private)"

# 8.3 Require password on wake (screen lock)
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1  # plugged in
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1  # on battery
powercfg /S SCHEME_CURRENT
Write-Host "[OK] Screen lock: password required on wake"

# 8.4 Disable Remote Desktop and Remote Assistance
Set-ItemProperty `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 1
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" `
    -Name "fAllowToGetHelp" -Value 0
# Also disable via firewall rule for defence-in-depth
Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
Write-Host "[OK] Remote Desktop and Remote Assistance: disabled"

# 8.5 Disable SMBv1 (legacy protocol, high attack surface)
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
Write-Host "[OK] SMBv1: disabled"

# 8.6 Enable BitLocker (TPM-only, silent encryption) - Pro/Enterprise only
$BitLockerAvailable = (Get-Command Enable-BitLocker -ErrorAction SilentlyContinue) -ne $null
$IsPro = (Get-WindowsEdition -Online).Edition -match "Pro|Enterprise|Education"

if ($BitLockerAvailable -and $IsPro) {
    $BLStatus = (Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue).VolumeStatus
    if ($BLStatus -eq "FullyDecrypted") {
        Write-Host "Enabling BitLocker on C: ..."
        Enable-BitLocker -MountPoint "C:" -TpmProtector -EncryptionMethod XtsAes256 -SkipHardwareTest
        Write-Host "[OK] BitLocker: encryption started on C:"
    } elseif ($BLStatus -eq "FullyEncrypted") {
        Write-Host "[OK] BitLocker: already enabled on C:"
    } else {
        Write-Host "[INFO] BitLocker status: $BLStatus (no action taken)"
    }
} else {
    Write-Host "[INFO] BitLocker: skipped (requires Pro/Enterprise edition)"
}

Write-Host ""

# ================================================================
# PHASE 9: Cleanup and Summary
# ================================================================

Write-Host "============================================"
Write-Host "         PROVISIONING COMPLETE"
Write-Host "============================================"
Write-Host ""
Write-Host "Log file saved to: $LogFile"
Write-Host ""
Write-Host "Summary of actions taken:"
Write-Host "  [OK] OS verified: Windows 11 build $OSBuild"
Write-Host "  [OK] Package manager updated"

if (-not [string]::IsNullOrEmpty($ConfiguredITAdmin)) {
    Write-Host "  [OK] IT admin hidden from login screen: $ConfiguredITAdmin"
}
if ($RenameRequired) {
    Write-Host "  [OK] Computer rename pending (restart required): $NewComputerName"
}
if (-not [string]::IsNullOrEmpty($ConfiguredNewUser)) {
    Write-Host "  [OK] End user account created: $ConfiguredNewUser"
}
Write-Host "  [OK] Security hardening applied"
Write-Host ""

# Offer to delete setup folder
$DeleteScript = Read-Host "Delete the setup folder (C:\Setup or script directory)? (y/N)"
if ($DeleteScript -ieq 'y') {
    Stop-Transcript
    # Small delay so transcript file is released before deletion
    Start-Sleep -Seconds 1
    Remove-Item -Path $ScriptDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Setup folder removed."
} else {
    Stop-Transcript
    Write-Host "Setup folder kept at: $ScriptDir"
}

# Prompt for restart (needed for computer rename + BitLocker init)
if ($RenameRequired) {
    $Restart = Read-Host "Restart now to apply computer rename? (y/N)"
    if ($Restart -ieq 'y') {
        Restart-Computer -Force
    }
}
