#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows 11 provisioning - runs ON THE TARGET PC.

.DESCRIPTION
    Reads client.json (settings) and secrets.json (passwords/keys) from its own
    folder - both written by the provisioning UI / Build-*.ps1 - and sets the PC up:
    computer name, WiFi, apps, users, security, Action1, custom script, Windows Update.

    Never prompts. Every step runs on its own: a failing step is logged and the
    rest continue. Results go to:
        C:\ProgramData\Provisioning\status.json
        C:\ProgramData\Provisioning\logs\setup_*.log
    and, when the build set a report URL, to the provisioning UI.

    Compatible with Windows PowerShell 5.1 (what a fresh Windows has).

.PARAMETER Unattended
    Accepted for compatibility; the script never prompts.
#>
param(
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
Get-ChildItem -Path $Here -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# Present when Provision-OOBE.ps1 staged this folder: cleanup + reboot at the end.
$OobeMode = Test-Path (Join-Path $Here '.oobe-provisioned')

# ================================================================
# Helpers
# ================================================================

# Safe nested lookup: Get-Cfg $Client 'endUser.username' 'default'
function Get-Cfg($Obj, [string]$Path, $Default = $null) {
    $cur = $Obj
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($p)) { $cur = $cur[$p] } else { return $Default }
        } else {
            $prop = $cur.PSObject.Properties[$p]
            if ($prop) { $cur = $prop.Value } else { return $Default }
        }
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Test-Feature([string]$Name, [bool]$Default = $false) {
    return [bool](Get-Cfg $Client "features.$Name" $Default)
}

$Results = New-Object System.Collections.ArrayList
$script:StepState = 'ok'
$script:StepNotes = New-Object System.Collections.ArrayList

# Step N of M, shown in the provisioning UI
$script:StepIndex     = 0
$script:StepTotal     = ([regex]::Matches((Get-Content -Path $PSCommandPath -Raw), "(?m)^Invoke-Step '")).Count
$script:CurrentStep   = ''
$script:StepStartedAt = ''
$script:ReportsLive   = $false   # progress reports start once the PC is online

function Invoke-Step([string]$Name, [scriptblock]$Action) {
    $script:StepState = 'ok'
    $script:StepNotes = New-Object System.Collections.ArrayList
    $script:StepIndex++
    $script:CurrentStep   = $Name
    $script:StepStartedAt = (Get-Date).ToString('s')
    Write-Host ''
    Write-Host "--- [$($script:StepIndex)/$($script:StepTotal)] $Name ---" -ForegroundColor Cyan
    if ($script:ReportsLive) { Send-Report 'running' -Quiet }
    try {
        & $Action
    } catch {
        $script:StepState = 'fail'
        [void]$script:StepNotes.Add($_.Exception.Message)
        Write-Warning "$Name failed: $($_.Exception.Message)"
    }
    [void]$Results.Add([pscustomobject]@{ step = $Name; status = $script:StepState; detail = ($script:StepNotes -join '; ') })
}
function Skip-Step([string]$Why) { $script:StepState = 'skip'; [void]$script:StepNotes.Add($Why); Write-Host "Skipped: $Why" }
function Warn-Step([string]$Msg) { if ($script:StepState -eq 'ok') { $script:StepState = 'warn' }; [void]$script:StepNotes.Add($Msg); Write-Warning $Msg }
function Ok-Step([string]$Msg) { [void]$script:StepNotes.Add($Msg); Write-Host "[OK] $Msg" }

function Wait-Winget([int]$TimeoutSeconds = 600) {
    # winget is registered for a new profile a few minutes after first logon
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
        Write-Host '  waiting for winget to be registered...'
        Start-Sleep -Seconds 20
    }
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# Runs winget attached to this console window so it draws its own progress bar.
# Piping winget (| Out-Host) redirects its output: the bar then turns into one long
# line of garbled characters. Its output is kept in a winget log file instead of the
# transcript. Returns winget's exit code.
function Invoke-Winget([string[]]$Arguments, [string]$LogName = '') {
    $exe = (Get-Command winget -ErrorAction Stop).Source
    $argList = @($Arguments)
    if ($LogName) { $argList += @('--log', ('"' + (Join-Path $LogDir "winget_$LogName.log") + '"')) }
    $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}

