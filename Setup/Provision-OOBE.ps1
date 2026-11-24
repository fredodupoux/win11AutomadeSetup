<#
.SYNOPSIS
    Finishes setup on a PC sitting at the Windows 11 OOBE screen - unattended,
    without reinstalling Windows.

.DESCRIPTION
    Run from the OOBE command prompt (Shift+F10):
        D:\RUN 3                       (provisioning ISO; 3 = PC number)
        D:\Setup\Provision-OOBE.cmd    (USB stick; picks the next free number)

    1. Reads client.json / secrets.json next to this script (built by the UI)
    2. Computer name = the batch's name pattern + PC number (SAFITEKHT-CS-## + 3 -> SAFITEKHT-CS-03).
       On a writable USB stick, numbers are recorded in provisioned-machines.csv (keyed by MAC),
       so re-running on the same PC reuses its number and new PCs get the next one.
    3. Copies this client's files to C:\Setup (Administrators only)
    4. Writes an oobeSystem answer file: skip OOBE, create the IT admin, sign in ONCE,
       run C:\Setup\Setup.ps1 (which turns auto sign-in off again at the end)
    5. sysprep /oobe /reboot /unattend:<file>   (no /generalize: Windows, drivers, activation kept)

    Windows PowerShell 5.1 compatible.

.PARAMETER Name
    PC number (e.g. 3) or a full computer name.

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

$Media        = $PSScriptRoot
$LedgerFile   = Join-Path $Media 'provisioned-machines.csv'
$Target       = 'C:\Setup'
$UnattendPath = Join-Path $Target 'oobe-unattend.xml'
$SysprepExe   = Join-Path $env:WINDIR 'System32\Sysprep\sysprep.exe'

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Get-Cfg($Obj, [string]$Path, $Default = $null) {
    $cur = $Obj
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$p]
        if ($prop) { $cur = $prop.Value } else { return $Default }
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Escape-Xml([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

function Format-Name([string]$Pattern, [int]$Number) {
    if ($Pattern -match '#+') {
        $h = $Matches[0]
        return $Pattern.Replace($h, $Number.ToString("D$($h.Length)")).ToUpper()
    }
    return $Pattern.ToUpper()
}

Write-Host '============================================'
Write-Host '   OOBE provisioning - no reinstall'
Write-Host '============================================'
Write-Host ''

# ----------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'Must run elevated. Use the Shift+F10 command prompt at the OOBE screen.'
}
if (-not (Test-Path $SysprepExe)) {
    Fail "sysprep.exe not found at $SysprepExe. Run this from the installed Windows (OOBE), not from the Windows installer."
}
$oobe = (Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name OOBEInProgress -ErrorAction SilentlyContinue)
if (-not $oobe -or $oobe.OOBEInProgress -ne 1) {
    Write-Warning 'This PC does not look like it is at the OOBE screen.'
    Write-Warning 'Running this on a PC that is already in use sends it back through setup.'
    if ((Read-Host 'Type YES to continue anyway') -cne 'YES') { Fail 'Cancelled.' }
}

Get-ChildItem -Path $Media -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ----------------------------------------------------------------
# Load client
# ----------------------------------------------------------------

$clientFile  = Join-Path $Media 'client.json'
$secretsFile = Join-Path $Media 'secrets.json'
if (-not (Test-Path $clientFile))  { Fail "client.json not found in $Media - rebuild the media with the provisioning UI." }
if (-not (Test-Path $secretsFile)) { Fail "secrets.json not found in $Media - rebuild the media with the provisioning UI." }
$Client  = Get-Content $clientFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Secrets = Get-Content $secretsFile -Raw -Encoding UTF8 | ConvertFrom-Json

$org       = [string](Get-Cfg $Client 'organization' '')
$adminUser = [string](Get-Cfg $Client 'itAdmin.username' '')
$adminName = [string](Get-Cfg $Client 'itAdmin.displayName' $adminUser)
$adminPass = [string](Get-Cfg $Secrets 'itAdminPassword' '')
$pattern   = [string](Get-Cfg $Client 'computerNamePattern' '')
$first     = [int](Get-Cfg $Client 'build.start' 1)
$last      = [int](Get-Cfg $Client 'build.end' 1)
if (-not $adminUser -or -not $adminPass) { Fail 'IT admin username/password missing - fix the client in the provisioning UI.' }
Write-Host "[OK] $org - batch '$(Get-Cfg $Client 'build.batchName' '(none)')', PCs $first to $last ($pattern)"

# ----------------------------------------------------------------
# Computer name
# ----------------------------------------------------------------

$writable = $true
try {
    $probe = Join-Path $Media '.write-test'
    [System.IO.File]::WriteAllText($probe, 'x')
    Remove-Item $probe -Force
} catch { $writable = $false }

$macs = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.MacAddress } | Where-Object { $_ } | Sort-Object -Unique)
$serial = [string](Get-CimInstance Win32_BIOS).SerialNumber
$cs = Get-CimInstance Win32_ComputerSystem
$hardwareId = if ($macs.Count -gt 0) { $macs -join ';' } else { "SERIAL:$serial" }

