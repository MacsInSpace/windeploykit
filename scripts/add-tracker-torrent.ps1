#requires -Version 7.0
<#
.SYNOPSIS
    Add a SOE .torrent to the bundled tracker catalog (packaging/aria2-tracker.json
    + packaging/torrents/), parsing the torrent for its real content size.

    Maintainer tool - DE releases SOE torrents roughly every 6 months. After adding,
    run scripts/publish-aria2-torrents.ps1 to push the torrent + manifest to GitLab
    (the app prefers the hosted manifest over the bundled fallback).

.EXAMPLE
    pwsh -File ./scripts/add-tracker-torrent.ps1 -TorrentPath ~/Downloads/School-SOE-Win11-24H2-v2.torrent -InsertBeforeId school-soe-win11-24h2

.EXAMPLE
    # Re-parse every bundled torrent and stamp contentSizeBytes on its entry.
    pwsh -File ./scripts/add-tracker-torrent.ps1 -BackfillContentSizes

.EXAMPLE
    # Reshare prep: add the Schools tracker to a DE-released torrent (in place, or
    # -OutPath elsewhere). The info dict is spliced through byte-for-byte, so the
    # info-hash - and therefore the swarm - is unchanged; both copies' clients meet
    # via the tracker(s) they share. Follows the existing reshare convention of one
    # announce tier holding every tracker. Idempotent.
    pwsh -File ./scripts/add-tracker-torrent.ps1 -TorrentPath School-SOE-Win11-26H1.torrent -AddAnnounce 'http://deploy.example.com/announce'
#>
[CmdletBinding()]
param(
    [string] $TorrentPath,
    [string] $Id,
    [string] $DisplayName,
    [string] $AssetKind,
    [string] $InsertBeforeId,
    [string] $AddAnnounce,
    [string] $OutPath,
    [switch] $BackfillContentSizes,
    [switch] $Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $RepoRoot 'packaging/aria2-tracker.json'
$torrentsDir = Join-Path $RepoRoot 'packaging/torrents'

function Read-Bencode {
    param([byte[]]$Data, [ref]$Pos)
    $c = [char]$Data[$Pos.Value]
    if ($c -eq 'i') {
        $end = [Array]::IndexOf($Data, [byte][char]'e', $Pos.Value)
        $num = [long][System.Text.Encoding]::ASCII.GetString($Data, $Pos.Value + 1, $end - $Pos.Value - 1)
        $Pos.Value = $end + 1
        return $num
    }
    if ($c -eq 'l') {
        $Pos.Value++
        $list = [System.Collections.Generic.List[object]]::new()
        while ([char]$Data[$Pos.Value] -ne 'e') { $list.Add((Read-Bencode -Data $Data -Pos $Pos)) }
        $Pos.Value++
        return , $list
    }
    if ($c -eq 'd') {
        $Pos.Value++
        $dict = [ordered]@{}
        while ([char]$Data[$Pos.Value] -ne 'e') {
            $keyBytes = Read-Bencode -Data $Data -Pos $Pos
            $key = [System.Text.Encoding]::UTF8.GetString([byte[]]$keyBytes)
            $dict[$key] = Read-Bencode -Data $Data -Pos $Pos
        }
        $Pos.Value++
        return $dict
    }
    # byte string: <len>:<bytes>
    $colon = [Array]::IndexOf($Data, [byte][char]':', $Pos.Value)
    $len = [int][System.Text.Encoding]::ASCII.GetString($Data, $Pos.Value, $colon - $Pos.Value)
    $bytes = [byte[]]::new($len)
    if ($len -gt 0) { [Array]::Copy($Data, $colon + 1, $bytes, 0, $len) }
    $Pos.Value = $colon + 1 + $len
    return , $bytes
}

function Get-TorrentSummary {
    param([Parameter(Mandatory)][string]$Path)
    $raw = [IO.File]::ReadAllBytes($Path)
    $pos = [ref]0
    $t = Read-Bencode -Data $raw -Pos $pos
    if (-not $t.Contains('info')) { throw "Not a torrent (no info dict): $Path" }
    $info = $t['info']
    $name = [System.Text.Encoding]::UTF8.GetString([byte[]]$info['name'])
    $fileNames = @()
    $total = [long]0
    if ($info.Contains('files')) {
        foreach ($f in $info['files']) {
            $total += [long]$f['length']
            $parts = @($f['path'] | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([byte[]]$_) })
            $fileNames += ($parts -join '/')
        }
    } else {
        $total = [long]$info['length']
        $fileNames += $name
    }
    @{
        name             = $name
        contentSizeBytes = $total
        torrentSizeBytes = [long]$raw.Length
        files            = $fileNames
    }
}

