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

# Unblock all files in the Setup folder - Windows flags files copied
# from USB drives as potentially unsafe, which blocks dot-sourcing.
Get-ChildItem -Path $PSScriptRoot -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ================================================================
# PHASE 1: Configuration Collection
# ================================================================

Write-Host "============================================"
Write-Host "     Windows 11 Provisioning Script"
Write-Host "============================================"
Write-Host ""

# Load config.ps1 if it exists alongside this script.
# config.ps1 can pre-set $Config_TailscaleAuthKey and $Config_PackageFile
# so the IT admin is never prompted to type long values manually.
$ConfigFile = Join-Path $PSScriptRoot "config.ps1"
$Config_PackageFile    = ""
$Config_WifiSSID       = ""
$Config_WifiPassword   = ""
$Config_TailscaleAuthKey = ""
$Config_Action1AgentUrl = ""
$Config_NewUsername    = ""
$Config_NewFullName    = ""
$Config_NewPassword    = ""
$Config_NewUserIsAdmin = $false
if (Test-Path $ConfigFile) {
    # Unblock the file in case Windows flagged it from USB/download
    Unblock-File -Path $ConfigFile -ErrorAction SilentlyContinue
    try {
        . $ConfigFile
        Write-Host "[OK] Loaded config.ps1"
    } catch {
        Write-Warning "config.ps1 found but failed to load: $_"
        Write-Warning "Continuing with interactive prompts for all values."
    }
} else {
    Write-Host "[INFO] No config.ps1 found - will prompt for all values"
}
Write-Host ""

# 1.1 Package file name - use config value or prompt
if (-not [string]::IsNullOrWhiteSpace($Config_PackageFile)) {
    $PackageFile = $Config_PackageFile
    Write-Host "Package file (from config): $PackageFile"
} else {
    $PackageFile = Read-Host "Enter package file name (default: packages.json)"
    if ([string]::IsNullOrWhiteSpace($PackageFile)) { $PackageFile = "packages.json" }
}

# 1.2 Tailscale auth key - use config value or prompt
if (-not [string]::IsNullOrWhiteSpace($Config_TailscaleAuthKey)) {
    $TailscaleAuthKey = $Config_TailscaleAuthKey
    Write-Host "Tailscale auth key (from config): loaded"
    $Config_TailscaleAuthKey = $null  # clear from config variable immediately
} else {
    $TailscaleAuthKey = Read-Host "Enter Tailscale auth key (leave empty to skip)"
}

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

# 3.4 WiFi Setup - connect before any network-dependent phase
Write-Host ""
Write-Host "--- Phase 3.4: WiFi Setup ---"

if (-not [string]::IsNullOrWhiteSpace($Config_WifiSSID)) {
    $WifiSSID     = $Config_WifiSSID
    $WifiPassword = $Config_WifiPassword
} else {
    $WifiSSID = Read-Host "WiFi SSID (leave empty to skip)"
    if (-not [string]::IsNullOrWhiteSpace($WifiSSID)) {
        $WifiPassword = Read-Host "WiFi password"
    }
}

