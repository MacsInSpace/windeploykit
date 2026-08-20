#!/usr/bin/env pwsh
# Refresh vendor SCCM driver catalogs and write packaging/*.json (the bundled fallbacks
# shipped with releases). LOCAL/MAINTAINER USE ONLY — the GitLab CI job was retired
# 2026-08-18; day-to-day refresh now lives in the app (aria2 Tracker -> Refresh catalogs).
# Acer resolves via AcerCatalog.xml (curl-friendly CDN) merged over the cached KB-harvest
# list; the legacy HTML scrape only runs as a last resort and fails from any curl client
# (fingerprint bot wall) — the stale-cache tolerance covers that path.

param(
    [switch]$ForceRefresh,
    [switch]$WritePackaging,
    [int]$MinAcerUrls = 150,
    [int]$MinAcerModels = 50,
    [int]$MinLenovoModels = 300,
    [int]$MinDellModels = 200,
    [int]$MinHpModels = 80,
    [int]$MinMicrosoftModels = 30,
    [int]$MaxStaleCacheAgeDays = 45
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $RepoRoot 'sidecar/lib/NpsLogViewer.ps1')
if (-not (Get-Command Write-SidecarLog -ErrorAction SilentlyContinue)) {
    function Write-SidecarLog { param([string]$Message) if ($Message) { Write-Host $Message } }
}
if (-not (Get-Command Write-SidecarLogVerbose -ErrorAction SilentlyContinue)) {
    function Write-SidecarLogVerbose { param([string]$Message) }
}

. (Join-Path $RepoRoot 'sidecar/lib/Aria2Plugin.ps1')
. (Join-Path $RepoRoot 'sidecar/lib/AcerSccmDriverCatalog.ps1')
. (Join-Path $RepoRoot 'sidecar/lib/LenovoSccmDriverCatalog.ps1')
. (Join-Path $RepoRoot 'sidecar/lib/DellSccmDriverCatalog.ps1')
. (Join-Path $RepoRoot 'sidecar/lib/HpSccmDriverCatalog.ps1')
. (Join-Path $RepoRoot 'sidecar/lib/MicrosoftSccmDriverCatalog.ps1')

function Copy-AppVendorSccmCatalogCacheToPackaging {
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][string]$VendorLabel
    )
    if (-not (Test-Path -LiteralPath $CachePath)) {
        throw "$VendorLabel cache missing at $CachePath — run with -ForceRefresh."
    }
    Copy-Item -LiteralPath $CachePath -Destination $DestPath -Force
    Write-Host "Wrote $DestPath"
}

function Test-AppVendorSccmRefreshPrerequisites {
    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
        throw 'curl is required for vendor SCCM catalog refresh.'
    }
}

