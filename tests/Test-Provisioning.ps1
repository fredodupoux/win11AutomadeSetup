#Requires -Version 7.0
<#
.SYNOPSIS
    Self-contained tests (no Pester needed). Runs on macOS or Windows against a
    throw-away copy of the project, so real clients are never touched.

.EXAMPLE
    pwsh ./tests/Test-Provisioning.ps1             # everything
    pwsh ./tests/Test-Provisioning.ps1 -Offline    # skip the winget catalog download
    pwsh ./tests/Test-Provisioning.ps1 -UI         # also click through the UI in headless Chrome/Edge (needs Node.js)
#>
param([switch]$Offline, [switch]$UI)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$script:Passed = 0
$script:Failed = 0

function Assert([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:Passed++; Write-Host "  ok   $Message" -ForegroundColor DarkGreen }
    else { $script:Failed++; Write-Host "  FAIL $Message" -ForegroundColor Red }
}
function Assert-Throws([scriptblock]$Block, [string]$Message) {
    try { & $Block; Assert $false "$Message (did not throw)" } catch { Assert $true $Message }
}
function Section([string]$Name) { Write-Host ''; Write-Host "== $Name" -ForegroundColor Cyan }

# ---------------------------------------------------------------------
# Sandbox copy of the project
# ---------------------------------------------------------------------
$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('prov-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Sandbox | Out-Null
foreach ($item in 'lib', 'Setup', 'ui', 'tools', 'autounattend.template.xml', 'Start-UI.ps1') {
    Copy-Item -Path (Join-Path $Repo $item) -Destination $Sandbox -Recurse
}
New-Item -ItemType Directory -Path (Join-Path $Sandbox 'clients') | Out-Null
Copy-Item -Path (Join-Path $Repo 'clients/_example') -Destination (Join-Path $Sandbox 'clients') -Recurse
$cachedCatalog = Join-Path $Repo 'cache/winget-catalog.json'
if (Test-Path $cachedCatalog) {
    New-Item -ItemType Directory -Path (Join-Path $Sandbox 'cache') | Out-Null
    Copy-Item $cachedCatalog (Join-Path $Sandbox 'cache')
}
Import-Module (Join-Path $Sandbox 'lib/Provisioning.psm1') -Force
Write-Host "Sandbox: $Sandbox"

try {
    Section 'Computer names'
    Assert ((Format-ComputerName 'SAFITEKHT-CS-##' 3) -eq 'SAFITEKHT-CS-03') 'pattern + number'
    Assert ((Format-ComputerName 'acme-pc-###' 12) -eq 'ACME-PC-012') 'zero padding + uppercase'
    Assert ((Format-ComputerName 'KIOSK' 7) -eq 'KIOSK') 'fixed name without #'
    Assert ((Get-ComputerNumber 'SAFITEKHT-CS-##' 'safitekht-cs-11') -eq 11) 'number from name'
    Assert ($null -eq (Get-ComputerNumber 'SAFITEKHT-CS-##' 'OTHER-01')) 'non-matching name -> null'
    Assert ([bool](Test-ComputerName 'BERLING-PROD-PC01')) 'name > 15 chars rejected'
    Assert (-not (Test-ComputerName 'ACME-PC-01')) 'valid name accepted'

    Section 'Clients'
    Assert-Throws { New-ClientFromTemplate -Name 'Bad Name' } 'invalid client name rejected'
    Assert-Throws { New-ClientFromTemplate -Name '../evil' } 'path traversal rejected'
    $acme = New-ClientFromTemplate -Name 'acme'
    Assert (Test-Path (Join-Path $Sandbox 'clients/acme/client.json')) 'client.json created from template'
    Assert ($acme.client.organization -eq 'ACME') 'organization defaults to the name'
    $v = Test-ClientData -Client $acme.client -Secrets $acme.secrets
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'secrets.itAdminPassword' }).Count -eq 1) 'missing IT admin password is an error'

    $acme.client.computerNamePattern = 'ACME-PC-##'
    $acme.client.wifi.ssid = 'Office'
    $acme.client.features.customScript = $true
    $secrets = $acme.secrets
    $secrets.itAdminPassword = 'Adm1n-Pass!'
    $secrets.endUserPassword = 'Welcome-2026'
    $secrets.wifiPassword = 'wifi<&>"pass'
    $v = Save-ClientData -Name 'acme' -Client $acme.client -Secrets $secrets -CustomScript "param(`$Client)`nWrite-Host hi"
    Assert (@($v.errors).Count -eq 0) "valid client has no errors ($((@($v.errors) | ForEach-Object message) -join '; '))"
    Assert (-not ((Get-Content (Join-Path $Sandbox 'clients/acme/client.json') -Raw) -match 'Adm1n')) 'no password in client.json'
    Assert ((Get-DefaultClient).features.shareUpdates -eq $true) 'update sharing is on by default'
    Assert (Test-Path (Join-Path $Sandbox 'clients/acme/custom.ps1')) 'custom.ps1 saved'

    $bad = Copy-Deep $acme.client
    $bad.features.action1 = $true
    $bad.apps.winget = @('not a winget id')
    $bad.locale.input = 'zz zz'
    $v = Test-ClientData -Client $bad -Secrets $secrets
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'secrets.action1AgentUrl' }).Count -eq 1) 'Action1 on without URL is an error'
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'apps.winget' }).Count -eq 1) 'bad winget id is an error'
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'locale.input' }).Count -eq 1) 'bad locale is an error'

    $ad = Copy-Deep $acme.client
    $ad.features.anydesk = $true
    $ad.apps.winget = @('Google.Chrome')
    $adSecrets = Copy-Deep $secrets
    $v = Test-ClientData -Client $ad -Secrets $adSecrets
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'secrets.anydeskPassword' }).Count -eq 1) 'AnyDesk on without a password is an error'
    $adSecrets.anydeskPassword = 'Remote-2026!'
    $v = Test-ClientData -Client $ad -Secrets $adSecrets
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'secrets.anydeskPassword' }).Count -eq 0) 'AnyDesk password accepted'
    Assert (@(@($v.warnings) | Where-Object { $_.field -eq 'secrets.anydeskPassword' }).Count -eq 1) 'AnyDesk on but not in the app list is a warning'
    $adSecrets.anydeskPassword = 'has space 1'
    $v = Test-ClientData -Client $ad -Secrets $adSecrets
    Assert (@(@($v.errors) | Where-Object { $_.field -eq 'secrets.anydeskPassword' }).Count -eq 1) 'AnyDesk password with a space is an error'

    $copy = New-ClientFromTemplate -Name 'acme2' -From 'acme'
    Assert ($copy.client.computerNamePattern -eq 'ACME-PC-##') 'copy keeps settings'
    Assert (-not $copy.secrets.itAdminPassword) 'copy does not copy passwords'
    Assert (@(Get-ClientList | ForEach-Object name) -contains 'acme2') 'client list includes the copy'

    Section 'Batches'
    Assert-Throws { Save-Batch -Name 'acme' -Batch @{ name = 'x'; start = 5; end = 2 } } 'end < start rejected'
    Assert-Throws { Save-Batch -Name 'acme' -Batch @{ name = 'x'; start = 1; end = 120 } } 'more PCs than # digits rejected'
    $batch = Save-Batch -Name 'acme' -Batch @{ name = 'Front desk'; computerNamePattern = 'ACME-FD-##'; start = 3; end = 6; overrides = @{ wifiSsid = 'Guest'; endUserUsername = 'frontdesk' } }
    Assert ($batch.id -and $batch.token.Length -eq 32) 'batch gets an id and a token'
    $batch2 = Save-Batch -Name 'acme' -Batch @{ id = $batch.id; name = 'Front desk 2'; start = 3; end = 7; overrides = @{ wifiSsid = 'Guest' } }
    Assert ($batch2.token -eq $batch.token -and $batch2.end -eq 7) 'editing keeps the token'

    $r = Resolve-BuildConfig -Name 'acme' -BatchId $batch.id -Media 'provision' -ReportUrl 'http://10.0.0.5:8765/api/report'
    Assert ($r.client.computerName -eq 'ACME-PC-03') 'first name uses batch start (pattern from client when batch pattern cleared)'
    Assert ($r.client.wifi.ssid -eq 'Guest') 'batch WiFi override applied'
    Assert ($r.client.build.report.token -eq $batch.token) 'report token embedded when a report URL is set'

    Section 'Clean-install USB folder'
    $usb = Invoke-UsbBuild -Name 'acme' -BatchId $batch.id
    $usbDir = $usb.outputs[0]
    $xmlText = Get-Content (Join-Path $usbDir 'autounattend.xml') -Raw
    $xml = [xml]$xmlText
    Assert ($null -ne $xml) 'autounattend.xml is valid XML'
    Assert ($xmlText -notmatch '%%') 'no unfilled placeholders'
    Assert ($xmlText -notmatch '<!--') 'comments stripped (no password copies)'
    Assert ($xmlText -match '<ComputerName>ACME-PC-03</ComputerName>') 'computer name from batch'
    Assert ($xmlText -match 'wifi&lt;|DevicePasswordLess') 'answer file has the passwordless fix'
    Assert ($xmlText -match '<InputLocale>en-US</InputLocale>') 'locale filled'
    foreach ($f in 'Setup.ps1', 'Provision-OOBE.ps1', 'Launch-Setup.cmd', 'client.json', 'secrets.json', 'custom.ps1') {
        Assert (Test-Path (Join-Path $usbDir "Setup/$f")) "Setup\$f staged"
    }
    Assert (-not (Test-Path (Join-Path $usbDir 'Setup/batches.json'))) 'batches.json not on the media'
    $cmdBytes = [System.IO.File]::ReadAllBytes((Join-Path $usbDir 'Setup/Launch-Setup.cmd'))
    Assert (([System.Text.Encoding]::ASCII.GetString($cmdBytes)) -match "`r`n") '.cmd files have CRLF'

    Section 'Provisioning ISO'
    if (Get-IsoTool) {
        $prov = Invoke-ProvisionBuild -Name 'acme' -BatchId $batch.id
        $iso = $prov.outputs[0]
        Assert ((Test-Path $iso) -and (Get-Item $iso).Length -gt 50KB) "ISO created ($([int]((Get-Item $iso).Length / 1KB)) KB)"
        if ($IsMacOS) {
            $mount = (& hdiutil attach -readonly -nobrowse $iso 2>$null | Select-Object -Last 1).Split("`t")[-1].Trim()
            try {
                foreach ($f in 'RUN.cmd', 'README.txt', 'Setup/Setup.ps1', 'Setup/client.json', 'Setup/secrets.json') {
                    Assert (Test-Path (Join-Path $mount $f)) "ISO contains $f"
                }
                $c = Get-Content (Join-Path $mount 'Setup/client.json') -Raw | ConvertFrom-Json
                Assert ($c.build.start -eq 3 -and $c.build.end -eq 7) 'ISO client.json carries the batch range'
            } finally { & hdiutil detach $mount 2>$null | Out-Null }
        }
    } else { Write-Host '  skip (no ISO tool on this OS)' }

    Section 'Reports'
    $report = [ordered]@{ token = $batch.token; state = 'done'; computerName = 'ACME-PC-05'; serial = 'SN1'; model = 'M1'; warnings = 1; failures = 0; results = @() }
    $report.anydeskId = '123456789'; $report.ipAddress = '10.16.20.41'
    $m = Add-MachineReport $report
    Assert ($m.status -eq 'done' -and $m.number -eq 5) 'report marks PC 5 done'
    Assert ($m.anydeskId -eq '123456789' -and $m.ipAddress -eq '10.16.20.41') 'report keeps the AnyDesk ID and IP address'
    $report.hardware = @{ cpu = 'Intel N100 (4 cores, 4 threads)'; ram = '16 GB (1 x 16 GB)'; storage = '512 GB NVMe SSD (X)'; gpu = 'Intel UHD'; windows = 'Windows 11 Pro 24H2'; windowsBuild = '26100.1' }
    [void](Add-MachineReport $report)
    $saved = (Get-ClientData -Name 'acme').batches.batches | Where-Object { $_.id -eq $batch.id }
    Assert ($saved.machines['5'].hardware.ram -eq '16 GB (1 x 16 GB)' -and $saved.machines['5'].hardware.windowsBuild -eq '26100.1') 'hardware details saved with the PC'
    $report.token = 'wrong'
    Assert-Throws { Add-MachineReport $report } 'wrong token rejected'
    $report.token = $batch.token; $report.computerName = 'OTHER-01'
    Assert-Throws { Add-MachineReport $report } 'name outside the pattern rejected'
    $m = Set-MachineStatus -Name 'acme' -BatchId $batch.id -Number 6 -Fields @{ status = 'used'; source = 'manual' }
    Assert ($m.status -eq 'used') 'manual status saved'

    $progress = [ordered]@{ token = $batch.token; state = 'running'; computerName = 'ACME-PC-04'; currentStep = 'Apps (winget)'; stepIndex = 5; stepTotal = 19
                            stepStartedAt = '2026-11-24T20:00:00'; log = "line 1`nInstalling Google.Chrome..."; results = @() }
    $m = Add-MachineReport $progress
    Assert ($m.status -eq 'in-progress' -and $m.currentStep -eq 'Apps (winget)' -and $m.stepIndex -eq 5) 'progress report keeps the current step'
    Assert ($m.hasLog -and -not $m.Contains('log')) 'log is kept out of batches.json'
    Assert ((Get-MachineLog -Name 'acme' -BatchId $batch.id -Number 4) -like '*Installing Google.Chrome*') 'PC log saved to its own file'
    Assert ((Get-MachineLog -Name 'acme' -BatchId $batch.id -Number 3) -eq '') 'no log yet is empty'
    Assert-Throws { Get-MachineLog -Name 'acme' -BatchId '../x' -Number 4 } 'bad batch id rejected for logs'
    $progress.state = 'failed'; $progress.failures = 1; $progress.finishedAt = '2026-11-24T20:30:00'
    $m = Add-MachineReport $progress
    Assert ($m.status -eq 'done') 'a PC that finished with a failed step counts as finished'

    Section 'Hardware details'
    # Get-HardwareSpecs from Setup.ps1, run against stand-ins for the Windows commands
    $setupAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Sandbox 'Setup/Setup.ps1'), [ref]$null, [ref]$null)
    $fn = $setupAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HardwareSpecs' }, $true)
    $hw = & {
        Set-StrictMode -Version Latest
        function Get-CimInstance($ClassName) {
            switch ($ClassName) {
                'Win32_Processor' { [pscustomobject]@{ Name = 'Intel(R)  N100 '; NumberOfCores = 4; NumberOfLogicalProcessors = 4 } }
                'Win32_PhysicalMemory' { 1..2 | ForEach-Object { [pscustomobject]@{ Capacity = [uint64]8GB; ConfiguredClockSpeed = 3200 } } }
                'Win32_VideoController' {
                    [pscustomobject]@{ Name = 'Intel(R) UHD Graphics'; PNPDeviceID = 'PCI\VEN_8086' }
                    [pscustomobject]@{ Name = 'AnyDesk Virtual Display'; PNPDeviceID = 'ROOT\DISPLAY\0000' }
                }
                'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro' } }
            }
        }
        function Get-PhysicalDisk {
            [pscustomobject]@{ Size = [uint64]512110190592; BusType = 'NVMe'; MediaType = 'SSD'; FriendlyName = 'ACME 512' }
            [pscustomobject]@{ Size = [uint64]32000000000; BusType = 'USB'; MediaType = 'Unspecified'; FriendlyName = 'USB stick' }
        }
        function Get-ItemProperty { [pscustomobject]@{ DisplayVersion = '24H2'; CurrentBuildNumber = '26100'; UBR = 2314 } }
        $script:Hardware = $null
        . ([scriptblock]::Create($fn.Extent.Text))
        Get-HardwareSpecs
    }
    Assert ($hw.cpu -eq 'Intel(R) N100 (4 cores, 4 threads)') "processor: $($hw.cpu)"
    Assert ($hw.ram -eq '16 GB (2 x 8 GB, 3200 MT/s)') "memory: $($hw.ram)"
    Assert ($hw.storage -eq '512 GB NVMe SSD (ACME 512)') "storage, without USB drives: $($hw.storage)"
    Assert ($hw.gpu -eq 'Intel(R) UHD Graphics') "graphics, without virtual adapters: $($hw.gpu)"
    Assert ($hw.windows -eq 'Windows 11 Pro 24H2' -and $hw.windowsBuild -eq '26100.2314') "windows: $($hw.windows) $($hw.windowsBuild)"
    $none = & {
        Set-StrictMode -Version Latest
        function Get-CimInstance { throw 'unavailable' }
        function Get-PhysicalDisk { throw 'unavailable' }
        $script:Hardware = $null
        . ([scriptblock]::Create($fn.Extent.Text))
        Get-HardwareSpecs
    }
    Assert ($none.cpu -eq '' -and $none.storage -eq '' -and $none.windows -eq '') 'unreadable hardware is left blank, never an error'

    Section 'Legacy migration'
    $legacyDir = Join-Path $Sandbox 'clients/oldco'
    New-Item -ItemType Directory -Path $legacyDir | Out-Null
    @'
