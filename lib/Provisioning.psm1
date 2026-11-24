#Requires -Version 7.0
<#
.SYNOPSIS
    Shared logic for the provisioning UI and the Build-*.ps1 scripts.
    Runs on the TECH's machine (macOS or Windows, PowerShell 7).
    The scripts that run on the target PC (Setup\*.ps1) stay Windows PowerShell 5.1.

    clients\<name>\client.json    settings (no secrets)
    clients\<name>\secrets.json   passwords / keys / agent URLs
    clients\<name>\custom.ps1     optional extra steps
    clients\<name>\batches.json   batches of PCs + what each PC reported
    dist\<name>\<batch>\          build output
#>

Set-StrictMode -Version Latest

$script:RepoRoot    = Split-Path $PSScriptRoot -Parent
$script:ClientsRoot = Join-Path $script:RepoRoot 'clients'
$script:DistRoot    = Join-Path $script:RepoRoot 'dist'
$script:SetupSource = Join-Path $script:RepoRoot 'Setup'
$script:CacheRoot   = Join-Path $script:RepoRoot 'cache'
$script:LibRoot     = $PSScriptRoot

$script:SchemaVersion      = 1
$script:GenericSetupFiles  = @('Setup.ps1', 'Launch-Setup.cmd', 'Provision-OOBE.ps1', 'Provision-OOBE.cmd', 'Launch-Setup-GUI.ps1')
$script:WifiSecurityTypes  = @('WPA2PSK', 'WPA3SAE', 'open')
$script:WindowsEditions    = @('Windows 11 Pro', 'Windows 11 Home', 'Windows 11 Enterprise', 'Windows 11 Education', 'Windows 11 Pro for Workstations')

# ====================================================================
# Paths / small helpers
# ====================================================================

function Get-ProvPaths {
    [ordered]@{
        Repo    = $script:RepoRoot
        Clients = $script:ClientsRoot
        Dist    = $script:DistRoot
        Setup   = $script:SetupSource
        Cache   = $script:CacheRoot
    }
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -AsHashtable -Depth 30)
}

function Copy-Deep($Object) {
    if ($null -eq $Object) { return $null }
    return ($Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -Depth 30)
}

# Fills keys missing from $Target with values from $Defaults (recursively for hashtables).
function Merge-Defaults($Target, $Defaults) {
    if ($null -eq $Target) { return (Copy-Deep $Defaults) }
    foreach ($k in @($Defaults.Keys)) {
        if (-not $Target.Contains($k)) {
            $Target[$k] = Copy-Deep $Defaults[$k]
        } elseif ($Defaults[$k] -is [System.Collections.IDictionary] -and $Target[$k] -is [System.Collections.IDictionary]) {
            Merge-Defaults $Target[$k] $Defaults[$k] | Out-Null
        }
    }
    return $Target
}

function Write-CrlfFile([string]$Path, [string]$Text) {
    $Text = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function New-RandomToken {
    $bytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

function Assert-ClientName([string]$Name) {
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') {
        throw "Invalid client name '$Name' (lowercase letters, numbers and hyphens, max 40)."
    }
}

# ====================================================================
# Schema: defaults + reference lists
# ====================================================================

function Get-DefaultClient {
    [ordered]@{
        schemaVersion       = $script:SchemaVersion
        organization        = ''
        windowsEdition      = 'Windows 11 Pro'
        timezone            = 'Eastern Standard Time'
        locale              = [ordered]@{ ui = 'en-US'; input = 'en-US'; system = 'en-US'; user = 'en-US' }
        computerNamePattern = 'PC-##'
        itAdmin             = [ordered]@{ username = 'itadmin'; displayName = 'IT Admin' }
        endUser             = [ordered]@{ create = $true; username = ''; fullName = ''; isAdmin = $false; mustChangePassword = $true }
        wifi                = [ordered]@{ ssid = ''; security = 'WPA2PSK'; hidden = $false }
        apps                = [ordered]@{ winget = @(); installers = @(); webApps = @() }
        features            = [ordered]@{
            action1           = $false
            tailscale         = $false
            automaticUpdates  = $true
            firewall          = $true
            screenLockOnWake  = $true
            remoteDesktop     = $true
            disableSmb1       = $true
            dellCommandUpdate = $true
            windowsUpdate     = $true
            customScript      = $false
        }
        notes               = ''
    }
}

function Get-DefaultSecrets {
    [ordered]@{
        itAdminPassword  = ''
        endUserPassword  = ''
        wifiPassword     = ''
        tailscaleAuthKey = ''
        action1AgentUrl  = ''
    }
}

function Get-ProvMeta {
    $tzFile = Join-Path $script:LibRoot 'timezones.txt'
    $tz = if (Test-Path $tzFile) { @(Get-Content $tzFile | Where-Object { $_ -and -not $_.StartsWith('#') }) } else { @() }
    [ordered]@{
        timezones       = $tz
        locales         = @('en-US', 'en-GB', 'en-CA', 'fr-FR', 'fr-CA', 'fr-BE', 'fr-CH', 'es-ES', 'es-MX', 'es-US', 'pt-BR', 'pt-PT', 'de-DE', 'it-IT', 'nl-NL', 'nl-BE', 'ht-HT')
        wifiSecurity    = $script:WifiSecurityTypes
        windowsEditions = $script:WindowsEditions
        features        = [ordered]@{
            action1           = 'Install the Action1 agent (needs the agent URL in secrets)'
            tailscale         = 'Install Tailscale and join the tailnet (needs an auth key)'
            automaticUpdates  = 'Windows Update policy: download and install automatically'
            firewall          = 'Turn the firewall on for all profiles'
            screenLockOnWake  = 'Require a password when the PC wakes up'
            remoteDesktop     = 'Enable Remote Desktop (with firewall rule)'
            disableSmb1       = 'Disable SMBv1 (legacy, insecure)'
            dellCommandUpdate = 'Install Dell Command Update (Dell hardware only)'
            windowsUpdate     = 'Install Windows updates at the end of setup (slowest step)'
            customScript      = 'Run this client''s custom script near the end of setup'
        }
    }
}

# ====================================================================
# Computer names
# ====================================================================

# 'SAFITEKHT-CS-##' + 3 -> 'SAFITEKHT-CS-03'. A pattern without # is a fixed name.
function Format-ComputerName([string]$Pattern, [int]$Number) {
    if ($Pattern -match '#+') {
        $hashes = $Matches[0]
        return $Pattern.Replace($hashes, $Number.ToString("D$($hashes.Length)")).ToUpper()
    }
    return $Pattern.ToUpper()
}

# 'SAFITEKHT-CS-03' with 'SAFITEKHT-CS-##' -> 3, or $null
function Get-ComputerNumber([string]$Pattern, [string]$Name) {
    if (-not $Pattern -or $Pattern -notmatch '#+') { return $null }
    # [regex]::Escape turns '#' into '\#'
    $rx = '^' + ([regex]::Escape($Pattern.ToUpper()) -replace '(\\#)+', '(\d+)') + '$'
    if ($Name.ToUpper() -match $rx) { return [int]$Matches[1] }
    return $null
}

function Test-ComputerName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'is empty' }
    if ($Name.Length -gt 15) { return "'$Name' is longer than 15 characters" }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return "'$Name' may only contain letters, numbers and hyphens" }
    if ($Name -match '^\d+$') { return "'$Name' cannot be only numbers" }
    return $null
}

