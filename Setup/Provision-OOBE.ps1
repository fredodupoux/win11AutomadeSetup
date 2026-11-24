<#
.SYNOPSIS
    Finishes setup on a PC that is sitting at the Windows 11 OOBE screen
    ("Let's set things up for your work or school" / "Who's going to use
    this device?") - unattended, without reinstalling Windows.

.DESCRIPTION
    Run from the OOBE command prompt:
        1. At any OOBE screen press  Shift + F10   (Fn+Shift+F10 on some keyboards)
        2. Type:  D:\Setup\Provision-OOBE.cmd      (use the USB drive letter)

    What it does:
        1. Reads Setup\config.ps1 from the USB
        2. Assigns this PC the next computer name (SAFITEKHT-CS-01, -02, ...).
           Assignments are recorded on the USB in provisioned-machines.csv,
           keyed by MAC address, so re-running on the same PC reuses its name.
        3. Copies only the files this client needs to C:\Setup (admin-only ACL)
        4. Writes an oobeSystem answer file that skips OOBE, creates the IT
           admin account, auto-logs in once and launches
           C:\Setup\Setup.ps1 -Unattended (WiFi, apps, Action1, end user...)
        5. Runs  sysprep /oobe /reboot /unattend:<file>
           No /generalize: Windows, drivers and activation are kept.

    As soon as the PC reboots you can pull the USB and move to the next PC.
    Setup.ps1 removes C:\Setup and the answer files when it finishes.

    Read-only media (ISO mounted through a KVM, CD): the counter and ledger
    cannot be written, so give the PC number instead:
        D:\RUN 3          ->  SAFITEKHT-CS-03   (prefix/padding from config.ps1)
    Without a number it asks for one.

.PARAMETER Name
    PC number (e.g. 3) or full computer name. Overrides the automatic counter.

.PARAMETER SkipSysprep
    Prepare C:\Setup and the answer file but do not run sysprep (testing).
#>
param(
    [Parameter(Position = 0)]
    [string]$Name = '',
    [switch]$SkipSysprep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UsbSetup     = $PSScriptRoot
$ConfigFile   = Join-Path $UsbSetup 'config.ps1'
$LedgerFile   = Join-Path $UsbSetup 'provisioned-machines.csv'
$Target       = 'C:\Setup'
$UnattendPath = Join-Path $Target 'oobe-unattend.xml'
$SysprepExe   = Join-Path $env:WINDIR 'System32\Sysprep\sysprep.exe'

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Escape-Xml([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

# SAFITEKHT-CS-01 -> SAFITEKHT-CS-02 (zero padding kept). $null if no trailing number.
function Get-NextName([string]$Name) {
    if ($Name -match '^(.*?)(\d+)$') {
        $width = $Matches[2].Length
        return $Matches[1] + ([int]$Matches[2] + 1).ToString("D$width")
    }
    return $null
}

# Rewrites the $Config_ComputerName = '...' line of a config file.
function Set-ConfigComputerName([string]$Path, [string]$Name) {
    $text    = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?m)^(\s*\$Config_ComputerName\s*=\s*)[''"][^''"\r\n]*[''"]'
    if ($text -notmatch $pattern) {
        Write-Warning "No `$Config_ComputerName line found in $Path - not updated"
        return
    }
    $safe = $Name -replace "'", "''"
    $text = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + "'" + $safe + "'" })
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::UTF8)
}

Write-Host "============================================"
Write-Host "   OOBE Provisioning - no reinstall"
Write-Host "============================================"
Write-Host ""

# ----------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------

$Principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Must run elevated. Use the Shift+F10 command prompt at the OOBE screen."
}

if (-not (Test-Path $SysprepExe)) {
    Fail "sysprep.exe not found at $SysprepExe. Run this from the installed Windows (OOBE), not from the Windows installer."
}

$OobeInProgress = (Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name OOBEInProgress -ErrorAction SilentlyContinue).OOBEInProgress
if ($OobeInProgress -ne 1) {
    Write-Warning "This PC does not look like it is at the OOBE screen."
    Write-Warning "Running sysprep /oobe on a PC that is already in use will send it back through setup."
    if ((Read-Host "Type YES to continue anyway") -cne 'YES') { Fail "Cancelled." }
}

