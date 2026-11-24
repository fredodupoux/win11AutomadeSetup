#Requires -RunAsAdministrator
<#
.SYNOPSIS
    BACKUP on-PC menu: review / change this PC's settings, then run Setup.ps1.

.DESCRIPTION
    The normal way to set up clients is the provisioning UI (Start-UI). This
    text menu is the fallback for last-minute changes on the PC itself: it edits
    client.json / secrets.json in this folder and runs Setup.ps1.
    Apps, features and the custom script are shown but edited in the UI only.

    Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Get-ChildItem -Path $PSScriptRoot -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$esc = [char]27
function a([string]$n) { "${esc}[${n}m" }
$R = a 0; $B = a 1; $D = a 2; $Cy = a 36; $Ye = a 33; $Gr = a 32; $Wh = a 97

$ClientFile  = Join-Path $PSScriptRoot 'client.json'
$SecretsFile = Join-Path $PSScriptRoot 'secrets.json'
if (-not (Test-Path $ClientFile)) {
    Write-Host "client.json not found in $PSScriptRoot - build this folder with the provisioning UI." -ForegroundColor Red
    exit 1
}
$Client  = Get-Content $ClientFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Secrets = if (Test-Path $SecretsFile) { Get-Content $SecretsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$Docs = @{ client = $Client; secrets = $Secrets }

# Num, section, label, document, path, type (text|bool|secret|choice), choices
$Fields = @(
    @{ Num = 1;  Section = 'COMPANY';      Label = 'Organization';         Doc = 'client';  Path = 'organization';          Type = 'text' }
    @{ Num = 2;  Section = '';             Label = 'This PC''s name';      Doc = 'client';  Path = 'computerName';          Type = 'text' }
    @{ Num = 3;  Section = '';             Label = 'Timezone';             Doc = 'client';  Path = 'timezone';              Type = 'text' }
    @{ Num = 4;  Section = 'ACCOUNTS';     Label = 'IT admin username';    Doc = 'client';  Path = 'itAdmin.username';      Type = 'text' }
    @{ Num = 5;  Section = '';             Label = 'IT admin password';    Doc = 'secrets'; Path = 'itAdminPassword';       Type = 'secret' }
    @{ Num = 6;  Section = '';             Label = 'Create end user';      Doc = 'client';  Path = 'endUser.create';        Type = 'bool' }
    @{ Num = 7;  Section = '';             Label = 'End user username';    Doc = 'client';  Path = 'endUser.username';      Type = 'text' }
    @{ Num = 8;  Section = '';             Label = 'End user full name';   Doc = 'client';  Path = 'endUser.fullName';      Type = 'text' }
    @{ Num = 9;  Section = '';             Label = 'End user password';    Doc = 'secrets'; Path = 'endUserPassword';       Type = 'secret' }
    @{ Num = 10; Section = '';             Label = 'Must change password'; Doc = 'client';  Path = 'endUser.mustChangePassword'; Type = 'bool' }
    @{ Num = 11; Section = 'NETWORK';      Label = 'WiFi name (SSID)';     Doc = 'client';  Path = 'wifi.ssid';             Type = 'text' }
    @{ Num = 12; Section = '';             Label = 'WiFi security';        Doc = 'client';  Path = 'wifi.security';         Type = 'choice'; Choices = @('WPA2PSK', 'WPA3SAE', 'open') }
    @{ Num = 13; Section = '';             Label = 'WiFi password';        Doc = 'secrets'; Path = 'wifiPassword';          Type = 'secret' }
    @{ Num = 14; Section = 'MANAGEMENT';   Label = 'Action1 agent';        Doc = 'client';  Path = 'features.action1';      Type = 'bool' }
    @{ Num = 15; Section = '';             Label = 'Action1 agent URL';    Doc = 'secrets'; Path = 'action1AgentUrl';       Type = 'secret' }
    @{ Num = 16; Section = '';             Label = 'Windows Update';       Doc = 'client';  Path = 'features.windowsUpdate'; Type = 'bool' }
)

function Get-Value($Field) {
    $cur = $Docs[$Field.Doc]
    foreach ($p in $Field.Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $prop = $cur.PSObject.Properties[$p]
        if (-not $prop) { return $null }
        $cur = $prop.Value
    }
    return $cur
}

function Set-Value($Field, $Value) {
    $parts = $Field.Path.Split('.')
    $cur = $Docs[$Field.Doc]
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $prop = $cur.PSObject.Properties[$parts[$i]]
        if (-not $prop) { $cur | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([pscustomobject]@{}); $prop = $cur.PSObject.Properties[$parts[$i]] }
        $cur = $prop.Value
    }
    $cur | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

function Show-Value($Field) {
    $v = Get-Value $Field
    if ($Field.Type -eq 'bool') {
        if ($v) { return "${Gr}Yes${R}" } else { return "${Ye}No${R}" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return "${D}(not set)${R}" }
    if ($Field.Type -eq 'secret') { return "${D}●●●●●●●●${R}" }
    return "${Wh}$v${R}"
}

function Show-Screen([string]$Msg = '') {
    Clear-Host
    Write-Host ''
    Write-Host "  ${Cy}Windows 11 provisioning - backup menu${R}   ${D}(normal path: the provisioning UI)${R}"
    Write-Host "  ${D}$PSScriptRoot${R}"
    Write-Host ''
    foreach ($f in $Fields) {
        if ($f.Section) { Write-Host ''; Write-Host "  ${Cy}${B}$($f.Section)${R}" }
        $n = $f.Num.ToString().PadLeft(2)
        Write-Host "  ${Ye}$n${R}  ${D}$($f.Label.PadRight(22))${R}  $(Show-Value $f)"
    }
    $apps = @($Client.apps.winget).Count + @($Client.apps.installers).Count + @($Client.apps.webApps).Count
    Write-Host ''
    Write-Host "  ${D}Apps: $apps (edit in the UI)   Batch: $(if ($Client.PSObject.Properties['build']) { $Client.build.batchName } else { '-' })${R}"
    Write-Host ''
    if ($Msg) { Write-Host "  $Msg" }
    Write-Host "  ${D}Number to edit  ·  R to save and run Setup  ·  Q to quit${R}"
    Write-Host -NoNewline "  ${B}>${R} "
}

function Edit-Field($Field) {
    Write-Host ''
    Write-Host "  ${B}$($Field.Label)${R}"
    switch ($Field.Type) {
        'bool' {
            $v = Read-Host '  Yes or No [y/n] (ENTER to keep)'
            if ($v -ieq 'y') { Set-Value $Field $true } elseif ($v -ieq 'n') { Set-Value $Field $false }
        }
        'choice' {
            Write-Host "  Options: $($Field.Choices -join ', ')"
            $v = Read-Host '  New value (ENTER to keep)'
            if ($v) {
                $match = $Field.Choices | Where-Object { $_ -ieq $v } | Select-Object -First 1
                if ($match) { Set-Value $Field $match } else { return "${Ye}Not one of: $($Field.Choices -join ', ')${R}" }
            }
        }
        default {
            if ($Field.Type -ne 'secret') { Write-Host "  Current: $(Get-Value $Field)" }
            $v = Read-Host '  New value (ENTER to keep)'
            if ($v.Length -gt 0) {
                if ($Field.Path -eq 'computerName') {
                    $v = $v.ToUpper()
                    if ($v.Length -gt 15 -or $v -notmatch '^[A-Z0-9-]+$') { return "${Ye}Computer name: max 15 letters, numbers, hyphens${R}" }
                }
                Set-Value $Field $v
            }
        }
    }
    return ''
}

function Save-All {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ClientFile, ($Client | ConvertTo-Json -Depth 30), $utf8)
    [System.IO.File]::WriteAllText($SecretsFile, ($Secrets | ConvertTo-Json -Depth 30), $utf8)
}

$msg = ''
while ($true) {
    Show-Screen $msg
    $msg = ''
    $raw = (Read-Host).Trim()
    if ($raw -ieq 'q') { Clear-Host; Write-Host '  Nothing saved.'; exit 0 }
    if ($raw -ieq 'r') {
        if ((Read-Host '  Save and start setup now? [Y/n]').Trim() -in @('', 'y', 'Y')) { break }
        continue
    }
    $n = 0
    if ([int]::TryParse($raw, [ref]$n)) {
        $field = $Fields | Where-Object { $_.Num -eq $n } | Select-Object -First 1
        if ($field) { $msg = Edit-Field $field } else { $msg = "${Ye}No field $n${R}" }
    } else {
        $msg = "${Ye}Type a number, R or Q${R}"
    }
}

Save-All
Write-Host ''
Write-Host "  Saved. Starting Setup.ps1..." -ForegroundColor Green
& (Join-Path $PSScriptRoot 'Setup.ps1')