# ====================================================================
# Validation
# ====================================================================

function Test-ClientData {
    <# Returns @{ errors = @(@{field;message}); warnings = @(...) } #>
    param($Client, $Secrets, [string]$CustomScript = '')

    $errors   = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    function E($f, $m) { $errors.Add([ordered]@{ field = $f; message = $m }) }
    function W($f, $m) { $warnings.Add([ordered]@{ field = $f; message = $m }) }

    $c = Merge-Defaults (Copy-Deep $Client) (Get-DefaultClient)
    $s = Merge-Defaults (Copy-Deep $Secrets) (Get-DefaultSecrets)
    $badUser = '[\\/\[\]:;|=,+*?<>@"]'

    if ([string]::IsNullOrWhiteSpace($c.organization)) { E 'organization' 'Organization is required' }
    if ($script:WindowsEditions -notcontains $c.windowsEdition) { W 'windowsEdition' "Unusual Windows edition '$($c.windowsEdition)' - must match the install image name (clean install only)" }

    $tz = @((Get-ProvMeta).timezones)
    if ([string]::IsNullOrWhiteSpace($c.timezone)) { E 'timezone' 'Timezone is required' }
    elseif ($tz.Count -gt 0 -and $tz -notcontains $c.timezone) { W 'timezone' "'$($c.timezone)' is not a known Windows timezone ID - check the spelling" }

    foreach ($k in 'ui', 'input', 'system', 'user') {
        $v = [string]$c.locale[$k]
        if ($v -notmatch '^[a-zA-Z]{2,3}(-[A-Za-z0-9]{2,8})*$' -and $v -notmatch '^[0-9a-fA-F]{4}:[0-9a-fA-F]{8}$') {
            E "locale.$k" "Locale '$v' is not valid (examples: en-US, fr-FR, or a keyboard ID like 040c:0000040c)"
        }
    }

    # Computer names
    $pattern = [string]$c.computerNamePattern
    if ([string]::IsNullOrWhiteSpace($pattern)) { E 'computerNamePattern' 'Computer name pattern is required (example: ACME-PC-##)' }
    else {
        $sample = Format-ComputerName $pattern 1
        $problem = Test-ComputerName $sample
        if ($problem) { E 'computerNamePattern' "Pattern gives a bad name: $problem" }
        if ($pattern -notmatch '#') { W 'computerNamePattern' 'No # in the pattern: every PC gets the same name' }
        if (([regex]::Matches($pattern, '#+')).Count -gt 1) { E 'computerNamePattern' 'Use only one group of # in the pattern' }
    }

    # IT admin
    $admin = [string]$c.itAdmin.username
    if ([string]::IsNullOrWhiteSpace($admin)) { E 'itAdmin.username' 'IT admin username is required' }
    elseif ($admin.Length -gt 20 -or $admin -match $badUser) { E 'itAdmin.username' 'IT admin username: max 20 characters, no \ / [ ] : ; | = , + * ? < > @ "' }
    if ([string]::IsNullOrEmpty($s.itAdminPassword)) { E 'secrets.itAdminPassword' 'IT admin password is required' }
    elseif ($s.itAdminPassword.Length -lt 8) { W 'secrets.itAdminPassword' 'IT admin password is shorter than 8 characters' }

    # End user
    if ($c.endUser.create) {
        $u = [string]$c.endUser.username
        if ([string]::IsNullOrWhiteSpace($u)) { E 'endUser.username' 'End user username is required (or turn off "create end user")' }
        elseif ($u.Length -gt 20 -or $u -match $badUser) { E 'endUser.username' 'End user username: max 20 characters, no special characters' }
        elseif ($u -ieq $admin) { E 'endUser.username' 'End user and IT admin cannot have the same username' }
        if ([string]::IsNullOrEmpty($s.endUserPassword)) { E 'secrets.endUserPassword' 'End user password is required' }
        elseif ($s.endUserPassword -ceq $s.itAdminPassword) { W 'secrets.endUserPassword' 'End user password is the same as the IT admin password' }
        if (-not $c.endUser.mustChangePassword) { W 'endUser.mustChangePassword' 'End user keeps the shared default password (not forced to change it)' }
    }

    # WiFi
    if ([string]::IsNullOrWhiteSpace($c.wifi.ssid)) {
        W 'wifi.ssid' 'No WiFi configured - the PCs need Ethernet during setup'
    } else {
        if ($script:WifiSecurityTypes -notcontains $c.wifi.security) { E 'wifi.security' "WiFi security must be one of: $($script:WifiSecurityTypes -join ', ')" }
        elseif ($c.wifi.security -ne 'open') {
            $len = ([string]$s.wifiPassword).Length
            if ($len -lt 8 -or $len -gt 63) { E 'secrets.wifiPassword' 'WiFi password must be 8 to 63 characters' }
        }
    }

    # Remote management
    if ($c.features.action1) {
        if ([string]$s.action1AgentUrl -notmatch '^https://\S+$') { E 'secrets.action1AgentUrl' 'Action1 is on but the agent URL is missing or not https://' }
    }
    if ($c.features.tailscale) {
        if ([string]$s.tailscaleAuthKey -notmatch '^tskey-') { E 'secrets.tailscaleAuthKey' 'Tailscale is on but the auth key is missing (starts with tskey-)' }
    }

    # Apps
    $winget = @($c.apps.winget)
    if ($winget.Count -eq 0) { W 'apps.winget' 'No winget apps selected' }
    foreach ($id in $winget) {
        if ([string]$id -notmatch '^[^\s.]+(\.[^\s.]+)+$') { E 'apps.winget' "'$id' does not look like a winget ID (Publisher.App)" }
    }
    $i = 0
    foreach ($inst in @($c.apps.installers)) {
        if (-not $inst -or [string]::IsNullOrWhiteSpace($inst['name'])) { E "apps.installers[$i]" 'Installer needs a name' }
        if (-not $inst -or [string]$inst['url'] -notmatch '^https?://\S+$') { E "apps.installers[$i]" 'Installer needs an http(s) download URL' }
        elseif ($inst['url'] -like 'http://*') { W "apps.installers[$i]" "$($inst['name']): downloaded over plain http" }
        $i++
    }
    $i = 0
    foreach ($w in @($c.apps.webApps)) {
        if (-not $w -or [string]::IsNullOrWhiteSpace($w['name'])) { E "apps.webApps[$i]" 'Web app needs a name' }
        if (-not $w -or [string]$w['url'] -notmatch '^https?://\S+$') { E "apps.webApps[$i]" 'Web app needs an http(s) URL' }
        $i++
    }

    if ($c.features.customScript -and [string]::IsNullOrWhiteSpace($CustomScript)) {
        W 'customScript' 'Custom script is turned on but empty'
    }

    return [ordered]@{ errors = @($errors); warnings = @($warnings) }
}

