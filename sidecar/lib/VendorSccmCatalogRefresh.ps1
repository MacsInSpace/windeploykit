# Vendor SCCM catalog refresh — USM-side, all four vendors uniformly.
#
# Replaces the GitLab CI job `refresh:vendor-sccm-catalogs` (removed 2026-08-18, Craig's
# call: the catalogs should have ONE refresh path, and CI could no longer cover Acer —
# the discovery pages sit behind fingerprint-level bot mitigation that blocks curl from
# any network, while a real browser passes; see AGENT_NOTES_PXE_DRIVERS §12).
#
#   Dell / HP / Lenovo — sidecar curl via the existing catalog libs (verified curl-clean).
#   Acer               — AcerCatalog.xml over curl (open CDN host; friendly model names +
#                        per-pack MD5) merged into the cached URL list. The XML only covers
#                        current TravelMate P-lines, so when the last full browser harvest
#                        of the community KB is missing or >60 days old the response flags
#                        `acerHarvestRecommended` and the app tops up coverage through the
#                        hidden-webview harvest (Rust `harvest_acer_sccm_urls`).
#
# Floors mirror the retired CI guard rails: below-floor results are recorded and the
# cache is still written (warn-inside-window house style) — the caller surfaces the
# warning; genuine rot shows up as staleness, not silent absence.

$script:AppVendorSccmCatalogFloors = @{
    dell      = 200   # models
    hp        = 80    # models
    lenovo    = 300   # models
    acer      = 150   # urls (plus >= 50 TravelMate entries)
    microsoft = 30    # Surface models (51 as of 2026-08)
}

function Invoke-AppVendorSccmCatalogRefresh {
    <#
    .SYNOPSIS
        Force-refresh all four vendor catalogs live over curl (per-vendor isolation — one
        vendor failing never blocks the others). Acer uses AcerCatalog.xml merged into the
        cached URL list; the response also says whether the app should top up coverage
        with a browser harvest of the KB page (Set-AppAcerSccmCatalogFromHarvest).
    #>
    param([string[]]$Vendors = @('dell', 'hp', 'lenovo', 'microsoft', 'acer'))
    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($vendor in @($Vendors | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })) {
        $entry = @{ vendor = $vendor; ok = $false; count = 0; belowFloor = $false; error = $null }
        try {
            switch ($vendor) {
                'dell' {
                    $cat = Get-AppDellSccmDriverCatalog -ForceRefresh
                    $entry.count = @($cat.models).Count
                    $entry.fetchedAt = [string]$cat.fetchedAt
                    $entry.ok = -not ($cat.fromCache -or $cat.stale)
                    if (-not $entry.ok) { $entry.error = [string](Get-AppDellSccmCatalogLastError) }
                }
                'hp' {
                    $cat = Get-AppHpSccmDriverCatalog -ForceRefresh
                    $entry.count = @($cat.models).Count
                    $entry.fetchedAt = [string]$cat.fetchedAt
                    $entry.ok = -not ($cat.fromCache -or $cat.stale)
                    if (-not $entry.ok) { $entry.error = [string](Get-AppHpSccmCatalogLastError) }
                }
                'lenovo' {
                    $cat = Get-AppLenovoSccmDriverCatalog -ForceRefresh
                    $entry.count = @($cat.models).Count
                    $entry.fetchedAt = [string]$cat.fetchedAt
                    $entry.ok = -not ($cat.fromCache -or $cat.stale)
                    if (-not $entry.ok) { $entry.error = [string](Get-AppLenovoSccmCatalogLastError) }
                }
                'microsoft' {
                    $cat = Get-AppMicrosoftSccmDriverCatalog -ForceRefresh
                    $entry.count = @($cat.models).Count
                    $entry.fetchedAt = [string]$cat.fetchedAt
                    $entry.ok = -not ($cat.fromCache -or $cat.stale)
                    if (-not $entry.ok) { $entry.error = [string](Get-AppMicrosoftSccmCatalogLastError) }
                }
                'acer' {
                    $out = Update-AppAcerSccmCatalogFromXml
                    $entry.count = [int]$out.mergedUrlCount
                    $entry.xmlModelCount = [int]$out.xmlModelCount
                    $entry.harvestAgeDays = $out.harvestAgeDays
                    $entry.harvestRecommended = [bool]$out.harvestRecommended
                    $entry.ok = [bool]$out.ok
                }
                default {
                    $entry.error = "unknown vendor '$vendor'"
                }
            }
        } catch {
            $entry.error = $_.Exception.Message
        }
        $floor = if ($script:AppVendorSccmCatalogFloors.ContainsKey($vendor)) { [int]$script:AppVendorSccmCatalogFloors[$vendor] } else { 0 }
        $entry.floor = $floor
        if ($entry.ok -and $floor -gt 0 -and $entry.count -lt $floor) {
            $entry.belowFloor = $true
            Write-SidecarLog "vendor catalogs: $vendor refreshed with $($entry.count) models — below the $floor floor (source may have broken)"
        } elseif ($entry.ok) {
            Write-SidecarLog "vendor catalogs: $vendor refreshed ($($entry.count) models)"
        } else {
            Write-SidecarLog "vendor catalogs: $vendor refresh failed — $($entry.error)"
        }
        [void]$results.Add($entry)
    }
    $acerEntry = @($results) | Where-Object { $_.vendor -eq 'acer' } | Select-Object -First 1
    @{
        results                = @($results)
        # The page the frontend's hidden webview harvests for Acer coverage top-ups (a
        # real browser passes the bot wall; sidecar curl cannot).
        acerHarvestUrl         = [string]@($script:AppAcerSccmFallbackUrls)[0]
        # Harvest when the XML refresh failed, or the last full KB harvest is stale.
        # harvestRecommended only exists on a successful acer entry (StrictMode-safe read).
        acerHarvestRecommended = [bool]($acerEntry -and ((-not $acerEntry.ok) -or ($acerEntry.ContainsKey('harvestRecommended') -and $acerEntry.harvestRecommended)))
    }
}

