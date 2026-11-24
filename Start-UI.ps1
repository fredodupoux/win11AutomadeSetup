#Requires -Version 7.0
<#
.SYNOPSIS
    Provisioning UI - local web app for onsite techs (macOS or Windows).

.DESCRIPTION
    Starts a small web server on this machine and opens the browser:
        http://localhost:8765
    Manage clients, batches of PCs and build the media without editing code.

    PC progress reports: turn them on from the System page or the Build screen
    (or start with -Lan). The server then also listens on the local network so
    PCs being set up can report back (Batches screen). Only /api/report is
    reachable from the network, and only with the batch's secret token;
    everything else (settings, passwords) stays reachable from this machine
    only. The choice is remembered in cache/ui-settings.json.

.EXAMPLE
    pwsh ./Start-UI.ps1
    pwsh ./Start-UI.ps1 -Lan          # start with PC progress reports already on
#>
param(
    [int]$Port = 8765,
    [switch]$Lan,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ModulePath = Join-Path $PSScriptRoot 'lib/Provisioning.psm1'
Import-Module $ModulePath -Force
$UiRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ui'))
$Paths  = Get-ProvPaths
$Jobs   = @{}
$MaxBody = 10MB

# ====================================================================
# HTTP plumbing
# ====================================================================

$ContentTypes = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.json' = 'application/json; charset=utf-8'
}
$StatusText = @{ 200 = 'OK'; 201 = 'Created'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict'; 413 = 'Payload Too Large'; 500 = 'Internal Server Error' }

class HttpError : System.Exception {
    [int]$Status
    HttpError([int]$status, [string]$message) : base($message) { $this.Status = $status }
}

# Parses a buffered request. Returns $null while it is still incomplete.
function ConvertFrom-RequestBytes([byte[]]$All) {
    $latin1 = [System.Text.Encoding]::Latin1
    $text = $latin1.GetString($All)
    $headerEnd = $text.IndexOf("`r`n`r`n")
    if ($headerEnd -lt 0) {
        if ($All.Length -gt 65536) { throw [HttpError]::new(413, 'Headers too large') }
        return $null
    }
    $lines = $text.Substring(0, $headerEnd).Split("`r`n")
    $first = $lines[0].Split(' ')
    if ($first.Count -lt 2) { throw [HttpError]::new(400, 'Bad request line') }
    $headers = @{}
    foreach ($l in $lines | Select-Object -Skip 1) {
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim() }
    }
    $len = 0
    if ($headers.ContainsKey('content-length')) { $len = [int]$headers['content-length'] }
    if ($len -gt $MaxBody) { throw [HttpError]::new(413, 'Body too large') }
    $bodyStart = $headerEnd + 4
    if (($All.Length - $bodyStart) -lt $len) { return $null }
    $body = if ($len -gt 0) { [System.Text.Encoding]::UTF8.GetString($All, $bodyStart, $len) } else { '' }

    $target = $first[1]
    $path = $target; $query = @{}
    $q = $target.IndexOf('?')
    if ($q -ge 0) {
        $path = $target.Substring(0, $q)
        foreach ($pair in $target.Substring($q + 1).Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $query[[System.Uri]::UnescapeDataString($kv[0])] = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
        }
    }
    return @{ Method = $first[0].ToUpper(); Path = [System.Uri]::UnescapeDataString($path); Query = $query; Headers = $headers; Body = $body }
}

function Write-Response([System.Net.Sockets.NetworkStream]$Stream, [int]$Status, [byte[]]$Body, [string]$ContentType) {
    $text = if ($StatusText.ContainsKey($Status)) { $StatusText[$Status] } else { 'Status' }
    $head = "HTTP/1.1 $Status $text`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`nReferrer-Policy: no-referrer`r`n`r`n"
    $h = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($h, 0, $h.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
}

function ConvertTo-JsonBytes($Object) {
    return [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Depth 30 -Compress))
}

function Get-JsonBody($Req) {
    if ([string]::IsNullOrWhiteSpace($Req.Body)) { throw [HttpError]::new(400, 'JSON body expected') }
    try { return ($Req.Body | ConvertFrom-Json -AsHashtable -Depth 30) } catch { throw [HttpError]::new(400, 'Invalid JSON') }
}