# ====================================================================
# Clients
# ====================================================================

function Get-ClientDir([string]$Name) {
    Assert-ClientName $Name
    return (Join-Path $script:ClientsRoot $Name)
}

function Get-ClientList {
    if (-not (Test-Path $script:ClientsRoot)) { return @() }
    $list = foreach ($d in Get-ChildItem -Path $script:ClientsRoot -Directory | Sort-Object Name) {
        if ($d.Name -eq '_example' -or $d.Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') { continue }
        if (-not (Test-Path (Join-Path $d.FullName 'client.json'))) {
            [ordered]@{ name = $d.Name; organization = ''; legacy = (Test-Path (Join-Path $d.FullName 'config.ps1')); errors = 1; warnings = 0; batches = 0; apps = 0; pattern = '' }
            continue
        }
        $data = Get-ClientData -Name $d.Name
        $v = Test-ClientData -Client $data.client -Secrets $data.secrets -CustomScript $data.customScript
        [ordered]@{
            name         = $d.Name
            organization = $data.client.organization
            pattern      = $data.client.computerNamePattern
            apps         = @($data.client.apps.winget).Count + @($data.client.apps.installers).Count + @($data.client.apps.webApps).Count
            batches      = @($data.batches.batches).Count
            errors       = @($v.errors).Count
            warnings     = @($v.warnings).Count
            legacy       = $false
        }
    }
    return @($list)
}

function Get-ClientData {
    param([Parameter(Mandatory)][string]$Name)
    $dir = Get-ClientDir $Name
    if (-not (Test-Path (Join-Path $dir 'client.json'))) {
        if (Test-Path (Join-Path $dir 'config.ps1')) { throw "Client '$Name' still uses the old config.ps1 format. Convert it first (Convert-LegacyClient / tools\Convert-LegacyConfig.ps1)." }
        throw "Client '$Name' not found ($dir)"
    }
    $client  = Merge-Defaults (Read-JsonFile (Join-Path $dir 'client.json')) (Get-DefaultClient)
    $secrets = Merge-Defaults (Read-JsonFile (Join-Path $dir 'secrets.json')) (Get-DefaultSecrets)
    $customPath = Join-Path $dir 'custom.ps1'
    $custom  = if (Test-Path $customPath) { [System.IO.File]::ReadAllText($customPath) } else { '' }
    $batches = Read-JsonFile (Join-Path $dir 'batches.json')
    if (-not $batches) { $batches = [ordered]@{ batches = @() } }
    if (-not $batches.Contains('batches') -or $null -eq $batches.batches) { $batches.batches = @() }
    return [ordered]@{ name = $Name; client = $client; secrets = $secrets; customScript = $custom; batches = $batches }
}

function Save-ClientData {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Client,
        $Secrets,
        [AllowNull()][string]$CustomScript
    )
    $dir = Get-ClientDir $Name
    $c = Merge-Defaults (Copy-Deep $Client) (Get-DefaultClient)
    $c.schemaVersion = $script:SchemaVersion
    # Never let secrets leak into client.json
    foreach ($k in @((Get-DefaultSecrets).Keys)) { if ($c.Contains($k)) { $c.Remove($k) } }
    Write-JsonFile (Join-Path $dir 'client.json') $c
    if ($null -ne $Secrets) { Write-JsonFile (Join-Path $dir 'secrets.json') (Merge-Defaults (Copy-Deep $Secrets) (Get-DefaultSecrets)) }
    $customPath = Join-Path $dir 'custom.ps1'
    if ($null -ne $CustomScript) {
        if ([string]::IsNullOrWhiteSpace($CustomScript)) { Remove-Item $customPath -Force -ErrorAction SilentlyContinue }
        else { Write-CrlfFile $customPath $CustomScript }
    }
    return (Test-ClientData -Client $c -Secrets (Get-ClientData -Name $Name).secrets -CustomScript ([string]$CustomScript))
}

function New-ClientFromTemplate {
    <# Creates clients\<Name>\ from clients\_example, or copies another client's settings (never its secrets or batches). #>
    param([Parameter(Mandatory)][string]$Name, [string]$From = '')
    $dir = Get-ClientDir $Name
    if (Test-Path $dir) { throw "Client '$Name' already exists" }

    if ($From) {
        $src = Get-ClientData -Name $From
        $client = Copy-Deep $src.client
        $custom = $src.customScript
    } else {
        $exampleDir = Join-Path $script:ClientsRoot '_example'
        $example = Join-Path $exampleDir 'client.json'
        $client = Merge-Defaults (Read-JsonFile $example) (Get-DefaultClient)
        $customPath = Join-Path $exampleDir 'custom.ps1'
        $custom = if (Test-Path $customPath) { [System.IO.File]::ReadAllText($customPath) } else { '' }
    }
    $client.organization = if ($From) { $client.organization } else { $Name.ToUpper() }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Save-ClientData -Name $Name -Client $client -Secrets (Get-DefaultSecrets) -CustomScript $custom | Out-Null
    return (Get-ClientData -Name $Name)
}

# ====================================================================
# Batches
# ====================================================================

function Save-Batches([string]$Name, $Batches) {
    Write-JsonFile (Join-Path (Get-ClientDir $Name) 'batches.json') $Batches
}

function Get-Batch([string]$Name, [string]$BatchId) {
    $data = Get-ClientData -Name $Name
    $b = @($data.batches.batches) | Where-Object { $_.id -eq $BatchId } | Select-Object -First 1
    if (-not $b) { throw "Batch '$BatchId' not found for client '$Name'" }
    return $b
}

function Test-BatchData($Batch, $Client) {
    $errors = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Batch.name)) { $errors.Add('Batch name is required') }
    $pattern = if ($Batch.computerNamePattern) { $Batch.computerNamePattern } else { $Client.computerNamePattern }
    $start = [int]$Batch.start; $end = [int]$Batch.end
    if ($start -lt 0 -or $end -lt $start) { $errors.Add('End number must be greater than or equal to the start number') }
    if ($end - $start -gt 999) { $errors.Add('A batch can have at most 1000 PCs') }
    foreach ($n in @($start, $end)) {
        $p = Test-ComputerName (Format-ComputerName $pattern $n)
        if ($p) { $errors.Add("Computer name for PC $n $p") }
    }
    if ($pattern -match '#+' -and $end.ToString().Length -gt $Matches[0].Length) { $errors.Add("Pattern '$pattern' has fewer # than digits in $end") }
    return @($errors)
}