# Adds a user to a built-in group by SID (works on any Windows language); "already a member" is fine.
function Add-ToLocalGroup([string]$Sid, [string]$User) {
    try {
        Add-LocalGroupMember -SID (New-Object System.Security.Principal.SecurityIdentifier($Sid)) -Member $User
    } catch {
        if ($_.Exception.GetType().Name -ne 'MemberExistsException') { throw }
    }
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        return ($r.Content -like 'Microsoft Connect Test*')
    } catch { return $false }
}

function Wait-Internet([int]$TimeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Internet) { return $true }
        Write-Host '  waiting for internet...'
        Start-Sleep -Seconds 10
    }
    return $false
}

function Get-FileFromUrl([string]$Url) {
    $leaf = [System.Uri]::UnescapeDataString((Split-Path $Url -Leaf)) -replace '[?#].*$', ''
    if (-not $leaf) { $leaf = 'download.bin' }
    $path = Join-Path $env:TEMP $leaf
    curl.exe -fsSL -o $path $Url
    if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit code $LASTEXITCODE)" }
    return $path
}

# ================================================================
# Load configuration
# ================================================================

$ClientFile  = Join-Path $Here 'client.json'
$SecretsFile = Join-Path $Here 'secrets.json'
if (-not (Test-Path $ClientFile)) {
    Write-Host "ERROR: client.json not found in $Here - build this folder with the provisioning UI." -ForegroundColor Red
    exit 1
}
$Client  = Get-Content -Path $ClientFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Secrets = if (Test-Path $SecretsFile) { Get-Content -Path $SecretsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }

$ProvDir = Join-Path $env:ProgramData 'Provisioning'
$LogDir  = Join-Path $ProvDir 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
icacls $ProvDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
$LogFile = Join-Path $LogDir "setup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile | Out-Null

$StartedAt   = (Get-Date).ToString('s')
$TargetName  = [string](Get-Cfg $Client 'computerName' '')
$Org         = [string](Get-Cfg $Client 'organization' '')
$ReportUrl   = [string](Get-Cfg $Client 'build.report.url' '')
$ReportToken = [string](Get-Cfg $Client 'build.report.token' '')
$script:RebootRequired = $false
$script:WingetReady    = $false
$script:AnyDeskId      = ''

Write-Host '============================================'
Write-Host "  Windows 11 provisioning - $Org"
Write-Host '============================================'
Write-Host "Target name : $TargetName"
Write-Host "Batch       : $(Get-Cfg $Client 'build.batchName' '(none)')"
Write-Host "Log         : $LogFile"

# ================================================================
# Report to the provisioning UI (best effort, never fails setup)
# ================================================================

function Get-MachineFacts {
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $mac  = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.MacAddress } | Where-Object { $_ } | Sort-Object) -join ';'
    # IPv4 of the connected adapters (the ones with a default gateway first), to reach the PC by IP
    $ip = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address } |
            Sort-Object { -not $_.IPv4DefaultGateway } |
            ForEach-Object { $_.IPv4Address } | ForEach-Object { $_.IPAddress } |
            Where-Object { $_ -and $_ -notlike '169.254.*' -and $_ -ne '127.0.0.1' } | Select-Object -Unique) -join ', '
    return @{
        serial       = $(if ($bios) { [string]$bios.SerialNumber } else { '' })
        manufacturer = $(if ($cs) { [string]$cs.Manufacturer } else { '' })
        model        = $(if ($cs) { [string]$cs.Model } else { '' })
        mac          = $mac
        ipAddress    = $ip
    }
}

