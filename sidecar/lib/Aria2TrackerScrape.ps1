# BitTorrent tracker scrape - seeders / leechers for aria2 Tracker torrent rows.
# Agent notes: docs/plugins/aria2/AGENT_NOTES_ARIA2.md

$script:AppAria2TrackerPeerCacheTtlMinutes = 10

function Get-AppAria2TrackerPeerCachePath {
    Join-Path (Get-AppAria2StoreRoot) 'tracker-peer-cache.json'
}

function Read-AppAria2TrackerPeerCache {
    $path = Get-AppAria2TrackerPeerCachePath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ fetchedAt = $null; rows = @{} }
    }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $rows = @{}
        $rowProp = Get-AppAria2JsonProp -Item $doc -Name 'rows'
        if ($rowProp) {
            foreach ($p in @($rowProp.PSObject.Properties)) {
                $rows[[string]$p.Name] = $p.Value
            }
        }
        return @{
            fetchedAt = [string](Get-AppAria2JsonProp -Item $doc -Name 'fetchedAt')
            rows      = $rows
        }
    } catch {
        Write-SidecarLogVerbose "aria2: tracker peer cache read failed - $($_.Exception.Message)"
        return @{ fetchedAt = $null; rows = @{} }
    }
}

function Write-AppAria2TrackerPeerCache {
    param([Parameter(Mandatory)]$Cache)
    $path = Get-AppAria2TrackerPeerCachePath
    $payload = @{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        rows      = $Cache.rows
    }
    ($payload | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Read-AppBencodeSkipValue {
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [Parameter(Mandatory)][int]$Index
    )
    if ($Index -ge $Data.Length) { throw 'bencode: unexpected end' }
    switch ([char]$Data[$Index]) {
        'i' {
            $end = [Array]::IndexOf($Data, [byte][char]'e', $Index)
            if ($end -lt 0) { throw 'bencode: unterminated integer' }
            return $end + 1
        }
        'l' {
            $i = $Index + 1
            while ($Data[$i] -ne [byte][char]'e') {
                $i = Read-AppBencodeSkipValue -Data $Data -Index $i
            }
            return $i + 1
        }
        'd' {
            return (Get-AppBencodeDictEndIndex -Data $Data -StartIndex $Index)
        }
        default {
            $colon = [Array]::IndexOf($Data, [byte][char]':', $Index)
            if ($colon -lt 0) { throw 'bencode: expected string length' }
            $lenText = [System.Text.Encoding]::ASCII.GetString($Data, $Index, $colon - $Index)
            if (-not ($lenText -match '^\d+$')) { throw "bencode: invalid string length '$lenText'" }
            return $colon + 1 + [int]$lenText
        }
    }
}

function Get-AppBencodeDictEndIndex {
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [Parameter(Mandatory)][int]$StartIndex
    )
    if ($Data[$StartIndex] -ne [byte][char]'d') { throw 'bencode: expected dictionary' }
    $i = $StartIndex + 1
    while ($Data[$i] -ne [byte][char]'e') {
        $i = Read-AppBencodeSkipValue -Data $Data -Index $i
        $i = Read-AppBencodeSkipValue -Data $Data -Index $i
    }
    return $i + 1
}

