# Dell Command Deploy driver pack catalog - parse DriverPackCatalog.cab -> DriverPackCatalog.xml
# Primary: https://downloads.dell.com/catalog/DriverPackCatalog.cab
# See https://www.dell.com/support/kbdoc/en-us/000122176/driver-pack-catalog

$script:AppDellSccmCatalogCabUrl = 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
$script:AppDellSccmCatalogCacheHours = 168
$script:AppDellSccmCatalogLastError = $null

function Get-AppDellSccmCatalogLastError {
    return $script:AppDellSccmCatalogLastError
}

function Get-AppDellSccmCatalogCachePath {
    if (-not (Get-Command Get-AppAria2StoreRoot -ErrorAction SilentlyContinue)) {
        return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'windeploykit/dell-sccm-catalog.json'
    }
    Join-Path (Get-AppAria2StoreRoot) 'dell-sccm-catalog.json'
}

function Read-AppDellSccmCatalogCache {
    $path = Get-AppDellSccmCatalogCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-AppDellSccmCatalogCache {
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$SourceUrl = $script:AppDellSccmCatalogCabUrl
    )
    $path = Get-AppDellSccmCatalogCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $payload = @{
        schema     = 1
        sourceUrl  = $SourceUrl
        fetchedAt  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        modelCount = @($Catalog.models).Count
        models     = @($Catalog.models)
    }
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function Get-AppDellSccmCatalogCabCachePath {
    Join-Path (Split-Path -Parent (Get-AppDellSccmCatalogCachePath)) 'dell-DriverPackCatalog.cab'
}

function Write-AppDellSccmCatalogCabCache {
    param(
        [Parameter(Mandatory)][byte[]]$CabBytes
    )
    $path = Get-AppDellSccmCatalogCabCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    [IO.File]::WriteAllBytes($path, $CabBytes)
    $path
}

function Get-AppDellSccmCatalogCabCacheSizeLabel {
    param([Parameter(Mandatory)][string]$CabPath)
    if (-not (Test-Path -LiteralPath $CabPath)) { return 'unknown size' }
    $bytes = (Get-Item -LiteralPath $CabPath).Length
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    "$bytes bytes"
}

function Invoke-AppDellSccmHttpGetBytes {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxTimeSec = 180
    )
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl is required to fetch Dell DriverPackCatalog.cab.' }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $out = & curl -sS -L --http1.1 --max-time $MaxTimeSec -A 'Mozilla/5.0 (compatible; WinDeployKit/1.0)' -o $tmp $Uri 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "curl failed (exit $LASTEXITCODE): $out"
        }
        return [IO.File]::ReadAllBytes($tmp)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-AppDellSccmCabExtractTool {
    $cabextract = Get-Command cabextract -ErrorAction SilentlyContinue
    if ($cabextract) {
        return @{ kind = 'cabextract'; command = $cabextract.Source }
    }

    foreach ($name in @('7z', '7za')) {
        $sevenZip = Get-Command $name -ErrorAction SilentlyContinue
        if ($sevenZip) {
            return @{ kind = '7z'; command = $sevenZip.Source; name = $name }
        }
    }

    if ($IsWindows -or ($env:OS -match '(?i)windows')) {
        $expand = Get-Command expand.exe -ErrorAction SilentlyContinue
        if (-not $expand) {
            $expand = Get-Command expand -ErrorAction SilentlyContinue
        }
        if ($expand -and $expand.Source -match '(?i)(\\Windows\\|\\Sysnative\\|\\System32\\|expand\.exe)') {
            return @{ kind = 'expand'; command = $expand.Source }
        }
    }

    return $null
}

