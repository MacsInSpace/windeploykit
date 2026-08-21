# HP client driver pack catalog - parse HPClientDriverPackCatalog.cab -> XML.
# Primary: https://ftp.hp.com/pub/caps-softpaq/cmit/HPClientDriverPackCatalog.cab
# Replaces the HP_Driverpack_Matrix_x64.html scrape (th/td regex + column-offset
# state machine - fragile by construction; AGENT_NOTES_PXE_DRIVERS section 3.2): the cab
# is the canonical SCCM driver *pack* source, carries per-product SystemId (matches
# Win32_BaseBoard.Product) and per-SoftPaq MD5/SHA-256, and a sibling UpdateInfo.xml
# publishes the cab's own SHA1 so the catalog is verified before parsing.

$script:AppHpSccmCatalogUrl = 'https://ftp.hp.com/pub/caps-softpaq/cmit/HPClientDriverPackCatalog.cab'
$script:AppHpSccmCatalogUpdateInfoUrl = 'https://ftp.hp.com/pub/caps-softpaq/cmit/HPClientDriverPackCatalogUpdateInfo.xml'
$script:AppHpSccmCatalogCacheHours = 168
$script:AppHpSccmCatalogLastError = $null

# OSName preference (exact strings from ProductOSDriverPack/OSName). An unknown
# future Windows 11 release ranks below all listed ones until added here.
$script:AppHpSccmOsColumnPreference = @(
    'Windows 11 64-bit, 25H2',
    'Windows 11 64-bit, 24H2',
    'Windows 11 64-bit, 23H2',
    'Windows 11 64-bit, 22H2',
    'Windows 11 64-bit, 21H2'
)

function Get-AppHpSccmCatalogLastError {
    return $script:AppHpSccmCatalogLastError
}

function Get-AppHpSccmCatalogCachePath {
    if (-not (Get-Command Get-AppAria2StoreRoot -ErrorAction SilentlyContinue)) {
        return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'windeploykit/hp-sccm-catalog.json'
    }
    Join-Path (Get-AppAria2StoreRoot) 'hp-sccm-catalog.json'
}

function Read-AppHpSccmCatalogCache {
    $path = Get-AppHpSccmCatalogCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-AppHpSccmCatalogCache {
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$SourceUrl = $script:AppHpSccmCatalogUrl
    )
    $path = Get-AppHpSccmCatalogCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $payload = @{
        schema     = 1
        sourceUrl  = $SourceUrl
        fetchedAt  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        modelCount = @($Catalog.models).Count
        osColumn   = [string]$Catalog.osColumn
        models     = @($Catalog.models)
    }
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function Invoke-AppHpSccmHttpGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxTimeSec = 90
    )
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl is required to fetch HP driver pack matrix.' }
    $out = & curl -sS -L --http1.1 --max-time $MaxTimeSec -A 'Mozilla/5.0 (compatible; WinDeployKit/1.0)' $Uri 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed (exit $LASTEXITCODE): $out"
    }
    return [string]$out
}

function Invoke-AppHpSccmHttpGetBytes {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxTimeSec = 180
    )
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl is required to fetch HPClientDriverPackCatalog.cab.' }
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

function Get-AppHpSccmCabExtractTool {
    # Same tool ladder as the Dell lib (cabextract -> 7z -> expand.exe) - CI-side only.
    $cabextract = Get-Command cabextract -ErrorAction SilentlyContinue
    if ($cabextract) { return @{ kind = 'cabextract'; command = $cabextract.Source } }
    foreach ($name in @('7z', '7za')) {
        $sevenZip = Get-Command $name -ErrorAction SilentlyContinue
        if ($sevenZip) { return @{ kind = '7z'; command = $sevenZip.Source; name = $name } }
    }
    if ($IsWindows -or ($env:OS -match '(?i)windows')) {
        $expand = Get-Command expand.exe -ErrorAction SilentlyContinue
        if (-not $expand) { $expand = Get-Command expand -ErrorAction SilentlyContinue }
        if ($expand -and $expand.Source -match '(?i)(\\Windows\\|\\Sysnative\\|\\System32\\|expand\.exe)') {
            return @{ kind = 'expand'; command = $expand.Source }
        }
    }
    return $null
}

