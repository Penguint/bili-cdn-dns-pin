# Native PowerShell/curl equivalent of download-speed.sh.
$SpeedRounds = if ($env:BILI_SPEED_ROUNDS) { [int]$env:BILI_SPEED_ROUNDS } else { 3 }
$SpeedBytes = if ($env:BILI_SPEED_BYTES) { [long]$env:BILI_SPEED_BYTES } else { 33554432 }
$SpeedTimeout = if ($env:BILI_SPEED_TIMEOUT) { [int]$env:BILI_SPEED_TIMEOUT } else { 60 }
$KeepThresholdBps = if ($env:BILI_KEEP_BPS) { [long]$env:BILI_KEEP_BPS } else { 5000000 }
$MediaDir = if ($env:BILI_MEDIA_DIR) { $env:BILI_MEDIA_DIR } else { Join-Path $PSScriptRoot '..\media' }

. (Join-Path $PSScriptRoot 'media-urls.ps1')
function Initialize-Speed {
    if ($SpeedRounds -lt 3 -or $SpeedBytes -le 0 -or $SpeedTimeout -le 0 -or $KeepThresholdBps -lt 0) { throw 'Invalid speed settings' }
    $script:FreshMedia = $null
    if ((-not $env:BILI_VIDEO_URL -or -not $env:BILI_AUDIO_URL) -and $env:BILI_USE_MEDIA_FILES -ne '1') { Get-FreshMedia }
    $script:VideoUrl = if ($env:BILI_VIDEO_URL) { $env:BILI_VIDEO_URL } elseif ($FreshMedia) { $FreshMedia['video'] } else { (Get-Content (Join-Path $MediaDir 'video.url') -Raw -ErrorAction Stop).Trim() }
    $script:AudioUrl = if ($env:BILI_AUDIO_URL) { $env:BILI_AUDIO_URL } elseif ($FreshMedia) { $FreshMedia['audio'] } else { (Get-Content (Join-Path $MediaDir 'audio.url') -Raw -ErrorAction Stop).Trim() }
    foreach ($url in $VideoUrl, $AudioUrl) {
        $uri = [uri]$url
        if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('upos-hz-mirrorakam.akamaized.net','upos-sz-mirroraliov.bilivideo.com','upos-sz-mirrorcosov.bilivideo.com') -or -not $uri.IsDefaultPort -or $uri.UserInfo) { throw 'Invalid media URL' }
    }
}

function Get-Median($Values) {
    $ordered = @($Values | Sort-Object)
    $n = $ordered.Count
    if ($n % 2) { return $ordered[[int][math]::Floor($n / 2)] }
    return ($ordered[$n / 2 - 1] + $ordered[$n / 2]) / 2
}

function Test-IpSpeed {
    param([string]$Domain, [string]$Ip)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$parsed) -or $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or $Ip -eq '0.0.0.0') { return $null }
    $headerFile = [IO.Path]::GetTempFileName()
    $errorFile = [IO.Path]::GetTempFileName()
    $medians = @()
    try {
        foreach ($kind in 'video', 'audio') {
            $sourceUrl = if ($kind -eq 'video') { $VideoUrl } else { $AudioUrl }
            $explicit = if ($kind -eq 'video') { $env:BILI_VIDEO_URL } else { $env:BILI_AUDIO_URL }
            $domainFile = Join-Path $MediaDir "$Domain.$kind.url"
            if (-not $explicit -and $FreshMedia -and $FreshMedia.ContainsKey("$Domain.$kind")) { $sourceUrl = $FreshMedia["$Domain.$kind"] }
            if (-not $explicit -and -not $FreshMedia -and (Test-Path $domainFile)) { $sourceUrl = (Get-Content $domainFile -Raw -ErrorAction Stop).Trim() }
            $uri = [uri]$sourceUrl
            if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('upos-hz-mirrorakam.akamaized.net','upos-sz-mirroraliov.bilivideo.com','upos-sz-mirrorcosov.bilivideo.com') -or -not $uri.IsDefaultPort -or $uri.UserInfo) { return $null }
            $url = 'https://' + $Domain + $uri.PathAndQuery
            $speeds = @()
            for ($round = 1; $round -le $SpeedRounds; $round++) {
                $curlArgs = @('--silent','--show-error','--noproxy','*','--proto','=https',
                    '--connect-timeout','5','--max-time',"$SpeedTimeout",'--max-filesize',"$SpeedBytes",
                    '--range',"0-$($SpeedBytes - 1)",'--user-agent','Mozilla/5.0','--referer','https://www.bilibili.com/',
                    '--resolve',"${Domain}:443:${Ip}",'--dump-header',$headerFile,'--output','NUL',
                    '--write-out','%{http_code} %{size_download} %{speed_download}',$url)
                $stats = & curl.exe @curlArgs 2> $errorFile
                if ($LASTEXITCODE -ne 0) { Write-Host "  $Domain $Ip $kind round=$round failed (curl $LASTEXITCODE)"; return $null }
                $parts = ($stats -join '').Trim() -split '\s+'
                $headers = Get-Content $headerFile -Raw
                $matches = [regex]::Matches($headers, '(?im)^Content-Range:\s*bytes\s+(\d+)-(\d+)/(\d+)\s*$')
                if ($parts.Count -ne 3 -or $parts[0] -ne '206' -or $matches.Count -eq 0) { Write-Host "  $Domain $Ip $kind invalid HTTP/range"; return $null }
                $range = $matches[$matches.Count - 1]
                $expected = [math]::Min($SpeedBytes, [long]$range.Groups[3].Value)
                $speed = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
                if ($expected -le 0 -or [long]$range.Groups[1].Value -ne 0 -or [long]$range.Groups[2].Value -ne $expected - 1 -or [long]$parts[1] -ne $expected -or $speed -le 0) { Write-Host "  $Domain $Ip $kind incomplete range"; return $null }
                $speeds += $speed
                Write-Host "  $Domain $Ip $kind round=$round bytes=$($parts[1]) bytes/s=$speed"
            }
            $medians += Get-Median $speeds
        }
        return [long][math]::Floor(($medians | Measure-Object -Minimum).Minimum)
    } finally { Remove-Item $headerFile,$errorFile -Force }
}

function Get-FreshCandidates($Domain) {
    try {
        $dns = Invoke-RestMethod -Uri "https://cloudflare-dns.com/dns-query?name=$Domain&type=A" -Headers @{Accept='application/dns-json'} -TimeoutSec 15
        return @($dns.Answer | Where-Object { $_.type -eq 1 -and $_.data -ne '0.0.0.0' } | ForEach-Object { $_.data })
    } catch { return @() }
}