function Save-Batch {
    <# Creates (no id) or updates a batch. Keeps machines and token. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Batch)
    $data = Get-ClientData -Name $Name
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($b in @($data.batches.batches)) { $list.Add($b) }

    $incoming = Copy-Deep $Batch
    foreach ($k in 'computerNamePattern', 'notes') { if (-not $incoming.Contains($k)) { $incoming[$k] = '' } }
    if (-not $incoming.Contains('overrides') -or $null -eq $incoming.overrides) { $incoming.overrides = [ordered]@{} }
    $incoming.start = [int]$incoming.start
    $incoming.end   = [int]$incoming.end
    $problems = @(Test-BatchData $incoming $data.client)
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }

    $existing = if ($incoming['id']) { $list | Where-Object { $_.id -eq $incoming.id } | Select-Object -First 1 } else { $null }
    if ($existing) {
        foreach ($k in 'name', 'computerNamePattern', 'start', 'end', 'overrides', 'notes') { $existing[$k] = $incoming[$k] }
        $result = $existing
    } else {
        $result = [ordered]@{
            id                  = 'b' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            name                = $incoming.name
            computerNamePattern = $incoming.computerNamePattern
            start               = $incoming.start
            end                 = $incoming.end
            overrides           = $incoming.overrides
            notes               = $incoming.notes
            token               = New-RandomToken
            created             = (Get-Date).ToString('s')
            machines            = [ordered]@{}
        }
        $list.Add($result)
    }
    $data.batches.batches = @($list)
    Save-Batches $Name $data.batches
    return $result
}

function Set-MachineStatus {
    <# Records what happened to PC number $Number in a batch (from a report or set by hand). #>
    param([string]$Name, [string]$BatchId, [int]$Number, [hashtable]$Fields)
    $data = Get-ClientData -Name $Name
    $b = @($data.batches.batches) | Where-Object { $_.id -eq $BatchId } | Select-Object -First 1
    if (-not $b) { throw "Batch '$BatchId' not found" }
    if (-not $b.Contains('machines') -or $null -eq $b.machines) { $b.machines = [ordered]@{} }
    $key = [string]$Number
    $m = if ($b.machines.Contains($key)) { $b.machines[$key] } else { [ordered]@{ number = $Number } }
    foreach ($k in $Fields.Keys) { $m[$k] = $Fields[$k] }
    $m.updated = (Get-Date).ToString('s')
    $b.machines[$key] = $m
    Save-Batches $Name $data.batches
    return $m
}

function Find-BatchByToken([string]$Token) {
    if (-not $Token) { return $null }
    foreach ($c in Get-ClientList) {
        if ($c.legacy) { continue }
        $data = Get-ClientData -Name $c.name
        foreach ($b in @($data.batches.batches)) {
            if ($b.token -and ([string]$b.token) -ceq $Token) {
                return [ordered]@{ client = $c.name; batch = $b; clientData = $data }
            }
        }
    }
    return $null
}

# Applies a report sent by Setup.ps1 at the end (or start) of a PC's setup.
function Add-MachineReport($Report) {
    $hit = Find-BatchByToken ([string]$Report.token)
    if (-not $hit) { throw 'Unknown report token' }
    $pattern = if ($hit.batch.computerNamePattern) { $hit.batch.computerNamePattern } else { $hit.clientData.client.computerNamePattern }
    $number = Get-ComputerNumber $pattern ([string]$Report.computerName)
    if ($null -eq $number) { throw "Computer name '$($Report.computerName)' does not match pattern '$pattern'" }
    $fields = @{}
    foreach ($k in 'state', 'computerName', 'serial', 'manufacturer', 'model', 'mac', 'startedAt', 'finishedAt', 'warnings', 'failures', 'results') {
        if ($Report.Contains($k)) { $fields[$k] = $Report[$k] }
    }
    $fields.status = switch ([string]$Report.state) { 'started' { 'in-progress' } 'done' { 'done' } 'failed' { 'failed' } default { 'in-progress' } }
    $fields.source = 'report'
    return (Set-MachineStatus -Name $hit.client -BatchId $hit.batch.id -Number $number -Fields $fields)
}

# ====================================================================
# Build: resolve config, stage Setup\, answer file
# ====================================================================

function Resolve-BuildConfig {
    <# Client + batch overrides + build metadata, validated. Throws on errors. #>
    param([Parameter(Mandatory)][string]$Name, [string]$BatchId = '', [string]$Media = 'provision', [string]$ReportUrl = '')
    $data    = Get-ClientData -Name $Name
    $client  = Copy-Deep $data.client
    $secrets = Copy-Deep $data.secrets
    $batch   = $null
    $start = 1; $end = 1

    if ($BatchId) {
        $batch = @($data.batches.batches) | Where-Object { $_.id -eq $BatchId } | Select-Object -First 1
        if (-not $batch) { throw "Batch '$BatchId' not found" }
        if ($batch.computerNamePattern) { $client.computerNamePattern = $batch.computerNamePattern }
        $start = [int]$batch.start; $end = [int]$batch.end
        $o = $batch.overrides
        if ($o) {
            if ($o['wifiSsid'])        { $client.wifi.ssid = $o.wifiSsid }
            if ($o['wifiSecurity'])    { $client.wifi.security = $o.wifiSecurity }
            if ($o['wifiPassword'])    { $secrets.wifiPassword = $o.wifiPassword }
            if ($o['endUserUsername']) { $client.endUser.username = $o.endUserUsername }
            if ($o['endUserFullName']) { $client.endUser.fullName = $o.endUserFullName }
            if ($o['endUserPassword']) { $secrets.endUserPassword = $o.endUserPassword }
        }
    }

    $v = Test-ClientData -Client $client -Secrets $secrets -CustomScript $data.customScript
    if (@($v.errors).Count -gt 0) {
        throw ("Fix these before building: " + ((@($v.errors) | ForEach-Object { $_.message }) -join '; '))
    }

    # Apps that are not in the (cached) winget catalog would be skipped silently on the PC
    $warnings = [System.Collections.Generic.List[object]]::new()
    foreach ($w in @($v.warnings)) { $warnings.Add($w) }
    if (Test-Path (Get-WingetCatalogPath)) {
        foreach ($chk in Test-WingetIds -Ids @($client.apps.winget)) {
            if (-not $chk.found) { $warnings.Add([ordered]@{ field = 'apps.winget'; message = "$($chk.id) is not in the winget catalog - it will be skipped" }) }
        }
    }
    $v.warnings = @($warnings)

    $client.computerName = Format-ComputerName $client.computerNamePattern $start
    $client.build = [ordered]@{
        client    = $Name
        batchId   = $BatchId
        batchName = if ($batch) { $batch.name } else { '' }
        start     = $start
        end       = $end
        media     = $Media
        builtAt   = (Get-Date).ToString('s')
        report    = [ordered]@{ url = $ReportUrl; token = if ($batch -and $ReportUrl) { $batch.token } else { '' } }
    }
    $custom = if ($client.features.customScript) { $data.customScript } else { '' }
    return [ordered]@{ name = $Name; client = $client; secrets = $secrets; customScript = $custom; batch = $batch; warnings = @($v.warnings) }
}