$rows = @()
if ($writable -and (Test-Path $LedgerFile)) { $rows = @(Import-Csv -Path $LedgerFile) }
$existing = $rows | Where-Object { $_.HardwareId -eq $hardwareId } | Select-Object -First 1

if (-not $Name -and $existing) {
    $Name = [string]$existing.Number
    Write-Host "[OK] This PC already had number $Name on this USB stick - reusing it"
}
if (-not $Name -and $writable -and $pattern -match '#') {
    $used = @($rows | ForEach-Object { [int]$_.Number })
    $n = $first
    while ($used -contains $n) { $n++ }
    $Name = [string]$n
    Write-Host "[OK] Next free number on this USB stick: $n"
}
while (-not $Name) {
    Write-Host ''
    if ($pattern -match '#') { $Name = Read-Host "PC number ($first to $last, e.g. $first -> $(Format-Name $pattern $first))" }
    else { $Name = Read-Host 'Computer name' }
}

$number = $null
if ($Name.Trim() -match '^\d+$') {
    $number = [int]$Name.Trim()
    if ($pattern -notmatch '#') { Fail "Got PC number $number but the name pattern '$pattern' has no #." }
    $computerName = Format-Name $pattern $number
    if ($number -lt $first -or $number -gt $last) {
        Write-Warning "PC number $number is outside this batch ($first to $last)."
        if ((Read-Host 'Type YES to use it anyway') -cne 'YES') { Fail 'Cancelled.' }
    }
} else {
    $computerName = $Name.Trim().ToUpper()
}
if ($computerName.Length -gt 15 -or $computerName -notmatch '^[A-Z0-9-]+$' -or $computerName -match '^\d+$') {
    Fail "Invalid computer name '$computerName' (max 15 chars, letters/numbers/hyphens, not only numbers)."
}
Write-Host "[OK] Computer name: $computerName"

if ($writable) {
    [pscustomobject]@{
        Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Number = $(if ($null -ne $number) { $number } else { '' })
        ComputerName = $computerName; Serial = $serial; Manufacturer = $cs.Manufacturer; Model = $cs.Model; HardwareId = $hardwareId
    } | Export-Csv -Path $LedgerFile -Append -NoTypeInformation
}

# ----------------------------------------------------------------
# Stage C:\Setup (only this client's files, Administrators only)
# ----------------------------------------------------------------

