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
    - -Unattended: never prompt. Anything missing from config.ps1 is skipped.
      Provision-OOBE.ps1 launches it this way after first logon.

.PARAMETER Unattended
    Do not prompt for anything; skip steps whose values are not in config.ps1.
#>
param(
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Unblock all files in the Setup folder - Windows flags files copied
# from USB drives as potentially unsafe, which blocks dot-sourcing.
Get-ChildItem -Path $PSScriptRoot -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# Present when Provision-OOBE.ps1 staged this folder: enables cleanup + reboot at the end.
$OobeMode = Test-Path (Join-Path $PSScriptRoot '.oobe-provisioned')

# Read-Host that returns $Default instead of prompting when -Unattended.
function Ask([string]$Prompt, [string]$Default = "") {
    if ($Unattended) { return $Default }
    return Read-Host $Prompt
}

# winget is registered for a new profile a few minutes after first logon.
function Wait-Winget([int]$TimeoutSeconds = 600) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
        Write-Host "  waiting for winget to be registered..."
        Start-Sleep -Seconds 20
    }
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Wait-Internet([int]$TimeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
            if ($r.Content -like 'Microsoft Connect Test*') { return $true }
        } catch { }
        Write-Host "  waiting for internet..."
        Start-Sleep -Seconds 10
    }
    return $false
}

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
$Config_Organization       = ""
$Config_Timezone           = ""
$Config_ITAdminUsername    = ""
$Config_ITAdminDisplayName = ""
$Config_ITAdminPassword    = ""
$Config_ComputerName       = ""
$Config_PackageFile        = ""
$Config_WifiSSID           = ""
$Config_WifiPassword       = ""
$Config_TailscaleAuthKey   = ""
$Config_Action1AgentUrl    = ""
$Config_NewUsername        = ""
$Config_NewFullName        = ""
$Config_NewPassword        = ""
$Config_NewUserIsAdmin     = $false
$ITAdminAutoLogonPassword  = ""
if (Test-Path $ConfigFile) {
    # Unblock the file in case Windows flagged it from USB/download
    Unblock-File -Path $ConfigFile -ErrorAction SilentlyContinue
    try {
        . $ConfigFile
        Write-Host "[OK] Loaded config.ps1"
        # Kept for the permanent IT admin auto-logon at the end (Phase 12.5);
        # $Config_ITAdminPassword itself is cleared once the account is created.
        $ITAdminAutoLogonPassword = $Config_ITAdminPassword
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
    $PackageFile = Ask "Enter package file name (default: packages.json)"
    if ([string]::IsNullOrWhiteSpace($PackageFile)) { $PackageFile = "packages.json" }
}

# 1.2 Tailscale auth key - use config value or prompt
if (-not [string]::IsNullOrWhiteSpace($Config_TailscaleAuthKey)) {
    $TailscaleAuthKey = $Config_TailscaleAuthKey
    Write-Host "Tailscale auth key (from config): loaded"
    $Config_TailscaleAuthKey = $null  # clear from config variable immediately
} else {
    $TailscaleAuthKey = Ask "Enter Tailscale auth key (leave empty to skip)"
}

# 1.3 Action1 agent URL - use config value or prompt
if (-not [string]::IsNullOrWhiteSpace($Config_Action1AgentUrl)) {
    Write-Host "Action1 agent URL (from config): loaded"
} else {
    $Config_Action1AgentUrl = Ask "Enter Action1 agent MSI URL (leave empty to skip)"
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
    Write-Warning "winget not found yet. Registering App Installer and waiting (up to 10 min)..."
    # winget ships with Windows 11 but is registered asynchronously for a new profile
    if (-not (Wait-Winget)) {
        Write-Error "winget still not available. Install 'App Installer' from the Microsoft Store and re-run."
        Stop-Transcript
        exit 1
    }
}
Write-Host "[OK] winget available"

# 3.4 System Configuration - mirrors what autounattend.xml applies during install
Write-Host ""
Write-Host "--- Phase 3.4: System Configuration ---"

$RebootRequired = $false

if (-not [string]::IsNullOrWhiteSpace($Config_ComputerName)) {
    if ($env:COMPUTERNAME -ne $Config_ComputerName) {
        Rename-Computer -NewName $Config_ComputerName -Force -ErrorAction SilentlyContinue
        $RebootRequired = $true
        Write-Host "[OK] Computer renamed: $($env:COMPUTERNAME) -> $Config_ComputerName (reboot required)"
    } else {
        Write-Host "[OK] Computer name already correct: $Config_ComputerName"
    }
} else {
    Write-Host "Computer name: skipped (not configured)"
}

if (-not [string]::IsNullOrWhiteSpace($Config_Timezone)) {
    Set-TimeZone -Id $Config_Timezone
    Write-Host "[OK] Timezone: $Config_Timezone"
} else {
    Write-Host "Timezone: skipped (not configured)"
}

if (-not [string]::IsNullOrWhiteSpace($Config_Organization)) {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
        -Name "RegisteredOrganization" -Value $Config_Organization
    Write-Host "[OK] Registered organization: $Config_Organization"
} else {
    Write-Host "Registered organization: skipped (not configured)"
}

# 3.5 WiFi Setup - connect before any network-dependent phase
Write-Host ""
Write-Host "--- Phase 3.5: WiFi Setup ---"

if (-not [string]::IsNullOrWhiteSpace($Config_WifiSSID)) {
    $WifiSSID     = $Config_WifiSSID
    $WifiPassword = $Config_WifiPassword
} else {
    $WifiSSID = Ask "WiFi SSID (leave empty to skip)"
    if (-not [string]::IsNullOrWhiteSpace($WifiSSID)) {
        $WifiPassword = Read-Host "WiFi password"
    }
}

if (-not [string]::IsNullOrWhiteSpace($WifiSSID)) {
    Write-Host "Configuring WiFi profile for: $WifiSSID"

    $SsidXml = [System.Security.SecurityElement]::Escape($WifiSSID)
    $KeyXml  = [System.Security.SecurityElement]::Escape($WifiPassword)
    $WifiProfileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$SsidXml</name>
    <SSIDConfig>
        <SSID>
            <name>$SsidXml</name>
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
                <keyMaterial>$KeyXml</keyMaterial>
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
    $KeyXml = $null

    Write-Host "[OK] WiFi profile added and connection initiated: $WifiSSID"
} else {
    Write-Host "WiFi: skipped"
}

if (Wait-Internet) {
    Write-Host "[OK] Internet connection available"
} else {
    Write-Warning "No internet after 3 minutes - downloads below will likely fail. Check WiFi/Ethernet."
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

# 6.5 Apps that are not in winget: direct-download installers (machine-wide)
# and web apps (Chrome --app shortcuts for all users). No Microsoft Store.
# Both come from installers.json next to this script.
$InstallersFile = Join-Path $ScriptDir 'installers.json'
$Installers = @(); $WebApps = @()
if (Test-Path $InstallersFile) {
    $InstallersJson = Get-Content -Path $InstallersFile -Raw | ConvertFrom-Json
    if ($InstallersJson.PSObject.Properties['installers']) { $Installers = @($InstallersJson.installers) }
    if ($InstallersJson.PSObject.Properties['webApps'])    { $WebApps    = @($InstallersJson.webApps) }
}

foreach ($inst in $Installers) {
    Write-Host "Installing $($inst.name) (direct download)..."
    try {
        $FileName = [System.Uri]::UnescapeDataString((Split-Path $inst.url -Leaf))
        $TempPath = Join-Path $env:TEMP $FileName
        curl.exe -fsSL -o $TempPath $inst.url
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit code $LASTEXITCODE)" }
        $InstArgs = if ($inst.PSObject.Properties['args']) { [string]$inst.args } else { '' }
        if ($TempPath -like '*.msi') {
            $Proc = Start-Process msiexec.exe -ArgumentList "/i `"$TempPath`" /qn $InstArgs" -Wait -PassThru
        } elseif ($InstArgs) {
            $Proc = Start-Process -FilePath $TempPath -ArgumentList $InstArgs -Wait -PassThru
        } else {
            $Proc = Start-Process -FilePath $TempPath -Wait -PassThru
        }
        Remove-Item $TempPath -Force -ErrorAction SilentlyContinue
        if ($Proc.ExitCode -notin 0, 3010) { throw "installer exit code $($Proc.ExitCode)" }
        Write-Host "[OK] $($inst.name) installed"
    } catch {
        Write-Warning "$($inst.name) installation failed: $_"
    }
}

if ($WebApps.Count -gt 0) {
    $Chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Chrome) {
        Write-Warning "Chrome not found - web app shortcuts skipped"
    } else {
        $IconDir = Join-Path $env:ProgramData 'Provisioning\icons'
        New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
        $Shell = New-Object -ComObject WScript.Shell
        $ShortcutDirs = @([Environment]::GetFolderPath('CommonDesktopDirectory'),
                          [Environment]::GetFolderPath('CommonPrograms'))
        foreach ($app in $WebApps) {
            $Icon = "$Chrome,0"
            if ($app.PSObject.Properties['icon']) {
                $IconPath = Join-Path $IconDir "$($app.name).ico"
                curl.exe -fsSL -o $IconPath $app.icon
                if ($LASTEXITCODE -eq 0) { $Icon = "$IconPath,0" }
            }
            foreach ($dir in $ShortcutDirs) {
                $lnk = $Shell.CreateShortcut((Join-Path $dir "$($app.name).lnk"))
                $lnk.TargetPath   = $Chrome
                $lnk.Arguments    = "--app=$($app.url)"
                $lnk.IconLocation = $Icon
                $lnk.Description  = $app.name
                $lnk.Save()
            }
            Write-Host "[OK] $($app.name) web app shortcut (all users): $($app.url)"
        }
    }
}
Write-Host ""

# ================================================================
# PHASE 7: User Management
# ================================================================

Write-Host "--- Phase 7: User Management ---"

# 7.0 IT admin account - mirrors the local account autounattend.xml creates during OOBE
if (-not [string]::IsNullOrWhiteSpace($Config_ITAdminUsername)) {
    $ITAdminExists = Get-LocalUser -Name $Config_ITAdminUsername -ErrorAction SilentlyContinue
    if ($ITAdminExists) {
        Write-Host "[OK] IT admin account already exists: $Config_ITAdminUsername"
    } elseif ([string]::IsNullOrWhiteSpace($Config_ITAdminPassword)) {
        Write-Warning "IT admin username configured but no password set - skipping account creation"
    } else {
        $ITAdminPassSecure = ConvertTo-SecureString $Config_ITAdminPassword -AsPlainText -Force
        $Config_ITAdminPassword = $null
        New-LocalUser `
            -Name                $Config_ITAdminUsername `
            -Password            $ITAdminPassSecure `
            -FullName            $Config_ITAdminDisplayName `
            -Description         "IT admin account" `
            -PasswordNeverExpires:$true | Out-Null
        Add-LocalGroupMember -Group "Administrators" -Member $Config_ITAdminUsername
        [System.GC]::Collect()
        Write-Host "[OK] IT admin account created: $Config_ITAdminUsername"
    }

    # Keep the IT admin account enabled and VISIBLE on the sign-in screen
    # (a 0 under SpecialAccounts\UserList hides an account).
    if (Get-LocalUser -Name $Config_ITAdminUsername -ErrorAction SilentlyContinue) {
        Enable-LocalUser -Name $Config_ITAdminUsername -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' `
            -Name $Config_ITAdminUsername -ErrorAction SilentlyContinue
        Write-Host "[OK] IT admin account is enabled and shown on the sign-in screen"
    }
}
Write-Host ""

$ConfiguredNewUser = ""

# Determine if user creation is driven by config or interactive
$ConfigHasUser = (-not [string]::IsNullOrWhiteSpace($Config_NewUsername)) -and
                 (-not [string]::IsNullOrWhiteSpace($Config_NewFullName))

if ($ConfigHasUser) {
    Write-Host "End user account (from config): $Config_NewUsername / $Config_NewFullName"
    $DoCreateUser = $true
} else {
    $DoCreateUser = (Ask "Create a new end user account? (y/N)" "n") -ieq 'y'
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
        } elseif ($Unattended) {
            Write-Warning "No `$Config_NewPassword in config.ps1 - cannot create '$NewUsername' unattended."
            $PasswordsMatch = $false
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
            Write-Warning "No usable password. Skipping user creation."
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

# Remove the per-user Store-app task left by earlier versions of this script
Unregister-ScheduledTask -TaskName 'Provisioning - Per-user apps' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $env:ProgramData 'Provisioning\Install-UserApps.ps1'),
                  (Join-Path $env:ProgramData 'Provisioning\user-apps.json') -Force -ErrorAction SilentlyContinue

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
$Manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
$IsDell = $Manufacturer -like '*Dell*'
if (-not $IsDell) {
    Write-Host "Dell Command Update: skipped (manufacturer: $Manufacturer)"
} else {
    winget install --id Dell.CommandUpdate --source winget --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Dell Command Update installed"
    } elseif ($LASTEXITCODE -eq -1978335189) {
        Write-Host "[OK] Dell Command Update already installed"
    } else {
        Write-Warning "Dell Command Update install exited with code $LASTEXITCODE - may need to be installed manually"
    }
}
Write-Host ""

# ================================================================
# PHASE 10: Action1 Agent Deployment
# ================================================================

Write-Host "--- Phase 10: Action1 Agent ---"

if (-not [string]::IsNullOrWhiteSpace($Config_Action1AgentUrl)) {
    $Action1FileName = Split-Path $Config_Action1AgentUrl -Leaf
    $Action1TempPath = Join-Path $env:TEMP $Action1FileName

    Write-Host "Downloading Action1 agent..."
    try {
        curl.exe -fsSL -o $Action1TempPath $Config_Action1AgentUrl
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit code $LASTEXITCODE)" }
        Write-Host "Installing Action1 agent..."
        $Action1Proc = Start-Process msiexec.exe -ArgumentList "/i `"$Action1TempPath`" /quiet /qn" -Wait -PassThru
        Remove-Item $Action1TempPath -Force -ErrorAction SilentlyContinue
        if ($Action1Proc.ExitCode -notin 0, 3010) { throw "msiexec exit code $($Action1Proc.ExitCode)" }
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

if ($OobeMode) {
    Write-Host "Skipped - Provision-OOBE.ps1 already assigned the name and advanced the counter on the USB"
} elseif (Test-Path $AutounattendPath) {
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
# PHASE 11.5: Windows Update (last - slowest step)
# ================================================================
# Runs after everything else so apps, Action1 and the user account are
# in place even if updates take an hour or fail.

# Never let an update failure stop the script: cleanup + reboot must still run.
# 0x80248007 (WU_E_DS_NODATA) shows up when Windows' own automatic update run
# is busy at the same time, or on some driver updates - so wait for it, retry
# without drivers, and as a last resort hand off to Windows' built-in updater.

Write-Host "--- Phase 11.5: Windows Update ---"
$WUStatus = "not run"

function Wait-WindowsUpdateIdle([int]$TimeoutSeconds = 900) {
    # Wait while Windows' own update session is installing
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $installer = New-Object -ComObject Microsoft.Update.Installer
    while ($installer.IsBusy -and (Get-Date) -lt $deadline) {
        Write-Host "  Windows is already installing updates - waiting..."
        Start-Sleep -Seconds 30
    }
}

try {
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Host "Installing PSWindowsUpdate module..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -AllowClobber -ErrorAction SilentlyContinue
    }
    Import-Module PSWindowsUpdate -ErrorAction Stop

    $Attempts = @(
        @{ Label = 'all updates';             Params = @{} },
        @{ Label = 'all updates (retry)';     Params = @{} },
        @{ Label = 'software only (no drivers)'; Params = @{ NotCategory = 'Drivers' } }
    )
    foreach ($a in $Attempts) {
        Wait-WindowsUpdateIdle
        Write-Host "Installing Windows updates: $($a.Label) (this may take a while)..."
        try {
            $p = $a.Params
            Install-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop @p | Out-Host
            $WUStatus = "installed ($($a.Label))"
            break
        } catch {
            Write-Warning "Windows Update attempt failed ($($a.Label)): $($_.Exception.Message)"
            Start-Sleep -Seconds 60
        }
    }
} catch {
    Write-Warning "PSWindowsUpdate unavailable: $($_.Exception.Message)"
}

if ($WUStatus -eq "not run") {
    # Hand off to the built-in updater; it keeps going in the background and
    # finishes at the reboot below / during normal use.
    try { Start-Process -FilePath "$env:WINDIR\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan' -ErrorAction Stop } catch { }
    $WUStatus = "handed off to Windows Update (finishes in background)"
    Write-Warning "Could not install updates directly - Windows Update will finish them on its own."
} else {
    Write-Host "[OK] Windows Update: $WUStatus"
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
if ($IsDell) { Write-Host "  [OK] Dell Command Update installed" }
Write-Host "  [OK] Windows Update: $WUStatus"
Write-Host "  [OK] Security hardening applied"
if ($RebootRequired -and -not $OobeMode) {
    Write-Host ""
    Write-Host "  [!] REBOOT REQUIRED: computer name change will take effect after restart"
}
Write-Host ""

# ================================================================
# PHASE 12.5: Permanent IT admin auto-logon (Sysinternals Autologon)
# ================================================================
# Autologon.exe stores the password encrypted (LSA secret) instead of in
# plain text in the registry. No logon count: the IT admin signs in
# automatically after every reboot until this is turned off.
# To turn it off later:  reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f

$Winlogon       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$AutologonExe   = Join-Path $PSScriptRoot 'Autologon.exe'
$AutoLogonSet   = $false

# Plain-text password / one-time count left by the answer file
Remove-ItemProperty -Path $Winlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue

if ((Test-Path $AutologonExe) -and $Config_ITAdminUsername -and $ITAdminAutoLogonPassword) {
    Write-Host "--- Phase 12.5: IT admin auto-logon ---"
    # Local account: the "domain" is the computer name (the new one if a rename is pending)
    $LogonDomain = if ($Config_ComputerName) { $Config_ComputerName } else { $env:COMPUTERNAME }
    $AutologonArgs = '-accepteula "{0}" "{1}" "{2}"' -f $Config_ITAdminUsername, $LogonDomain, ($ITAdminAutoLogonPassword -replace '"', '\"')
    $AutologonProc = Start-Process -FilePath $AutologonExe -ArgumentList $AutologonArgs -Wait -PassThru
    $AutologonArgs = $null

    $wl = Get-ItemProperty -Path $Winlogon
    if ($wl.AutoAdminLogon -eq '1' -and $wl.DefaultUserName -eq $Config_ITAdminUsername) {
        $AutoLogonSet = $true
        Write-Host "[OK] '$Config_ITAdminUsername' will sign in automatically after every reboot"
    } else {
        Write-Warning "Autologon.exe (exit code $($AutologonProc.ExitCode)) did not enable auto-logon for '$Config_ITAdminUsername'"
    }
} elseif ($OobeMode) {
    Write-Host "Auto-logon: Autologon.exe not found - sign-in screen after reboot"
}
if (-not $AutoLogonSet -and $OobeMode) {
    Set-ItemProperty -Path $Winlogon -Name AutoAdminLogon -Value '0'
}
$ITAdminAutoLogonPassword = $null
Write-Host ""

# ================================================================
# PHASE 13: Cleanup + reboot (OOBE flow only)
# ================================================================
# C:\Setup and the answer files hold plain-text passwords. Remove them
# and reboot.

if ($OobeMode) {
    Write-Host "--- Phase 13: Cleanup ---"

    @(
        "$env:WINDIR\Panther\unattend.xml",
        "$env:WINDIR\Panther\Unattend\unattend.xml",
        "$env:WINDIR\System32\Sysprep\unattend.xml",
        (Join-Path $PSScriptRoot 'oobe-unattend.xml'),
        (Join-Path $PSScriptRoot 'config.ps1')
    ) | ForEach-Object { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
    Write-Host "[OK] Answer files and config.ps1 removed"

    # This script is still running from the folder - delete the rest at next boot.
    $CleanAction = New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument "/c rmdir /s /q `"$PSScriptRoot`" & schtasks /delete /tn ProvisioningCleanup /f"
    $CleanPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'ProvisioningCleanup' -Action $CleanAction `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $CleanPrincipal -Force | Out-Null
    Write-Host "[OK] $PSScriptRoot will be deleted at next boot"

    Write-Host ""
    Write-Host "Rebooting in 2 minutes (run 'shutdown /a' to cancel)." -ForegroundColor Green
    shutdown.exe /r /t 120 /c "Provisioning complete - restarting."
}

Stop-Transcript