# --- Background refresh (child pwsh process) --------------------------------
# The synchronous refresh curled five vendor catalogs inside the single-threaded
# dispatch loop — every panel's IPC queued behind it for up to minutes (the exact
# blocking pattern the runspace downloads fixed). An in-process runspace can't
# safely re-load the catalog libs (they lean on much of the sidecar), but a child
# pwsh PROCESS can: scripts/refresh-vendor-sccm-catalogs.ps1 already proves the
# standalone loading pattern. The child shares the on-disk catalog caches, writes
# its result JSON to a temp file, and the housekeeping tick emits the
# 'vendor-catalog-refresh' event the panel finishes from. (Craig, 2026-08-20.)

$script:AppVendorSccmCatalogRefreshJob = $null

$script:AppVendorSccmCatalogRefreshRunner = @'
param(
    [Parameter(Mandatory)][string]$SidecarRoot,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$Vendors = ''
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $SidecarRoot 'lib/NpsLogViewer.ps1')
    if (-not (Get-Command Write-SidecarLog -ErrorAction SilentlyContinue)) {
        function Write-SidecarLog { param([string]$Message) }
    }
    if (-not (Get-Command Write-SidecarLogVerbose -ErrorAction SilentlyContinue)) {
        function Write-SidecarLogVerbose { param([string]$Message) }
    }
    . (Join-Path $SidecarRoot 'lib/Aria2Plugin.ps1')
    . (Join-Path $SidecarRoot 'lib/AcerSccmDriverCatalog.ps1')
    . (Join-Path $SidecarRoot 'lib/LenovoSccmDriverCatalog.ps1')
    . (Join-Path $SidecarRoot 'lib/DellSccmDriverCatalog.ps1')
    . (Join-Path $SidecarRoot 'lib/HpSccmDriverCatalog.ps1')
    . (Join-Path $SidecarRoot 'lib/MicrosoftSccmDriverCatalog.ps1')
    . (Join-Path $SidecarRoot 'lib/VendorSccmCatalogRefresh.ps1')
    $vendorList = @(($Vendors -split ',') | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $out = if ($vendorList.Count -gt 0) {
        Invoke-AppVendorSccmCatalogRefresh -Vendors $vendorList
    } else {
        Invoke-AppVendorSccmCatalogRefresh
    }
    ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    (@{ error = $_.Exception.Message } | ConvertTo-Json) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
'@

function Start-AppVendorSccmCatalogRefreshJob {
    param([string[]]$Vendors = @())
    if ($script:AppVendorSccmCatalogRefreshJob) {
        return @{ accepted = $true; background = $true; alreadyRunning = $true }
    }
    $stamp = [Guid]::NewGuid().ToString('N')
    $runnerPath = Join-Path ([IO.Path]::GetTempPath()) "usm-catalog-refresh-$stamp.ps1"
    $resultPath = Join-Path ([IO.Path]::GetTempPath()) "usm-catalog-refresh-$stamp.json"
    Set-Content -LiteralPath $runnerPath -Value $script:AppVendorSccmCatalogRefreshRunner -Encoding UTF8
    $pwsh = if ([string]::IsNullOrWhiteSpace([string][Environment]::ProcessPath)) { 'pwsh' } else { [string][Environment]::ProcessPath }
    $procArgs = @('-NoProfile', '-NonInteractive', '-File', $runnerPath, '-SidecarRoot', [string]$script:SidecarRoot, '-ResultPath', $resultPath)
    if (@($Vendors).Count -gt 0) { $procArgs += @('-Vendors', (@($Vendors) -join ',')) }
    $proc = Start-AppNativeProcess -FilePath $pwsh -Arguments $procArgs
    $script:AppVendorSccmCatalogRefreshJob = @{
        process    = $proc
        resultPath = $resultPath
        runnerPath = $runnerPath
        startedAt  = Get-Date
    }
    Write-SidecarLog 'vendor catalogs: background refresh started (child pwsh)'
    @{ accepted = $true; background = $true }
}

function Sync-AppVendorSccmCatalogRefreshJob {
    # Housekeeping tick: reap the finished child and emit the completion event.
    $job = $script:AppVendorSccmCatalogRefreshJob
    if (-not $job) { return }
    $proc = $job.process
    if ($proc -and -not $proc.HasExited) {
        # Watchdog: five vendors at curl --max-time worst case stay well inside
        # this; a wedged child must not hold the "already running" latch forever.
        if (((Get-Date) - $job.startedAt).TotalMinutes -gt 15) {
            Write-SidecarLog 'vendor catalogs: background refresh watchdog kill (15 min)'
            try { $proc.Kill($true) } catch { }
        }
        return
    }
    $script:AppVendorSccmCatalogRefreshJob = $null
    $payload = $null
    try {
        if (Test-Path -LiteralPath $job.resultPath) {
            $payload = Get-Content -LiteralPath $job.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    } catch { $payload = $null }
    Remove-Item -LiteralPath $job.resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $job.runnerPath -Force -ErrorAction SilentlyContinue
    if (-not $payload) {
        Write-SidecarLog 'vendor catalogs: background refresh ended with no result'
        Write-SidecarEvent -EventName 'vendor-catalog-refresh' -Data @{ error = 'refresh process ended without a result (killed or crashed)' }
        return
    }
    Write-SidecarLog 'vendor catalogs: background refresh finished'
    Write-SidecarEvent -EventName 'vendor-catalog-refresh' -Data $payload
}

function Stop-AppVendorSccmCatalogRefreshJob {
    # Shutdown cleanup only — no event (the app is going away).
    $job = $script:AppVendorSccmCatalogRefreshJob
    if (-not $job) { return }
    $script:AppVendorSccmCatalogRefreshJob = $null
    try { if ($job.process -and -not $job.process.HasExited) { $job.process.Kill($true) } } catch { }
    Remove-Item -LiteralPath $job.resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $job.runnerPath -Force -ErrorAction SilentlyContinue
}

function Set-AppAcerSccmCatalogFromHarvest {
    <#
    .SYNOPSIS
        Validate and store a browser-harvested Acer URL list as the live Acer catalog
        cache. Normalises hrefs (Acer's KB contains an http://https// typo link), keeps
        only global-download.acer.com pack files, and enforces the CI-era floors before
        overwriting the cache — a bad harvest can never clobber a good catalog.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [string]$HarvestedFrom
    )
    $clean = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $Urls) {
        $u = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($u)) { continue }
        # Normalise: anything up to the CDN host is dropped (fixes scheme typos), and only
        # pack-file extensions are kept.
        $m = [regex]::Match($u, '(?i)global-download\.acer\.com/(.+)$')
        if (-not $m.Success) { continue }
        $rel = $m.Groups[1].Value
        if ($rel -notmatch '(?i)\.(cab|zip|exe)$') { continue }
        if ($rel -match '[\s"''<>]') { continue }
        $url = "https://global-download.acer.com/$rel"
        if ($seen.Add($url)) { [void]$clean.Add($url) }
    }

    $floor = [int]$script:AppVendorSccmCatalogFloors.acer
    if ($clean.Count -lt $floor) {
        throw "Acer harvest rejected: $($clean.Count) usable URLs is below the $floor floor (page may not have finished rendering)."
    }
    $entries = @(Get-AppAcerSccmTravelMateCatalogEntries -Urls @($clean))
    if ($entries.Count -lt 50) {
        throw "Acer harvest rejected: only $($entries.Count) TravelMate model entries parsed (need >= 50)."
    }

    $resolved = if ([string]::IsNullOrWhiteSpace($HarvestedFrom)) { [string]@($script:AppAcerSccmFallbackUrls)[0] } else { [string]$HarvestedFrom }
    # Preserve the structured XML model entries across a harvest write (they come from
    # AcerCatalog.xml, not the KB page) and stamp when this full harvest happened.
    $existing = Read-AppAcerSccmCatalogCache
    $models = $null
    if ($existing) {
        # Indexer, not `.Name -contains`: member enumeration on an EMPTY property
        # collection throws under StrictMode (the documented `fields: {}` trap).
        $prop = if ($existing -is [System.Collections.IDictionary]) {
            if ($existing.Contains('models')) { $existing['models'] } else { $null }
        } else {
            $p = $existing.PSObject.Properties['models']
            if ($p) { $p.Value } else { $null }
        }
        if ($prop) { $models = @($prop) }
    }
    Write-AppAcerSccmCatalogCache -Urls @($clean) -SourceUrl $script:AppAcerSccmEntryUrl -ResolvedUrl $resolved `
        -Models $models -HarvestedAt ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    Write-SidecarLog "vendor catalogs: Acer harvest stored ($($clean.Count) URLs, $($entries.Count) TravelMate entries)"
    @{
        ok         = $true
        urlCount   = $clean.Count
        modelCount = $entries.Count
        summary    = (Get-AppAcerSccmCatalogSummary -Urls @($clean))
    }
}
