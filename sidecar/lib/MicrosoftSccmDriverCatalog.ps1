# Microsoft Surface driver pack catalog - parse OSDCatalogMicrosoftDriverPack.json.
# Primary: https://raw.githubusercontent.com/maurice-daly/DriverAutomationTool/master/Data/OSDCatalogMicrosoftDriverPack.json
# Source choice (2026-08-18): the FFU project's Surface support scrapes three HTML pages
# (Learn SKU reference + support model list + Download Center __DLCDetails__) - its most
# fragile scraper (upstream issue #94). MSEndpointMgr's Driver Automation Tool maintains
# this JSON instead (same OEMLinks.xml that surfaced AcerCatalog.xml): every entry carries
# a direct download.microsoft.com MSI URL plus the Surface SystemId list
# (Win32_ComputerSystemProduct SKU strings) for exact matching. No hashes published
# (HashMD5 is null throughout) - noted, not available from this source.

# Canonical data-root + product-identity resolvers (no-op when the sidecar already
# dot-sourced AppPaths.ps1; needed when dev/test scripts or the catalog-refresh child
# load this lib standalone). AppPaths.ps1 pulls AppProductIdentity.ps1 itself.
if (-not (Get-Command Get-AppDataRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppPaths.ps1')
}

$script:AppMicrosoftSccmCatalogUrl = 'https://raw.githubusercontent.com/maurice-daly/DriverAutomationTool/master/Data/OSDCatalogMicrosoftDriverPack.json'
$script:AppMicrosoftSccmCatalogCacheHours = 168
$script:AppMicrosoftSccmCatalogLastError = $null

function Get-AppMicrosoftSccmCatalogLastError {
    return $script:AppMicrosoftSccmCatalogLastError
}

function Get-AppMicrosoftSccmCatalogCachePath {
    # Same folder whether or not Aria2Plugin.ps1 is loaded: <data root>/plugins/aria2/.
    # (Until 2026-08-22 the standalone branch used a second, slug-named folder.)
    if (-not (Get-Command Get-AppAria2StoreRoot -ErrorAction SilentlyContinue)) {
        return Join-Path (Get-AppPluginDir -Plugin 'aria2') 'microsoft-sccm-catalog.json'
    }
    Join-Path (Get-AppAria2StoreRoot) 'microsoft-sccm-catalog.json'
}

function Read-AppMicrosoftSccmCatalogCache {
    $path = Get-AppMicrosoftSccmCatalogCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-AppMicrosoftSccmCatalogCache {
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$SourceUrl = $script:AppMicrosoftSccmCatalogUrl
    )
    $path = Get-AppMicrosoftSccmCatalogCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $payload = @{
        schema         = 1
        sourceUrl      = $SourceUrl
        fetchedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        modelCount     = @($Catalog.models).Count
        catalogVersion = [string]$Catalog.catalogVersion
        models         = @($Catalog.models)
    }
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function Invoke-AppMicrosoftSccmHttpGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxTimeSec = 90
    )
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl is required to fetch the Microsoft driver pack catalog.' }
    $out = & curl -sS -L --http1.1 --max-time $MaxTimeSec -A (Get-AppUserAgent) $Uri 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed (exit $LASTEXITCODE): $out"
    }
    return [string]($out -join "`n")
}

function Get-AppMicrosoftSccmFolderFromModelName {
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim() -replace '[^\w\s-]+', ''
    $n = ($n.Trim() -replace '\s+', '-')
    if ([string]::IsNullOrWhiteSpace($n)) { return 'Surface-Model' }
    $n
}

function Get-AppMicrosoftSccmModelFamily {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -match '(?i)\bSurface Pro\b') { return 'surface-pro' }
    if ($Name -match '(?i)\bSurface Laptop\b') { return 'surface-laptop' }
    if ($Name -match '(?i)\bSurface Go\b') { return 'surface-go' }
    if ($Name -match '(?i)\bSurface Book\b') { return 'surface-book' }
    if ($Name -match '(?i)\bSurface (Studio|Hub)\b') { return 'surface-studio' }
    'other'
}

