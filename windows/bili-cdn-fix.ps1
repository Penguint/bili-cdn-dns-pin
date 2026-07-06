# ============================================================
# Bilibili overseas CDN fix - hosts optimizer
# Tests latency to known Bilibili overseas CDN node IPs and
# pins the fastest one in the Windows hosts file.
# Run:     right-click -> "Run with PowerShell" (auto-elevates)
# Undo:    powershell -File bili-cdn-fix.ps1 -Restore
# ============================================================
param([switch]$Restore)

$Marker = "# BiliCdnFix"
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

# --- self-elevate to admin ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = "-ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    if ($Restore) { $argList += " -Restore" }
    Start-Process powershell -ArgumentList $argList -Verb RunAs
    exit
}

function Flush-Dns { ipconfig /flushdns | Out-Null }

# --- restore mode: remove our entries and exit ---
if ($Restore) {
    $lines = @(Get-Content $HostsPath | Where-Object { $_ -notmatch [regex]::Escape($Marker) })
    Set-Content -Path $HostsPath -Value $lines -Encoding Default
    Flush-Dns
    Write-Host "Restored: all BiliCdnFix entries removed from hosts." -ForegroundColor Green
    return
}

# --- candidate node IPs (from akamTester project, plus live DNS) ---
$Domains = @{
    "upos-hz-mirrorakam.akamaized.net" = @(
        "23.48.96.104","23.48.96.113","202.130.202.19","202.130.202.40","203.153.17.248",
        "2.19.117.132","23.62.212.66","203.186.47.73","23.220.71.197","23.215.0.36",
        "23.49.104.199","23.45.207.170","23.215.0.44","203.186.47.160","23.211.60.70",
        "23.62.212.110","5.178.42.226","23.47.48.104","23.47.48.84","23.47.48.68",
        "23.49.5.40","23.45.207.172","203.186.47.74","23.202.34.240","23.62.212.101",
        "23.47.48.120","23.62.212.99","203.186.47.147","2.19.117.148","23.215.0.43",
        "23.47.48.78","23.62.212.68","23.220.71.186","23.62.212.67","2.16.154.161",
        "23.215.0.46","203.186.47.162","23.202.34.248","23.62.212.93","2.16.154.98",
        "23.49.5.18","5.178.42.163","23.211.60.78","23.62.212.106","23.49.104.213","23.62.212.96"
    )
    "upos-sz-mirroraliov.bilivideo.com" = @(
        "163.181.154.238","163.181.35.184","155.102.60.35","163.181.131.210","163.181.228.231",
        "163.181.1.227","155.102.4.6","155.102.60.31","163.181.1.231","163.181.81.233",
        "163.181.35.186","155.102.4.143","155.102.4.4","163.181.60.223","163.181.228.228",
        "155.102.60.33","163.181.60.220","47.246.38.203","163.181.154.237","47.246.38.202",
        "163.181.35.183","47.246.38.206","155.102.4.22","163.181.81.231","163.181.60.219",
        "47.246.38.207","163.181.35.180","155.102.4.5","155.102.60.34","163.181.1.230",
        "155.102.60.30","155.102.4.146","163.181.60.224","155.102.4.142","47.246.38.205",
        "163.181.131.215","155.102.4.140","163.181.228.225","155.102.4.144","155.102.60.32",
        "163.181.60.221","47.246.38.209","163.181.78.184","163.181.1.229","155.102.60.29",
        "163.181.35.187","155.102.4.145","47.246.38.208","155.102.4.141","163.181.78.186",
        "47.246.38.204","163.181.81.236","155.102.4.147","163.181.78.185","163.181.78.183"
    )
}

# add IPs from live DNS resolution as extra candidates
foreach ($d in @($Domains.Keys)) {
    try {
        $resolved = (Resolve-DnsName -Name $d -Type A -ErrorAction Stop).IPAddress
        $Domains[$d] = @($Domains[$d] + $resolved | Select-Object -Unique)
    } catch {}
}