function Expand-AppDellSccmCatalogCab {
    param(
        [Parameter(Mandatory)][string]$CabPath,
        [Parameter(Mandatory)][string]$OutDir
    )
    if (-not (Test-Path -LiteralPath $CabPath)) {
        throw "Dell DriverPackCatalog.cab not found at $CabPath"
    }
    if (-not (Test-Path -LiteralPath $OutDir)) {
        $null = New-Item -Path $OutDir -ItemType Directory -Force
    }

    $xmlPath = Join-Path $OutDir 'DriverPackCatalog.xml'
    if (Test-Path -LiteralPath $xmlPath) {
        Remove-Item -LiteralPath $xmlPath -Force
    }

    $cabLabel = Get-AppDellSccmCatalogCabCacheSizeLabel -CabPath $CabPath
    $cabHint = "CAB downloaded to $CabPath ($cabLabel)."
    $tool = Get-AppDellSccmCabExtractTool
    if (-not $tool) {
        throw "cabextract, 7z/7za, or Windows expand.exe is required to unpack DriverPackCatalog.cab. $cabHint"
    }

    switch ([string]$tool.kind) {
        'cabextract' {
            & $tool.command -q -d $OutDir $CabPath 2>&1 | ForEach-Object { Write-Verbose $_ }
            if ($LASTEXITCODE -ne 0) {
                throw "cabextract failed (exit $LASTEXITCODE). $cabHint"
            }
        }
        '7z' {
            $sevenName = if ($tool.name) { [string]$tool.name } else { '7z' }
            & $tool.command x -y ("-o{0}" -f $OutDir) $CabPath 2>&1 | ForEach-Object { Write-Verbose $_ }
            if ($LASTEXITCODE -ne 0) {
                throw "$sevenName failed (exit $LASTEXITCODE). $cabHint"
            }
        }
        'expand' {
            & $tool.command $CabPath $xmlPath 2>&1 | ForEach-Object { Write-Verbose $_ }
        }
        default {
            throw "Unsupported CAB extract tool '$($tool.kind)'. $cabHint"
        }
    }

    if (-not (Test-Path -LiteralPath $xmlPath)) {
        throw "CAB extract via $($tool.kind) did not produce DriverPackCatalog.xml. $cabHint"
    }
    return $xmlPath
}

function Test-AppDellSccmOperatingSystemWin11X64 {
    param($OsNode)
    if (-not $OsNode) { return $false }
    $arch = ([string]$OsNode.GetAttribute('osArch')).ToLowerInvariant()
    if ($arch -ne 'x64') { return $false }
    $osCode = ([string]$OsNode.GetAttribute('osCode')).ToLowerInvariant()
    if ($osCode -eq 'windows11') { return $true }
    $display = $null
    foreach ($child in @($OsNode.ChildNodes)) {
        if ($child.LocalName -eq 'Display') {
            $display = [string]$child.InnerText
            break
        }
    }
    return ($display -match '(?i)windows\s*11.*x64')
}

function Get-AppDellSccmDriverPackScore {
    param(
        [string]$DateTime,
        [string]$Format,
        [string]$Path
    )
    $score = 0
    if ($DateTime) {
        try {
            $dt = [datetime]::Parse($DateTime)
            $score += [int]($dt.ToUniversalTime() - [datetime]'2000-01-01').TotalDays
        } catch { }
    }
    $fmt = ($Format ?? '').ToLowerInvariant()
    if ($fmt -eq 'cab') { $score += 12 }
    elseif ($fmt -eq 'exe') { $score += 8 }
    $pathNorm = ($Path ?? '').ToLowerInvariant()
    if ($pathNorm -match 'win11') { $score += 20 }
    $score
}

function Get-AppDellSccmModelFamily {
    param([Parameter(Mandatory)][string]$Brand)
    if ([string]::IsNullOrWhiteSpace($Brand)) { return 'other' }
    $b = $Brand.Trim()
    if ($b -match '(?i)\bLatitude\b') { return 'latitude' }
    if ($b -match '(?i)\bOptiPlex\b|Optiplex') { return 'optiplex' }
    if ($b -match '(?i)\bXPS\b') { return 'xps' }
    if ($b -match '(?i)\bPrecision\b') { return 'precision' }
    if ($b -match '(?i)\bInspiron\b') { return 'inspiron' }
    if ($b -match '(?i)\bVostro\b') { return 'vostro' }
    if ($b -match '(?i)\bChromebook\b') { return 'chromebook' }
    if ($b -match '(?i)\bWyse\b') { return 'wyse' }
    'other'
}