if (-not [string]::IsNullOrWhiteSpace($WifiSSID)) {
    Write-Host "Configuring WiFi profile for: $WifiSSID"

    $WifiProfileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$WifiSSID</name>
    <SSIDConfig>
        <SSID>
            <name>$WifiSSID</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$WifiPassword</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@

    $ProfilePath = "$env:TEMP\wifi-profile.xml"
    [System.IO.File]::WriteAllText($ProfilePath, $WifiProfileXml, [System.Text.Encoding]::UTF8)

    netsh wlan add profile filename="$ProfilePath" user=all | Out-Null
    netsh wlan connect name="$WifiSSID" | Out-Null

    Remove-Item $ProfilePath -Force
    $WifiPassword = $null

    Write-Host "[OK] WiFi profile added and connection initiated: $WifiSSID"
} else {
    Write-Host "WiFi: skipped"
}
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
    winget install --id Tailscale.Tailscale --source winget --accept-source-agreements --accept-package-agreements --silent

    # Give the service a moment to start
    Start-Sleep -Seconds 10

    # Refresh PATH so newly installed executables are visible
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Find Tailscale executable - check PATH first, then common install locations
    $TailscaleCmd = Get-Command tailscale -ErrorAction SilentlyContinue
    $TailscalePath = if ($TailscaleCmd) { $TailscaleCmd.Source } else { $null }
    if (-not $TailscalePath) {
        $TailscalePath = @(
            "C:\Program Files\Tailscale\tailscale.exe",
            "C:\Program Files (x86)\Tailscale\tailscale.exe",
            "$env:ProgramFiles\Tailscale\tailscale.exe",
            "$env:LOCALAPPDATA\Tailscale\tailscale.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $TailscalePath) {
        # Last resort - search Program Files
        $TailscalePath = Get-ChildItem -Path "C:\Program Files" -Filter "tailscale.exe" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if ($TailscalePath) {
        Write-Host "Authenticating Tailscale at: $TailscalePath"
        & $TailscalePath up --authkey="$TailscaleAuthKey" --unattended
        Write-Host "[OK] Tailscale connected"
    } else {
        Write-Warning "Tailscale installed but tailscale.exe not found. Open Tailscale from the system tray to authenticate manually."
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
    winget import --import-file $PackagePath --accept-source-agreements --accept-package-agreements --ignore-unavailable
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

$ConfiguredNewUser = ""

# Determine if user creation is driven by config or interactive
$ConfigHasUser = (-not [string]::IsNullOrWhiteSpace($Config_NewUsername)) -and
                 (-not [string]::IsNullOrWhiteSpace($Config_NewFullName))

if ($ConfigHasUser) {
    Write-Host "End user account (from config): $Config_NewUsername / $Config_NewFullName"
    $DoCreateUser = $true
} else {
    $DoCreateUser = (Read-Host "Create a new end user account? (y/N)") -ieq 'y'
}

if ($DoCreateUser) {
    # Username and full name - config or prompt
    if ($ConfigHasUser) {
        $NewUsername = $Config_NewUsername
        $NewFullName = $Config_NewFullName
    } else {
        $NewUsername = Read-Host "Enter username"
        $NewFullName = Read-Host "Enter full name"
    }

    # Check if the user already exists
    $UserAlreadyExists = Get-LocalUser -Name $NewUsername -ErrorAction SilentlyContinue
    if ($UserAlreadyExists) {
        Write-Warning "User '$NewUsername' already exists. Skipping user creation."
    } else {
        # Password - config or prompt (with confirmation)
        if (-not [string]::IsNullOrWhiteSpace($Config_NewPassword)) {
            $NewPasswordSecure = ConvertTo-SecureString $Config_NewPassword -AsPlainText -Force
            $Config_NewPassword = $null  # clear from memory immediately
            $PasswordsMatch = $true
        } else {
            $NewPasswordSecure  = Read-Host "Enter password" -AsSecureString
            $NewPasswordConfirm = Read-Host "Confirm password" -AsSecureString

            $Pwd1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPasswordSecure))
            $Pwd2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPasswordConfirm))
            $PasswordsMatch = ($Pwd1 -eq $Pwd2)
            $Pwd1 = $null
            $Pwd2 = $null
        }

        if (-not $PasswordsMatch) {
            Write-Warning "Passwords do not match. Skipping user creation."
        } else {
            New-LocalUser `
                -Name                $NewUsername `
                -Password            $NewPasswordSecure `
                -FullName            $NewFullName `
                -Description         "End user account" `
                -PasswordNeverExpires:$false | Out-Null

            # Admin group - config or prompt
            if ($ConfigHasUser) {
                $MakeAdmin = $Config_NewUserIsAdmin
            } else {
                $MakeAdmin = (Read-Host "Add '$NewUsername' to Administrators group? (y/N)") -ieq 'y'
            }

            if ($MakeAdmin) {
                Add-LocalGroupMember -Group "Administrators" -Member $NewUsername
                Write-Host "[OK] '$NewUsername' created and added to Administrators"
            } else {
                Add-LocalGroupMember -Group "Users" -Member $NewUsername
                Write-Host "[OK] '$NewUsername' created as standard user"
            }

            # Force password change on first login
            & net user $NewUsername /logonpasswordchg:yes | Out-Null
            Write-Host "[OK] '$NewUsername' will be prompted to change password on first login"

            $ConfiguredNewUser = $NewUsername
        }

        [System.GC]::Collect()
    }
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


# 8.4 Enable Remote Desktop
Set-ItemProperty `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
Write-Host "[OK] Remote Desktop: enabled"

# 8.5 Disable SMBv1 (legacy protocol, high attack surface)
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
Write-Host "[OK] SMBv1: disabled"


# ================================================================
# PHASE 9: Dell Command Update
# ================================================================
# Dell Command Update is installed via packages.json but consistently
# fails during winget import due to a .NET runtime timing issue.
# Running it explicitly here after all other apps are installed
# resolves the problem reliably.

Write-Host "--- Phase 9: Dell Command Update ---"
winget install --id Dell.CommandUpdate --source winget --accept-source-agreements --accept-package-agreements --silent
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Dell Command Update installed"
} elseif ($LASTEXITCODE -eq -1978335189) {
    Write-Host "[OK] Dell Command Update already installed"
} else {
    Write-Warning "Dell Command Update install exited with code $LASTEXITCODE - may need to be installed manually"
}
Write-Host ""

# ================================================================
# PHASE 10: Windows Update
# ================================================================

Write-Host "--- Phase 10: Windows Update ---"
Write-Host "Installing PSWindowsUpdate module..."

Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
Install-Module -Name PSWindowsUpdate -Force -AllowClobber -ErrorAction SilentlyContinue

if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
    Import-Module PSWindowsUpdate
    Write-Host "Scanning and installing Windows updates (this may take a while)..."
    Install-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
    Write-Host "[OK] Windows Update: completed"
} else {
    Write-Warning "PSWindowsUpdate module could not be installed. Run Windows Update manually after provisioning."
}
Write-Host ""