function New-SetupFolder {
    <# Generic scripts + this client's resolved client.json / secrets.json / custom.ps1. Only one client per image. #>
    param([Parameter(Mandatory)]$Resolved, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($f in $script:GenericSetupFiles) {
        $src = Join-Path $script:SetupSource $f
        if (-not (Test-Path $src)) { throw "Missing Setup\$f" }
        Copy-Item $src $Destination
    }
    Write-JsonFile (Join-Path $Destination 'client.json')  $Resolved.client
    Write-JsonFile (Join-Path $Destination 'secrets.json') $Resolved.secrets
    if (-not [string]::IsNullOrWhiteSpace($Resolved.customScript)) {
        Write-CrlfFile (Join-Path $Destination 'custom.ps1') $Resolved.customScript
    }
    Get-ChildItem $Destination -Filter *.cmd | ForEach-Object {
        Write-CrlfFile $_.FullName ([System.IO.File]::ReadAllText($_.FullName))
    }
}

function ConvertTo-XmlText([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

function New-AutounattendXml {
    <# Clean-install answer file from autounattend.template.xml. #>
    param([Parameter(Mandatory)]$Resolved)
    $tpl = Join-Path $script:RepoRoot 'autounattend.template.xml'
    # Drop the template's comments: they name the placeholders and would otherwise get the values (password) too
    $xml = [regex]::Replace([System.IO.File]::ReadAllText($tpl), '(?s)<!--.*?-->', '')
    $c = $Resolved.client; $s = $Resolved.secrets
    $map = [ordered]@{
        '%%ORGANIZATION%%'     = $c.organization
        '%%WINDOWS_EDITION%%'  = $c.windowsEdition
        '%%TIMEZONE%%'         = $c.timezone
        '%%ITADMIN_USERNAME%%' = $c.itAdmin.username
        '%%ITADMIN_DISPLAY%%'  = $(if ($c.itAdmin.displayName) { $c.itAdmin.displayName } else { $c.itAdmin.username })
        '%%ITADMIN_PASSWORD%%' = $s.itAdminPassword
        '%%COMPUTER_NAME%%'    = $c.computerName
        '%%UI_LANGUAGE%%'      = $c.locale.ui
        '%%INPUT_LOCALE%%'     = $c.locale.input
        '%%SYSTEM_LOCALE%%'    = $c.locale.system
        '%%USER_LOCALE%%'      = $c.locale.user
    }
    foreach ($k in $map.Keys) { $xml = $xml.Replace($k, (ConvertTo-XmlText ([string]$map[$k]))) }
    if ($xml -match '%%[A-Z_]+%%') { throw "Unfilled placeholder in answer file: $($Matches[0])" }
    [xml]$xml | Out-Null   # must be well-formed
    return $xml
}

function Get-BuildDir([string]$Name, [string]$BatchId) {
    $sub = if ($BatchId) { $BatchId } else { 'default' }
    $dir = Join-Path (Join-Path $script:DistRoot $Name) $sub
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Get-SafeFileName([string]$s) { return (($s -replace '[^A-Za-z0-9_-]', '') -replace '^$', 'client') }

# ====================================================================
# ISO creation (macOS: hdiutil, Windows: IMAPI2 or oscdimg, Linux: xorriso)
# ====================================================================

function Get-IsoTool {
    if ($IsMacOS -and (Get-Command hdiutil -ErrorAction SilentlyContinue)) { return 'hdiutil' }
    if ($IsWindows) { return 'imapi2' }
    foreach ($t in 'xorriso', 'genisoimage', 'mkisofs') { if (Get-Command $t -ErrorAction SilentlyContinue) { return $t } }
    return $null
}

function Find-Oscdimg {
    if (-not $IsWindows) { return $null }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = @("$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
           "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe") |
         Where-Object { Test-Path $_ } | Select-Object -First 1
    return $p
}

function Initialize-ImapiWriter {
    if ('ProvIsoWriter' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ProvIsoWriter {
    public static void Write(string path, object stream) {
        IStream s = (IStream)stream;
        byte[] buf = new byte[1048576];
        IntPtr pcb = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (FileStream fs = File.Create(path)) {
                while (true) {
                    s.Read(buf, buf.Length, pcb);
                    int n = Marshal.ReadInt32(pcb);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n);
                }
            }
        } finally { Marshal.FreeHGlobal(pcb); }
    }
}
'@
}

function New-ImapiBootOption([string]$File, [int]$PlatformId) {
    $stream = New-Object -ComObject ADODB.Stream
    $stream.Open()
    $stream.Type = 1   # binary
    $stream.LoadFromFile($File)
    $boot = New-Object -ComObject IMAPI2FS.BootOptions
    $boot.AssignBootImage($stream)
    $boot.PlatformId = $PlatformId   # 0 = BIOS (x86), 0xEF = UEFI
    $boot.Emulation  = 0             # no emulation
    return $boot
}

function New-IsoImage {
    <#
    .SYNOPSIS  Creates an ISO from a folder.
    -BiosBoot / -UefiBoot make it bootable (Windows only: oscdimg if the ADK
    is installed, otherwise the built-in IMAPI2 - no ADK needed).
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$VolumeName = 'PROVISION',
        [string]$BiosBoot = '',
        [string]$UefiBoot = ''
    )
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    $bootable = [bool]($BiosBoot -or $UefiBoot)
    $tool = Get-IsoTool

    if ($bootable -and -not $IsWindows) {
        throw 'A bootable (clean-install) ISO can only be built on Windows. On macOS build the clean-install USB folder instead.'
    }

    if ($bootable -and (Find-Oscdimg)) {
        $osc = Find-Oscdimg
        $bootData = "2#p0,e,b$BiosBoot#pEF,e,b$UefiBoot"
        & $osc -m -o -u2 -udfver102 "-l$VolumeName" "-bootdata:$bootData" $SourceDir $OutFile | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)" }
        return $OutFile
    }

    switch ($tool) {
        'hdiutil' {
            & hdiutil makehybrid -iso -joliet -default-volume-name $VolumeName -o $OutFile $SourceDir | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "hdiutil failed ($LASTEXITCODE)" }
        }
        'imapi2' {
            Initialize-ImapiWriter
            $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
            $fsi.ChooseImageDefaultsForMediaType(18)   # BD-R: room for a full Windows image
            # Bootable Windows media: UDF only (install.wim is > 4 GB). Data ISO: ISO9660 + Joliet.
            $fsi.FileSystemsToCreate = if ($bootable) { 4 } else { 3 }
            if ($bootable) { $fsi.UDFRevision = 0x102 }
            $fsi.VolumeName = $VolumeName
            $fsi.Root.AddTree($SourceDir, $false)
            if ($bootable) {
                $opts = @()
                if ($BiosBoot) { $opts += New-ImapiBootOption $BiosBoot 0 }
                if ($UefiBoot) { $opts += New-ImapiBootOption $UefiBoot 0xEF }
                if ($opts.Count -gt 1) { $fsi.BootImageOptionsArray = [object[]]$opts }
                else { $fsi.BootImageOptions = $opts[0] }
            }
            $result = $fsi.CreateResultImage()
            [ProvIsoWriter]::Write($OutFile, $result.ImageStream)
        }
        { $_ -in 'xorriso' } {
            & xorriso -as mkisofs -J -R -V $VolumeName -o $OutFile $SourceDir | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "xorriso failed ($LASTEXITCODE)" }
        }
        { $_ -in 'genisoimage', 'mkisofs' } {
            & $tool -J -R -V $VolumeName -o $OutFile $SourceDir | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "$tool failed ($LASTEXITCODE)" }
        }
        default { throw 'No ISO tool found (macOS: hdiutil, Windows: built in, Linux: install xorriso).' }
    }
    if (-not (Test-Path $OutFile)) { throw "ISO was not created: $OutFile" }
    return $OutFile
}