function Expand-AppHpSccmCatalogCab {
    param(
        [Parameter(Mandatory)][byte[]]$CabBytes
    )
    $tool = Get-AppHpSccmCabExtractTool
    if (-not $tool) { throw 'No cab extraction tool available (need cabextract, 7z, or expand.exe).' }
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("hp-sccm-cab-" + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $workDir -ItemType Directory -Force
    try {
        $cabPath = Join-Path $workDir 'HPClientDriverPackCatalog.cab'
        [IO.File]::WriteAllBytes($cabPath, $CabBytes)
        switch ($tool.kind) {
            'cabextract' { $null = & $tool.command -q -d $workDir $cabPath 2>&1 }
            '7z'         { $null = & $tool.command x "-o$workDir" -y $cabPath 2>&1 }
            'expand'     { $null = & $tool.command $cabPath -F:* $workDir 2>&1 }
        }
        $xmlFile = Get-ChildItem -LiteralPath $workDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $xmlFile) { throw 'HPClientDriverPackCatalog.cab extraction produced no XML.' }
        return Get-Content -LiteralPath $xmlFile.FullName -Raw -Encoding UTF8
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-AppHpSccmCatalogCabHash {
    <#
    .SYNOPSIS
        Verify the cab against the SHA1 the sibling UpdateInfo.xml publishes
        (base64-encoded). $true/$false on a definite answer; $null when the
        UpdateInfo has no usable hash (caller logs and proceeds unverified).
    #>
    param(
        [Parameter(Mandatory)][byte[]]$CabBytes,
        [string]$UpdateInfoXml
    )
    if ([string]::IsNullOrWhiteSpace($UpdateInfoXml)) { return $null }
    try {
        $m = [regex]::Match($UpdateInfoXml, '<CatalogSHA1>\s*([^<]+?)\s*</CatalogSHA1>')
        if (-not $m.Success) { return $null }
        $expected = [Convert]::FromBase64String($m.Groups[1].Value)
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        try {
            $actual = $sha1.ComputeHash($CabBytes)
        } finally {
            $sha1.Dispose()
        }
        if ($expected.Length -ne $actual.Length) { return $false }
        for ($i = 0; $i -lt $expected.Length; $i++) {
            if ($expected[$i] -ne $actual[$i]) { return $false }
        }
        return $true
    } catch {
        return $null
    }
}

function Get-AppHpSccmFolderFromModelName {
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim()
    $n = $n -replace '(?i)^HP\s+', ''
    $n = $n -replace '(?i)\s+(Notebook|Desktop|PC|AI PC|Tablet|Workstation|All-in-One|AIO).*$', ''
    $n = $n -replace '[^\w\s-]+', ''
    $n = ($n.Trim() -replace '\s+', '-')
    if ([string]::IsNullOrWhiteSpace($n)) {
        return 'HP-Model'
    }
    $n
}

function Get-AppHpSccmModelFamily {
    param([Parameter(Mandatory)][string]$Group)
    if ([string]::IsNullOrWhiteSpace($Group)) { return 'other' }
    if ($Group -match '(?i)notebook|tablet') { return 'notebooks' }
    if ($Group -match '(?i)desktop| aio|all-in-one') { return 'desktops' }
    if ($Group -match '(?i)workstation') { return 'workstations' }
    if ($Group -match '(?i)thin|zero') { return 'thin-clients' }
    'other'
}

function Get-AppHpSccmSoftpaqFromUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ($Url -match '/(sp\d+)\.exe') { return $Matches[1].ToLowerInvariant() }
    return $null
}


function Get-AppHpSccmXmlChildText {
    # XmlElement child access by name. $node.Name / $node.Id collide with native
    # XmlElement properties, so always index the child element explicitly.
    param($Node, [Parameter(Mandatory)][string]$Child)
    if (-not $Node) { return $null }
    $el = $Node[$Child]
    if (-not $el) { return $null }
    ([string]$el.InnerText).Trim()
}

function Parse-AppHpSccmCatalogFromXml {
    param([Parameter(Mandatory)][string]$XmlText)
    $XmlText = $XmlText.TrimStart([char]0xFEFF).TrimStart()
    $doc = [xml]$XmlText

    # SoftPaq lookup: id -> url / version / date / hashes.
    $softpaqs = @{}
    foreach ($sp in @($doc.GetElementsByTagName('SoftPaq'))) {
        $id = ([string](Get-AppHpSccmXmlChildText -Node $sp -Child 'Id')).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $sha256 = Get-AppHpSccmXmlChildText -Node $sp -Child 'SHA256'
        $md5 = Get-AppHpSccmXmlChildText -Node $sp -Child 'MD5'
        $expectedHash = $null
        $expectedHashAlgorithm = $null
        if (-not [string]::IsNullOrWhiteSpace($sha256)) {
            $expectedHash = $sha256; $expectedHashAlgorithm = 'SHA256'
        } elseif (-not [string]::IsNullOrWhiteSpace($md5)) {
            $expectedHash = $md5; $expectedHashAlgorithm = 'MD5'
        }
        $softpaqs[$id] = @{
            url          = Get-AppHpSccmXmlChildText -Node $sp -Child 'Url'
            version      = Get-AppHpSccmXmlChildText -Node $sp -Child 'Version'
            dateReleased = Get-AppHpSccmXmlChildText -Node $sp -Child 'DateReleased'
            size         = Get-AppHpSccmXmlChildText -Node $sp -Child 'Size'
            expectedHash = $expectedHash
            expectedHashAlgorithm = $expectedHashAlgorithm
        }
    }
    if ($softpaqs.Count -eq 0) {
        throw 'HPClientDriverPackCatalog.xml has no SoftPaq entries.'
    }

    $osRank = @{}
    for ($i = 0; $i -lt @($script:AppHpSccmOsColumnPreference).Count; $i++) {
        $osRank[[string]$script:AppHpSccmOsColumnPreference[$i]] = $i
    }

    # One entry per product (SystemName): best Windows 11 64-bit OS by preference,
    # tie-broken by newest SoftPaq release date.
    $byName = @{}
    foreach ($pp in @($doc.GetElementsByTagName('ProductOSDriverPack'))) {
        $arch = Get-AppHpSccmXmlChildText -Node $pp -Child 'Architecture'
        if ($arch -and $arch -notmatch '64') { continue }
        $osName = Get-AppHpSccmXmlChildText -Node $pp -Child 'OSName'
        if ([string]::IsNullOrWhiteSpace($osName) -or $osName -notlike 'Windows 11 64-bit*') { continue }
        $systemName = Get-AppHpSccmXmlChildText -Node $pp -Child 'SystemName'
        if ([string]::IsNullOrWhiteSpace($systemName)) { continue }
        $softpaqId = ([string](Get-AppHpSccmXmlChildText -Node $pp -Child 'SoftPaqId')).ToLowerInvariant()
        if (-not $softpaqs.ContainsKey($softpaqId)) { continue }
        $sp = $softpaqs[$softpaqId]
        if ([string]::IsNullOrWhiteSpace([string]$sp.url)) { continue }

        $rank = if ($osRank.ContainsKey($osName)) { [int]$osRank[$osName] } else { 50 }
        $released = [datetime]::MinValue
        [void][datetime]::TryParse([string]$sp.dateReleased, [ref]$released)

        $systemIds = @((([string](Get-AppHpSccmXmlChildText -Node $pp -Child 'SystemId')) -split ',') |
            ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
        $productType = Get-AppHpSccmXmlChildText -Node $pp -Child 'ProductType'

        $candidate = @{
            name        = $systemName
            folder      = Get-AppHpSccmFolderFromModelName -Name $systemName
            family      = Get-AppHpSccmModelFamily -Group $productType
            group       = $productType
            systemId    = if ($systemIds.Count -gt 0) { [string]$systemIds[0] } else { $null }
            systemIds   = @($systemIds)
            softpaq     = $softpaqId
            url         = [string]$sp.url
            os          = 'win11'
            osName      = $osName
            version     = [string]$sp.version
            dateReleased = [string]$sp.dateReleased
            expectedHash = [string]$sp.expectedHash
            expectedHashAlgorithm = [string]$sp.expectedHashAlgorithm
            rank        = $rank
            released    = $released
        }
        if (-not $byName.ContainsKey($systemName)) {
            $byName[$systemName] = $candidate
        } else {
            $existing = $byName[$systemName]
            if ($rank -lt [int]$existing.rank -or
                ($rank -eq [int]$existing.rank -and $released -gt [datetime]$existing.released)) {
                $byName[$systemName] = $candidate
            }
        }
    }

    $models = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @($byName.Values | Sort-Object { [string]$_.name })) {
        $entry.Remove('rank')
        $entry.Remove('released')
        [void]$models.Add($entry)
    }
    if ($models.Count -eq 0) {
        throw 'HPClientDriverPackCatalog.xml returned no Windows 11 64-bit driver packs.'
    }

    @{
        models   = @($models)
        osColumn = 'per-product best Windows 11 64-bit (' + (@($script:AppHpSccmOsColumnPreference)[0]) + ' first)'
    }
}

function Get-AppHpSccmCatalogFamilySummary {
    param([Parameter(Mandatory)]$Catalog)
    $summary = @{
        notebooks     = 0
        desktops      = 0
        workstations  = 0
        'thin-clients' = 0
        other         = 0
        total         = 0
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

function Test-AppHpModelNameMatchesPattern {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Pattern
    )
    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    return ($Name -like "*$Pattern*")
}

function Resolve-AppHpSccmDriverUrlForWmiPatterns {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)]$Catalog
    )
    if (-not $Patterns -or $Patterns.Count -eq 0 -or -not $Catalog) { return $null }

    foreach ($model in @(Get-AppAria2JsonProp -Item $Catalog -Name 'models')) {
        $name = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        $folder = [string](Get-AppAria2JsonProp -Item $model -Name 'folder')
        $systemIds = @(Get-AppAria2JsonProp -Item $model -Name 'systemIds')
        $matched = $false
        foreach ($pattern in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            # SystemId (Win32_BaseBoard.Product) exact match - sturdier than name fuzzing.
            foreach ($sysId in $systemIds) {
                if ([string]$sysId -and ([string]$sysId).Trim().Equals($pattern.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $true
                    break
                }
            }
            if ($matched) { break }
            if (Test-AppHpModelNameMatchesPattern -Name $name -Pattern $pattern) {
                $matched = $true
                break
            }
            if ($folder -and $folder -like "*$pattern*") {
                $matched = $true
                break
            }
        }
        if (-not $matched) { continue }
        $url = [string](Get-AppAria2JsonProp -Item $model -Name 'url')
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        return @{
            url    = $url
            source = 'hp'
            model  = $name
        }
    }
    return $null
}