function Get-AppTorrentInfoHashBytes {
    param([Parameter(Mandatory)][byte[]]$TorrentBytes)
    if (-not $TorrentBytes -or $TorrentBytes.Length -lt 20) {
        throw 'aria2: torrent file too small.'
    }
    $needle = [System.Text.Encoding]::ASCII.GetBytes('4:infod')
    $start = -1
    for ($i = 0; $i -le $TorrentBytes.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($TorrentBytes[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) {
            $start = $i + ($needle.Length - 1)
            break
        }
    }
    if ($start -lt 0) { throw 'aria2: torrent has no info dictionary.' }
    $dictEnd = Get-AppBencodeDictEndIndex -Data $TorrentBytes -StartIndex $start
    $len = $dictEnd - $start
    $infoBytes = New-Object byte[] $len
    [Array]::Copy($TorrentBytes, $start, $infoBytes, 0, $len)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        return ,@($sha.ComputeHash($infoBytes))
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-AppTrackerScrapeUrl {
    param([Parameter(Mandatory)][string]$AnnounceUrl)
    $url = $AnnounceUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    if ($url -match '(?i)announce\.php') {
        return ($url -replace '(?i)announce\.php', 'scrape.php')
    }
    if ($url -match '(?i)/announce/?$') {
        return ($url -replace '(?i)/announce/?$', '/announce?scrape')
    }
    return $null
}

function Get-AppAria2TrackerScrapeUrls {
    $urls = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($announce in @(Get-AppAria2BtTrackerList)) {
        $scrape = ConvertTo-AppTrackerScrapeUrl -AnnounceUrl ([string]$announce)
        if ($scrape -and $seen.Add($scrape)) {
            [void]$urls.Add($scrape)
        }
    }
    @($urls)
}

function ConvertTo-AppTrackerScrapeInfoHashParam {
    param([Parameter(Mandatory)][byte[]]$InfoHash)
    if ($InfoHash.Length -ne 20) { throw 'aria2: info hash must be 20 bytes.' }
    -join ($InfoHash | ForEach-Object { '%{0:X2}' -f $_ })
}

function ConvertFrom-AppBencodeScrapeResponse {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return $null }
    $text = [System.Text.Encoding]::Latin1.GetString($Bytes)
    if ($text -match '8:completei(\d+)e') {
        $seeders = [int]$Matches[1]
    } else {
        return $null
    }
    $leechers = 0
    if ($text -match '10:incompletei(\d+)e') {
        $leechers = [int]$Matches[1]
    } elseif ($text -match '10:downloadedi(\d+)e') {
        $leechers = [int]$Matches[1]
    }
    [PSCustomObject]@{
        Seeders  = $seeders
        Leechers = $leechers
    }
}

function Get-AppWebResponseBytes {
    param([Parameter(Mandatory)]$Response)
    if ($Response.RawContentStream) {
        $ms = New-Object System.IO.MemoryStream
        $Response.RawContentStream.CopyTo($ms)
        return $ms.ToArray()
    }
    if ($Response.Content -is [byte[]]) { return [byte[]]$Response.Content }
    if ($null -ne $Response.Content) {
        return [System.Text.Encoding]::Latin1.GetBytes([string]$Response.Content)
    }
    return $null
}

function Invoke-AppAria2TrackerScrapeForInfoHash {
    param(
        [Parameter(Mandatory)][byte[]]$InfoHash,
        [Parameter(Mandatory)][string[]]$ScrapeUrls
    )
    if (@($ScrapeUrls).Count -eq 0) { return $null }
    $hashParam = ConvertTo-AppTrackerScrapeInfoHashParam -InfoHash $InfoHash
    $bestSeeders = $null
    $bestLeechers = $null
    foreach ($base in @($ScrapeUrls)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $uri = if ($base.Contains('?')) { "$base&info_hash=$hashParam" } else { "$base`?info_hash=$hashParam" }
        try {
            $resp = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -TimeoutSec 20
            $bytes = Get-AppWebResponseBytes -Response $resp
            $parsed = ConvertFrom-AppBencodeScrapeResponse -Bytes $bytes
            if (-not $parsed) { continue }
            if ($null -eq $bestSeeders -or $parsed.Seeders -gt $bestSeeders) {
                $bestSeeders = $parsed.Seeders
                $bestLeechers = $parsed.Leechers
            }
        } catch {
            Write-SidecarLogVerbose "aria2: scrape $uri failed - $($_.Exception.Message)"
        }
    }
    if ($null -eq $bestSeeders) { return $null }
    $leechers = 0
    if ($null -ne $bestLeechers) { $leechers = [int]$bestLeechers }
    [PSCustomObject]@{
        Seeders  = [int]$bestSeeders
        Leechers = $leechers
    }
}

function Get-AppAria2TorrentFileBytesForCatalogRow {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$PackagingDir
    )
    $relProp = Get-AppAria2JsonProp -Item $Row -Name 'torrentPath'
    $rel = if ($relProp) { [string]$relProp } elseif ($Row.torrentPath) { [string]$Row.torrentPath } else { $null }
    if ($rel -and $rel -notmatch '\.\.') {
        $full = Join-Path $PackagingDir $rel
        if (Test-Path -LiteralPath $full) {
            return [System.IO.File]::ReadAllBytes($full)
        }
    }
    $downloadProp = Get-AppAria2JsonProp -Item $Row -Name 'downloadUrl'
    $downloadUrl = if ($downloadProp) { [string]$downloadProp } elseif ($Row.downloadUrl) { [string]$Row.downloadUrl } else { $null }
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) { return $null }
    try {
        $resp = Invoke-WebRequest -Uri $downloadUrl -Method Get -UseBasicParsing -TimeoutSec 120
        return Get-AppWebResponseBytes -Response $resp
    } catch {
        Write-SidecarLogVerbose "aria2: torrent fetch failed ($downloadUrl) - $($_.Exception.Message)"
        return $null
    }
}