Get-ChildItem -Path $UsbSetup -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ----------------------------------------------------------------
# Load config
# ----------------------------------------------------------------

$Config_Organization       = ''
$Config_Timezone           = ''
$Config_ITAdminUsername    = ''
$Config_ITAdminDisplayName = ''
$Config_ITAdminPassword    = ''
$Config_ComputerName       = ''
$Config_PackageFile        = ''

if (-not (Test-Path $ConfigFile)) { Fail "config.ps1 not found in $UsbSetup" }
. $ConfigFile
Write-Host "[OK] Loaded config.ps1 ($Config_Organization)"

if ([string]::IsNullOrWhiteSpace($Config_ITAdminUsername) -or [string]::IsNullOrWhiteSpace($Config_ITAdminPassword)) {
    Fail "`$Config_ITAdminUsername and `$Config_ITAdminPassword must be set in config.ps1"
}
if ([string]::IsNullOrWhiteSpace($Config_ITAdminDisplayName)) { $Config_ITAdminDisplayName = $Config_ITAdminUsername }
if ([string]::IsNullOrWhiteSpace($Config_PackageFile))        { $Config_PackageFile = 'packages.json' }

$RequiredFiles = @('Setup.ps1', $Config_PackageFile)
foreach ($f in $RequiredFiles) {
    if (-not (Test-Path (Join-Path $UsbSetup $f))) { Fail "$f not found in $UsbSetup" }
}

# ----------------------------------------------------------------
# Computer name - ledger on the USB, keyed by MAC address
# ----------------------------------------------------------------

$Macs = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
          ForEach-Object { $_.MacAddress } | Where-Object { $_ } | Sort-Object -Unique)
$Serial = (Get-CimInstance Win32_BIOS).SerialNumber
$CS     = Get-CimInstance Win32_ComputerSystem
$HardwareId = if ($Macs.Count -gt 0) { $Macs -join ';' } else { "SERIAL:$Serial" }

# Writable source (USB) or read-only (ISO / CD through a KVM)?
$Writable = $true
try {
    $probe = Join-Path $UsbSetup '.write-test'
    [System.IO.File]::WriteAllText($probe, 'x')
    Remove-Item $probe -Force
} catch { $Writable = $false }

# "3" -> SAFITEKHT-CS-03 using the prefix/padding of $Config_ComputerName; full names pass through.
function Resolve-ComputerName([string]$Value) {
    $Value = $Value.Trim()
    if ($Value -match '^\d+$') {
        if ($Config_ComputerName -notmatch '^(.*?)(\d+)$') {
            Fail "Got PC number '$Value' but `$Config_ComputerName ('$Config_ComputerName') has no trailing number to use as a pattern."
        }
        $Value = $Matches[1] + ([int]$Value).ToString("D$($Matches[2].Length)")
    }
    $Value = $Value.ToUpper()
    if ($Value.Length -gt 15 -or $Value -notmatch '^[A-Z0-9-]+$' -or $Value -match '^\d+$') {
        Fail "Invalid computer name '$Value' (max 15 chars, letters/numbers/hyphens, not all digits)."
    }
    return $Value
}

$Rows = @()
if (Test-Path $LedgerFile) { $Rows = @(Import-Csv -Path $LedgerFile) }
$UsedNames = @($Rows | ForEach-Object { $_.ComputerName })
$Existing  = $Rows | Where-Object { $_.HardwareId -eq $HardwareId } | Select-Object -First 1

if (-not $Writable -and -not $Name) {
    Write-Host ""
    Write-Host "Setup media is read-only (ISO/CD) - the name counter can't be saved." -ForegroundColor Yellow
    $example = if ($Config_ComputerName) { " (e.g. 3 -> $(Resolve-ComputerName '3'))" } else { '' }
    while (-not $Name) { $Name = Read-Host "PC number or full computer name$example" }
}

