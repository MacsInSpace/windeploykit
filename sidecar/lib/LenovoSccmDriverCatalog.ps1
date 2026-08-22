# Lenovo ThinkPad SCCM driver pack catalog - parse catalogv2.xml + support-page fallbacks.
# Primary: https://download.lenovo.com/cdrt/td/catalogv2.xml
# Fallback support pages when a machine type is not listed in the XML (scrape when reachable).

# Canonical data-root + product-identity resolvers (no-op when the sidecar already
# dot-sourced AppPaths.ps1; needed when dev/test scripts or the catalog-refresh child
# load this lib standalone). AppPaths.ps1 pulls AppProductIdentity.ps1 itself.
if (-not (Get-Command Get-AppDataRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppPaths.ps1')
}

$script:AppLenovoSccmCatalogUrl = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'
# 14 days: drivers change rarely; the list path reads the cache only and the sidecar's
# automatic check (VendorSccmCatalogRefresh.ps1) refreshes in the background once this
# age is exceeded. Manual Refresh catalogs forces it at any time.
$script:AppLenovoSccmCatalogCacheHours = 336
$script:AppLenovoSccmCatalogLastError = $null

# Support download pages - machine types from page titles; offlineWin11Url is last-resort when scrape fails.
$script:AppLenovoSccmSupportFallbackPages = @(
    @{
        id             = 'ds555902'
        url            = 'https://support.lenovo.com/au/en/downloads/ds555902'
        machineTypes   = @('21AH', '21AJ', '21BV', '21BW', '21AK', '21AL', '21BT', '21BU')
        offlineWin11Url = 'https://download.lenovo.com/pccbbs/mobiles/tp_t14-p14s-gen3-t16-p16s-gen1_w11_25h2_202601.exe'
    },
    @{
        id             = 'ds555980'
        url            = 'https://support.lenovo.com/au/en/downloads/ds555980'
        machineTypes   = @('21BR', '21BS', '21BN', '21BQ')
        offlineWin11Url = 'https://download.lenovo.com/pccbbs/mobiles/tp_t14s_gen3_mt21br_21bs_x13_gen3_mt21bn_21bq_w11_25h2_202601.exe'
    }
)

function Get-AppLenovoSccmCatalogLastError {
    return $script:AppLenovoSccmCatalogLastError
}

function Get-AppLenovoSccmCatalogCachePath {
    # Same folder whether or not Aria2Plugin.ps1 is loaded: <data root>/plugins/aria2/.
    # (Until 2026-08-22 the standalone branch used a second, slug-named folder.)
    if (-not (Get-Command Get-AppAria2StoreRoot -ErrorAction SilentlyContinue)) {
        return Join-Path (Get-AppPluginDir -Plugin 'aria2') 'lenovo-sccm-catalog.json'
    }
    Join-Path (Get-AppAria2StoreRoot) 'lenovo-sccm-catalog.json'
}

function Read-AppLenovoSccmCatalogCache {
    $path = Get-AppLenovoSccmCatalogCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-AppLenovoSccmCatalogCache {
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$SourceUrl = $script:AppLenovoSccmCatalogUrl
    )
    $path = Get-AppLenovoSccmCatalogCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $payload = @{
        schema      = 1
        sourceUrl   = $SourceUrl
        fetchedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        modelCount  = @($Catalog.models).Count
        models      = @($Catalog.models)
        fallbacks   = @($Catalog.fallbacks)
    }
    # Atomic replace: the list path may read this file while the refresh child writes it;
    # a half-written file would fall back to the bundled catalog and the list would shrink.
    $tmp = "$path.tmp"
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Invoke-AppLenovoSccmHttpGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxTimeSec = 90
    )
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if ($curl) {
        $out = & curl -sS -L --http1.1 --max-time $MaxTimeSec -A (Get-AppUserAgent) $Uri 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "curl failed (exit $LASTEXITCODE): $out"
        }
        return [string]$out
    }
    throw 'curl is required to fetch Lenovo SCCM catalog.'
}