# ====================================================================
# Builds
# ====================================================================

function Invoke-ProvisionBuild {
    <# Provisioning-only ISO (PCs at the OOBE screen). Mount as CD-ROM. #>
    param([Parameter(Mandatory)][string]$Name, [string]$BatchId = '', [string]$ReportUrl = '')
    $r = Resolve-BuildConfig -Name $Name -BatchId $BatchId -Media 'provision' -ReportUrl $ReportUrl
    foreach ($w in $r.warnings) { Write-Host "WARNING: $($w.message)" }
    $c = $r.client
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('provision-iso-' + [guid]::NewGuid().ToString('N'))
    try {
        New-SetupFolder -Resolved $r -Destination (Join-Path $stage 'Setup')
        Write-CrlfFile (Join-Path $stage 'RUN.cmd') @'
@echo off
rem Usage at the OOBE screen (Shift+F10):  D:\RUN <PC number>     e.g.  D:\RUN 3
call "%~d0\Setup\Provision-OOBE.cmd" %*
'@
        $example = Format-ComputerName $c.computerNamePattern ([Math]::Min($c.build.start + 2, $c.build.end))
        $range = "$($c.build.start) to $($c.build.end)"
        Write-CrlfFile (Join-Path $stage 'README.txt') @"
$($c.organization) - Windows 11 provisioning (no reinstall)
Batch: $(if ($c.build.batchName) { $c.build.batchName } else { '(none)' })   PC numbers: $range

1. Mount this ISO AS CD-ROM, power on, let Windows boot to the setup (OOBE) screen.
2. Press Shift+F10 to open a command prompt.
3. Type:  D:\RUN <number>     e.g.  D:\RUN $(Get-ComputerNumber $c.computerNamePattern $example)  ->  $example
   If D: is not the DVD drive, try E:
4. The PC reboots and finishes on its own, then stops at the sign-in screen.
   Unmount the ISO after the first reboot.
"@
        $out = Join-Path (Get-BuildDir $Name $BatchId) ((Get-SafeFileName $c.organization) + '-Provision.iso')
        Write-Host "Creating ISO ($(Get-IsoTool))..."
        New-IsoImage -SourceDir $stage -OutFile $out -VolumeName 'PROVISION' | Out-Null
        Write-Host "[OK] $out"
        return [ordered]@{
            outputs      = @($out)
            instructions = @(
                'Mount the ISO on the KVM as CD-ROM (not flash drive).',
                'Power on, wait for the Windows setup (OOBE) screen, press Shift+F10.',
                "Type D:\RUN <PC number> (numbers $range, e.g. D:\RUN $($c.build.start) -> $(Format-ComputerName $c.computerNamePattern $c.build.start)).",
                'The PC reboots and finishes on its own. Unmount after the first reboot.'
            )
            warnings     = @($r.warnings | ForEach-Object { $_.message })
        }
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-UsbBuild {
    <# Clean-install USB folder: autounattend.xml + Setup\. Copy its contents onto a Windows 11 USB. #>
    param([Parameter(Mandatory)][string]$Name, [string]$BatchId = '', [string]$ReportUrl = '', [string]$Media = 'usb')
    $r = Resolve-BuildConfig -Name $Name -BatchId $BatchId -Media $Media -ReportUrl $ReportUrl
    foreach ($w in $r.warnings) { Write-Host "WARNING: $($w.message)" }
    $usb = Join-Path (Get-BuildDir $Name $BatchId) 'usb'
    New-SetupFolder -Resolved $r -Destination (Join-Path $usb 'Setup')
    [System.IO.File]::WriteAllText((Join-Path $usb 'autounattend.xml'), (New-AutounattendXml -Resolved $r), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "[OK] $usb"
    return [ordered]@{
        outputs      = @($usb)
        instructions = @(
            'Write a stock Windows 11 ISO to a USB stick (Rufus: GPT / UEFI).',
            "Copy the CONTENTS of $usb to the root of the USB stick.",
            "Boot each PC from the USB - the disk is WIPED. First PC: $($r.client.computerName); the name increments on the stick.",
            'Delete autounattend.xml and Setup\secrets.json from the stick when the batch is done.'
        )
        warnings     = @($r.warnings | ForEach-Object { $_.message })
        resolved     = $r
    }
}

function Invoke-CleanIsoBuild {
    <# Bootable clean-install ISO (Windows only). Needs a stock Windows 11 ISO; uses oscdimg if the ADK is installed, else IMAPI2. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$StockIso, [string]$BatchId = '', [string]$ReportUrl = '')
    if (-not $IsWindows) { throw 'The clean-install ISO can only be built on Windows. On macOS use the clean-install USB folder.' }
    if (-not (Test-Path $StockIso)) { throw "Stock ISO not found: $StockIso" }
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Building the clean-install ISO mounts the stock ISO, which needs Administrator. Start the UI (or pwsh) as Administrator.'
    }
    $usbResult = Invoke-UsbBuild -Name $Name -BatchId $BatchId -ReportUrl $ReportUrl -Media 'iso'
    $usb = $usbResult.outputs[0]
    $c = $usbResult.resolved.client
    $work = Join-Path $env:SystemDrive ('provwork_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $StockIso = (Resolve-Path $StockIso).Path
    $mounted = $false
    try {
        New-Item -ItemType Directory -Path $work | Out-Null
        Write-Host 'Mounting the stock ISO...'
        $img = Mount-DiskImage -ImagePath $StockIso -PassThru
        $mounted = $true
        $drive = ($img | Get-Volume).DriveLetter + ':'
        Write-Host 'Copying Windows files (a few minutes)...'
        Copy-Item -Path "$drive\*" -Destination $work -Recurse -Force
        Dismount-DiskImage -ImagePath $StockIso | Out-Null
        $mounted = $false
        Get-ChildItem $work -Recurse -File | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
        Copy-Item (Join-Path $usb 'autounattend.xml') $work -Force
        Copy-Item (Join-Path $usb 'Setup') $work -Recurse -Force
        $bios = Join-Path $work 'boot\etfsboot.com'
        $uefi = Join-Path $work 'efi\microsoft\boot\efisys.bin'   # 'press any key' prompt kept on purpose: this media wipes the disk
        foreach ($f in $bios, $uefi) { if (-not (Test-Path $f)) { throw "Boot file missing in stock ISO: $f" } }
        $out = Join-Path (Get-BuildDir $Name $BatchId) ("Win11-" + (Get-SafeFileName $c.organization) + '-Install.iso')
        Write-Host "Creating bootable ISO ($(if (Find-Oscdimg) { 'oscdimg' } else { 'IMAPI2, no ADK' }))..."
        New-IsoImage -SourceDir $work -OutFile $out -VolumeName 'WIN11_INSTALL' -BiosBoot $bios -UefiBoot $uefi | Out-Null
        Write-Host "[OK] $out"
        return [ordered]@{
            outputs      = @($out, $usb)
            instructions = @(
                'Boot each PC from this ISO (KVM / VM: CD-ROM first in boot order; or write to USB with Rufus).',
                'Press a key when asked to boot from CD - the disk is WIPED.',
                "First PC is named $($c.computerName). The ISO is read-only: change the batch / pattern to name the next PCs, or use the USB folder (auto-increments)."
            )
            warnings     = $usbResult.warnings
        }
    } finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $StockIso -ErrorAction SilentlyContinue | Out-Null }
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ProvBuild {
    <# Entry point used by the UI jobs and the CLI. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('provision', 'usb', 'iso')][string]$Media,
          [string]$BatchId = '', [string]$ReportUrl = '', [string]$StockIso = '')
    switch ($Media) {
        'provision' { $r = Invoke-ProvisionBuild -Name $Name -BatchId $BatchId -ReportUrl $ReportUrl }
        'usb'       { $r = Invoke-UsbBuild -Name $Name -BatchId $BatchId -ReportUrl $ReportUrl }
        'iso'       { $r = Invoke-CleanIsoBuild -Name $Name -BatchId $BatchId -ReportUrl $ReportUrl -StockIso $StockIso }
    }
    if ($r.Contains('resolved')) { $r.Remove('resolved') }
    return $r
}

# ====================================================================
# winget catalog (the official index, downloaded and searched locally)
# ====================================================================

$script:WingetCatalog = $null

function Get-WingetCatalogPath { Join-Path $script:CacheRoot 'winget-catalog.json' }
function Get-WingetCatalogMetaPath { Join-Path $script:CacheRoot 'winget-catalog.meta.json' }

function Initialize-WinSqlite {
    if ('ProvSqlite' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ProvSqlite {
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)]
    static extern int Open16(string filename, out IntPtr db);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare16_v2", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)]
    static extern int Prepare16(IntPtr db, string sql, int nBytes, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step", CallingConvention = CallingConvention.StdCall)]
    static extern int Step(IntPtr stmt);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text16", CallingConvention = CallingConvention.StdCall)]
    static extern IntPtr ColumnText16(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize", CallingConvention = CallingConvention.StdCall)]
    static extern int Finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close", CallingConvention = CallingConvention.StdCall)]
    static extern int Close(IntPtr db);
    public static List<string[]> Query(string file, string sql, int columns) {
        IntPtr db, stmt;
        if (Open16(file, out db) != 0) throw new Exception("sqlite open failed");
        var rows = new List<string[]>();
        try {
            if (Prepare16(db, sql, -1, out stmt, IntPtr.Zero) != 0) throw new Exception("sqlite prepare failed");
            try {
                while (Step(stmt) == 100) {
                    var row = new string[columns];
                    for (int i = 0; i < columns; i++) { IntPtr p = ColumnText16(stmt, i); row[i] = p == IntPtr.Zero ? "" : Marshal.PtrToStringUni(p); }
                    rows.Add(row);
                }
            } finally { Finalize(stmt); }
        } finally { Close(db); }
        return rows;
    }
}
'@
}

function Update-WingetCatalog {
    <# Downloads the official winget index (source2.msix, ~4 MB) and caches id/name/version as JSON. #>
    param([switch]$Force, [int]$MaxAgeDays = 7)
    $out = Get-WingetCatalogPath
    if (-not $Force -and (Test-Path $out) -and ((Get-Date) - (Get-Item $out).LastWriteTime).TotalDays -lt $MaxAgeDays) {
        return (Get-WingetCatalogInfo)
    }
    New-Item -ItemType Directory -Path $script:CacheRoot -Force | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msix = Join-Path $tmp 'source2.msix'
        Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache/source2.msix' -OutFile $msix -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq 'Public/index.db' } | Select-Object -First 1
            if (-not $entry) { throw 'index.db not found in source2.msix' }
            $db = Join-Path $tmp 'index.db'
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $db, $true)
        } finally { $zip.Dispose() }

        $sql = 'SELECT id, name, latest_version FROM packages ORDER BY id'
        $rows = [System.Collections.Generic.List[object]]::new()
        if ($IsWindows) {
            Initialize-WinSqlite
            foreach ($r in [ProvSqlite]::Query($db, $sql, 3)) { $rows.Add([ordered]@{ id = $r[0]; name = $r[1]; version = $r[2] }) }
        } elseif (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
            $sep = [char]0x1f
            foreach ($line in (& sqlite3 -separator $sep $db $sql)) {
                $p = $line.Split($sep)
                if ($p.Count -ge 3) { $rows.Add([ordered]@{ id = $p[0]; name = $p[1]; version = $p[2] }) }
            }
        } else {
            throw 'sqlite3 not found (macOS has it built in; on Linux install sqlite3).'
        }
        if ($rows.Count -lt 1000) { throw "winget catalog looks incomplete ($($rows.Count) packages)" }
        $stamp = (Get-Date).ToString('s')
        Write-JsonFile $out ([ordered]@{ updated = $stamp; count = $rows.Count; packages = @($rows) })
        Write-JsonFile (Get-WingetCatalogMetaPath) ([ordered]@{ updated = $stamp; count = $rows.Count })
        $script:WingetCatalog = $null
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return (Get-WingetCatalogInfo)
}

function Get-WingetCatalog {
    if ($script:WingetCatalog) { return $script:WingetCatalog }
    $path = Get-WingetCatalogPath
    if (-not (Test-Path $path)) { Update-WingetCatalog | Out-Null }
    $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    $index = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $data.packages) { $index[$p.id] = $p }
    $script:WingetCatalog = [pscustomobject]@{ updated = $data.updated; count = $data.count; packages = $data.packages; index = $index }
    return $script:WingetCatalog
}