function Add-AppAria2TorrentPeerCountsToRows {
    param(
        [Parameter(Mandatory)]$Rows
    )
    if (@($Rows).Count -eq 0) { return @() }
    $packagingDir = Get-AppAria2PackagingDir
    $scrapeUrls = @(Get-AppAria2TrackerScrapeUrls)
    if ($scrapeUrls.Count -eq 0) { return @($Rows) }

    $cache = Read-AppAria2TrackerPeerCache
    $cacheDirty = $false
    $now = Get-Date
    $out = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($row in @($Rows)) {
        $idProp = Get-AppAria2JsonProp -Item $row -Name 'id'
        $id = if ($idProp) { [string]$idProp } elseif ($row.id) { [string]$row.id } else { $null }
        if (-not $id) {
            [void]$out.Add(@{} + $row)
            continue
        }

        $updated = @{} + $row
        $cached = $null
        if ($cache.rows -and $cache.rows.ContainsKey($id)) {
            $cached = $cache.rows[$id]
        }
        if ($cached) {
            $fetchedAt = [string](Get-AppAria2JsonProp -Item $cached -Name 'fetchedAt')
            if (-not $fetchedAt -and $cached.fetchedAt) { $fetchedAt = [string]$cached.fetchedAt }
            if ($fetchedAt) {
                try {
                    $age = $now - [datetimeoffset]::Parse($fetchedAt).UtcDateTime
                    if ($age.TotalMinutes -lt $script:AppAria2TrackerPeerCacheTtlMinutes) {
                        $seedVal = Get-AppAria2JsonProp -Item $cached -Name 'seeders'
                        $leechVal = Get-AppAria2JsonProp -Item $cached -Name 'leechers'
                        $updated['seeders'] = if ($null -ne $seedVal) { [int]$seedVal } elseif ($null -ne (Get-AppSidecarJsonProp -Item $cached -Name 'seeders')) { [int](Get-AppSidecarJsonProp -Item $cached -Name 'seeders') } else { $null }
                        $updated['leechers'] = if ($null -ne $leechVal) { [int]$leechVal } elseif ($null -ne (Get-AppSidecarJsonProp -Item $cached -Name 'leechers')) { [int](Get-AppSidecarJsonProp -Item $cached -Name 'leechers') } else { $null }
                        $updated['peerCountsAt'] = $fetchedAt
                        [void]$out.Add($updated)
                        continue
                    }
                } catch { }
            }
        }

        $torrentBytes = Get-AppAria2TorrentFileBytesForCatalogRow -Row $row -PackagingDir $packagingDir
        if (-not $torrentBytes) {
            [void]$out.Add($updated)
            continue
        }

        try {
            $infoHash = Get-AppTorrentInfoHashBytes -TorrentBytes $torrentBytes
            $peers = Invoke-AppAria2TrackerScrapeForInfoHash -InfoHash $infoHash -ScrapeUrls $scrapeUrls
            if ($peers) {
                $updated['seeders'] = [int]$peers.Seeders
                $updated['leechers'] = [int]$peers.Leechers
                $updated['peerCountsAt'] = (Get-Date).ToUniversalTime().ToString('o')
                if (-not $cache.rows) { $cache.rows = @{} }
                $cache.rows[$id] = @{
                    seeders     = [int]$peers.Seeders
                    leechers    = [int]$peers.Leechers
                    fetchedAt   = [string]$updated['peerCountsAt']
                    infoHashHex = ([BitConverter]::ToString($infoHash)).Replace('-', '').ToLowerInvariant()
                }
                $cacheDirty = $true
            }
        } catch {
            Write-SidecarLogVerbose "aria2: peer scrape failed for $id - $($_.Exception.Message)"
        }
        [void]$out.Add($updated)
    }

    if ($cacheDirty) {
        Write-AppAria2TrackerPeerCache -Cache $cache
    }
    @($out)
}