# ====================================================================
# Builds run as background jobs (a clean-install ISO takes minutes)
# ====================================================================

function Start-BuildJob([hashtable]$Params) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $job = Start-Job -Name "build-$id" -ScriptBlock {
        param($mod, $p)
        Import-Module $mod -Force
        Invoke-ProvBuild @p
    } -ArgumentList $ModulePath, $Params
    $Jobs[$id] = @{ job = $job; params = $Params; started = (Get-Date).ToString('s') }
    return $id
}

function Get-BuildJob([string]$Id) {
    if (-not $Jobs.ContainsKey($Id)) { throw [HttpError]::new(404, 'Unknown job') }
    $j = $Jobs[$Id].job
    $child = $j.ChildJobs[0]
    $log = @($child.Information | ForEach-Object { [string]$_.MessageData })
    $state = [string]$j.State
    $result = $null; $errorText = ''
    if ($state -eq 'Completed') {
        $out = @(Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue)
        $result = $out | Where-Object { $_ -is [System.Collections.IDictionary] -or $_.PSObject.Properties['outputs'] } | Select-Object -Last 1
    }
    # A job only failed if it stopped with an error or returned no result. Non-fatal
    # error records (e.g. a tool writing to stderr) are shown in the log, not as a failure.
    $notes = @($child.Error | ForEach-Object { $_.Exception.Message } | Where-Object { $_ -and $_ -notmatch '^NotSpecified: \(:String\) \[\], RemoteException$' })
    if ($state -eq 'Failed') {
        $errorText = [string]$child.JobStateInfo.Reason.Message
        if (-not $errorText) { $errorText = $notes -join "`n" }
    } elseif ($state -eq 'Completed' -and -not $result) {
        $errorText = if ($notes) { $notes -join "`n" } else { 'The build ended without a result' }
    } elseif ($notes) {
        $log += @($notes | ForEach-Object { "note: $_" })
    }
    return [ordered]@{ id = $Id; state = $state; started = $Jobs[$Id].started; params = $Jobs[$Id].params; log = $log; error = $errorText; result = $result }
}

# ====================================================================
# API
# ====================================================================

function Get-ReportUrl([string]$Ip) {
    if (-not $script:LanMode) { throw [HttpError]::new(400, 'Turn on "receive progress reports" first (System page or the Build screen).') }
    $addrs = @(Get-LanAddresses)
    if (-not $Ip) { $Ip = $addrs | Select-Object -First 1 }
    if (-not $Ip) { throw [HttpError]::new(400, 'No network address found on this machine') }
    return "http://${Ip}:$Port/api/report"
}