function Get-WingetCatalogInfo {
    # Cheap: read the small meta file instead of loading 16,000 packages
    $path = Get-WingetCatalogPath
    if (-not (Test-Path $path)) { return [ordered]@{ available = $false; updated = $null; count = 0 } }
    $meta = Read-JsonFile (Get-WingetCatalogMetaPath)
    if ($meta) { return [ordered]@{ available = $true; updated = $meta.updated; count = $meta.count } }
    $cat = Get-WingetCatalog
    Write-JsonFile (Get-WingetCatalogMetaPath) ([ordered]@{ updated = $cat.updated; count = $cat.count })
    return [ordered]@{ available = $true; updated = $cat.updated; count = $cat.count }
}

function Search-WingetCatalog {
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 25)
    $q = $Query.Trim()
    if ($q.Length -lt 2) { return @() }
    $cat = Get-WingetCatalog
    $scored = foreach ($p in $cat.packages) {
        $score = -1
        if ($p.id -ieq $q -or $p.name -ieq $q) { $score = 0 }
        elseif ($p.name.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)) { $score = 1 }
        elseif ($p.id.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)) { $score = 2 }
        elseif ($p.name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $score = 3 }
        elseif ($p.id.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $score = 4 }
        if ($score -ge 0) { [pscustomobject]@{ score = $score; id = $p.id; name = $p.name; version = $p.version } }
    }
    return @($scored | Sort-Object score, name | Select-Object -First $Limit | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; version = $_.version } })
}