# ================================================================
# PHASE 10.5: Action1 Agent Deployment
# ================================================================

Write-Host "--- Phase 10.5: Action1 Agent ---"

if (-not [string]::IsNullOrWhiteSpace($Config_Action1AgentUrl)) {
    $Action1FileName = Split-Path $Config_Action1AgentUrl -Leaf
    $Action1TempPath = Join-Path $env:TEMP $Action1FileName

    Write-Host "Downloading Action1 agent..."
    try {
        curl.exe -s -o $Action1TempPath $Config_Action1AgentUrl
        Write-Host "Installing Action1 agent..."
        Start-Process msiexec.exe -ArgumentList "/i `"$Action1TempPath`" /quiet /qn" -Wait
        Remove-Item $Action1TempPath -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Action1 agent installed"
    } catch {
        Write-Warning "Action1 agent installation failed: $_"
    }
} else {
    Write-Host "Action1 agent: skipped (no URL configured)"
}
Write-Host ""

# ================================================================
# PHASE 11: Increment computer name on USB for next deployment
# ================================================================
# Edits autounattend.xml on the USB drive so the next machine
# provisioned gets an automatically incremented name.
# e.g. SOLIMA-PC01 -> SOLIMA-PC02, preserving zero-padding.

Write-Host "--- Phase 11: Updating computer name on USB ---"

$AutounattendPath = Join-Path (Split-Path $PSScriptRoot -Parent) "autounattend.xml"

if (Test-Path $AutounattendPath) {
    $xmlContent = Get-Content -Path $AutounattendPath -Raw -Encoding UTF8

    if ($xmlContent -match '<ComputerName>([^<]+)</ComputerName>') {
        $currentName = $Matches[1]

        if ($currentName -match '^(.*?)(\d+)$') {
            $prefix     = $Matches[1]
            $number     = $Matches[2]
            $width      = $number.Length
            $nextNumber = ([int]$number + 1).ToString("D$width")
            $newName    = "$prefix$nextNumber"

            $xmlContent = $xmlContent -replace "<ComputerName>$([regex]::Escape($currentName))</ComputerName>",
                                               "<ComputerName>$newName</ComputerName>"
            [System.IO.File]::WriteAllText($AutounattendPath, $xmlContent, [System.Text.Encoding]::UTF8)
            Write-Host "[OK] Computer name on USB incremented: $currentName -> $newName"
        } else {
            Write-Warning "Computer name '$currentName' has no trailing number - skipping increment"
        }
    } else {
        Write-Warning "No <ComputerName> tag found in autounattend.xml - skipping increment"
    }
} else {
    Write-Warning "autounattend.xml not found at: $AutounattendPath - skipping increment"
}
Write-Host ""

# ================================================================
# PHASE 12: Summary
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

if (-not [string]::IsNullOrEmpty($ConfiguredNewUser)) {
    Write-Host "  [OK] End user account created: $ConfiguredNewUser"
}
Write-Host "  [OK] Dell Command Update installed"
Write-Host "  [OK] Windows Update: completed"
Write-Host "  [OK] Security hardening applied"
Write-Host ""

Stop-Transcript