function Parse-AppMicrosoftSccmCatalogFromJson {
    param([Parameter(Mandatory)][string]$JsonText)
    $items = ($JsonText.TrimStart([char]0xFEFF)) | ConvertFrom-Json
    $models = [System.Collections.Generic.List[hashtable]]::new()
    $catalogVersion = $null
    foreach ($item in @($items)) {
        # Sidecar runs under Set-StrictMode (NpsLogViewer.ps1) - a catalog entry missing
        # any key must degrade, not throw, so all reads go through Get-AppAria2JsonProp.
        $model = ([string](Get-AppAria2JsonProp -Item $item -Name 'Model')).Trim()
        $url = ([string](Get-AppAria2JsonProp -Item $item -Name 'Url')).Trim()
        if ([string]::IsNullOrWhiteSpace($model) -or $url -notmatch '(?i)^https://') { continue }
        $itemVersion = [string](Get-AppAria2JsonProp -Item $item -Name 'CatalogVersion')
        if (-not $catalogVersion -and $itemVersion) { $catalogVersion = $itemVersion }
        $systemIds = @(Get-AppAria2JsonProp -Item $item -Name 'SystemId' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        [void]$models.Add(@{
                name           = $model
                folder         = Get-AppMicrosoftSccmFolderFromModelName -Name $model
                family         = Get-AppMicrosoftSccmModelFamily -Name $model
                systemIds      = @($systemIds)
                url            = $url
                fileName       = [string](Get-AppAria2JsonProp -Item $item -Name 'FileName')
                os             = [string](Get-AppAria2JsonProp -Item $item -Name 'OperatingSystem')
                arch           = [string](Get-AppAria2JsonProp -Item $item -Name 'OSArchitecture')
                releaseDate    = [string](Get-AppAria2JsonProp -Item $item -Name 'ReleaseDate')
            })
    }
    if ($models.Count -eq 0) {
        throw 'Microsoft driver pack catalog returned no Surface models.'
    }
    @{ models = @($models); catalogVersion = $catalogVersion }
}

function Get-AppMicrosoftSccmCatalogFamilySummary {
    param([Parameter(Mandatory)]$Catalog)
    $summary = @{
        'surface-pro'    = 0
        'surface-laptop' = 0
        'surface-go'     = 0
        'surface-book'   = 0
        'surface-studio' = 0
        other            = 0
        total            = 0
    }
    foreach ($model in @(Get-AppAria2JsonProp -Item $Catalog -Name 'models')) {
        $family = ([string](Get-AppAria2JsonProp -Item $model -Name 'family')).ToLowerInvariant()
        if ($summary.ContainsKey($family)) {
            $summary[$family] = [int]$summary[$family] + 1
        } else {
            $summary.other = [int]$summary.other + 1
        }
        $summary.total = [int]$summary.total + 1
    }
    $summary
}

function Resolve-AppMicrosoftSccmDriverUrlForWmiPatterns {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)]$Catalog
    )
    if (-not $Patterns -or $Patterns.Count -eq 0 -or -not $Catalog) { return $null }
    foreach ($model in @(Get-AppAria2JsonProp -Item $Catalog -Name 'models')) {
        $name = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        $systemIds = @(Get-AppAria2JsonProp -Item $model -Name 'systemIds')
        $matched = $false
        foreach ($pattern in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            # Surface SystemId (Win32_ComputerSystemProduct SKU, e.g.
            # Surface_Laptop_7th_Edition_2036) - exact match beats name fuzzing.
            foreach ($sysId in $systemIds) {
                if ([string]$sysId -and ([string]$sysId).Trim().Equals($pattern.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $true
                    break
                }
            }
            if ($matched) { break }
            if ($name -and $name -like "*$pattern*") {
                $matched = $true
                break
            }
        }
        if (-not $matched) { continue }
        $url = [string](Get-AppAria2JsonProp -Item $model -Name 'url')
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        return @{
            url    = $url
            source = 'microsoft'
            model  = $name
        }
    }
    return $null
}