# --- TCP connect latency test (port 443) ---
function Test-IpLatency {
    param([string]$Ip, [int]$TimeoutMs = 900, [int]$Tries = 2)
    $best = [int]::MaxValue
    for ($i = 0; $i -lt $Tries; $i++) {
        $client = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $task = $client.ConnectAsync($Ip, 443)
            if ($task.Wait($TimeoutMs) -and $client.Connected) {
                $sw.Stop()
                if ($sw.ElapsedMilliseconds -lt $best) { $best = $sw.ElapsedMilliseconds }
            }
        } catch {} finally { $client.Close() }
    }
    if ($best -eq [int]::MaxValue) { return $null } else { return $best }
}

$results = @{}
foreach ($domain in $Domains.Keys) {
    Write-Host "`nTesting nodes for $domain ..." -ForegroundColor Cyan
    $bestIp = $null; $bestMs = [int]::MaxValue
    $ips = $Domains[$domain]; $n = 0
    foreach ($ip in $ips) {
        $n++
        Write-Progress -Activity $domain -Status "$ip ($n/$($ips.Count))" -PercentComplete (100*$n/$ips.Count)
        $ms = Test-IpLatency -Ip $ip
        if ($ms -ne $null) {
            $color = if ($ms -lt 60) { "Green" } elseif ($ms -lt 150) { "Yellow" } else { "DarkGray" }
            Write-Host ("  {0,-16} {1,5} ms" -f $ip, $ms) -ForegroundColor $color
            if ($ms -lt $bestMs) { $bestMs = $ms; $bestIp = $ip }
        }
    }
    Write-Progress -Activity $domain -Completed
    if ($bestIp) {
        $results[$domain] = @{ Ip = $bestIp; Ms = $bestMs }
        Write-Host ("  BEST: {0}  {1} ms" -f $bestIp, $bestMs) -ForegroundColor Green
    } else {
        Write-Host "  No reachable node found, skipping this domain." -ForegroundColor Red
    }
}

if ($results.Count -eq 0) {
    Write-Host "`nNothing to write. Check your network and retry." -ForegroundColor Red
    return
}

# --- update hosts (backup first, remove old entries, append new) ---
Copy-Item $HostsPath "$HostsPath.bak_$(Get-Date -Format yyyyMMdd_HHmmss)" -Force
$domainPattern = ($Domains.Keys | ForEach-Object { [regex]::Escape($_) }) -join "|"
$lines = @(Get-Content $HostsPath | Where-Object {
    $_ -notmatch [regex]::Escape($Marker) -and $_ -notmatch $domainPattern
})
foreach ($domain in $results.Keys) {
    $lines += ("{0} {1} {2} ({3} ms, {4})" -f $results[$domain].Ip, $domain, $Marker, $results[$domain].Ms, (Get-Date -Format yyyy-MM-dd))
}
# retry a few times in case antivirus/another process has the file locked
$written = $false
for ($try = 1; $try -le 5 -and -not $written; $try++) {
    try {
        Set-Content -Path $HostsPath -Value $lines -Encoding Default -ErrorAction Stop
        $written = $true
    } catch {
        Write-Host ("hosts file is locked, retrying ({0}/5)..." -f $try) -ForegroundColor Yellow
        Start-Sleep -Milliseconds 1500
    }
}
if (-not $written) {
    Write-Host "`nFAILED to write hosts file (locked by another process)." -ForegroundColor Red
    Write-Host "Add these lines manually (Notepad as admin):" -ForegroundColor Yellow
    foreach ($domain in $results.Keys) {
        Write-Host ("  {0} {1}" -f $results[$domain].Ip, $domain)
    }
    return
}
Flush-Dns

Write-Host "`nDone! hosts updated:" -ForegroundColor Green
foreach ($domain in $results.Keys) {
    Write-Host ("  {0} -> {1} ({2} ms)" -f $domain, $results[$domain].Ip, $results[$domain].Ms)
}
Write-Host "`nA backup of your old hosts file was saved next to it."
Write-Host "Re-run this script anytime to re-test; run with -Restore to undo."