# The end of this PC's setup log (the transcript), sent with each report so a
# tech can follow the PC from the provisioning UI.
function Get-LogTail([int]$MaxChars = 200000) {
    try {
        $fs = New-Object System.IO.FileStream($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        if ($text.Length -gt $MaxChars) { $text = $text.Substring($text.Length - $MaxChars) }
        return $text
    } catch { return '' }
}

function Send-Report([string]$State, [switch]$Quiet) {
    if (-not $ReportUrl -or -not $ReportToken) { return }
    try {
        $facts = Get-MachineFacts
        $body = @{
            token        = $ReportToken
            state        = $State
            computerName = $(if ($TargetName) { $TargetName } else { $env:COMPUTERNAME })
            serial       = $facts.serial
            manufacturer = $facts.manufacturer
            model        = $facts.model
            mac          = $facts.mac
            ipAddress    = $facts.ipAddress
            anydeskId    = $script:AnyDeskId
            startedAt    = $StartedAt
            finishedAt   = $(if ($State -eq 'done') { (Get-Date).ToString('s') } else { '' })
            currentStep  = $(if ($State -eq 'done') { '' } else { $script:CurrentStep })
            stepIndex    = $script:StepIndex
            stepTotal    = $script:StepTotal
            stepStartedAt = $script:StepStartedAt
            warnings     = @($Results | Where-Object { $_.status -eq 'warn' }).Count
            failures     = @($Results | Where-Object { $_.status -eq 'fail' }).Count
            results      = @($Results)
            log          = (Get-LogTail)
        } | ConvertTo-Json -Depth 6
        Invoke-RestMethod -Uri $ReportUrl -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 10 | Out-Null
        if (-not $Quiet) { Write-Host "[OK] Reported '$State' to $ReportUrl" }
    } catch {
        Write-Host "Report to $ReportUrl not delivered: $($_.Exception.Message)"
    }
}

# How much of the update downloads came from other PCs ('' if Windows can't say)
function Get-DownloadSources {
    try {
        $jobs = @(Get-DeliveryOptimizationStatus -ErrorAction Stop)
        $http  = [double](($jobs | Measure-Object -Property BytesFromHttp -Sum).Sum)
        $peers = [double](($jobs | Measure-Object -Property BytesFromPeers -Sum).Sum)
        if (($http + $peers) -le 0) { return '' }
        return ('update downloads: {0:N0} MB from the internet, {1:N0} MB from PCs on this network' -f ($http / 1MB), ($peers / 1MB))
    } catch { return '' }
}

# ================================================================
# Pre-flight (fatal on failure)
# ================================================================

$OSBuild = [System.Environment]::OSVersion.Version.Build
if ($OSBuild -lt 22000) {
    Write-Host "ERROR: Windows 11 required (build 22000+). This PC: $OSBuild" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "[OK] Windows 11 build $OSBuild"

# ================================================================
# Steps
# ================================================================

Invoke-Step 'System settings' {
    if ($TargetName) {
        if ($env:COMPUTERNAME -ne $TargetName) {
            Rename-Computer -NewName $TargetName -Force
            $script:RebootRequired = $true
            Ok-Step "Computer renamed $($env:COMPUTERNAME) -> $TargetName (after reboot)"
        } else { Ok-Step "Computer name already $TargetName" }
    }
    $tz = [string](Get-Cfg $Client 'timezone' '')
    if ($tz) { Set-TimeZone -Id $tz; Ok-Step "Timezone $tz" }
    if ($Org) {
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'RegisteredOrganization' -Value $Org
        Ok-Step "Registered organization $Org"
    }
}

Invoke-Step 'Update sharing' {
    # Delivery Optimization: PCs on the same network pass update downloads to each other.
    # Set before anything downloads. Files are kept 30 days (Windows keeps them 3 by default).
    if (-not (Test-Feature 'shareUpdates' $true)) { Skip-Step 'turned off for this client'; return }
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'DODownloadMode' -Value 1 -Type DWord          # 1 = local network
    Set-ItemProperty -Path $key -Name 'DOMaxCacheAge' -Value 2592000 -Type DWord     # seconds
    Ok-Step 'shared with PCs on the local network, kept 30 days'
}

Invoke-Step 'WiFi' {
    $ssid = [string](Get-Cfg $Client 'wifi.ssid' '')
    if (-not $ssid) { Skip-Step 'no WiFi configured' }
    else {
        $security = [string](Get-Cfg $Client 'wifi.security' 'WPA2PSK')
        $hidden   = [bool](Get-Cfg $Client 'wifi.hidden' $false)
        $ssidXml  = [System.Security.SecurityElement]::Escape($ssid)
        $nonBroadcast = if ($hidden) { '<nonBroadcast>true</nonBroadcast>' } else { '' }
        if ($security -eq 'open') {
            $securityXml = '<authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption>'
        } else {
            $auth   = if ($security -eq 'WPA3SAE') { 'WPA3SAE' } else { 'WPA2PSK' }
            $keyXml = [System.Security.SecurityElement]::Escape([string](Get-Cfg $Secrets 'wifiPassword' ''))
            $securityXml = "<authEncryption><authentication>$auth</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption><sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$keyXml</keyMaterial></sharedKey>"
        }
        $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$ssidXml</name>
    <SSIDConfig><SSID><name>$ssidXml</name></SSID>$nonBroadcast</SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM><security>$securityXml</security></MSM>
</WLANProfile>
"@
        $profilePath = Join-Path $env:TEMP 'wifi-profile.xml'
        [System.IO.File]::WriteAllText($profilePath, $profileXml, (New-Object System.Text.UTF8Encoding $false))
        try {
            $out = netsh wlan add profile filename="$profilePath" user=all
            if ($LASTEXITCODE -ne 0) { throw "netsh add profile failed: $out" }
            netsh wlan connect name="$ssid" | Out-Null
            Ok-Step "WiFi profile added ($security): $ssid"
        } finally {
            Remove-Item $profilePath -Force -ErrorAction SilentlyContinue
        }
    }
    # Some PCs take several minutes to join the WiFi: wait up to 10 minutes before warning
    if (Wait-Internet 600) { Ok-Step 'Internet connection available' }
    else { Warn-Step 'No internet after 10 minutes - downloads will likely fail. Check WiFi/Ethernet.' }
}

Send-Report 'started'
$script:ReportsLive = $true

Invoke-Step 'Package manager (winget)' {
    if (-not (Wait-Winget)) { throw "winget not available after 10 minutes - install 'App Installer' and re-run" }
    [void](Invoke-Winget @('source', 'update'))
    $script:WingetReady = $true
    Ok-Step 'winget ready'
}

Invoke-Step 'Tailscale' {
    $key = [string](Get-Cfg $Secrets 'tailscaleAuthKey' '')
    if (-not (Test-Feature 'tailscale')) { Skip-Step 'turned off for this client'; return }
    if (-not $key) { Skip-Step 'no auth key'; return }
    if (-not $script:WingetReady) { throw 'winget not available' }
    $code = Invoke-Winget @('install', '--id', 'Tailscale.Tailscale', '--exact', '--source', 'winget', '--silent', '--accept-source-agreements', '--accept-package-agreements') 'Tailscale.Tailscale'
    if (@(0, -1978335189, -1978335135) -notcontains $code) { throw "winget exit code $code" }
    Start-Sleep -Seconds 10
    $exe = @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe") |
           Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw 'tailscale.exe not found after install' }
    & $exe up --authkey="$key" --unattended | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "tailscale up exit code $LASTEXITCODE" }
    Ok-Step 'Tailscale connected'
}