function Read-AppMicrosoftSccmBundledCatalog {
    if (-not (Get-Command Resolve-AppAria2PackagingFile -ErrorAction SilentlyContinue)) { return $null }
    $path = Resolve-AppAria2PackagingFile -FileName 'microsoft-sccm-catalog.json'
    if (-not $path) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function ConvertTo-AppMicrosoftSccmCatalogResult {
    param(
        $Record,
        [bool]$FromCache,
        [bool]$Stale,
        [bool]$Bundled = $false
    )
    if (-not $Record) { return $null }
    $models = Get-AppAria2JsonProp -Item $Record -Name 'models'
    if (-not $models) { return $null }
    $recordSource = [string](Get-AppAria2JsonProp -Item $Record -Name 'sourceUrl')
    @{
        sourceUrl      = if ($recordSource) { $recordSource } else { $script:AppMicrosoftSccmCatalogUrl }
        fetchedAt      = [string](Get-AppAria2JsonProp -Item $Record -Name 'fetchedAt')
        catalogVersion = [string](Get-AppAria2JsonProp -Item $Record -Name 'catalogVersion')
        models         = @($models)
        fromCache      = [bool]$FromCache
        stale          = [bool]$Stale
        bundled        = [bool]$Bundled
    }
}

function Get-AppMicrosoftSccmDriverCatalog {
    param(
        [switch]$ForceRefresh,
        [switch]$CacheOnly
    )
    $script:AppMicrosoftSccmCatalogLastError = $null
    if (-not $ForceRefresh) {
        $cached = Read-AppMicrosoftSccmCatalogCache
        if ($cached) {
            $fetchedAtRaw = Get-AppAria2JsonProp -Item $cached -Name 'fetchedAt'
            $modelsRaw = Get-AppAria2JsonProp -Item $cached -Name 'models'
            if ($fetchedAtRaw -and $modelsRaw) {
                try {
                    # PS7 ConvertFrom-Json hydrates ISO strings into [DateTime] - parse only strings.
                    $fetchedAt = if ($fetchedAtRaw -is [datetime]) {
                        [datetime]$fetchedAtRaw
                    } else {
                        [datetime]::Parse([string]$fetchedAtRaw, $null, [Globalization.DateTimeStyles]::RoundtripKind)
                    }
                    $ageHours = ((Get-Date).ToUniversalTime() - $fetchedAt.ToUniversalTime()).TotalHours
                    $stale = $ageHours -ge $script:AppMicrosoftSccmCatalogCacheHours
                    if (-not $stale -or $CacheOnly) {
                        $result = ConvertTo-AppMicrosoftSccmCatalogResult -Record $cached -FromCache $true -Stale $stale
                        if ($result) { return $result }
                    }
                } catch { }
            }
        }
    }

    if ($CacheOnly) {
        $bundled = Read-AppMicrosoftSccmBundledCatalog
        $result = ConvertTo-AppMicrosoftSccmCatalogResult -Record $bundled -FromCache $false -Stale $false -Bundled $true
        if ($result) { return $result }
        $script:AppMicrosoftSccmCatalogLastError = 'No Microsoft SCCM catalog in local cache or bundled packaging.'
        return $null
    }

    try {
        $jsonText = Invoke-AppMicrosoftSccmHttpGet -Uri $script:AppMicrosoftSccmCatalogUrl
        $parsed = Parse-AppMicrosoftSccmCatalogFromJson -JsonText $jsonText
        Write-AppMicrosoftSccmCatalogCache -Catalog $parsed
        return @{
            sourceUrl      = $script:AppMicrosoftSccmCatalogUrl
            fetchedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            catalogVersion = [string]$parsed.catalogVersion
            models         = @($parsed.models)
            fromCache      = $false
            stale          = $false
        }
    } catch {
        $script:AppMicrosoftSccmCatalogLastError = $_.Exception.Message
        $cached = Read-AppMicrosoftSccmCatalogCache
        if ($cached -and (Get-AppAria2JsonProp -Item $cached -Name 'models')) {
            Write-SidecarLog "Microsoft SCCM catalog: live fetch failed - $($_.Exception.Message); using stale cache."
            $result = ConvertTo-AppMicrosoftSccmCatalogResult -Record $cached -FromCache $true -Stale $true
            if ($result) { return $result }
        }
        throw
    }
}
