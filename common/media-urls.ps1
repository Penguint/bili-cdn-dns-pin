# Native PowerShell media discovery; no Python or external JSON parser.
function Get-MediaApi([string]$Url) {
    Invoke-RestMethod -Uri $Url -TimeoutSec 25 -UserAgent 'Mozilla/5.0' -Headers @{ Referer = 'https://www.bilibili.com/' } -ErrorAction Stop
}
function Get-FreshMedia {
    $bvid = if ($env:BILI_BVID) { $env:BILI_BVID } else { 'BV1Ra4y117kf' }
    if ($bvid -cnotmatch '^BV[0-9A-Za-z]{10}$') { throw 'Invalid BILI_BVID' }
    $codec = if ($env:BILI_VIDEO_CODEC) { $env:BILI_VIDEO_CODEC } else { 'hevc' }
    $codecIds = @{ auto = 0; hevc = 12; avc = 7; av1 = 13 }
    if (-not $codecIds.ContainsKey($codec)) { throw 'Invalid BILI_VIDEO_CODEC' }
    $cid = $env:BILI_CID
    if (-not $cid) {
        try {
            $view = Get-MediaApi "https://api.bilibili.com/x/web-interface/view?bvid=$bvid"
            if ($view.code -eq 0) { $cid = $view.data.cid }
        } catch { }
        if (-not $cid) {
            $pages = Get-MediaApi "https://api.bilibili.com/x/player/pagelist?bvid=$bvid"
            if ($pages.code -eq 0 -and $pages.data.Count -gt 0) { $cid = $pages.data[0].cid }
        }
    }
    if ("$cid" -notmatch '^\d+$') { throw 'Cannot obtain content ID' }
    $result = Get-MediaApi "https://api.bilibili.com/x/player/playurl?bvid=$bvid&cid=$cid&qn=127&fnval=4048&fourk=1"
    if ($result.code -ne 0) { throw 'Cannot obtain media URLs' }
    $dash = $result.data.dash
    $video = @($dash.video | Where-Object { $codecIds[$codec] -eq 0 -or $_.codecid -eq $codecIds[$codec] })
    $audio = @($dash.audio)
    if (-not $video.Count -or -not $audio.Count) { throw 'No video/audio for requested codec' }
    $script:FreshMedia = @{}
    foreach ($kind in 'video','audio') {
        $tracks = if ($kind -eq 'video') { $video } else { $audio }
        $ordered = @($tracks | Sort-Object bandwidth -Descending)
        $script:FreshMedia[$kind] = $ordered[0].baseUrl
        foreach ($hostName in 'upos-hz-mirrorakam.akamaized.net','upos-sz-mirroraliov.bilivideo.com','upos-sz-mirrorcosov.bilivideo.com') {
            $urls = @($ordered | ForEach-Object { $_.baseUrl; $_.backupUrl } | Where-Object { $_ -like "https://$hostName/*" })
            if ($urls.Count) { $script:FreshMedia["$hostName.$kind"] = $urls[0] }
        }
    }
    Write-Host "Fresh video/audio fetched: $bvid ($codec)"
}