$Config_Organization       = 'OLDCO'
$Config_Timezone           = 'Haiti Standard Time'
$Config_ITAdminUsername    = 'itsupport'
$Config_ITAdminDisplayName = 'IT Support'
$Config_ITAdminPassword    = 'secret-1'
$Config_PackageFile        = 'packages.json'
$Config_WifiSSID           = 'Shop'
$Config_WifiPassword       = 'shopwifi1'
$Config_TailscaleAuthKey   = ''
$Config_ComputerName       = 'OLDCO-PC-07'
$Config_NewUsername        = 'clerk'
$Config_NewFullName        = 'Shop Clerk'
$Config_NewPassword        = 'change-me-1'
$Config_NewUserIsAdmin     = $false
$Config_Action1AgentUrl    = 'https://app.action1.com/agent/x/Windows/agent.msi'
'@ | Set-Content (Join-Path $legacyDir 'config.ps1')
    '{"Sources":[{"Packages":[{"PackageIdentifier":"Google.Chrome"},{"PackageIdentifier":"7zip.7zip"}]}]}' | Set-Content (Join-Path $legacyDir 'packages.json')
    Assert ((Get-ClientList | Where-Object name -eq 'oldco').legacy) 'old-format client flagged as legacy'
    $mig = Convert-LegacyClient -Name 'oldco'
    Assert ($mig.client.computerNamePattern -eq 'OLDCO-PC-##') 'pattern derived from old name'
    Assert ($mig.client.timezone -eq 'Haiti Standard Time') 'timezone kept'
    Assert (@($mig.client.apps.winget).Count -eq 2) 'winget apps imported'
    Assert ($mig.client.features.action1 -and -not $mig.client.features.tailscale) 'features derived from old values'
    Assert ($mig.secrets.itAdminPassword -eq 'secret-1' -and $mig.secrets.wifiPassword -eq 'shopwifi1') 'secrets moved to secrets.json'
    Assert (Test-Path (Join-Path $legacyDir 'config.ps1.legacy')) 'old config kept as .legacy'
    Assert (-not (Test-Path (Join-Path $Sandbox 'clients/OLDCO-PC-07'))) 'no stray folder named after the computer'

    Section 'winget catalog'
    if ($Offline -and -not (Test-Path (Join-Path $Sandbox 'cache/winget-catalog.json'))) { Write-Host '  skip (-Offline)' }
    else {
        $info = Update-WingetCatalog
        Assert ($info.count -gt 5000) "catalog loaded ($($info.count) packages)"
        $hits = Search-WingetCatalog -Query 'chrome'
        Assert (@($hits | Where-Object id -eq 'Google.Chrome').Count -eq 1) 'search finds Google.Chrome'
        $chk = Test-WingetIds -Ids @('google.chrome', 'WhatsApp.WhatsApp')
        Assert ($chk[0].found -and $chk[0].canonicalId -eq 'Google.Chrome') 'ID check is case-insensitive'
        Assert (-not $chk[1].found) 'WhatsApp.WhatsApp correctly reported missing'
    }

    Section 'UI server'
    $port = Get-Random -Minimum 20000 -Maximum 40000
    $job = Start-Job -ScriptBlock { param($s, $p) & (Join-Path $s 'Start-UI.ps1') -Port $p -NoBrowser -Lan } -ArgumentList $Sandbox, $port
    $base = "http://127.0.0.1:$port"
    $up = $false
    for ($i = 0; $i -lt 40 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 250
        try { Invoke-RestMethod "$base/api/system" -TimeoutSec 2 | Out-Null; $up = $true } catch { }
    }
    Assert $up 'server starts'
    if ($up) {
        $h = @{ 'X-Prov' = '1' }
        # Browsers open connections that send nothing; they must not block real requests
        $idle = 1..4 | ForEach-Object { $t = [System.Net.Sockets.TcpClient]::new(); $t.Connect('127.0.0.1', $port); $t }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-RestMethod "$base/api/system" -TimeoutSec 10 | Out-Null
        Invoke-RestMethod "$base/api/clients" -TimeoutSec 10 | Out-Null
        $sw.Stop()
        Assert ($sw.Elapsed.TotalSeconds -lt 3) "idle browser connections don't block requests ($([int]$sw.Elapsed.TotalMilliseconds) ms)"
        $idle | ForEach-Object { $_.Close() }
        $half = [System.Net.Sockets.TcpClient]::new(); $half.Connect('127.0.0.1', $port)
        $hs = $half.GetStream(); $partial = [System.Text.Encoding]::ASCII.GetBytes("GET /api/system HTTP/1.1`r`nHost: localhost`r`n")
        $hs.Write($partial, 0, $partial.Length)
        $sw.Restart(); Invoke-RestMethod "$base/api/meta" -TimeoutSec 10 | Out-Null; $sw.Stop()
        Assert ($sw.Elapsed.TotalSeconds -lt 3) 'a half-sent request does not block others'
        $half.Close()
        $page = Invoke-WebRequest "$base/" -UseBasicParsing
        Assert ($page.Content -match 'app.js') 'serves the UI'
        $list = Invoke-RestMethod "$base/api/clients"
        Assert (@($list.clients.name) -contains 'acme') 'GET /api/clients'
        $d = Invoke-RestMethod "$base/api/clients/acme"
        Assert ($d.client.organization -eq 'ACME') 'GET /api/clients/acme'
        $body = @{ client = $d.client; secrets = $d.secrets; customScript = $d.customScript } | ConvertTo-Json -Depth 30
        try { Invoke-RestMethod "$base/api/clients/acme" -Method Put -Body $body -ContentType 'application/json' | Out-Null; Assert $false 'PUT without X-Prov blocked' }
        catch { Assert ($_.Exception.Response.StatusCode.value__ -eq 403) 'PUT without X-Prov blocked (403)' }
        $saved = Invoke-RestMethod "$base/api/clients/acme" -Method Put -Body $body -ContentType 'application/json' -Headers $h
        Assert ($saved.saved) 'PUT with X-Prov saves'
        try { Invoke-RestMethod "$base/api/clients" -Headers @{ Host = 'evil.example' } | Out-Null; Assert $false 'foreign Host header blocked' }
        catch { Assert ($_.Exception.Response.StatusCode.value__ -eq 403) 'foreign Host header blocked (403)' }
        try { Invoke-RestMethod "$base/../lib/Provisioning.psm1" | Out-Null; Assert $false 'path traversal blocked' }
        catch { Assert ($_.Exception.Response.StatusCode.value__ -in 400, 403, 404) 'path traversal blocked' }
        $rep = @{ token = $batch.token; state = 'started'; computerName = 'ACME-PC-04' } | ConvertTo-Json
        $ok = Invoke-RestMethod "$base/api/report" -Method Post -Body $rep -ContentType 'application/json'
        Assert ($ok.ok) 'POST /api/report with token accepted'
        $bad = @{ token = 'nope'; state = 'done'; computerName = 'ACME-PC-04' } | ConvertTo-Json
        try { Invoke-RestMethod "$base/api/report" -Method Post -Body $bad -ContentType 'application/json' | Out-Null; Assert $false 'bad report token blocked' }
        catch { Assert ($_.Exception.Response.StatusCode.value__ -eq 403) 'bad report token blocked (403)' }
        $off = Invoke-RestMethod "$base/api/lan" -Method Post -Headers $h -ContentType 'application/json' -Body '{"enabled":false}'
        Start-Sleep -Milliseconds 500
        Assert (-not (Invoke-RestMethod "$base/api/system").lan) 'reports can be turned off from the UI'
        $on = Invoke-RestMethod "$base/api/lan" -Method Post -Headers $h -ContentType 'application/json' -Body '{"enabled":true}'
        Start-Sleep -Milliseconds 500
        Assert ((Invoke-RestMethod "$base/api/system").lan) 'reports can be turned back on without a restart'
        $build = Invoke-RestMethod "$base/api/build" -Method Post -Headers $h -ContentType 'application/json' -Body (@{ client = 'acme'; batch = $batch.id; media = 'usb' } | ConvertTo-Json)
        $state = $null
        for ($i = 0; $i -lt 120; $i++) {
            Start-Sleep -Milliseconds 500
            $state = Invoke-RestMethod "$base/api/jobs/$($build.jobId)"
            if ($state.state -notin 'Running', 'NotStarted') { break }
        }
        Assert ($state.state -eq 'Completed' -and -not $state.error -and @($state.result.outputs).Count -ge 1) "build job completes ($($state.state) $($state.error))"
        if (Get-IsoTool) {
            # The provisioning ISO through the UI job queue (hdiutil writes to stderr on macOS)
            $pb = Invoke-RestMethod "$base/api/build" -Method Post -Headers $h -ContentType 'application/json' -Body (@{ client = 'acme'; batch = $batch.id; media = 'provision' } | ConvertTo-Json)
            for ($i = 0; $i -lt 120; $i++) {
                Start-Sleep -Milliseconds 500
                $ps = Invoke-RestMethod "$base/api/jobs/$($pb.jobId)"
                if ($ps.state -notin 'Running', 'NotStarted') { break }
            }
            Assert ($ps.state -eq 'Completed' -and -not $ps.error -and "$($ps.result.outputs)" -like '*.iso') "provisioning ISO job reports success ($($ps.state) '$($ps.error)')"
        }
        $bc = Invoke-RestMethod "$base/api/build" -Method Post -Headers $h -ContentType 'application/json' -Body (@{ client = 'acme2'; media = 'usb' } | ConvertTo-Json) -SkipHttpErrorCheck
        Assert ([bool]$bc.error) 'build of an incomplete client is refused with a message'
    }
    Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue

    if ($UI) {
        Section 'UI end-to-end (headless browser)'
        if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host '  skip (Node.js not installed)' }
        else {
            $uiPort = Get-Random -Minimum 40001 -Maximum 50000
            $uiJob = Start-Job -ScriptBlock { param($s, $p) & (Join-Path $s 'Start-UI.ps1') -Port $p -NoBrowser } -ArgumentList $Sandbox, $uiPort
            Start-Sleep -Seconds 3
            $profileDir = Join-Path $Sandbox 'browser-profile'
            $out = & node (Join-Path $Repo 'tests/ui-e2e.mjs') "http://localhost:$uiPort" $profileDir 2>&1
            $out | ForEach-Object { Write-Host "  $_" }
            Assert ($LASTEXITCODE -eq 0) 'UI end-to-end test'
            Stop-Job $uiJob -ErrorAction SilentlyContinue; Remove-Job $uiJob -Force -ErrorAction SilentlyContinue
        }
    }

    Section 'Target-PC scripts stay Windows PowerShell 5.1 compatible'
    foreach ($f in 'Setup.ps1', 'Provision-OOBE.ps1', 'Launch-Setup-GUI.ps1') {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Sandbox "Setup/$f"), [ref]$tokens, [ref]$errs)
        Assert ($errs.Count -eq 0) "$f parses"
        $ps7 = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TernaryExpressionAst] -or
            $n -is [System.Management.Automation.Language.PipelineChainAst] -or
            ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'QuestionQuestion') -or
            ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'QuestionQuestionEquals') -or
            ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.NullConditional)
        }, $true))
        $ps7Cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -in 'AsHashtable', 'Parallel', 'SkipHttpErrorCheck' }, $true))
        Assert (($ps7.Count + $ps7Cmds.Count) -eq 0) "$f uses no PowerShell 7-only syntax"
        # winget called directly (piped or not) loses its progress bar; use Invoke-Winget
        $rawWinget = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'winget' }, $true))
        Assert ($rawWinget.Count -eq 0) "$f runs winget only through Invoke-Winget"
    }
} finally {
    Remove-Module Provisioning -ErrorAction SilentlyContinue
    Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host "$script:Passed passed, $script:Failed failed" -ForegroundColor $color
exit $script:Failed