function Assert-AppVendorSccmLiveCatalog {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$VendorLabel,
        [string]$Detail = $null
    )
    if (-not $ForceRefresh) { return }
    if (-not ($Catalog.fromCache -or $Catalog.stale)) { return }

    # Vendor sites intermittently block datacenter/CLI clients (Acer WAF since
    # ~2026-08 timed out every nightly run and failed the whole job before the
    # other vendors refreshed). A cached catalog younger than the tolerance
    # window is a loud warning, not a failure - the per-vendor minimum count
    # floors below still validate whatever catalog is used. Beyond the window
    # the job fails so genuine rot cannot hide behind the tolerance.
    $ageDays = $null
    $fetchedRaw = $null
    if ($Catalog -is [System.Collections.IDictionary]) {
        if ($Catalog.Contains('fetchedAt')) { $fetchedRaw = $Catalog['fetchedAt'] }
    } elseif ($Catalog.PSObject.Properties.Name -contains 'fetchedAt') {
        $fetchedRaw = $Catalog.fetchedAt
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$fetchedRaw)) {
        try {
            $fetchedAt = [datetime]::Parse([string]$fetchedRaw, $null, [Globalization.DateTimeStyles]::RoundtripKind)
            $ageDays = ((Get-Date).ToUniversalTime() - $fetchedAt.ToUniversalTime()).TotalDays
        } catch { $ageDays = $null }
    }
    if ($null -ne $ageDays -and $ageDays -ge 0 -and $ageDays -le $MaxStaleCacheAgeDays) {
        Write-Warning ("{0} catalog did not refresh live (fromCache={1} stale={2}); continuing with cache aged {3:N1} days (tolerance {4} days). {5}" -f `
            $VendorLabel, $Catalog.fromCache, $Catalog.stale, $ageDays, $MaxStaleCacheAgeDays, $Detail)
        return
    }
    $ageText = if ($null -ne $ageDays) { '{0:N1} days' -f $ageDays } else { 'unknown' }
    throw "$VendorLabel catalog did not refresh live (fromCache=$($Catalog.fromCache) stale=$($Catalog.stale)) and cache age ($ageText) exceeds the $MaxStaleCacheAgeDays-day tolerance. $Detail"
}

if (-not $ForceRefresh) {
    Write-Warning 'Live scrape skipped — pass -ForceRefresh (required for CI).'
} else {
    Test-AppVendorSccmRefreshPrerequisites
}

Write-Host '=== Acer SCCM catalog ==='
$acerCatalog = Get-AppAcerSccmDriverUrlCatalog -ForceRefresh:$ForceRefresh
if (-not $acerCatalog -or -not $acerCatalog.urls) {
    $detail = if (Get-Command Get-AppAcerSccmCatalogLastError -ErrorAction SilentlyContinue) {
        Get-AppAcerSccmCatalogLastError
    } else { $null }
    throw "Acer catalog scrape failed. $detail"
}

Assert-AppVendorSccmLiveCatalog -Catalog $acerCatalog -VendorLabel 'Acer' -Detail (Get-AppAcerSccmCatalogLastError)

$acerUrls = @([string[]]$acerCatalog.urls)
$acerSummary = Get-AppAcerSccmCatalogSummary -Urls $acerUrls
$acerModels = if ($acerSummary.total) { [int]$acerSummary.total } else { [int]$acerSummary.travelmate }

Write-Host "Acer URLs: $($acerUrls.Count) · models: $acerModels (P2 $($acerSummary.p2xx), P4 $($acerSummary.p4xx), P6 $($acerSummary.p6xx), legacy $($acerSummary.legacyP), B1 $($acerSummary.b1xx), B3 $($acerSummary.b3xx), X3 $($acerSummary.x3xx))"
Write-Host "Fetched: $($acerCatalog.fetchedAt)"

if ($acerUrls.Count -lt $MinAcerUrls) {
    throw "Acer URL count $($acerUrls.Count) below minimum $MinAcerUrls"
}
if ($acerModels -lt $MinAcerModels) {
    throw "Acer model count $acerModels below minimum $MinAcerModels"
}

Write-Host ''
Write-Host '=== Lenovo SCCM catalog ==='
$lenovoCatalog = Get-AppLenovoSccmDriverCatalog -ForceRefresh:$ForceRefresh
if (-not $lenovoCatalog) {
    $detail = if (Get-Command Get-AppLenovoSccmCatalogLastError -ErrorAction SilentlyContinue) {
        Get-AppLenovoSccmCatalogLastError
    } else { $null }
    throw "Lenovo catalog scrape failed. $detail"
}

Assert-AppVendorSccmLiveCatalog -Catalog $lenovoCatalog -VendorLabel 'Lenovo' -Detail (Get-AppLenovoSccmCatalogLastError)

$lenovoSummary = Get-AppLenovoSccmCatalogFamilySummary -Catalog $lenovoCatalog
Write-Host "Lenovo models: $($lenovoSummary.total) (ThinkPad $($lenovoSummary.thinkpad), Yoga $($lenovoSummary.yoga), 11e $($lenovoSummary.'11e'))"
Write-Host "Fallback pages: $($lenovoCatalog.fallbacks.Count) (fromCache=$($lenovoCatalog.fromCache))"
Write-Host "Fetched: $($lenovoCatalog.fetchedAt)"

if ([int]$lenovoSummary.total -lt $MinLenovoModels) {
    throw "Lenovo model count $($lenovoSummary.total) below minimum $MinLenovoModels"
}

Write-Host ''
Write-Host '=== Dell SCCM catalog ==='
$dellCatalog = Get-AppDellSccmDriverCatalog -ForceRefresh:$ForceRefresh
if (-not $dellCatalog) {
    $detail = if (Get-Command Get-AppDellSccmCatalogLastError -ErrorAction SilentlyContinue) {
        Get-AppDellSccmCatalogLastError
    } else { $null }
    throw "Dell catalog scrape failed. $detail"
}

Assert-AppVendorSccmLiveCatalog -Catalog $dellCatalog -VendorLabel 'Dell' -Detail (Get-AppDellSccmCatalogLastError)

$dellSummary = Get-AppDellSccmCatalogFamilySummary -Catalog $dellCatalog
Write-Host "Dell models: $($dellSummary.total) (Latitude $($dellSummary.latitude), OptiPlex $($dellSummary.optiplex), XPS $($dellSummary.xps), Precision $($dellSummary.precision))"
Write-Host "Fetched: $($dellCatalog.fetchedAt)"

if ([int]$dellSummary.total -lt $MinDellModels) {
    throw "Dell model count $($dellSummary.total) below minimum $MinDellModels"
}

Write-Host ''
Write-Host '=== HP SCCM catalog ==='
$hpCatalog = Get-AppHpSccmDriverCatalog -ForceRefresh:$ForceRefresh
if (-not $hpCatalog) {
    $detail = if (Get-Command Get-AppHpSccmCatalogLastError -ErrorAction SilentlyContinue) {
        Get-AppHpSccmCatalogLastError
    } else { $null }
    throw "HP catalog scrape failed. $detail"
}

Assert-AppVendorSccmLiveCatalog -Catalog $hpCatalog -VendorLabel 'HP' -Detail (Get-AppHpSccmCatalogLastError)

$hpSummary = Get-AppHpSccmCatalogFamilySummary -Catalog $hpCatalog
Write-Host "HP models: $($hpSummary.total) (Notebooks $($hpSummary.notebooks), Desktops $($hpSummary.desktops), Workstations $($hpSummary.workstations))"
Write-Host "OS column: $($hpCatalog.osColumn)"
Write-Host "Fetched: $($hpCatalog.fetchedAt)"

if ([int]$hpSummary.total -lt $MinHpModels) {
    throw "HP model count $($hpSummary.total) below minimum $MinHpModels"
}

Write-Host ''
Write-Host '=== Microsoft (Surface) SCCM catalog ==='
$microsoftCatalog = Get-AppMicrosoftSccmDriverCatalog -ForceRefresh:$ForceRefresh
if (-not $microsoftCatalog) {
    $detail = if (Get-Command Get-AppMicrosoftSccmCatalogLastError -ErrorAction SilentlyContinue) {
        Get-AppMicrosoftSccmCatalogLastError
    } else { $null }
    throw "Microsoft catalog fetch failed. $detail"
}

Assert-AppVendorSccmLiveCatalog -Catalog $microsoftCatalog -VendorLabel 'Microsoft' -Detail (Get-AppMicrosoftSccmCatalogLastError)

$microsoftModels = @($microsoftCatalog.models).Count
Write-Host "Microsoft Surface models: $microsoftModels"
Write-Host "Fetched: $($microsoftCatalog.fetchedAt)"

if ($microsoftModels -lt $MinMicrosoftModels) {
    throw "Microsoft model count $microsoftModels below minimum $MinMicrosoftModels"
}

if ($WritePackaging) {
    Write-Host ''
    Write-Host '=== Write packaging ==='
    Copy-AppVendorSccmCatalogCacheToPackaging `
        -CachePath (Get-AppAcerSccmCatalogCachePath) `
        -DestPath (Join-Path $RepoRoot 'packaging/acer-sccm-catalog.json') `
        -VendorLabel 'Acer'
    Copy-AppVendorSccmCatalogCacheToPackaging `
        -CachePath (Get-AppLenovoSccmCatalogCachePath) `
        -DestPath (Join-Path $RepoRoot 'packaging/lenovo-sccm-catalog.json') `
        -VendorLabel 'Lenovo'
    Copy-AppVendorSccmCatalogCacheToPackaging `
        -CachePath (Get-AppDellSccmCatalogCachePath) `
        -DestPath (Join-Path $RepoRoot 'packaging/dell-sccm-catalog.json') `
        -VendorLabel 'Dell'
    Copy-AppVendorSccmCatalogCacheToPackaging `
        -CachePath (Get-AppHpSccmCatalogCachePath) `
        -DestPath (Join-Path $RepoRoot 'packaging/hp-sccm-catalog.json') `
        -VendorLabel 'HP'
    Copy-AppVendorSccmCatalogCacheToPackaging `
        -CachePath (Get-AppMicrosoftSccmCatalogCachePath) `
        -DestPath (Join-Path $RepoRoot 'packaging/microsoft-sccm-catalog.json') `
        -VendorLabel 'Microsoft'
}

Write-Host ''
Write-Host 'Vendor SCCM catalog refresh OK'
