# ============================================================
# bili-agh-update.ps1 (Windows always-on server mode)
# Test bilibili overseas CDN nodes, update AdGuard Home DNS
# rewrites via API. Schedule weekly with Task Scheduler.
# Stability rule: keep current IP unless dead or >60ms.
# ============================================================

# ------- EDIT THESE 3 LINES -------
$AghUrl  = "http://127.0.0.1:80"   # AdGuard Home admin address
$AghUser = "admin"
$AghPass = "CHANGE_ME"
# ----------------------------------

$KeepThresholdMs = 60
$StateFile = Join-Path $PSScriptRoot "bili-agh-state.txt"
$AuthHeader = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${AghUser}:${AghPass}")) }

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) }

$Domains = @{
    "upos-hz-mirrorakam.akamaized.net" = @(
        "23.48.96.104","23.48.96.113","203.153.17.248","202.130.202.19","202.130.202.40",
        "23.45.207.170","23.45.207.172","23.62.212.66","23.62.212.110","23.62.212.101",
        "23.62.212.99","23.220.71.197","23.220.71.186","23.49.104.199","23.49.104.213",
        "23.211.60.70","23.211.60.78","203.186.47.73","203.186.47.74","203.186.47.147","203.186.47.160"
    )
    "upos-sz-mirroraliov.bilivideo.com" = @(
        "47.246.41.174","47.246.41.175","47.246.41.176","47.246.41.177","47.246.41.178",
        "163.181.81.231","163.181.81.233","163.181.81.236","163.181.35.183","163.181.35.184",
        "155.102.4.5","155.102.4.6","155.102.4.141","155.102.4.145","163.181.78.183",
        "163.181.78.184","47.246.38.202","47.246.38.203"
    )
}

function Test-IpLatency {
    param([string]$Ip, [int]$TimeoutMs = 2000, [int]$Tries = 2)
    $best = $null
    for ($i = 0; $i -lt $Tries; $i++) {
        $client = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $task = $client.ConnectAsync($Ip, 443)
            if ($task.Wait($TimeoutMs) -and $client.Connected) {
                $sw.Stop()
                if ($best -eq $null -or $sw.ElapsedMilliseconds -lt $best) { $best = $sw.ElapsedMilliseconds }
            }
        } catch {} finally { $client.Close() }
    }
    return $best
}

function Get-State($domain) {
    if (Test-Path $StateFile) {
        $line = Get-Content $StateFile | Where-Object { $_ -like "$domain=*" } | Select-Object -First 1
        if ($line) { return $line.Split("=")[1] }
    }
    return $null
}

function Set-State($domain, $ip) {
    $lines = @()
    if (Test-Path $StateFile) { $lines = @(Get-Content $StateFile | Where-Object { $_ -notlike "$domain=*" }) }
    $lines += "$domain=$ip"
    Set-Content -Path $StateFile -Value $lines
}

function Agh($endpoint, $domain, $ip) {
    try {
        Invoke-RestMethod -Uri "$AghUrl/control/rewrite/$endpoint" -Method Post -Headers $AuthHeader `
            -ContentType "application/json" -Body (@{ domain = $domain; answer = $ip } | ConvertTo-Json) | Out-Null
        return $true
    } catch {
        Log "API $endpoint failed: $($_.Exception.Message)"
        return $false
    }
}

foreach ($domain in $Domains.Keys) {
    Log "=== $domain ==="
    $oldIp = Get-State $domain

    if ($oldIp) {
        $oldMs = Test-IpLatency -Ip $oldIp
        if ($oldMs -ne $null -and $oldMs -le $KeepThresholdMs) {
            Log "current $oldIp still good (${oldMs}ms) - keeping"
            continue
        }
        Log "current $oldIp slow or dead - re-testing"
    }

    # candidates: static list + fresh public-DNS resolution (bypasses AdGuard rewrite)
    $ips = $Domains[$domain]
    foreach ($dns in "1.1.1.1", "8.8.8.8") {
        try { $ips += (Resolve-DnsName -Name $domain -Type A -Server $dns -ErrorAction Stop).IPAddress } catch {}
    }
    $ips = $ips | Select-Object -Unique

    $bestIp = $null; $bestMs = [int]::MaxValue
    foreach ($ip in $ips) {
        $ms = Test-IpLatency -Ip $ip
        if ($ms -ne $null) {
            Log ("  {0,-16} {1,5} ms" -f $ip, $ms)
            if ($ms -lt $bestMs) { $bestMs = $ms; $bestIp = $ip }
        }
    }

    if (-not $bestIp) { Log "no reachable node, unchanged"; continue }
    if ($bestIp -eq $oldIp) { Log "best unchanged ($bestIp)"; continue }

    if ($oldIp) { Agh "delete" $domain $oldIp | Out-Null }
    if (Agh "add" $domain $bestIp) {
        Set-State $domain $bestIp
        Log "NEW rewrite: $domain -> $bestIp (${bestMs}ms)"
    }
}
Log "done"