function Read-AppHpSccmBundledCatalog {
    if (-not (Get-Command Resolve-AppAria2PackagingFile -ErrorAction SilentlyContinue)) { return $null }
    $path = Resolve-AppAria2PackagingFile -FileName 'hp-sccm-catalog.json'
    if (-not $path) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function ConvertTo-AppHpSccmCatalogResult {
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
    $osColProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('osColumn')) { $Record['osColumn'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'osColumn') {
        $Record.osColumn
    } else { $null }
    @{
        sourceUrl = if ($srcProp) { [string]$srcProp } else { $script:AppHpSccmCatalogUrl }
        fetchedAt = if ($fetchedProp) { [string]$fetchedProp } else { $null }
        osColumn  = if ($osColProp) { [string]$osColProp } else { $null }
        models    = @($modelsProp)
        fromCache = [bool]$FromCache
        stale     = [bool]$Stale
        bundled   = [bool]$Bundled
    }
}

function Get-AppHpSccmDriverCatalog {
    param(
        [switch]$ForceRefresh,
        [switch]$CacheOnly
    )
    $script:AppHpSccmCatalogLastError = $null
    if (-not $ForceRefresh) {
        $cached = Read-AppHpSccmCatalogCache
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
                    $stale = $ageHours -ge $script:AppHpSccmCatalogCacheHours
                    if (-not $stale -or $CacheOnly) {
                        $result = ConvertTo-AppHpSccmCatalogResult -Record $cached -FromCache $true -Stale $stale
                        if ($result) { return $result }
                    }
                } catch { }
            }
        }
    }

    if ($CacheOnly) {
        $bundled = Read-AppHpSccmBundledCatalog
        $result = ConvertTo-AppHpSccmCatalogResult -Record $bundled -FromCache $false -Stale $false -Bundled $true
        if ($result) { return $result }
        $script:AppHpSccmCatalogLastError = 'No HP SCCM catalog in local cache or bundled packaging.'
        return $null
    }

    try {
        # Verify the cab against the SHA1 its sibling UpdateInfo.xml publishes.
        # UpdateInfo unreachable -> proceed unverified (warn-inside-window house
        # style); definite hash mismatch -> one refetch (mid-publish race), then fail.
        $updateInfoXml = $null
        try {
            $updateInfoXml = Invoke-AppHpSccmHttpGet -Uri $script:AppHpSccmCatalogUpdateInfoUrl -MaxTimeSec 60
        } catch {
            Write-SidecarLog "HP SCCM catalog: UpdateInfo fetch failed - $($_.Exception.Message); proceeding without cab verification."
        }
        $cabBytes = Invoke-AppHpSccmHttpGetBytes -Uri $script:AppHpSccmCatalogUrl
        $hashOk = Test-AppHpSccmCatalogCabHash -CabBytes $cabBytes -UpdateInfoXml $updateInfoXml
        if ($hashOk -eq $false) {
            Write-SidecarLog 'HP SCCM catalog: cab SHA1 mismatch vs UpdateInfo - refetching once.'
            $cabBytes = Invoke-AppHpSccmHttpGetBytes -Uri $script:AppHpSccmCatalogUrl
            $hashOk = Test-AppHpSccmCatalogCabHash -CabBytes $cabBytes -UpdateInfoXml $updateInfoXml
            if ($hashOk -eq $false) {
                throw 'HPClientDriverPackCatalog.cab SHA1 does not match UpdateInfo.xml after refetch.'
            }
        }
        $xmlText = Expand-AppHpSccmCatalogCab -CabBytes $cabBytes
        $parsed = Parse-AppHpSccmCatalogFromXml -XmlText $xmlText
        if (@($parsed.models).Count -eq 0) {
            throw 'HP driver pack catalog returned no models.'
        }
        Write-AppHpSccmCatalogCache -Catalog $parsed
        return @{
            sourceUrl = $script:AppHpSccmCatalogUrl
            fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            osColumn  = [string]$parsed.osColumn
            models    = @($parsed.models)
            fromCache = $false
            stale     = $false
        }
    } catch {
        $script:AppHpSccmCatalogLastError = $_.Exception.Message
        if (-not $ForceRefresh) {
    $cached = Read-AppHpSccmCatalogCache
        if ($cached -and (Get-AppAria2JsonProp -Item $cached -Name 'models')) {
                Write-SidecarLog "HP SCCM catalog: live fetch failed - $($_.Exception.Message); using stale cache."
                $cachedSource = [string](Get-AppAria2JsonProp -Item $cached -Name 'sourceUrl')
                return @{
                    sourceUrl = if ($cachedSource) { $cachedSource } else { $script:AppHpSccmCatalogUrl }
                    fetchedAt = [string](Get-AppAria2JsonProp -Item $cached -Name 'fetchedAt')
                    osColumn  = [string](Get-AppAria2JsonProp -Item $cached -Name 'osColumn')
                    models    = @(Get-AppAria2JsonProp -Item $cached -Name 'models')
                    fromCache = $true
                    stale     = $true
                }
            }
        }
        throw
    }
}