function Write-BencodeTo {
    param($Value, [Parameter(Mandatory)][System.IO.MemoryStream]$Stream)
    if ($Value -is [byte[]]) {
        $len = [System.Text.Encoding]::ASCII.GetBytes("$($Value.Length):")
        $Stream.Write($len, 0, $len.Length)
        $Stream.Write($Value, 0, $Value.Length)
        return
    }
    if ($Value -is [long] -or $Value -is [int]) {
        $b = [System.Text.Encoding]::ASCII.GetBytes("i$($Value)e")
        $Stream.Write($b, 0, $b.Length)
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $Stream.WriteByte([byte][char]'d')
        # bencode requires raw-byte key order; Ordinal matches for ASCII keys.
        foreach ($key in @($Value.Keys | Sort-Object { [string]$_ } -Culture 'ordinal')) {
            Write-BencodeTo -Value ([System.Text.Encoding]::UTF8.GetBytes([string]$key)) -Stream $Stream
            Write-BencodeTo -Value $Value[$key] -Stream $Stream
        }
        $Stream.WriteByte([byte][char]'e')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $Stream.WriteByte([byte][char]'l')
        foreach ($item in $Value) { Write-BencodeTo -Value $item -Stream $Stream }
        $Stream.WriteByte([byte][char]'e')
        return
    }
    throw "Write-BencodeTo: unsupported value type $($Value.GetType().FullName)"
}

function Get-TorrentTopLevel {
    # Parses the top-level dict, recording each value's byte span so 'info' can be
    # spliced through untouched (its bytes define the info-hash - the swarm identity).
    param([Parameter(Mandatory)][byte[]]$Data)
    if ([char]$Data[0] -ne 'd') { throw 'Not a torrent (top level is not a dict).' }
    $pos = [ref]1
    $entries = [ordered]@{}
    $spans = @{}
    while ([char]$Data[$pos.Value] -ne 'e') {
        $keyBytes = Read-Bencode -Data $Data -Pos $pos
        $key = [System.Text.Encoding]::UTF8.GetString([byte[]]$keyBytes)
        $start = $pos.Value
        $entries[$key] = Read-Bencode -Data $Data -Pos $pos
        $spans[$key] = @($start, $pos.Value)
    }
    @{ entries = $entries; spans = $spans }
}

function Add-TorrentAnnounce {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )
    $raw = [IO.File]::ReadAllBytes($Path)
    $top = Get-TorrentTopLevel -Data $raw
    $entries = $top.entries
    if (-not $entries.Contains('info')) { throw "Not a torrent (no info dict): $Path" }

    $existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($entries.Contains('announce')) {
        [void]$existing.Add([System.Text.Encoding]::UTF8.GetString([byte[]]$entries['announce']))
    }
    if ($entries.Contains('announce-list')) {
        foreach ($tier in $entries['announce-list']) {
            foreach ($u in $tier) { [void]$existing.Add([System.Text.Encoding]::UTF8.GetString([byte[]]$u)) }
        }
    }
    if ($existing.Contains($Url)) {
        Write-Host "  '$Url' already announced - nothing to do."
        if ($Destination -ne $Path) { Copy-Item -LiteralPath $Path -Destination $Destination -Force }
        return
    }

    # Reshare convention (matches the existing bundled torrents): one tier listing
    # every tracker. Seed the tier from the primary announce when no list exists.
    $urlBytes = [System.Text.Encoding]::UTF8.GetBytes($Url)
    if ($entries.Contains('announce-list')) {
        $firstTier = $entries['announce-list'][0]
        $firstTier.Add($urlBytes)
    } else {
        $tier = [System.Collections.Generic.List[object]]::new()
        if ($entries.Contains('announce')) { $tier.Add([byte[]]$entries['announce']) }
        $tier.Add($urlBytes)
        $tiers = [System.Collections.Generic.List[object]]::new()
        $tiers.Add($tier)
        $entries['announce-list'] = $tiers
    }

    $ms = [System.IO.MemoryStream]::new()
    $ms.WriteByte([byte][char]'d')
    foreach ($key in @($entries.Keys | Sort-Object { [string]$_ } -Culture 'ordinal')) {
        Write-BencodeTo -Value ([System.Text.Encoding]::UTF8.GetBytes([string]$key)) -Stream $ms
        if ($key -eq 'info') {
            $span = $top.spans['info']
            $ms.Write($raw, $span[0], $span[1] - $span[0])
        } else {
            Write-BencodeTo -Value $entries[$key] -Stream $ms
        }
    }
    $ms.WriteByte([byte][char]'e')
    $out = $ms.ToArray()

    # Safety: the rewritten file must parse and carry the identical info bytes.
    $checkTop = Get-TorrentTopLevel -Data $out
    $inSpan = $top.spans['info']
    $outSpan = $checkTop.spans['info']
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hashIn = [Convert]::ToHexString($sha.ComputeHash($raw, $inSpan[0], $inSpan[1] - $inSpan[0]))
    $hashOut = [Convert]::ToHexString($sha.ComputeHash($out, $outSpan[0], $outSpan[1] - $outSpan[0]))
    if ($hashIn -ne $hashOut) { throw 'info-hash changed - refusing to write.' }

    [IO.File]::WriteAllBytes($Destination, $out)
    $tierText = @($checkTop.entries['announce-list'] | ForEach-Object {
            '[' + (@($_ | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([byte[]]$_) }) -join ', ') + ']'
        }) -join ' '
    Write-Host "  wrote $Destination"
    Write-Host "  info-hash $($hashIn.ToLowerInvariant()) (unchanged) | announce-list: $tierText"
}