function Get-AppDellSccmBrandDisplayText {
    param($BrandNode)
    if (-not $BrandNode) { return $null }
    foreach ($child in @($BrandNode.ChildNodes)) {
        if ($child.LocalName -eq 'Display') {
            return ([string]$child.InnerText).Trim()
        }
    }
    return $null
}

function Get-AppDellSccmModelDisplayText {
    param($ModelNode)
    if (-not $ModelNode) { return $null }
    foreach ($child in @($ModelNode.ChildNodes)) {
        if ($child.LocalName -eq 'Display') {
            return ([string]$child.InnerText).Trim()
        }
    }
    return $null
}

function Parse-AppDellSccmCatalogFromXml {
    param([Parameter(Mandatory)][string]$XmlText)
    $XmlText = $XmlText.TrimStart([char]0xFEFF).TrimStart()
    $doc = [xml]$XmlText
    $root = $doc.DocumentElement
    if (-not $root) { throw 'DriverPackCatalog.xml has no root element.' }

    $baseLocation = [string]$root.GetAttribute('baseLocation')
    if ([string]::IsNullOrWhiteSpace($baseLocation)) {
        $baseLocation = 'downloads.dell.com'
    }
    $baseUrl = if ($baseLocation -match '^https?://') { $baseLocation.TrimEnd('/') } else { "https://$baseLocation" }

    $modelMap = @{}
    foreach ($pkg in @($doc.GetElementsByTagName('DriverPackage'))) {
        if ([string]$pkg.GetAttribute('type') -ne 'win') { continue }

        $osNodes = @($pkg.GetElementsByTagName('OperatingSystem'))
        $win11 = $false
        foreach ($os in $osNodes) {
            if (Test-AppDellSccmOperatingSystemWin11X64 -OsNode $os) {
                $win11 = $true
                break
            }
        }
        if (-not $win11) { continue }

        $relPath = [string]$pkg.GetAttribute('path')
        if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
        $url = "$baseUrl/$relPath"
        $format = [string]$pkg.GetAttribute('format')
        $dateTime = [string]$pkg.GetAttribute('dateTime')
        $score = Get-AppDellSccmDriverPackScore -DateTime $dateTime -Format $format -Path $relPath
        # Surface per-pack hashes (previously dropped): newer entries publish SHA-256
        # under <Cryptography><Hash algorithm="...">, every entry still carries the
        # legacy hashMD5 attribute. Gates aria2 promotion and client verification.
        $expectedHash = $null
        $expectedHashAlgorithm = $null
        foreach ($hashNode in @($pkg.GetElementsByTagName('Hash'))) {
            $alg = ([string]$hashNode.GetAttribute('algorithm')).Trim().ToUpperInvariant()
            $val = ([string]$hashNode.InnerText).Trim()
            if ([string]::IsNullOrWhiteSpace($val)) { continue }
            if ($alg -eq 'SHA256') { $expectedHash = $val; $expectedHashAlgorithm = 'SHA256'; break }
            if (-not $expectedHash -and $alg) { $expectedHash = $val; $expectedHashAlgorithm = $alg }
        }
        if (-not $expectedHash) {
            $md5 = ([string]$pkg.GetAttribute('hashMD5')).Trim()
            if ($md5) { $expectedHash = $md5; $expectedHashAlgorithm = 'MD5' }
        }
        $packEntry = @{
            url      = $url
            format   = $format
            dateTime = $dateTime
            releaseId = [string]$pkg.GetAttribute('releaseID')
            score    = $score
            expectedHash = $expectedHash
            expectedHashAlgorithm = $expectedHashAlgorithm
        }

        foreach ($brand in @($pkg.GetElementsByTagName('Brand'))) {
            $brandName = Get-AppDellSccmBrandDisplayText -BrandNode $brand
            foreach ($model in @($brand.GetElementsByTagName('Model'))) {
                $systemId = ([string]$model.GetAttribute('systemID')).Trim().ToUpperInvariant()
                if ([string]::IsNullOrWhiteSpace($systemId)) { continue }
                $modelName = [string]$model.GetAttribute('name')
                if ([string]::IsNullOrWhiteSpace($modelName)) {
                    $modelName = Get-AppDellSccmModelDisplayText -ModelNode $model
                }
                if ([string]::IsNullOrWhiteSpace($modelName)) { continue }

                $family = Get-AppDellSccmModelFamily -Brand $brandName
                if (-not $modelMap.ContainsKey($systemId)) {
                    $modelMap[$systemId] = @{
                        name     = $modelName
                        systemId = $systemId
                        brand    = $brandName
                        family   = $family
                        packs    = @($packEntry)
                        bestScore = $score
                    }
                } else {
                    $existing = $modelMap[$systemId]
                    if ($score -gt [int]$existing.bestScore) {
                        $existing.packs = @($packEntry)
                        $existing.bestScore = $score
                        if ($modelName) { $existing.name = $modelName }
                        if ($brandName) { $existing.brand = $brandName; $existing.family = $family }
                    } elseif ($score -eq [int]$existing.bestScore) {
                        $existing.packs = @($existing.packs) + @($packEntry)
                    }
                }
            }
        }
    }

    $models = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @($modelMap.Values | Sort-Object { [string]$_.systemId })) {
        $packs = @($entry.packs | Sort-Object { -([int]$_.score) })
        [void]$models.Add(@{
                name     = [string]$entry.name
                systemId = [string]$entry.systemId
                brand    = [string]$entry.brand
                family   = [string]$entry.family
                packs    = @($packs)
            })
    }

    if ($models.Count -eq 0) {
        throw 'DriverPackCatalog.xml returned no Windows 11 x64 client driver packs.'
    }

    @{ models = @($models) }
}