function Test-AppLenovoTypeMatchesPattern {
    param(
        [Parameter(Mandatory)][string]$TypeCode,
        [Parameter(Mandatory)][string]$Pattern
    )
    if ([string]::IsNullOrWhiteSpace($TypeCode) -or [string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    $type = $TypeCode.Trim().ToUpperInvariant()
    $pat = $Pattern.Trim().ToUpperInvariant()
    if ($pat.Length -ge 4) { return $type -eq $pat }
    return $type.StartsWith($pat, [StringComparison]::OrdinalIgnoreCase)
}

function Test-AppLenovoSccmModelIncluded {
    param([Parameter(Mandatory)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    # catalogv2.xml lists Yoga + 11e under the ThinkPad product line (e.g. ThinkPad Yoga 11e).
    if ($Name -match '(?i)\bThinkPad\b') { return $true }
    # Education models without a ThinkPad prefix. [ew] matters: the Windows EDU
    # convertibles are w-suffix (100w/300w/500w) - the old e-only list dropped them
    # even when the source listed them (AGENT_NOTES_PXE_DRIVERS section 3.3).
    if ($Name -match '(?i)\b(Yoga|11e|[1-6]00[ew])\b') { return $true }
    return $false
}

function Get-AppLenovoSccmModelFamily {
    param([Parameter(Mandatory)][string]$Name)
    # [ew]: count the w-suffix EDU convertibles (100w/300w/500w) with their e-siblings.
    if ($Name -match '(?i)\b11e\b|\b[1-6]00[ew]\b') { return '11e' }
    if ($Name -match '(?i)\bYoga\b') { return 'yoga' }
    if ($Name -match '(?i)\bThinkPad\b') { return 'thinkpad' }
    return 'other'
}

function Get-AppLenovoSccmPrimaryTypeCode {
    param([Parameter(Mandatory)][string[]]$Types)
    $normalized = @($Types | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ })
    if ($normalized.Count -eq 0) { return $null }
    $fourChar = @($normalized | Where-Object { $_.Length -ge 4 } | Sort-Object)
    if ($fourChar.Count -gt 0) { return $fourChar[0].Substring(0, 4) }
    return ($normalized | Sort-Object | Select-Object -First 1)
}

function Get-AppLenovoSccmBestSccmEntryForModel {
    param([Parameter(Mandatory)]$Model)
    $bestEntry = $null
    # Lenovo is the only SIGNED scorer of the five vendors (win10 scores -100,
    # _HSA_ -40), so a -1 seed silently discarded every Win10-only model - 80 of
    # 372 (22%) resolved to nothing and vanished from the catalog. Do NOT copy
    # this to Acer (-1 is its deliberate no-match sentinel, real scores clamp >= 1)
    # or Dell (additive-only, never negative). USM 3ebc463 / handover 2026-08-21.
    $bestScore = [int]::MinValue
    foreach ($entry in @(Get-AppAria2JsonProp -Item $Model -Name 'sccm')) {
        if (-not $entry) { continue }
        $score = Get-AppLenovoSccmEntryScore `
            -Os ([string](Get-AppAria2JsonProp -Item $entry -Name 'os')) `
            -Version ([string](Get-AppAria2JsonProp -Item $entry -Name 'version')) `
            -Date ([string](Get-AppAria2JsonProp -Item $entry -Name 'date')) `
            -Url ([string](Get-AppAria2JsonProp -Item $entry -Name 'url'))
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestEntry = $entry
        }
    }
    if (-not $bestEntry) { return $null }
    $url = [string](Get-AppAria2JsonProp -Item $bestEntry -Name 'url')
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    @{
        url      = $url
        fileName = [System.IO.Path]::GetFileName($url)
        score    = $bestScore
    }
}

function Get-AppLenovoSccmCatalogFamilySummary {
    param([Parameter(Mandatory)]$Catalog)
    $summary = @{
        thinkpad = 0
        yoga     = 0
        '11e'    = 0
        other    = 0
        total    = 0
    }
    foreach ($model in @(Get-AppAria2JsonProp -Item $Catalog -Name 'models')) {
        $name = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $family = Get-AppLenovoSccmModelFamily -Name $name
        if ($summary.ContainsKey($family)) {
            $summary[$family] = [int]$summary[$family] + 1
        } else {
            $summary.other = [int]$summary.other + 1
        }
        $summary.total = [int]$summary.total + 1
    }
    $summary
}

function Get-AppLenovoSccmEntryScore {
    param(
        [string]$Os,
        [string]$Version,
        [string]$Date,
        [string]$Url
    )
    $score = 0
    $osNorm = ($Os ?? '').ToLowerInvariant()
    if ($osNorm -eq 'win11') { $score += 200 }
    elseif ($osNorm -eq 'win10') { $score -= 100 }
    else { $score -= 50 }
    $ver = ($Version ?? '').ToUpperInvariant()
    if ($ver -match '25H2') { $score += 55 }
    elseif ($ver -match '24H2') { $score += 45 }
    elseif ($ver -match '23H2') { $score += 35 }
    elseif ($ver -match '22H2') { $score += 25 }
    elseif ($ver -match '21H2') { $score += 15 }
    elseif ($ver -eq '*') { $score += 5 }
    if ($Date) {
        try {
            $d = [datetime]::Parse($Date)
            $days = ([datetime]::UtcNow - $d.ToUniversalTime()).TotalDays
            if ($days -ge 0 -and $days -lt 5000) { $score += [int][math]::Min(40, 40 - ($days / 30)) }
        } catch { }
    }
    $name = [System.IO.Path]::GetFileName($Url ?? '').ToUpperInvariant()
    if ($name -match '\.EXE$') { $score += 8 }
    if ($name -match '_HSA_') { $score -= 40 }
    return $score
}

function Parse-AppLenovoSccmDriverUrlsFromHtml {
    param([Parameter(Mandatory)][string]$Html)
    $matches = [regex]::Matches($Html, 'https://download\.lenovo\.com/[^"''\s<>]+', 'IgnoreCase')
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $matches) {
        $url = [System.Uri]::UnescapeDataString($m.Value.Trim().TrimEnd(')', ',', ';'))
        if ($url -match '\.(exe|cab|zip)(\?|$)') {
            [void]$set.Add($url)
        }
    }
    @($set)
}

function Get-AppLenovoSccmBestUrlFromList {
    param([Parameter(Mandatory)][string[]]$Urls)
    if (-not $Urls -or $Urls.Count -eq 0) { return $null }
    $best = $null
    # Signed scorer - must not seed at -1. See Get-AppLenovoSccmBestSccmEntryForModel.
    $bestScore = [int]::MinValue
    foreach ($url in $Urls) {
        $name = [System.IO.Path]::GetFileName($url).ToLowerInvariant()
        $score = 0
        if ($name -match 'w11|win11') { $score += 200 }
        if ($name -match '25h2') { $score += 55 }
        elseif ($name -match '24h2|_24_') { $score += 45 }
        elseif ($name -match '23h2') { $score += 35 }
        elseif ($name -match '22h2|_22_') { $score += 25 }
        elseif ($name -match '21h2|_21_') { $score += 15 }
        if ($name -match 'w10|win10|w1064') { $score -= 100 }
        if ($name -match '_hsa_') { $score -= 40 }
        if ($name -match '\.exe$') { $score += 8 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $url
        }
    }
    $best
}

function Get-AppLenovoSccmSupportFallbackUrls {
    param([Parameter(Mandatory)][hashtable]$PageDef)
    $urls = [System.Collections.Generic.List[string]]::new()
    if ($PageDef.offlineWin11Url) {
        [void]$urls.Add([string]$PageDef.offlineWin11Url)
    }
    @($urls)
}

function Parse-AppLenovoSccmCatalogFromXml {
    param([Parameter(Mandatory)][string]$XmlText)
    $XmlText = $XmlText.TrimStart([char]0xFEFF).TrimStart()
    $doc = [xml]$XmlText
    $models = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($modelNode in @($doc.ModelList.Model)) {
        $name = [string]$modelNode.name
        if (-not (Test-AppLenovoSccmModelIncluded -Name $name)) { continue }
        $types = @($modelNode.Types.Type | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($types.Count -eq 0) { continue }
        $sccm = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($sccmNode in @($modelNode.SCCM)) {
            $url = ([string]$sccmNode.'#text').Trim()
            if ([string]::IsNullOrWhiteSpace($url)) { continue }
            [void]$sccm.Add(@{
                    os      = [string]$sccmNode.os
                    version = [string]$sccmNode.version
                    date    = [string]$sccmNode.date
                    url     = $url
                })
        }
        if ($sccm.Count -eq 0) { continue }
        [void]$models.Add(@{
                name   = $name
                family = Get-AppLenovoSccmModelFamily -Name $name
                types  = $types
                sccm   = @($sccm)
            })
    }
    $fallbacks = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($page in @($script:AppLenovoSccmSupportFallbackPages)) {
        $urls = @(Get-AppLenovoSccmSupportFallbackUrls -PageDef $page)
        [void]$fallbacks.Add(@{
                id           = [string]$page.id
                url          = [string]$page.url
                machineTypes = @($page.machineTypes)
                urls         = $urls
            })
    }
    @{
        models    = @($models)
        fallbacks = @($fallbacks)
    }
}

function Resolve-AppLenovoSccmDriverUrlForWmiPatterns {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)]$Catalog,
        [string]$FallbackPageUrl = $null
    )
    if (-not $Patterns -or $Patterns.Count -eq 0 -or -not $Catalog) { return $null }

    $bestUrl = $null
    # Signed scorer - must not seed at -1. See Get-AppLenovoSccmBestSccmEntryForModel.
    $bestScore = [int]::MinValue
    $bestSource = $null
    $bestModel = $null

    foreach ($model in @($Catalog.models)) {
        $matched = $false
        foreach ($pattern in $Patterns) {
            foreach ($typeCode in @($model.types)) {
                if (Test-AppLenovoTypeMatchesPattern -TypeCode $typeCode -Pattern $pattern) {
                    $matched = $true
                    break
                }
            }
            if ($matched) { break }
        }
        if (-not $matched) { continue }
        foreach ($entry in @($model.sccm)) {
            $score = Get-AppLenovoSccmEntryScore -Os $entry.os -Version $entry.version -Date $entry.date -Url $entry.url
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestUrl = [string]$entry.url
                $bestSource = 'lenovo'
                $bestModel = [string]$model.name
            }
        }
    }

    if (-not $bestUrl) {
        foreach ($page in @($Catalog.fallbacks)) {
            $pageMatch = $false
            foreach ($pattern in $Patterns) {
                foreach ($typeCode in @($page.machineTypes)) {
                    if (Test-AppLenovoTypeMatchesPattern -TypeCode $typeCode -Pattern $pattern) {
                        $pageMatch = $true
                        break
                    }
                }
                if ($pageMatch) { break }
            }
            if (-not $pageMatch -and $FallbackPageUrl -and [string]$page.url -eq $FallbackPageUrl) {
                $pageMatch = $true
            }
            if (-not $pageMatch) { continue }
            $url = Get-AppLenovoSccmBestUrlFromList -Urls @($page.urls)
            if ($url) {
                return @{
                    url      = $url
                    fileName = [System.IO.Path]::GetFileName($url)
                    source   = 'lenovo-support'
                    model    = [string]$page.id
                    score    = 100
                }
            }
        }
    }

    if (-not $bestUrl -and $FallbackPageUrl) {
        foreach ($page in @($Catalog.fallbacks)) {
            if ([string]$page.url -ne $FallbackPageUrl) { continue }
            $url = Get-AppLenovoSccmBestUrlFromList -Urls @($page.urls)
            if ($url) {
                return @{
                    url      = $url
                    fileName = [System.IO.Path]::GetFileName($url)
                    source   = 'lenovo-support'
                    model    = [string]$page.id
                    score    = 90
                }
            }
        }
    }

    if (-not $bestUrl) { return $null }
    @{
        url      = $bestUrl
        fileName = [System.IO.Path]::GetFileName($bestUrl)
        source   = $bestSource
        model    = $bestModel
        score    = $bestScore
    }
}