function Test-WingetIds {
    <# For each ID: found in the official catalog? (exact, case-insensitive) #>
    param([string[]]$Ids)
    $cat = Get-WingetCatalog
    return @(foreach ($id in $Ids) {
        $hit = $null
        $found = $cat.index.TryGetValue($id, [ref]$hit)
        [ordered]@{ id = $id; found = $found; name = $(if ($found) { $hit.name } else { '' }); canonicalId = $(if ($found) { $hit.id } else { '' }) }
    })
}

# ====================================================================
# Migration from the old config.ps1 format
# ====================================================================

function Convert-LegacyClient {
    <# clients\<Name>\config.ps1 (+ packages.json, installers.json) -> client.json + secrets.json. Old files are renamed *.legacy. #>
    param([Parameter(Mandatory)][string]$Name, [switch]$Force)
    $dir = Get-ClientDir $Name
    $cfgPath = Join-Path $dir 'config.ps1'
    if (-not (Test-Path $cfgPath)) { throw "No config.ps1 in $dir" }
    if ((Test-Path (Join-Path $dir 'client.json')) -and -not $Force) { throw "$Name already has client.json (use -Force to overwrite)" }

    # Read the old file in an isolated scope
    $vals = & {
        $Config_Organization = ''; $Config_WindowsEdition = ''; $Config_Timezone = ''
        $Config_ITAdminUsername = ''; $Config_ITAdminDisplayName = ''; $Config_ITAdminPassword = ''
        $Config_PackageFile = ''; $Config_WifiSSID = ''; $Config_WifiPassword = ''; $Config_TailscaleAuthKey = ''
        $Config_Action1AgentUrl = ''; $Config_ComputerName = ''; $Config_NewUsername = ''; $Config_NewFullName = ''
        $Config_NewPassword = ''; $Config_NewUserIsAdmin = $false
        . $args[0]
        Get-Variable -Name 'Config_*' | ForEach-Object -Begin { $h = @{} } -Process { $h[$_.Name] = $_.Value } -End { $h }
    } $cfgPath
    function V($k) { $v = $vals[$k]; if ($null -eq $v) { '' } else { [string]$v } }

    $c = Get-DefaultClient
    $c.organization   = V 'Config_Organization'
    if (V 'Config_WindowsEdition') { $c.windowsEdition = V 'Config_WindowsEdition' }
    if (V 'Config_Timezone')       { $c.timezone = V 'Config_Timezone' }
    if (V 'Config_ITAdminUsername') { $c.itAdmin.username = V 'Config_ITAdminUsername' }
    if (V 'Config_ITAdminDisplayName') { $c.itAdmin.displayName = V 'Config_ITAdminDisplayName' }
    $legacyName = V 'Config_ComputerName'
    $c.computerNamePattern = if ($legacyName -match '^(.*?)(\d+)$') { $Matches[1] + ('#' * $Matches[2].Length) } elseif ($legacyName) { $legacyName } else { 'PC-##' }
    $c.endUser.username = V 'Config_NewUsername'
    $c.endUser.fullName = V 'Config_NewFullName'
    $c.endUser.isAdmin  = [bool]$vals['Config_NewUserIsAdmin']
    $c.endUser.create   = [bool](V 'Config_NewUsername')
    $c.wifi.ssid        = V 'Config_WifiSSID'
    $c.features.action1   = [bool](V 'Config_Action1AgentUrl')
    $c.features.tailscale = ((V 'Config_TailscaleAuthKey') -match '^tskey-')

    $pkgName = if (V 'Config_PackageFile') { V 'Config_PackageFile' } else { 'packages.json' }
    $pkgPath = Join-Path $dir $pkgName
    if (Test-Path $pkgPath) {
        $pkg = Read-JsonFile $pkgPath
        $c.apps.winget = @($pkg.Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier } | Where-Object { $_ })
    }
    $instPath = Join-Path $dir 'installers.json'
    if (Test-Path $instPath) {
        $inst = Read-JsonFile $instPath
        if ($inst.Contains('installers')) { $c.apps.installers = @($inst.installers) }
        if ($inst.Contains('webApps'))    { $c.apps.webApps = @($inst.webApps) }
    }

    $s = Get-DefaultSecrets
    $s.itAdminPassword  = V 'Config_ITAdminPassword'
    $s.endUserPassword  = V 'Config_NewPassword'
    $s.wifiPassword     = V 'Config_WifiPassword'
    $s.tailscaleAuthKey = V 'Config_TailscaleAuthKey'
    $s.action1AgentUrl  = V 'Config_Action1AgentUrl'

    Save-ClientData -Name $Name -Client $c -Secrets $s -CustomScript $null | Out-Null
    foreach ($old in @('config.ps1', $pkgName, 'installers.json')) {
        $p = Join-Path $dir $old
        if (Test-Path $p) { Move-Item $p "$p.legacy" -Force }
    }
    return (Get-ClientData -Name $Name)
}

# ====================================================================
# System info (for the UI)
# ====================================================================

function Get-LanAddresses {
    $addrs = foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $ua.Address.ToString()
            if ($ip -like '169.254.*' -or $ip -like '127.*') { continue }
            $ip
        }
    }
    # private ranges first
    return @($addrs | Sort-Object { if ($_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { 0 } else { 1 } } -Unique)
}

function Get-ProvSystemInfo {
    $os = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' }
    $isAdmin = $false
    if ($IsWindows) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    [ordered]@{
        os              = $os
        pwsh            = $PSVersionTable.PSVersion.ToString()
        isoTool         = Get-IsoTool
        oscdimg         = [bool](Find-Oscdimg)
        cleanIsoPossible = [bool]$IsWindows
        isAdmin         = $isAdmin
        repo            = $script:RepoRoot
        lanAddresses    = @(Get-LanAddresses)
        wingetCatalog   = Get-WingetCatalogInfo
    }
}

Export-ModuleMember -Function @(
    'Get-ProvPaths', 'Get-DefaultClient', 'Get-DefaultSecrets', 'Get-ProvMeta',
    'Format-ComputerName', 'Get-ComputerNumber', 'Test-ComputerName',
    'Test-ClientData', 'Get-ClientList', 'Get-ClientData', 'Save-ClientData', 'New-ClientFromTemplate',
    'Get-Batch', 'Save-Batch', 'Set-MachineStatus', 'Add-MachineReport', 'Find-BatchByToken',
    'Resolve-BuildConfig', 'New-SetupFolder', 'New-AutounattendXml', 'New-IsoImage', 'Get-IsoTool', 'Find-Oscdimg',
    'Invoke-ProvisionBuild', 'Invoke-UsbBuild', 'Invoke-CleanIsoBuild', 'Invoke-ProvBuild',
    'Update-WingetCatalog', 'Get-WingetCatalogInfo', 'Search-WingetCatalog', 'Test-WingetIds',
    'Convert-LegacyClient', 'Get-LanAddresses', 'Get-ProvSystemInfo', 'Read-JsonFile', 'Write-JsonFile', 'Copy-Deep'
)