function Get-AppDellSccmBestPackForModel {
    param([Parameter(Mandatory)]$Model)
    $packs = @(Get-AppAria2JsonProp -Item $Model -Name 'packs')
    if ($packs.Count -eq 0) { return $null }
    $best = $null
    # CORRECT AS WRITTEN - do not 'fix' to [int]::MinValue like Lenovo. Dell's scores are
    # purely additive (0 plus positive terms), so they never go negative and -1 is safe.
    $bestScore = -1
    foreach ($pack in $packs) {
        $scoreProp = Get-AppAria2JsonProp -Item $pack -Name 'score'
        $score = if ($null -ne $scoreProp) { [int]$scoreProp } else { 0 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $pack
        }
    }
    if (-not $best) { return $null }
    $url = [string](Get-AppAria2JsonProp -Item $best -Name 'url')
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    @{
        url      = $url
        fileName = [System.IO.Path]::GetFileName($url)
        format   = [string](Get-AppAria2JsonProp -Item $best -Name 'format')
        expectedHash = [string](Get-AppAria2JsonProp -Item $best -Name 'expectedHash')
        expectedHashAlgorithm = [string](Get-AppAria2JsonProp -Item $best -Name 'expectedHashAlgorithm')
    }
}

function Get-AppDellSccmCatalogFamilySummary {
    param([Parameter(Mandatory)]$Catalog)
    $summary = @{
        latitude  = 0
        optiplex  = 0
        xps       = 0
        precision = 0
        inspiron  = 0
        vostro    = 0
        other     = 0
        total     = 0
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

function Test-AppDellSystemIdMatchesPattern {
    param(
        [Parameter(Mandatory)][string]$SystemId,
        [Parameter(Mandatory)][string]$Pattern
    )
    if ([string]::IsNullOrWhiteSpace($SystemId) -or [string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    return $SystemId.Trim().Equals($Pattern.Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-AppDellSccmDriverUrlForWmiPatterns {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)]$Catalog
    )
    if (-not $Patterns -or $Patterns.Count -eq 0 -or -not $Catalog) { return $null }

    foreach ($model in @(Get-AppAria2JsonProp -Item $Catalog -Name 'models')) {
        $systemId = [string](Get-AppAria2JsonProp -Item $model -Name 'systemId')
        $modelName = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        $matched = $false
        foreach ($pattern in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            if (Test-AppDellSystemIdMatchesPattern -SystemId $systemId -Pattern $pattern) {
                $matched = $true
                break
            }
            if ($modelName -and $modelName -like "*$pattern*") {
                $matched = $true
                break
            }
        }
        if (-not $matched) { continue }
        $best = Get-AppDellSccmBestPackForModel -Model $model
        if (-not $best) { continue }
        return @{
            url    = [string]$best.url
            source = 'dell'
            model  = $modelName
        }
    }
    return $null
}

function Read-AppDellSccmBundledCatalog {
    if (-not (Get-Command Resolve-AppAria2PackagingFile -ErrorAction SilentlyContinue)) { return $null }
    $path = Resolve-AppAria2PackagingFile -FileName 'dell-sccm-catalog.json'
    if (-not $path) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function ConvertTo-AppDellSccmCatalogResult {
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
    @{
        sourceUrl = if ($srcProp) { [string]$srcProp } else { $script:AppDellSccmCatalogCabUrl }
        fetchedAt = if ($fetchedProp) { [string]$fetchedProp } else { $null }
        models    = @($modelsProp)
        fromCache = [bool]$FromCache
        stale     = [bool]$Stale
        bundled   = [bool]$Bundled
    }
}

function Get-AppDellSccmDriverCatalog {
    param(
        [switch]$ForceRefresh,
        [switch]$CacheOnly
    )
    $script:AppDellSccmCatalogLastError = $null
    if (-not $ForceRefresh) {
        $cached = Read-AppDellSccmCatalogCache
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
                    $stale = $ageHours -ge $script:AppDellSccmCatalogCacheHours
                    if (-not $stale -or $CacheOnly) {
                        $result = ConvertTo-AppDellSccmCatalogResult -Record $cached -FromCache $true -Stale $stale
                        if ($result) { return $result }
                    }
                } catch { }
            }
        }
    }

    if ($CacheOnly) {
        $bundled = Read-AppDellSccmBundledCatalog
        $result = ConvertTo-AppDellSccmCatalogResult -Record $bundled -FromCache $false -Stale $false -Bundled $true
        if ($result) { return $result }
        $script:AppDellSccmCatalogLastError = 'No Dell SCCM catalog in local cache or bundled packaging.'
        return $null
    }

    try {
        $cabBytes = Invoke-AppDellSccmHttpGetBytes -Uri $script:AppDellSccmCatalogCabUrl
        $cabPath = Write-AppDellSccmCatalogCabCache -CabBytes $cabBytes
        if (Get-Command Write-SidecarLogVerbose -ErrorAction SilentlyContinue) {
            Write-SidecarLogVerbose "Dell SCCM catalog: saved DriverPackCatalog.cab to $cabPath ($(Get-AppDellSccmCatalogCabCacheSizeLabel -CabPath $cabPath))."
        }
        $workDir = Join-Path ([IO.Path]::GetTempPath()) ("windeploykit-dell-catalog-" + [Guid]::NewGuid().ToString('N'))
        try {
            $xmlPath = Expand-AppDellSccmCatalogCab -CabPath $cabPath -OutDir $workDir
            $xmlText = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
            $parsed = Parse-AppDellSccmCatalogFromXml -XmlText $xmlText
            if (@($parsed.models).Count -eq 0) {
                throw 'DriverPackCatalog.xml returned no Windows 11 x64 models.'
            }
            Write-AppDellSccmCatalogCache -Catalog $parsed
            return @{
                sourceUrl = $script:AppDellSccmCatalogCabUrl
                fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                models    = @($parsed.models)
                fromCache = $false
                stale     = $false
            }
        } finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $script:AppDellSccmCatalogLastError = $_.Exception.Message
        if (-not $ForceRefresh) {
            $cached = Read-AppDellSccmCatalogCache
            if ($cached -and $cached.models) {
                Write-SidecarLog "Dell SCCM catalog: live fetch failed - $($_.Exception.Message); using stale cache."
                return @{
                    sourceUrl = if ($cached.sourceUrl) { [string]$cached.sourceUrl } else { $script:AppDellSccmCatalogCabUrl }
                    fetchedAt = [string]$cached.fetchedAt
                    models    = @($cached.models)
                    fromCache = $true
                    stale     = $true
                }
            }
        }
        throw
    }
}