function Open-InFileManager([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $dist = [System.IO.Path]::GetFullPath($Paths.Dist)
    if (-not $full.StartsWith($dist, [StringComparison]::OrdinalIgnoreCase)) { throw [HttpError]::new(403, 'Only build output can be opened') }
    if (-not (Test-Path $full)) { throw [HttpError]::new(404, 'Not found') }
    if ($IsMacOS) { if (Test-Path $full -PathType Leaf) { & open -R $full } else { & open $full } }
    elseif ($IsWindows) { if (Test-Path $full -PathType Leaf) { Start-Process explorer.exe "/select,`"$full`"" } else { Start-Process explorer.exe "`"$full`"" } }
    else { & xdg-open (Split-Path $full -Parent) }
}

function Invoke-Api($Req) {
    $m = $Req.Method; $p = $Req.Path

    if ($p -eq '/api/system' -and $m -eq 'GET') {
        $info = Get-ProvSystemInfo
        $info.lan = [bool]$script:LanMode
        $info.port = $Port
        return $info
    }
    if ($p -eq '/api/meta' -and $m -eq 'GET') { return (Get-ProvMeta) }

    # Switch progress reports on/off: the listener is re-opened right after this response
    if ($p -eq '/api/lan' -and $m -eq 'POST') {
        $b = Get-JsonBody $Req
        $script:PendingLan = [bool]$b.enabled
        return @{ lan = $script:PendingLan; addresses = @(Get-LanAddresses); port = $Port }
    }

    if ($p -eq '/api/clients') {
        if ($m -eq 'GET') { return @{ clients = @(Get-ClientList) } }
        if ($m -eq 'POST') {
            $b = Get-JsonBody $Req
            $data = New-ClientFromTemplate -Name ([string]$b.name) -From ([string]$b.from)
            return @{ name = $data.name }
        }
    }

    if ($p -match '^/api/clients/([a-z0-9-]+)$') {
        $n = $Matches[1]
        if ($m -eq 'GET') {
            $d = Get-ClientData -Name $n
            $d.validation = Test-ClientData -Client $d.client -Secrets $d.secrets -CustomScript $d.customScript
            return $d
        }
        if ($m -eq 'PUT') {
            $b = Get-JsonBody $Req
            $v = Save-ClientData -Name $n -Client $b.client -Secrets $b.secrets -CustomScript ([string]$b.customScript)
            return @{ saved = $true; validation = $v }
        }
    }

    if ($p -match '^/api/clients/([a-z0-9-]+)/validate$' -and $m -eq 'POST') {
        $b = Get-JsonBody $Req
        return (Test-ClientData -Client $b.client -Secrets $b.secrets -CustomScript ([string]$b.customScript))
    }

    if ($p -match '^/api/clients/([a-z0-9-]+)/batches$' -and $m -eq 'POST') {
        $b = Get-JsonBody $Req
        return (Save-Batch -Name $Matches[1] -Batch $b)
    }
    if ($p -match '^/api/clients/([a-z0-9-]+)/batches/([A-Za-z0-9-]+)$' -and $m -eq 'PUT') {
        $b = Get-JsonBody $Req
        $b.id = $Matches[2]
        return (Save-Batch -Name $Matches[1] -Batch $b)
    }
    if ($p -match '^/api/clients/([a-z0-9-]+)/batches/([A-Za-z0-9-]+)/machines/(\d+)$' -and $m -eq 'PUT') {
        $n = $Matches[1]; $bid = $Matches[2]; $num = [int]$Matches[3]
        $b = Get-JsonBody $Req
        $allowed = @('', 'used', 'in-progress', 'done', 'failed', 'skipped')
        if ($allowed -notcontains [string]$b.status) { throw [HttpError]::new(400, 'Unknown status') }
        return (Set-MachineStatus -Name $n -BatchId $bid -Number $num -Fields @{ status = [string]$b.status; note = [string]$b.note; source = 'manual' })
    }

    if ($p -eq '/api/winget/search' -and $m -eq 'GET') { return @{ results = @(Search-WingetCatalog -Query ([string]$Req.Query['q'])) } }
    if ($p -eq '/api/winget/check' -and $m -eq 'POST') { $b = Get-JsonBody $Req; return @{ results = @(Test-WingetIds -Ids @($b.ids)) } }
    if ($p -eq '/api/winget/refresh' -and $m -eq 'POST') { return (Update-WingetCatalog -Force) }

    if ($p -eq '/api/build' -and $m -eq 'POST') {
        $b = Get-JsonBody $Req
        $media = [string]$b.media
        if (@('provision', 'usb', 'iso') -notcontains $media) { throw [HttpError]::new(400, 'media must be provision, usb or iso') }
        $params = @{ Name = [string]$b.client; Media = $media; BatchId = [string]$b.batch }
        if ($b['report']) { $params.ReportUrl = Get-ReportUrl ([string]$b['reportIp']) }
        if ($media -eq 'iso') { $params.StockIso = [string]$b.stockIso }
        # Fail fast on configuration errors instead of inside the job
        Resolve-BuildConfig -Name $params.Name -BatchId $params.BatchId -Media $media | Out-Null
        return @{ jobId = (Start-BuildJob $params) }
    }
    if ($p -match '^/api/jobs/([a-f0-9]+)$' -and $m -eq 'GET') { return (Get-BuildJob $Matches[1]) }

    if ($p -eq '/api/open' -and $m -eq 'POST') { $b = Get-JsonBody $Req; Open-InFileManager ([string]$b.path); return @{ opened = $true } }

    throw [HttpError]::new(404, "No route for $m $p")
}

function Test-LocalHost([string]$HostHeader) {
    if (-not $HostHeader) { return $false }
    $h = $HostHeader.ToLower()
    $h = if ($h.StartsWith('[')) { $h.Substring(0, $h.IndexOf(']') + 1) } else { $h.Split(':')[0] }
    return @('localhost', '127.0.0.1', '[::1]') -contains $h
}

function Invoke-Request($Req, [bool]$FromLoopback) {
    # PCs on the network may only post progress reports (with their batch token)
    if ($Req.Path -eq '/api/report') {
        if ($Req.Method -ne 'POST') { throw [HttpError]::new(405, 'POST only') }
        $b = Get-JsonBody $Req
        try { $m = Add-MachineReport $b } catch { throw [HttpError]::new(403, $_.Exception.Message) }
        Write-Host "  report: $($b.computerName) -> $($m.status)" -ForegroundColor Green
        return @{ status = 200; body = (ConvertTo-JsonBytes @{ ok = $true }); type = $ContentTypes['.json'] }
    }
    if (-not $FromLoopback) { throw [HttpError]::new(403, 'Only available on this computer') }
    if (-not (Test-LocalHost $Req.Headers['host'])) { throw [HttpError]::new(403, 'Bad Host header') }

    if ($Req.Path.StartsWith('/api/')) {
        if ($Req.Method -ne 'GET' -and $Req.Headers['x-prov'] -ne '1') { throw [HttpError]::new(403, 'Missing X-Prov header') }
        $result = Invoke-Api $Req
        return @{ status = 200; body = (ConvertTo-JsonBytes $result); type = $ContentTypes['.json'] }
    }

    if ($Req.Method -ne 'GET') { throw [HttpError]::new(405, 'GET only') }
    $rel = if ($Req.Path -eq '/') { 'index.html' } else { $Req.Path.TrimStart('/') }
    $file = [System.IO.Path]::GetFullPath((Join-Path $UiRoot $rel))
    if (-not $file.StartsWith($UiRoot) -or -not (Test-Path $file -PathType Leaf)) { throw [HttpError]::new(404, 'Not found') }
    $ext = [System.IO.Path]::GetExtension($file).ToLower()
    $type = if ($ContentTypes.ContainsKey($ext)) { $ContentTypes[$ext] } else { 'application/octet-stream' }
    return @{ status = 200; body = [System.IO.File]::ReadAllBytes($file); type = $type }
}

# ====================================================================
# Main loop
# ====================================================================
# One thread, many connections: browsers open extra connections that send
# nothing (pre-connect / keep-alive). Only connections that have data are
# served; idle ones are closed quietly after a while. Never blocks on a read.

$SettingsFile = Join-Path $Paths.Cache 'ui-settings.json'
$saved = Read-JsonFile $SettingsFile
$script:LanMode = [bool]$Lan -or [bool]($saved -and $saved['lan'])
$script:PendingLan = $null

function Start-Listener([bool]$OnNetwork) {
    $addr = if ($OnNetwork) { [System.Net.IPAddress]::Any } else { [System.Net.IPAddress]::Loopback }
    $l = [System.Net.Sockets.TcpListener]::new($addr, $Port)
    $l.Start()
    return $l
}

try { $listener = Start-Listener $script:LanMode }
catch { Write-Host "Port $Port is busy. Try: pwsh ./Start-UI.ps1 -Port 8766" -ForegroundColor Red; exit 1 }

function Show-LanStatus {
    if ($script:LanMode) {
        foreach ($ip in Get-LanAddresses) { Write-Host "  Receiving PC reports at http://${ip}:$Port/api/report" -ForegroundColor DarkGray }
    } else {
        Write-Host '  Local only (turn on PC reports on the System page)' -ForegroundColor DarkGray
    }
}

$url = "http://localhost:$Port"
Write-Host ''
Write-Host '  Provisioning UI' -ForegroundColor Cyan
Write-Host "  $url"
Show-LanStatus
Write-Host '  Ctrl+C to stop'
Write-Host ''

if (-not $NoBrowser) {
    try {
        if ($IsMacOS) { & open $url } elseif ($IsWindows) { Start-Process $url } else { & xdg-open $url 2>$null }
    } catch { }
}

$conns = [System.Collections.Generic.List[object]]::new()
$buf = [byte[]]::new(65536)
$IdleSeconds = 20

function Send-Reply($Conn, [int]$Status, [byte[]]$Body, [string]$Type) {
    $stream = $Conn.tcp.GetStream()
    Write-Response $stream $Status $Body $Type
}

try {
    while ($true) {
        $busy = $false

        while ($listener.Pending()) {
            $t = $listener.AcceptTcpClient()
            $t.NoDelay = $true
            $t.SendTimeout = 15000
            $remote = ([System.Net.IPEndPoint]$t.Client.RemoteEndPoint).Address
            $loop = [System.Net.IPAddress]::IsLoopback($remote) -or ($remote.IsIPv4MappedToIPv6 -and [System.Net.IPAddress]::IsLoopback($remote.MapToIPv4()))
            $conns.Add(@{ tcp = $t; data = [System.IO.MemoryStream]::new(); last = [DateTime]::UtcNow; loopback = $loop })
            $busy = $true
        }

        for ($i = $conns.Count - 1; $i -ge 0; $i--) {
            $c = $conns[$i]
            $close = $false
            try {
                $sock = $c.tcp.Client
                if ($c.tcp.Available -gt 0) {
                    $n = $sock.Receive($buf)
                    $c.data.Write($buf, 0, $n)
                    $c.last = [DateTime]::UtcNow
                    $busy = $true
                    $req = $null
                    try { $req = ConvertFrom-RequestBytes $c.data.ToArray() }
                    catch {
                        $st = if ($_.Exception -is [HttpError]) { $_.Exception.Status } else { 400 }
                        Send-Reply $c $st (ConvertTo-JsonBytes @{ error = $_.Exception.Message }) $ContentTypes['.json']
                        $close = $true
                    }
                    if ($req) {
                        try {
                            $res = Invoke-Request $req $c.loopback
                            Send-Reply $c $res.status $res.body $res.type
                        } catch {
                            $status = if ($_.Exception -is [HttpError]) { $_.Exception.Status } else { 400 }
                            $msg = $_.Exception.Message
                            if ($status -eq 400 -or $status -ge 500) { Write-Host "  $($req.Method) $($req.Path) -> $status $msg" -ForegroundColor Yellow }
                            Send-Reply $c $status (ConvertTo-JsonBytes @{ error = $msg }) $ContentTypes['.json']
                        }
                        $close = $true
                    }
                } elseif ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $c.tcp.Available -eq 0) {
                    $close = $true   # closed by the browser
                } elseif (([DateTime]::UtcNow - $c.last).TotalSeconds -gt $IdleSeconds) {
                    $close = $true   # idle pre-connect: drop quietly
                }
            } catch {
                $close = $true
            }
            if ($close) {
                try { $c.tcp.Close() } catch { }
                $conns.RemoveAt($i)
            }
        }

        if ($null -ne $script:PendingLan) {
            $want = $script:PendingLan
            $script:PendingLan = $null
            if ($want -ne $script:LanMode) {
                $listener.Stop()
                try {
                    $listener = Start-Listener $want
                    $script:LanMode = $want
                } catch {
                    Write-Host "  Could not switch network mode: $($_.Exception.Message)" -ForegroundColor Yellow
                    $listener = Start-Listener $script:LanMode
                }
                Write-JsonFile $SettingsFile @{ lan = $script:LanMode }
                Show-LanStatus
            }
        }

        if (-not $busy) { Start-Sleep -Milliseconds 15 }
    }
} finally {
    $listener.Stop()
    foreach ($c in $conns) { try { $c.tcp.Close() } catch { } }
    Get-Job -Name 'build-*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
}