function Get-InferredAssetKind {
    param([string[]]$Files)
    if (@($Files | Where-Object { $_ -match '(?i)\.wim$' }).Count -gt 0) { return 'wim' }
    if (@($Files | Where-Object { $_ -match '(?i)\.iso$' }).Count -gt 0) { return 'iso' }
    'file'
}

if ($AddAnnounce) {
    if ([string]::IsNullOrWhiteSpace($TorrentPath)) { throw '-AddAnnounce needs -TorrentPath.' }
    $TorrentPath = (Resolve-Path -LiteralPath $TorrentPath).Path
    $dest = if ($OutPath) { $OutPath } else { $TorrentPath }
    Add-TorrentAnnounce -Path $TorrentPath -Url $AddAnnounce -Destination $dest
    exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($BackfillContentSizes) {
    foreach ($entry in @($manifest.torrents)) {
        $rel = [string]$entry.torrentPath
        if (-not $rel) { continue }
        $local = Join-Path $RepoRoot ("packaging/$rel")
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
            Write-Warning "missing bundled torrent for $($entry.id): $local"
            continue
        }
        $summary = Get-TorrentSummary -Path $local
        $entry | Add-Member -NotePropertyName contentSizeBytes -NotePropertyValue ([long]$summary.contentSizeBytes) -Force
        Write-Host ("  {0}: contentSizeBytes = {1:n0} ({2:n2} GiB)" -f $entry.id, $summary.contentSizeBytes, ($summary.contentSizeBytes / 1GB))
    }
    ($manifest | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
    Write-Host "Backfilled. Review with git diff, then run scripts/publish-aria2-torrents.ps1 -ManifestOnly"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($TorrentPath)) {
    throw 'Pass -TorrentPath <file.torrent> (or -BackfillContentSizes).'
}
$TorrentPath = (Resolve-Path -LiteralPath $TorrentPath).Path
$summary = Get-TorrentSummary -Path $TorrentPath
$leaf = Split-Path -Leaf $TorrentPath

if ([string]::IsNullOrWhiteSpace($Id)) {
    $Id = ($summary.name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
}
if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    $DisplayName = "$($summary.name -replace '-', ' ') / $($summary.name)"
}
if ([string]::IsNullOrWhiteSpace($AssetKind)) {
    $AssetKind = Get-InferredAssetKind -Files $summary.files
}

$existing = @($manifest.torrents | Where-Object { [string]$_.id -eq $Id })
if ($existing.Count -gt 0 -and -not $Force) {
    throw "Entry '$Id' already exists - pass -Force to replace it."
}

$dest = Join-Path $torrentsDir $leaf
Copy-Item -LiteralPath $TorrentPath -Destination $dest -Force
Write-Host "  bundled $leaf ($('{0:n0}' -f $summary.torrentSizeBytes) bytes)"

# downloadUrl matches the publish script's convention; publish re-stamps it anyway.
$baseUrl = 'https://artifacts.example.com/api/v4/projects/MacsInSpace%2Fwindeploykit/packages/generic/windeploykit/latest'
$newEntry = [pscustomobject]@{
    id               = $Id
    name             = $DisplayName
    assetKind        = $AssetKind
    torrentPath      = "torrents/$leaf"
    sizeBytes        = [long]$summary.torrentSizeBytes
    contentSizeBytes = [long]$summary.contentSizeBytes
    downloadUrl      = "$baseUrl/$([uri]::EscapeDataString($leaf))"
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($entry in @($manifest.torrents)) {
    if ([string]$entry.id -eq $Id) { continue }  # replaced under -Force
    if ($InsertBeforeId -and [string]$entry.id -eq $InsertBeforeId) { $rows.Add($newEntry) }
    $rows.Add($entry)
}
if (-not ($rows -contains $newEntry)) { $rows.Add($newEntry) }
$manifest.torrents = @($rows)

($manifest | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
Write-Host ("Added '{0}' ({1}, {2:n2} GiB content). Files:" -f $Id, $AssetKind, ($summary.contentSizeBytes / 1GB))
$summary.files | ForEach-Object { Write-Host "    $_" }
Write-Host 'Next: review git diff, then run scripts/publish-aria2-torrents.ps1 (needs GITLAB_TOKEN) to go live.'