Invoke-Step 'Apps (winget)' {
    $ids = @(Get-Cfg $Client 'apps.winget' @())
    if ($ids.Count -eq 0) { Skip-Step 'no winget apps'; return }
    if (-not $script:WingetReady) { throw 'winget not available' }
    # 0 = installed; the others = already installed / nothing to upgrade
    $okCodes = @(0, -1978335189, -1978335135)
    foreach ($id in $ids) {
        Write-Host "Installing $id..."
        $code = Invoke-Winget @('install', '--id', $id, '--exact', '--source', 'winget', '--silent', '--accept-source-agreements', '--accept-package-agreements') $id
        if ($okCodes -contains $code) { Ok-Step $id }
        elseif ($code -eq -1978335212) { Warn-Step "$id not found in winget" }
        else { Warn-Step "$id failed (winget exit code $code)" }
    }
}

Invoke-Step 'Apps (direct installers)' {
    $list = @(Get-Cfg $Client 'apps.installers' @())
    if ($list.Count -eq 0) { Skip-Step 'none'; return }
    foreach ($inst in $list) {
        $name = [string](Get-Cfg $inst 'name' 'installer')
        try {
            Write-Host "Installing $name..."
            $path = Get-FileFromUrl ([string](Get-Cfg $inst 'url' ''))
            $instArgs = [string](Get-Cfg $inst 'args' '')
            if ($path -like '*.msi') {
                $p = Start-Process msiexec.exe -ArgumentList "/i `"$path`" /qn $instArgs" -Wait -PassThru
            } elseif ($instArgs) {
                $p = Start-Process -FilePath $path -ArgumentList $instArgs -Wait -PassThru
            } else {
                $p = Start-Process -FilePath $path -Wait -PassThru
            }
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            if (@(0, 3010) -notcontains $p.ExitCode) { throw "installer exit code $($p.ExitCode)" }
            Ok-Step $name
        } catch {
            Warn-Step "$name failed: $($_.Exception.Message)"
        }
    }
}

Invoke-Step 'Web app shortcuts' {
    $list = @(Get-Cfg $Client 'apps.webApps' @())
    if ($list.Count -eq 0) { Skip-Step 'none'; return }
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { throw 'Chrome not found - add Google.Chrome to the winget apps' }
    $iconDir = Join-Path $ProvDir 'icons'
    New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $dirs = @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms'))
    foreach ($app in $list) {
        $name = [string](Get-Cfg $app 'name' '')
        $url  = [string](Get-Cfg $app 'url' '')
        $icon = "$chrome,0"
        $iconUrl = [string](Get-Cfg $app 'icon' '')
        if ($iconUrl) {
            $iconPath = Join-Path $iconDir "$name.ico"
            curl.exe -fsSL -o $iconPath $iconUrl
            if ($LASTEXITCODE -eq 0) { $icon = "$iconPath,0" }
        }
        foreach ($d in $dirs) {
            $lnk = $shell.CreateShortcut((Join-Path $d "$name.lnk"))
            $lnk.TargetPath   = $chrome
            $lnk.Arguments    = "--app=$url"
            $lnk.IconLocation = $icon
            $lnk.Description  = $name
            $lnk.Save()
        }
        Ok-Step "$name -> $url"
    }
}

Invoke-Step 'AnyDesk unattended access' {
    if (-not (Test-Feature 'anydesk')) { Skip-Step 'turned off for this client'; return }
    $pw = [string](Get-Cfg $Secrets 'anydeskPassword' '')
    if (-not $pw) { throw 'no AnyDesk password in secrets.json' }
    $exe = @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe", "$env:ProgramFiles\AnyDesk\AnyDesk.exe") +
           @(Get-ChildItem -Path "${env:ProgramFiles(x86)}\AnyDesk-*\AnyDesk-*.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) |
           Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw 'AnyDesk is not installed (add AnyDesk.AnyDesk to the winget apps)' }
    # AnyDesk reads the password from standard input. Capturing the output makes
    # PowerShell wait for AnyDesk (a GUI program) to finish.
    $out = ($pw | & $exe --set-password 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "AnyDesk --set-password failed (exit code $LASTEXITCODE) $out" }
    Ok-Step 'unattended-access password set'
    # The ID is only known once AnyDesk has reached its servers: retry for up to 2 minutes.
    $deadline = (Get-Date).AddMinutes(2)
    do {
        $id = (& $exe --get-id 2>&1 | Out-String).Trim()
        if ($id -match '^\d{6,}$') { break }
        $id = ''
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($id) {
        $script:AnyDeskId = $id
        Ok-Step "AnyDesk ID $id"
    } else {
        Warn-Step 'AnyDesk ID not available yet (AnyDesk not online) - read it on the PC'
    }
}


Invoke-Step 'IT admin account' {
    $user = [string](Get-Cfg $Client 'itAdmin.username' '')
    if (-not $user) { Skip-Step 'no IT admin configured'; return }
    $existing = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
    if (-not $existing) {
        $pw = [string](Get-Cfg $Secrets 'itAdminPassword' '')
        if (-not $pw) { throw 'IT admin password missing in secrets.json' }
        New-LocalUser -Name $user -Password (ConvertTo-SecureString $pw -AsPlainText -Force) `
            -FullName ([string](Get-Cfg $Client 'itAdmin.displayName' $user)) -Description 'IT admin account' `
            -PasswordNeverExpires:$true | Out-Null
        Ok-Step "Created $user"
    }
    Add-ToLocalGroup 'S-1-5-32-544' $user
    Enable-LocalUser -Name $user
    # A 0 under SpecialAccounts\UserList hides an account from the sign-in screen
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' -Name $user -ErrorAction SilentlyContinue
    Ok-Step "$user is an enabled administrator, visible on the sign-in screen"
}

Invoke-Step 'End user account' {
    if (-not [bool](Get-Cfg $Client 'endUser.create' $false)) { Skip-Step 'turned off for this client'; return }
    $user = [string](Get-Cfg $Client 'endUser.username' '')
    if (-not $user) { throw 'end user username missing' }
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) { Ok-Step "$user already exists"; return }
    $pw = [string](Get-Cfg $Secrets 'endUserPassword' '')
    if (-not $pw) { throw 'end user password missing in secrets.json' }
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $pw -AsPlainText -Force) `
        -FullName ([string](Get-Cfg $Client 'endUser.fullName' $user)) -Description 'End user account' `
        -PasswordNeverExpires:$false | Out-Null
    $groupSid = if ([bool](Get-Cfg $Client 'endUser.isAdmin' $false)) { 'S-1-5-32-544' } else { 'S-1-5-32-545' }
    Add-ToLocalGroup $groupSid $user
    if ([bool](Get-Cfg $Client 'endUser.mustChangePassword' $true)) {
        & net user $user /logonpasswordchg:yes | Out-Null
        Ok-Step "$user created; must change password at first sign-in"
    } else {
        Ok-Step "$user created"
    }
}

Invoke-Step 'Security settings' {
    if (Test-Feature 'automaticUpdates' $true) {
        $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (-not (Test-Path $wu)) { New-Item -Path $wu -Force | Out-Null }
        Set-ItemProperty -Path $wu -Name 'AUOptions' -Value 4
        Set-ItemProperty -Path $wu -Name 'NoAutoUpdate' -Value 0
        Ok-Step 'Automatic updates'
    }
    if (Test-Feature 'firewall' $true) {
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True
        Ok-Step 'Firewall on (all profiles)'
    }
    if (Test-Feature 'screenLockOnWake' $true) {
        powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
        powercfg /S SCHEME_CURRENT
        Ok-Step 'Password on wake'
    }
    if (Test-Feature 'remoteDesktop' $true) {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Ok-Step 'Remote Desktop enabled'
    }
    if (Test-Feature 'disableSmb1' $true) {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
        Ok-Step 'SMBv1 disabled'
    }
}

Invoke-Step 'Dell Command Update' {
    $manufacturer = [string](Get-CimInstance Win32_ComputerSystem).Manufacturer
    if (-not (Test-Feature 'dellCommandUpdate' $true)) { Skip-Step 'turned off for this client'; return }
    if ($manufacturer -notlike '*Dell*') { Skip-Step "not a Dell ($manufacturer)"; return }
    if (-not $script:WingetReady) { throw 'winget not available' }
    $code = Invoke-Winget @('install', '--id', 'Dell.CommandUpdate', '--exact', '--source', 'winget', '--silent', '--accept-source-agreements', '--accept-package-agreements') 'Dell.CommandUpdate'
    if (@(0, -1978335189, -1978335135) -notcontains $code) { throw "winget exit code $code" }
    Ok-Step 'Installed'
}

Invoke-Step 'Action1 agent' {
    $url = [string](Get-Cfg $Secrets 'action1AgentUrl' '')
    if (-not (Test-Feature 'action1')) { Skip-Step 'turned off for this client'; return }
    if (-not $url) { Skip-Step 'no agent URL'; return }
    $path = Get-FileFromUrl $url
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$path`" /quiet /qn" -Wait -PassThru
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    if (@(0, 3010) -notcontains $p.ExitCode) { throw "msiexec exit code $($p.ExitCode)" }
    Ok-Step 'Installed'
}

Invoke-Step 'Custom script' {
    $custom = Join-Path $Here 'custom.ps1'
    if (-not (Test-Feature 'customScript')) { Skip-Step 'turned off for this client'; return }
    if (-not (Test-Path $custom)) { Skip-Step 'no custom.ps1'; return }
    $text = Get-Content -Path $custom -Raw -Encoding UTF8
    $firstLine = @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($firstLine -and $firstLine[0] -match '^\s*(@?echo\s+off|@?rem(\s|$)|::|setlocal)') {
        # A Command Prompt (batch) script pasted into the custom script box: run it with cmd.exe.
        # cmd needs Windows line endings; run attached to this window (exit code != 0 = failed).
        $cmdFile = Join-Path $env:TEMP 'provisioning-custom.cmd'
        [System.IO.File]::WriteAllText($cmdFile, (($text -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding $false))
        try {
            $p = Start-Process -FilePath "$env:WINDIR\System32\cmd.exe" -ArgumentList "/d /c `"`"$cmdFile`"`"" -NoNewWindow -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "custom script (batch) exit code $($p.ExitCode)" }
        } finally { Remove-Item $cmdFile -Force -ErrorAction SilentlyContinue }
        Ok-Step 'custom script (batch) finished'
    } else {
        # PowerShell: gets the settings and secrets; anything it throws marks this step failed.
        & $custom -Client $Client -Secrets $Secrets
        Ok-Step 'custom.ps1 finished'
    }
}

Invoke-Step 'Next computer name on the USB' {
    if ($OobeMode) { Skip-Step 'provisioning-only media (name given at RUN)'; return }
    $xmlPath = Join-Path (Split-Path $Here -Parent) 'autounattend.xml'
    if (-not (Test-Path $xmlPath)) { Skip-Step 'no autounattend.xml next to Setup\'; return }
    $xml = Get-Content -Path $xmlPath -Raw -Encoding UTF8
    if ($xml -notmatch '<ComputerName>([^<]+)</ComputerName>') { Skip-Step 'no <ComputerName> in autounattend.xml'; return }
    $current = $Matches[1]
    if ($current -notmatch '^(.*?)(\d+)$') { Skip-Step "'$current' has no number to increment"; return }
    $next = $Matches[1] + ([int]$Matches[2] + 1).ToString("D$($Matches[2].Length)")
    $xml = $xml -replace "<ComputerName>$([regex]::Escape($current))</ComputerName>", "<ComputerName>$next</ComputerName>"
    try {
        [System.IO.File]::WriteAllText($xmlPath, $xml, (New-Object System.Text.UTF8Encoding $false))
        Ok-Step "$current -> $next"
    } catch {
        Skip-Step 'setup media is read-only (bootable ISO): name not incremented'
    }
}

Invoke-Step 'Windows Update' {
    # Last on purpose (slowest). 0x80248007 shows up when Windows' own update run is busy
    # at the same time or on some driver updates: wait, retry, skip drivers, then hand off.
    if (-not (Test-Feature 'windowsUpdate' $true)) { Skip-Step 'turned off for this client'; return }
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -AllowClobber -ErrorAction SilentlyContinue
    }
    $done = $false
    if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
        Import-Module PSWindowsUpdate
        $attempts = @(
            @{ Label = 'all updates'; Params = @{} },
            @{ Label = 'all updates (retry)'; Params = @{} },
            @{ Label = 'software only (no drivers)'; Params = @{ NotCategory = 'Drivers' } }
        )
        foreach ($a in $attempts) {
            $installer = New-Object -ComObject Microsoft.Update.Installer
            $deadline = (Get-Date).AddMinutes(15)
            while ($installer.IsBusy -and (Get-Date) -lt $deadline) {
                Write-Host '  Windows is already installing updates - waiting...'
                Start-Sleep -Seconds 30
            }
            Write-Host "Installing Windows updates: $($a.Label)..."
            try {
                $p = $a.Params
                Install-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop @p | Out-Host
                Ok-Step "installed ($($a.Label))"
                $done = $true
                break
            } catch {
                Write-Warning "Attempt failed ($($a.Label)): $($_.Exception.Message)"
                Start-Sleep -Seconds 60
            }
        }
    }
    if (-not $done) {
        try { Start-Process -FilePath "$env:WINDIR\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan' } catch { }
        Warn-Step 'could not install directly - handed off to Windows Update (finishes in the background)'
    }
    $sources = Get-DownloadSources
    if ($sources) { Ok-Step $sources }
}

Invoke-Step 'Auto sign-in off' {
    # The answer file signs the IT admin in ONCE so this script can run.
    # After setup, auto sign-in must never stay on (every client, every mode).
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0'
    Remove-ItemProperty -Path $winlogon -Name 'DefaultPassword', 'AutoLogonCount' -ErrorAction SilentlyContinue
    Ok-Step 'disabled; stored password removed'
}

# ================================================================
# Summary + status
# ================================================================

$failures = @($Results | Where-Object { $_.status -eq 'fail' })
$warnings = @($Results | Where-Object { $_.status -eq 'warn' })
# Setup always runs to the end: a failed step is reported, it doesn't stop the PC
$state = 'done'

Write-Host ''
Write-Host '============================================'
Write-Host "  PROVISIONING FINISHED  ($($failures.Count) step(s) failed, $($warnings.Count) with warnings)"
Write-Host '============================================'
foreach ($r in $Results) {
    $color = switch ($r.status) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'fail' { 'Red' } default { 'Gray' } }
    $line = '  [{0,-4}] {1}' -f $r.status.ToUpper(), $r.step
    if ($r.detail -and $r.status -ne 'ok') { $line += " - $($r.detail)" }
    Write-Host $line -ForegroundColor $color
}
Write-Host ''
Write-Host "Log: $LogFile"

$facts = Get-MachineFacts
@{
    state        = $state
    organization = $Org
    computerName = $TargetName
    batch        = [string](Get-Cfg $Client 'build.batchName' '')
    startedAt    = $StartedAt
    finishedAt   = (Get-Date).ToString('s')
    failures     = $failures.Count
    warnings     = $warnings.Count
    serial       = $facts.serial
    model        = $facts.model
    ipAddress    = $facts.ipAddress
    anydeskId    = $script:AnyDeskId
    results      = @($Results)
    log          = $LogFile
} | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ProvDir 'status.json') -Encoding UTF8

Send-Report $state

# ================================================================
# Cleanup + reboot (provisioning-only media)
# ================================================================
# C:\Setup and the answer files hold plain-text passwords. Remove them and reboot.

if ($OobeMode) {
    Write-Host ''
    Write-Host '--- Cleanup ---' -ForegroundColor Cyan
    @(
        "$env:WINDIR\Panther\unattend.xml",
        "$env:WINDIR\Panther\Unattend\unattend.xml",
        "$env:WINDIR\System32\Sysprep\unattend.xml",
        (Join-Path $Here 'oobe-unattend.xml'),
        (Join-Path $Here 'secrets.json'),
        (Join-Path $Here 'custom.ps1')
    ) | ForEach-Object { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
    Write-Host '[OK] Answer files and secrets removed'

    # This script is still running from the folder - delete the rest at next boot.
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c rmdir /s /q `"$Here`" & schtasks /delete /tn ProvisioningCleanup /f"
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'ProvisioningCleanup' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Force | Out-Null
    Write-Host "[OK] $Here will be deleted at next boot"

    Write-Host ''
    Write-Host "Rebooting in 2 minutes (run 'shutdown /a' to cancel)." -ForegroundColor Green
    shutdown.exe /r /t 120 /c 'Provisioning complete - restarting.'
} elseif ($script:RebootRequired) {
    Write-Host ''
    Write-Host '[!] Restart the PC to apply the new computer name.' -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