New-Item -ItemType Directory -Path $Target -Force | Out-Null
icacls $Target /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
foreach ($f in @('Setup.ps1', 'secrets.json', 'custom.ps1')) {
    $src = Join-Path $Media $f
    if (Test-Path $src) { Copy-Item -Path $src -Destination $Target -Force }
}
$Client | Add-Member -NotePropertyName computerName -NotePropertyValue $computerName -Force
[System.IO.File]::WriteAllText((Join-Path $Target 'client.json'), ($Client | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
# Files copied from an ISO keep the read-only flag, which breaks cleanup
Get-ChildItem -Path $Target -File | ForEach-Object { $_.IsReadOnly = $false }
Set-Content -Path (Join-Path $Target '.oobe-provisioned') -Value (Get-Date -Format o)
Write-Host "[OK] Files staged in $Target"

# ----------------------------------------------------------------
# oobeSystem answer file
# ----------------------------------------------------------------

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$comp = "processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`""
$loc = @{
    ui     = Escape-Xml ([string](Get-Cfg $Client 'locale.ui' 'en-US'))
    input  = Escape-Xml ([string](Get-Cfg $Client 'locale.input' 'en-US'))
    system = Escape-Xml ([string](Get-Cfg $Client 'locale.system' 'en-US'))
    user   = Escape-Xml ([string](Get-Cfg $Client 'locale.user' 'en-US'))
}
$tz      = [string](Get-Cfg $Client 'timezone' '')
$orgXml  = if ($org) { "<RegisteredOrganization>$(Escape-Xml $org)</RegisteredOrganization>" } else { '' }
$tzXml   = if ($tz) { "<TimeZone>$(Escape-Xml $tz)</TimeZone>" } else { '' }
$userXml = Escape-Xml $adminUser
$nameXml = Escape-Xml $adminName
$passXml = Escape-Xml $adminPass
# 'start' returns at once so the first sign-in is not blocked; -NoExit keeps errors visible.
$launch  = Escape-Xml "cmd.exe /c start `"Provisioning`" powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$Target\Setup.ps1`" -Unattended"

$unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $comp>
      <InputLocale>$($loc.input)</InputLocale>
      <SystemLocale>$($loc.system)</SystemLocale>
      <UILanguage>$($loc.ui)</UILanguage>
      <UserLocale>$($loc.user)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $comp>
      $orgXml
      $tzXml
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
            <Name>$userXml</Name>
            <DisplayName>$nameXml</DisplayName>
            <Group>Administrators</Group>
            <Password><Value>$passXml</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$userXml</Username>
        <LogonCount>1</LogonCount>
        <Password><Value>$passXml</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$launch</CommandLine>
          <Description>Run Setup.ps1</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
[System.IO.File]::WriteAllText($UnattendPath, $unattend, (New-Object System.Text.UTF8Encoding $false))
$adminPass = $null; $passXml = $null
Write-Host "[OK] Answer file written: $UnattendPath"

# Windows 11's "only allow Windows Hello sign-in" (passwordless) setting is on by
# default and silently blocks the one-time password auto sign-in.
$pwdLess = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
New-Item -Path $pwdLess -Force | Out-Null
Set-ItemProperty -Path $pwdLess -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' -Name $adminUser -ErrorAction SilentlyContinue
Write-Host '[OK] One-time auto sign-in allowed (passwordless-only sign-in off)'

if ($SkipSysprep) {
    Write-Host ''
    Write-Host '-SkipSysprep: stopping here. To continue manually run:'
    Write-Host "  $SysprepExe /oobe /reboot /quiet /unattend:$UnattendPath"
    exit 0
}

# ----------------------------------------------------------------
# sysprep /oobe (no generalize)
# ----------------------------------------------------------------

function Invoke-Sysprep {
    Get-Process -Name sysprep -ErrorAction SilentlyContinue | Stop-Process -Force
    $st = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'   # reset state left by a failed run
    if (Test-Path $st) {
        Set-ItemProperty -Path $st -Name GeneralizationState -Value 7 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $st -Name CleanupState -Value 2 -ErrorAction SilentlyContinue
    }
    $p = Start-Process -FilePath $SysprepExe -ArgumentList '/oobe', '/reboot', '/quiet', "/unattend:$UnattendPath" -Wait -PassThru
    return $p.ExitCode
}

Write-Host ''
Write-Host 'Running sysprep /oobe - the PC reboots and finishes setup on its own.'
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
            Write-Host ('  {0}% encrypted remaining' -f $bl.EncryptionPercentage)
        } while ($bl.VolumeStatus -ne 'FullyDecrypted')
        Write-Host 'Retrying sysprep...'
        $code = Invoke-Sysprep
    }
}

if ($code -eq 0) {
    Write-Host '[OK] Sysprep accepted the answer file - rebooting. You can unmount the ISO / remove the USB now.'
    exit 0
}

$errLog = Join-Path $env:WINDIR 'System32\Sysprep\Panther\setuperr.log'
Write-Host ''
Write-Host "Sysprep failed (exit code $code). Last lines of $($errLog):" -ForegroundColor Red
if (Test-Path $errLog) { Get-Content $errLog -Tail 15 }
Write-Host ''
Write-Host "Fallback: finish OOBE by hand with a local account named '$adminUser', then run as Administrator:"
Write-Host '  powershell -ExecutionPolicy Bypass -File C:\Setup\Setup.ps1'
exit 1