if ($Name) {
    $ComputerName = Resolve-ComputerName $Name
    Write-Host "[OK] Computer name: $ComputerName"
    if ($Writable) {
        [PSCustomObject]@{
            Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); ComputerName = $ComputerName; Serial = $Serial
            Manufacturer = $CS.Manufacturer; Model = $CS.Model; HardwareId = $HardwareId
        } | Export-Csv -Path $LedgerFile -Append -NoTypeInformation
    }
} elseif ($Existing) {
    $ComputerName = $Existing.ComputerName
    Write-Host "[OK] This PC was already assigned a name: $ComputerName (reusing it)"
} elseif ([string]::IsNullOrWhiteSpace($Config_ComputerName)) {
    $ComputerName = ''
    Write-Warning "No `$Config_ComputerName in config.ps1 - PC keeps its current name"
} else {
    $ComputerName = $Config_ComputerName
    # Skip names already handed out (e.g. config.ps1 restored from an older copy)
    while ($UsedNames -contains $ComputerName) {
        $next = Get-NextName $ComputerName
        if (-not $next) { Fail "Computer name '$ComputerName' is already used and has no trailing number to increment." }
        $ComputerName = $next
    }
    if ($ComputerName.Length -gt 15) { Fail "Computer name '$ComputerName' is longer than 15 characters." }

    [PSCustomObject]@{
        Date         = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        ComputerName = $ComputerName
        Serial       = $Serial
        Manufacturer = $CS.Manufacturer
        Model        = $CS.Model
        HardwareId   = $HardwareId
    } | Export-Csv -Path $LedgerFile -Append -NoTypeInformation

    $NextName = Get-NextName $ComputerName
    if ($NextName) {
        Set-ConfigComputerName -Path $ConfigFile -Name $NextName
        Write-Host "[OK] Computer name: $ComputerName  (next PC will get $NextName)"
    } else {
        Write-Warning "Computer name '$ComputerName' has no trailing number - the next PC would get the same name."
    }
}

# ----------------------------------------------------------------
# Stage C:\Setup (only this client's files, admin-only)
# ----------------------------------------------------------------

New-Item -ItemType Directory -Path $Target -Force | Out-Null
icacls $Target /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" | Out-Null

$StageFiles = @('Setup.ps1', $Config_PackageFile, 'installers.json')
foreach ($f in $StageFiles) {
    $src = Join-Path $UsbSetup $f
    if (Test-Path $src) { Copy-Item -Path $src -Destination $Target -Force }
}
Copy-Item -Path $ConfigFile -Destination (Join-Path $Target 'config.ps1') -Force
# Files copied from an ISO keep the read-only flag, which breaks editing and cleanup.
Get-ChildItem -Path $Target -File | ForEach-Object { $_.IsReadOnly = $false }
if ($ComputerName) {
    # The USB copy now holds the NEXT name; this PC's copy gets its own name.
    Set-ConfigComputerName -Path (Join-Path $Target 'config.ps1') -Name $ComputerName
}
# Tells Setup.ps1 it was launched by this flow: clean up + reboot at the end.
Set-Content -Path (Join-Path $Target '.oobe-provisioned') -Value (Get-Date -Format o)
Write-Host "[OK] Provisioning files staged in $Target"

# ----------------------------------------------------------------
# oobeSystem answer file
# ----------------------------------------------------------------