function Read-AppLenovoSccmBundledCatalog {
    if (-not (Get-Command Resolve-AppAria2PackagingFile -ErrorAction SilentlyContinue)) { return $null }
    $path = Resolve-AppAria2PackagingFile -FileName 'lenovo-sccm-catalog.json'
    if (-not $path) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function ConvertTo-AppLenovoSccmCatalogResult {
    param(
        $Record,
        [bool]$FromCache,
        [bool]$Stale,
        [bool]$Bundled = $false
    )
    if (-not $Record) { return $null }
    $modelsProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('models')) { $Record['models'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'models') {
        $Record.models
    } else { $null }
    if (-not $modelsProp) { return $null }
    $srcProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('sourceUrl')) { $Record['sourceUrl'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'sourceUrl') {
        $Record.sourceUrl
    } else { $null }
    $fetchedProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('fetchedAt')) { $Record['fetchedAt'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'fetchedAt') {
        $Record.fetchedAt
    } else { $null }
    $fallbacksProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('fallbacks')) { $Record['fallbacks'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'fallbacks') {
        $Record.fallbacks
    } else { $null }
    @{
        sourceUrl = if ($srcProp) { [string]$srcProp } else { $script:AppLenovoSccmCatalogUrl }
        fetchedAt = if ($fetchedProp) { [string]$fetchedProp } else { $null }
        models    = @($modelsProp)
        fallbacks = if ($fallbacksProp) { @($fallbacksProp) } else { @() }
        fromCache = [bool]$FromCache
        stale     = [bool]$Stale
        bundled   = [bool]$Bundled
    }
}

function Get-AppLenovoSccmDriverCatalog {
    param(
        [switch]$ForceRefresh,
        [switch]$CacheOnly
    )
    $script:AppLenovoSccmCatalogLastError = $null
    if (-not $ForceRefresh) {
        $cached = Read-AppLenovoSccmCatalogCache
        if ($cached) {
            $fetchedAtRaw = if ($cached -is [System.Collections.IDictionary]) {
                if ($cached.Contains('fetchedAt')) { $cached['fetchedAt'] } else { $null }
            } elseif ($cached.PSObject.Properties.Name -contains 'fetchedAt') {
                $cached.fetchedAt
            } else { $null }
            $modelsRaw = if ($cached -is [System.Collections.IDictionary]) {
                if ($cached.Contains('models')) { $cached['models'] } else { $null }
            } elseif ($cached.PSObject.Properties.Name -contains 'models') {
                $cached.models
            } else { $null }
            if ($fetchedAtRaw -and $modelsRaw) {
                try {
                    $fetchedAt = if ($fetchedAtRaw -is [datetime]) {
                        # PS7 ConvertFrom-Json hydrates ISO strings into [DateTime];
                        # re-stringifying culture-formats it and RoundtripKind rejects that.
                        [datetime]$fetchedAtRaw
                    } else {
                        [datetime]::Parse([string]$fetchedAtRaw, $null, [Globalization.DateTimeStyles]::RoundtripKind)
                    }
                    $ageHours = ((Get-Date).ToUniversalTime() - $fetchedAt.ToUniversalTime()).TotalHours
                    $stale = $ageHours -ge $script:AppLenovoSccmCatalogCacheHours
                    if (-not $stale -or $CacheOnly) {
                        $result = ConvertTo-AppLenovoSccmCatalogResult -Record $cached -FromCache $true -Stale $stale
                        if ($result) { return $result }
                    }
                } catch { }
            }
        }
    }

    if ($CacheOnly) {
        $bundled = Read-AppLenovoSccmBundledCatalog
        $result = ConvertTo-AppLenovoSccmCatalogResult -Record $bundled -FromCache $false -Stale $false -Bundled $true
        if ($result) { return $result }
        $script:AppLenovoSccmCatalogLastError = 'No Lenovo SCCM catalog in local cache or bundled packaging.'
        return $null
    }

    try {
        $xml = Invoke-AppLenovoSccmHttpGet -Uri $script:AppLenovoSccmCatalogUrl
        $parsed = Parse-AppLenovoSccmCatalogFromXml -XmlText $xml
        if (@($parsed.models).Count -eq 0) {
            throw 'Lenovo catalogv2.xml returned no ThinkPad/Yoga/11e SCCM models.'
        }
        Write-AppLenovoSccmCatalogCache -Catalog $parsed
        return @{
            sourceUrl = $script:AppLenovoSccmCatalogUrl
            fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            models    = @($parsed.models)
            fallbacks = @($parsed.fallbacks)
            fromCache = $false
            stale     = $false
        }
    } catch {
        $script:AppLenovoSccmCatalogLastError = $_.Exception.Message
        $cached = Read-AppLenovoSccmCatalogCache
        if ($cached -and $cached.models) {
            Write-SidecarLog "Lenovo SCCM catalog: live fetch failed - $($_.Exception.Message); using stale cache."
            return @{
                sourceUrl = if ($cached.sourceUrl) { [string]$cached.sourceUrl } else { $script:AppLenovoSccmCatalogUrl }
                fetchedAt = [string]$cached.fetchedAt
                models    = @($cached.models)
                fallbacks = if ($cached.fallbacks) { @($cached.fallbacks) } else { @() }
                fromCache = $true
                stale     = $true
            }
        }
        throw
    }
}