$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$Comp = "processorArchitecture=`"$Arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`""

$AdminUser = Escape-Xml $Config_ITAdminUsername
$AdminName = Escape-Xml $Config_ITAdminDisplayName
$AdminPass = Escape-Xml $Config_ITAdminPassword
$OrgXml    = if ($Config_Organization) { "<RegisteredOrganization>$(Escape-Xml $Config_Organization)</RegisteredOrganization>" } else { '' }
$TzXml     = if ($Config_Timezone)     { "<TimeZone>$(Escape-Xml $Config_Timezone)</TimeZone>" } else { '' }

# 'start' returns immediately so the first logon is not blocked; the
# PowerShell window stays open (-NoExit) so errors remain visible.
$LaunchCmd = Escape-Xml "cmd.exe /c start `"Provisioning`" powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$Target\Setup.ps1`" -Unattended"

$UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $Comp>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $Comp>
      $OrgXml
      $TzXml
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
        <UnattendEnableRetailDemo>false</UnattendEnableRetailDemo>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$AdminUser</Name>
            <DisplayName>$AdminName</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$AdminPass</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$AdminUser</Username>
        <LogonCount>1</LogonCount>
        <Password>
          <Value>$AdminPass</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$LaunchCmd</CommandLine>
          <Description>Run Setup.ps1 unattended</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@

[System.IO.File]::WriteAllText($UnattendPath, $UnattendXml, (New-Object System.Text.UTF8Encoding $false))
$Config_ITAdminPassword = $null
$AdminPass = $null
Write-Host "[OK] Answer file written: $UnattendPath"

# ----------------------------------------------------------------
# Make the one-time auto-logon work
# ----------------------------------------------------------------
# Windows 11's "only allow Windows Hello sign-in" (passwordless) setting is on
# by default and silently blocks password auto-logon, even for local accounts.
$PwdLess = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
New-Item -Path $PwdLess -Force | Out-Null
Set-ItemProperty -Path $PwdLess -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
# Never hide the IT admin account from the sign-in screen
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' `
    -Name $Config_ITAdminUsername -ErrorAction SilentlyContinue
Write-Host "[OK] Passwordless-only sign-in disabled (allows the one-time auto-logon)"

if ($SkipSysprep) {
    Write-Host ""
    Write-Host "-SkipSysprep: stopping here. To continue manually run:"
    Write-Host "  $SysprepExe /oobe /reboot /quiet /unattend:$UnattendPath"
    exit 0
}

# ----------------------------------------------------------------
# Sysprep /oobe (no generalize)
# ----------------------------------------------------------------

function Invoke-Sysprep {
    Get-Process -Name sysprep -ErrorAction SilentlyContinue | Stop-Process -Force
    # Reset state left behind by a previous failed run
    $st = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'
    if (Test-Path $st) {
        Set-ItemProperty -Path $st -Name GeneralizationState -Value 7 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $st -Name CleanupState        -Value 2 -ErrorAction SilentlyContinue
    }
    $p = Start-Process -FilePath $SysprepExe -ArgumentList '/oobe', '/reboot', '/quiet', "/unattend:$UnattendPath" -Wait -PassThru
    return $p.ExitCode
}

Write-Host ""
Write-Host "Running sysprep /oobe - the PC will reboot and finish setup on its own."
$code = Invoke-Sysprep

if ($code -ne 0) {
    Write-Warning "sysprep exited with code $code"

    # BitLocker / device encryption blocks sysprep - decrypt and retry once
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    if ($bl -and $bl.VolumeStatus -ne 'FullyDecrypted') {
        Write-Host "C: is encrypted ($($bl.VolumeStatus)). Decrypting so sysprep can run - this takes a few minutes..."
        Disable-BitLocker -MountPoint 'C:' | Out-Null
        do {
            Start-Sleep -Seconds 15
            $bl = Get-BitLockerVolume -MountPoint 'C:'
            Write-Host ("  {0}% encrypted remaining" -f $bl.EncryptionPercentage)
        } while ($bl.VolumeStatus -ne 'FullyDecrypted')
        Write-Host "Retrying sysprep..."
        $code = Invoke-Sysprep
    }
}

if ($code -eq 0) {
    Write-Host "[OK] Sysprep accepted the answer file - rebooting. You can remove the USB / unmount the ISO now."
    exit 0
}

$ErrLog = Join-Path $env:WINDIR 'System32\Sysprep\Panther\setuperr.log'
Write-Host ""
Write-Host "Sysprep failed (exit code $code). Last lines of $($ErrLog):" -ForegroundColor Red
if (Test-Path $ErrLog) { Get-Content $ErrLog -Tail 15 }
Write-Host ""
Write-Host "Fallback: close this window, finish OOBE by hand with a local account named"
Write-Host "'$Config_ITAdminUsername', then run as Administrator:"
Write-Host "  powershell -ExecutionPolicy Bypass -File C:\Setup\Setup.ps1 -Unattended"
exit 1
