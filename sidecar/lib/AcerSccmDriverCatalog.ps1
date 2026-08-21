# Acer SCCM driver pack catalog - scrape global-download URLs from Acer's SCCM page.
# Entry: https://www.acer.com/sccm/ (redirects to Community KB; fallback URL if redirect fails).
# Resolved landing page may change; we cache the effective URL from curl -L.

$script:AppAcerSccmEntryUrl = 'https://www.acer.com/sccm/'
$script:AppAcerSccmFallbackUrls = @(
    'https://community.acer.com/en/kb/articles/15378-microsoft-system-center-configuration-manager-sccm?expandedToggles=toggle-travelmate'
)
# Structured XML catalog Acer publishes for MSEndpointMgr's Driver Automation Tool -
# hosted on the open pack CDN, so plain curl works (unlike the KB pages, which sit behind
# fingerprint-level bot mitigation). Rich: friendly model names + per-pack os/version/date
# and MD5. Narrow: current TravelMate P-lines only (no B/X-series, no legacy), and its
# pack URLs are a subset of the KB list - so it is merged into the URL cache, never a
# replacement for the browser-harvested coverage (AGENT_NOTES_PXE_DRIVERS section 12).
$script:AppAcerSccmXmlCatalogUrl = 'https://global-download.acer.com/supportfiles/files/support/sourcefile/msepm/AcerCatalog.xml'
$script:AppAcerSccmCatalogCacheHours = 168
$script:AppAcerSccmCatalogLastError = $null

function Get-AppAcerSccmCatalogLastError {
    return $script:AppAcerSccmCatalogLastError
}

function Get-AppAcerSccmCatalogCachePath {
    if (-not (Get-Command Get-AppAria2StoreRoot -ErrorAction SilentlyContinue)) {
        return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'windeploykit/acer-sccm-catalog.json'
    }
    Join-Path (Get-AppAria2StoreRoot) 'acer-sccm-catalog.json'
}

function Read-AppAcerSccmCatalogCache {
    $path = Get-AppAcerSccmCatalogCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-AppAcerSccmCatalogCache {
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [string]$SourceUrl = $script:AppAcerSccmEntryUrl,
        [string]$ResolvedUrl = $null,
        # Structured model entries from AcerCatalog.xml (name/url/os/version/date/md5).
        $Models = $null,
        # When the URL list last came from a full browser harvest of the KB page.
        [string]$HarvestedAt = $null
    )
    $path = Get-AppAcerSccmCatalogCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $payload = @{
        schema      = 1
        sourceUrl   = $SourceUrl
        resolvedUrl = if ($ResolvedUrl) { $ResolvedUrl } else { $SourceUrl }
        fetchedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        urlCount    = $Urls.Count
        urls        = @($Urls)
    }
    if ($null -ne $Models) { $payload.models = @($Models) }
    if (-not [string]::IsNullOrWhiteSpace($HarvestedAt)) { $payload.harvestedAt = $HarvestedAt }
    ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function Invoke-AppAcerSccmHttpGet {
    param([Parameter(Mandatory)][string]$Uri)
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if ($curl) {
        $marker = '__EFFECTIVE_URL__:'
        $raw = & curl -sS -L --http1.1 --max-time 60 -A 'Mozilla/5.0 (compatible; WinDeployKit/1.0)' -w "`n$marker%{url_effective}" $Uri 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "curl failed (exit $LASTEXITCODE): $raw"
        }
        $text = [string]$raw
        $idx = $text.LastIndexOf($marker, [StringComparison]::Ordinal)
        if ($idx -lt 0) {
            return @{ Html = $text; EffectiveUrl = $Uri }
        }
        $effectiveUrl = $text.Substring($idx + $marker.Length).Trim()
        $html = $text.Substring(0, $idx)
        return @{ Html = $html; EffectiveUrl = if ($effectiveUrl) { $effectiveUrl } else { $Uri } }
    }
    $params = @{
        Uri         = $Uri
        Method      = 'Get'
        TimeoutSec  = 60
        ErrorAction = 'Stop'
    }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params['SkipCertificateCheck'] = $true
    }
    $params['Headers'] = @{ 'User-Agent' = 'Mozilla/5.0 (compatible; WinDeployKit/1.0)' }
    if (Get-Command Invoke-AppHttpWebRequest -ErrorAction SilentlyContinue) {
        $resp = Invoke-AppHttpWebRequest -RequestParams $params
    } else {
        $resp = Invoke-WebRequest @params
    }
    $html = if ($resp.Content) { [string]$resp.Content } else { [string]$resp }
    $effectiveUrl = $Uri
    if ($resp.BaseResponse -and $resp.BaseResponse.ResponseUri) {
        $effectiveUrl = [string]$resp.BaseResponse.ResponseUri
    }
    return @{ Html = $html; EffectiveUrl = $effectiveUrl }
}

function Parse-AppAcerSccmDriverUrlsFromHtml {
    param([Parameter(Mandatory)][string]$Html)
    $matches = [regex]::Matches($Html, 'https://global-download\.acer\.com/[^"''\s<>]+', 'IgnoreCase')
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $matches) {
        $url = [System.Uri]::UnescapeDataString($m.Value.Trim().TrimEnd(')', ',', ';'))
        if ($url -match '\.(cab|zip|exe)(\?|$)') {
            [void]$set.Add($url)
        }
    }
    @($set)
}

function Get-AppAcerSccmPatternVariants {
    param([Parameter(Mandatory)][string]$Pattern)
    $p = $Pattern.Trim()
    if ($p -match '(?i)^TravelMate\s+(.+)$') { $p = $Matches[1] }
    $upper = $p.ToUpperInvariant()
    $variants = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$variants.Add($upper)
    [void]$variants.Add("TMP$upper")
    $underscore = $upper -replace '-', '_'
    [void]$variants.Add($underscore)
    [void]$variants.Add("TMP$underscore")
    $compact = $upper -replace '[^A-Z0-9]', ''
    if ($compact) { [void]$variants.Add($compact) }
    if ($upper -match '^P(\d+)-(\d+)$') {
        $series = $Matches[1]
        $rev = $Matches[2]
        [void]$variants.Add("P${series}RN-${rev}")
        [void]$variants.Add("TMP${series}RN-${rev}")
        [void]$variants.Add("${series}RN-${rev}")
    }
    if ($upper -match '^P(\d+)RN-(\d+)$') {
        $series = $Matches[1]
        $rev = $Matches[2]
        [void]$variants.Add("P${series}-${rev}")
        [void]$variants.Add("TMP${series}-${rev}")
        [void]$variants.Add("${series}-${rev}")
    }
    if ($upper -match '^(\d+)RN-(\d+)$') {
        $series = $Matches[1]
        $rev = $Matches[2]
        [void]$variants.Add("P${series}RN-${rev}")
        [void]$variants.Add("TMP${series}RN-${rev}")
        [void]$variants.Add("P${series}-${rev}")
        [void]$variants.Add("TMP${series}-${rev}")
    }
    if ($upper -match '^([BX])(.+)') {
        $seriesLetter = $Matches[1]
        $rest = $Matches[2]
        [void]$variants.Add($rest)
        if ($seriesLetter -eq 'B') {
            [void]$variants.Add("TMB$rest")
            [void]$variants.Add("TM-B$rest")
            if ($rest -match '^(\d{3})') {
                [void]$variants.Add("TMB$($Matches[1])")
            }
        } elseif ($seriesLetter -eq 'X') {
            [void]$variants.Add("TMX$rest")
            if ($rest -match '^(\d{2,4})') {
                [void]$variants.Add("TMX$($Matches[1])")
            }
        }
    }
    if ($upper -match '^P(\d{3})$') {
        $digits = $Matches[1]
        [void]$variants.Add("SCCMTMP$digits")
        [void]$variants.Add("TMP$digits")
        [void]$variants.Add("TPMP$digits-M")
    }
    if ($upper -match '^P(\d{3}-[A-Z])$') {
        [void]$variants.Add("TPMP$($Matches[1])")
    }
    @($variants)
}

function Get-AppAcerSccmDriverUrlScore {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string[]]$Variants
    )
    $name = [System.IO.Path]::GetFileName($Url).ToUpperInvariant()
    $score = 0
    if ($name -match 'WIN11|W11|WINDOWS\s*11') { $score += 120 }
    elseif ($name -match 'WINDOWS11') { $score += 120 }
    if ($name -match '25H2') { $score += 35 }
    elseif ($name -match '24H2') { $score += 25 }
    if ($name -match 'WIN10|W10|WINDOWS\s*10|WINDOWS10') { $score -= 80 }
    if ($name -match 'WIN8|WINDOWS8') { $score -= 100 }
    if ($name -match '\.CAB$') { $score += 12 }
    elseif ($name -match '\.ZIP$') { $score += 10 }
    elseif ($name -match '\.EXE$') { $score -= 15 }
    if ($name -match '_(\d{8})\.') {
        try {
            $d = [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null)
            $days = ([datetime]::UtcNow - $d).TotalDays
            if ($days -ge 0 -and $days -lt 4000) { $score += [int][math]::Min(30, 30 - ($days / 40)) }
        } catch { }
    }
    $bestVariantScore = 0
    foreach ($variant in $Variants) {
        $v = $variant.ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $variantScore = 0
        if ($name.StartsWith("TMP$v", [StringComparison]::OrdinalIgnoreCase)) { $variantScore += 80 }
        elseif ($name.StartsWith($v, [StringComparison]::OrdinalIgnoreCase)) { $variantScore += 60 }
        elseif ($name -match [regex]::Escape($v)) { $variantScore += 40 }
        if ($variantScore -gt $bestVariantScore) { $bestVariantScore = $variantScore }
    }
    if ($bestVariantScore -eq 0) { return -1 }
    $score += $bestVariantScore
    $underscoreCount = ([regex]::Matches($name, 'TMP\d')).Count
    if ($underscoreCount -gt 2) { $score -= 8 * ($underscoreCount - 2) }
    if ($score -lt 1) { $score = [math]::Max(1, $bestVariantScore) }
    return $score
}

function Resolve-AppAcerSccmDriverUrlForWmiPatterns {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string[]]$Urls
    )
    if (-not $Patterns -or $Patterns.Count -eq 0 -or -not $Urls -or $Urls.Count -eq 0) {
        return $null
    }
    $variants = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pattern in $Patterns) {
        foreach ($v in @(Get-AppAcerSccmPatternVariants -Pattern $pattern)) {
            [void]$variants.Add($v)
        }
    }
    $variantList = @($variants)
    $bestUrl = $null
    # CORRECT AS WRITTEN - do not 'fix' to [int]::MinValue like Lenovo. Acer's -1 is a
    # deliberate no-match sentinel (scorer returns -1 when bestVariantScore -eq 0) and
    # every real match clamps to >= 1, so seeding lower would let no-match entries win.
    $bestScore = -1
    foreach ($url in $Urls) {
        $score = Get-AppAcerSccmDriverUrlScore -Url $url -Variants $variantList
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestUrl = $url
        }
    }
    if (-not $bestUrl) { return $null }
    @{
        url      = $bestUrl
        fileName = [System.IO.Path]::GetFileName($bestUrl)
        score    = $bestScore
    }
}

function Get-AppAcerSccmNormalizedTravelMateCode {
    param([Parameter(Mandatory)][string]$Raw)
    Get-AppAcerSccmNormalizedModelCode -Raw $Raw
}

function Get-AppAcerSccmNormalizedModelCode {
    param([Parameter(Mandatory)][string]$Raw)
    $text = $Raw.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    if ($text -match '^(P(?:2|4|6)\d{2}(?:RN)?-\d{2,3}(?:-[A-Z0-9]+)*)$') {
        return $Matches[1]
    }
    if ($text -match '^(?:(?:TMP|TM)?)?((?:2|4|6)\d{2}RN-\d{2,3}(?:-[A-Z0-9]+)*)$') {
        return "P$($Matches[1])"
    }
    if ($text -match '^(?:(?:TMP|TM)?)?((?:2|4|6)\d{2}-\d{2,3}(?:-[A-Z0-9]+)*)$') {
        return "P$($Matches[1])"
    }
    if ($text -match '^(P\d{3}-[A-Z][A-Z0-9-]*)$') {
        return $Matches[1]
    }
    if ($text -match '^(P\d{3}-[A-Z])$') {
        return $Matches[1]
    }
    if ($text -match '^(P\d{3})$') {
        return $Matches[1]
    }
    if ($text -match '^([BX]\d{2,4}(?:RN|R)?(?:-\d{2,3})?(?:-[A-Z0-9]+)*)$') {
        return $Matches[1]
    }
    if ($text -match '^(\d{3}(?:RN|R)?(?:-\d{2,3})?(?:-[A-Z0-9]+)*)$') {
        return "B$($Matches[1])"
    }
    return $null
}

function Get-AppAcerSccmModelFamilyFromCode {
    param([Parameter(Mandatory)][string]$Code)
    $c = $Code.Trim().ToUpperInvariant()
    if ($c -match '^P248$|^P256$|^P246-M$') { return 'legacy-p' }
    if ($c -match '^P\d{3}-[A-Z]') { return 'legacy-p' }
    if ($c -match '^P(?:2|4|6)\d{2}(?:RN)?-\d') {
        if ($c -match '^P2') { return 'p2xx' }
        if ($c -match '^P4') { return 'p4xx' }
        if ($c -match '^P6') { return 'p6xx' }
    }
    if ($c -match '^B514') { return 'b514' }
    if ($c -match '^X514') { return 'x514' }
    if ($c -match '^B1') { return 'b1xx' }
    if ($c -match '^B3') { return 'b3xx' }
    if ($c -match '^X') { return 'x3xx' }
    'travelmate'
}

function Add-AppAcerSccmModelCodeFromMatch {
    param(
        $Codes,
        [Parameter(Mandatory)][string]$Raw
    )
    if (-not $Codes) { return }
    $code = Get-AppAcerSccmNormalizedModelCode -Raw $Raw
    if ($code) { [void]$Codes.Add($code) }
}

function Get-AppAcerSccmTravelMateCodesFromFileName {
    param([Parameter(Mandatory)][string]$FileName)
    Get-AppAcerSccmModelCodesFromFileName -FileName $FileName
}

function Get-AppAcerSccmModelCodesFromFileName {
    param([Parameter(Mandatory)][string]$FileName)
    $codes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ([string]::IsNullOrWhiteSpace($base)) { return @() }

    foreach ($m in [regex]::Matches($base, '(?i)(?:TMP)?(P(?:2|4|6)\d{2}(?:RN)?-\d{2,3}(?:-[A-Z0-9]+)*)')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ([string]$m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($base, '(?i)TMP((?:2|4|6)\d{2}(?:RN)?-\d{2,3}(?:-[A-Z0-9]+)*)')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ("P$($m.Groups[1].Value)")
    }
    foreach ($m in [regex]::Matches($base, '(?i)TMB(\d{3}(?:RN|R)?(?:-\d{2,3})?(?:-[A-Z0-9]+)*)')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ("B$($m.Groups[1].Value)")
    }
    foreach ($m in [regex]::Matches($base, '(?i)TMX(\d{2,4}(?:RN|R)?(?:-\d{2,3})?(?:-[A-Z0-9]+)*)')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ("X$($m.Groups[1].Value)")
    }
    foreach ($m in [regex]::Matches($base, '(?i)TM-B(\d{3}(?:-[A-Z0-9]+)*)')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ("B$($m.Groups[1].Value)")
    }
    foreach ($m in [regex]::Matches($base, '(?i)(?:^|_)(P\d{3}-[A-Z][A-Z0-9-]*)(?:_|\.|$)')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ([string]$m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($base, '(?i)TPM(P\d{3}-[A-Z])')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ([string]$m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($base, '(?i)SCCMTMP(\d{3})')) {
        Add-AppAcerSccmModelCodeFromMatch -Codes $codes -Raw ("P$($m.Groups[1].Value)")
    }
    @($codes)
}

function Test-AppAcerSccmSeedPatternsCoverCode {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string[]]$SeedPatterns
    )
    foreach ($pattern in @($SeedPatterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $normalizedPattern = Get-AppAcerSccmNormalizedTravelMateCode -Raw $pattern
        if ($normalizedPattern -and ($normalizedPattern -eq $Code)) { return $true }
        foreach ($variant in @(Get-AppAcerSccmPatternVariants -Pattern $pattern)) {
            $normalizedVariant = Get-AppAcerSccmNormalizedTravelMateCode -Raw $variant
            if ($normalizedVariant -and ($normalizedVariant -eq $Code)) { return $true }
            if ($variant -eq $Code) { return $true }
        }
    }
    $false
}

function Get-AppAcerSccmTravelMateCatalogEntries {
    param([Parameter(Mandatory)][string[]]$Urls)
    $codeToUrls = @{}
    foreach ($url in @($Urls)) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $fileName = [System.IO.Path]::GetFileName($url)
        foreach ($code in @(Get-AppAcerSccmTravelMateCodesFromFileName -FileName $fileName)) {
            if (-not $codeToUrls.ContainsKey($code)) {
                $codeToUrls[$code] = [System.Collections.Generic.List[string]]::new()
            }
            if ($codeToUrls[$code] -notcontains $url) {
                [void]$codeToUrls[$code].Add($url)
            }
        }
    }
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($code in @($codeToUrls.Keys | Sort-Object)) {
        $resolved = Resolve-AppAcerSccmDriverUrlForWmiPatterns -Patterns @($code, "TravelMate $code") -Urls @($codeToUrls[$code])
        if (-not $resolved) { continue }
        $folder = "TravelMate $code"
        $family = Get-AppAcerSccmModelFamilyFromCode -Code $code
        [void]$entries.Add(@{
                code        = $code
                folder      = $folder
                displayName = $folder
                family      = $family
                url         = [string]$resolved.url
                fileName    = [string]$resolved.fileName
                score       = [int]$resolved.score
            })
    }
    # Acer often ships TMP414-53 packs for both base and RN SKUs (no separate TMP414RN-53 file).
    $existingCodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($entries)) { [void]$existingCodes.Add([string]$entry.code) }
    foreach ($entry in @($entries)) {
        $code = [string]$entry.code
        if ($code -notmatch '^P(\d+)-(\d+)$') { continue }
        $rnCode = "P$($Matches[1])RN-$($Matches[2])"
        if ($existingCodes.Contains($rnCode)) { continue }
        $rnFolder = "TravelMate $rnCode"
        [void]$entries.Add(@{
                code        = $rnCode
                folder      = $rnFolder
                displayName = $rnFolder
                family      = Get-AppAcerSccmModelFamilyFromCode -Code $rnCode
                url         = [string]$entry.url
                fileName    = [string]$entry.fileName
                score       = [int]$entry.score
                rnAliasOf   = $code
            })
        [void]$existingCodes.Add($rnCode)
    }
    @($entries)
}

function Get-AppAcerSccmCatalogSummary {
    param([Parameter(Mandatory)][string[]]$Urls)
    $entries = @(Get-AppAcerSccmTravelMateCatalogEntries -Urls $Urls)
    $p2 = @($entries | Where-Object { [string]$_.family -eq 'p2xx' }).Count
    $p4 = @($entries | Where-Object { [string]$_.family -eq 'p4xx' }).Count
    $p6 = @($entries | Where-Object { [string]$_.family -eq 'p6xx' }).Count
    @{
        travelmate = $entries.Count
        total      = $entries.Count
        p2xx       = $p2
        p4xx       = $p4
        p6xx       = $p6
        legacyP    = @($entries | Where-Object { [string]$_.family -eq 'legacy-p' }).Count
        b1xx       = @($entries | Where-Object { [string]$_.family -eq 'b1xx' }).Count
        b3xx       = @($entries | Where-Object { [string]$_.family -eq 'b3xx' }).Count
        x3xx       = @($entries | Where-Object { [string]$_.family -eq 'x3xx' }).Count
        b514       = @($entries | Where-Object { [string]$_.family -eq 'b514' }).Count
        x514       = @($entries | Where-Object { [string]$_.family -eq 'x514' }).Count
        urlCount   = @($Urls).Count
    }
}

function Read-AppAcerSccmBundledCatalog {
    if (-not (Get-Command Resolve-AppAria2PackagingFile -ErrorAction SilentlyContinue)) { return $null }
    $path = Resolve-AppAria2PackagingFile -FileName 'acer-sccm-catalog.json'
    if (-not $path) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function ConvertTo-AppAcerSccmCatalogResult {
    param(
        $Record,
        [string]$SourceUrl,
        [bool]$FromCache,
        [bool]$Stale,
        [bool]$Bundled = $false
    )
    if (-not $Record) { return $null }
    $urlsProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('urls')) { $Record['urls'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'urls') {
        $Record.urls
    } else { $null }
    if (-not $urlsProp) { return $null }
    $srcProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('sourceUrl')) { $Record['sourceUrl'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'sourceUrl') {
        $Record.sourceUrl
    } else { $null }
    $resolvedProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('resolvedUrl')) { $Record['resolvedUrl'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'resolvedUrl') {
        $Record.resolvedUrl
    } else { $null }
    $fetchedProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('fetchedAt')) { $Record['fetchedAt'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'fetchedAt') {
        $Record.fetchedAt
    } else { $null }
    @{
        sourceUrl   = if ($srcProp) { [string]$srcProp } else { $SourceUrl }
        resolvedUrl = if ($resolvedProp) { [string]$resolvedProp } else { $null }
        fetchedAt   = if ($fetchedProp) { [string]$fetchedProp } else { $null }
        urls        = @([string[]]$urlsProp)
        fromCache   = [bool]$FromCache
        stale       = [bool]$Stale
        bundled     = [bool]$Bundled
    }
}

function Get-AppAcerSccmCatalogRecordUrls {
    param($Record)
    if (-not $Record) { return @() }
    $urlsProp = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('urls')) { $Record['urls'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'urls') {
        $Record.urls
    } else { $null }
    if (-not $urlsProp) { return @() }
    @([string[]]$urlsProp)
}

function Get-AppAcerSccmCatalogRecordFetchedAt {
    param($Record)
    if (-not $Record) { return $null }
    $fetchedAtRaw = if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains('fetchedAt')) { $Record['fetchedAt'] } else { $null }
    } elseif ($Record.PSObject.Properties.Name -contains 'fetchedAt') {
        $Record.fetchedAt
    } else { $null }
    if ($fetchedAtRaw -is [datetime]) { return [datetime]$fetchedAtRaw }
    if ([string]::IsNullOrWhiteSpace([string]$fetchedAtRaw)) { return $null }
    try {
        # PS7 ConvertFrom-Json hydrates ISO strings into [DateTime] (handled above);
        # plain strings still parse round-trip.
        return [datetime]::Parse([string]$fetchedAtRaw, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

function Select-AppAcerSccmBestCatalogRecord {
    param(
        $Cached,
        $Bundled
    )
    $cachedUrls = @(Get-AppAcerSccmCatalogRecordUrls -Record $Cached)
    $bundledUrls = @(Get-AppAcerSccmCatalogRecordUrls -Record $Bundled)
    if ($cachedUrls.Count -eq 0 -and $bundledUrls.Count -eq 0) { return $null }
    if ($bundledUrls.Count -gt $cachedUrls.Count) {
        return @{ Record = $Bundled; Bundled = $true; FromCache = $false }
    }
    if ($cachedUrls.Count -gt $bundledUrls.Count) {
        return @{ Record = $Cached; Bundled = $false; FromCache = $true }
    }
    $cachedAt = Get-AppAcerSccmCatalogRecordFetchedAt -Record $Cached
    $bundledAt = Get-AppAcerSccmCatalogRecordFetchedAt -Record $Bundled
    if ($bundledAt -and (-not $cachedAt -or $bundledAt -gt $cachedAt)) {
        return @{ Record = $Bundled; Bundled = $true; FromCache = $false }
    }
    if ($Cached) {
        return @{ Record = $Cached; Bundled = $false; FromCache = $true }
    }
    @{ Record = $Bundled; Bundled = $true; FromCache = $false }
}

function Get-AppAcerSccmXmlCatalog {
    <#
    .SYNOPSIS
        Fetch + parse AcerCatalog.xml (curl-friendly CDN host). Returns
        @{ models = @(@{name; product; url; os; version; date; md5}); urls = @(...) }.
    #>
    $curl = Get-Command curl -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl is required to fetch AcerCatalog.xml.' }
    $out = & curl -sS -L --http1.1 --max-time 90 -A 'Mozilla/5.0 (compatible; WinDeployKit/1.0)' $script:AppAcerSccmXmlCatalogUrl 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed (exit $LASTEXITCODE): $out"
    }
    $xmlText = ([string]($out -join "`n")).TrimStart([char]0xFEFF).TrimStart()
    $doc = [xml]$xmlText
    $models = [System.Collections.Generic.List[hashtable]]::new()
    $urls = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Set-StrictMode: $doc.ModelList.Model throws if the XML shape changes - tag lookup
    # degrades to an empty list instead.
    foreach ($model in @($doc.GetElementsByTagName('Model'))) {
        if (-not $model) { continue }
        $name = [string]$model.GetAttribute('name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        foreach ($sccm in @($model.GetElementsByTagName('SCCM'))) {
            $url = ([string]$sccm.InnerText).Trim()
            if ($url -notmatch '(?i)^https://global-download\.acer\.com/') { continue }
            [void]$models.Add(@{
                    name    = $name
                    product = [string]$model.GetAttribute('product')
                    url     = $url
                    os      = [string]$sccm.GetAttribute('os')
                    version = [string]$sccm.GetAttribute('version')
                    date    = [string]$sccm.GetAttribute('date')
                    md5     = [string]$sccm.GetAttribute('md5')
                })
            if ($seen.Add($url)) { [void]$urls.Add($url) }
        }
    }
    if ($models.Count -eq 0) {
        throw 'AcerCatalog.xml returned no SCCM model entries.'
    }
    @{ models = @($models); urls = @($urls) }
}

function Update-AppAcerSccmCatalogFromXml {
    <#
    .SYNOPSIS
        Routine Acer refresh: fetch AcerCatalog.xml over curl, union its pack URLs into
        the cached URL list (the XML covers only current P-line TravelMates, so the
        browser-harvested KB list is kept), and store the structured model entries
        (with MD5 hashes) alongside. Preserves harvestedAt. Returns counts + whether a
        fresh browser harvest is recommended.
    #>
    $xml = Get-AppAcerSccmXmlCatalog

    $existing = Read-AppAcerSccmCatalogCache
    if (-not $existing) { $existing = Read-AppAcerSccmBundledCatalog }
    $existingUrls = @(Get-AppAcerSccmCatalogRecordUrls -Record $existing)
    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in @($existingUrls) + @($xml.urls)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$u) -and $seen.Add([string]$u)) { [void]$merged.Add([string]$u) }
    }

    # harvestedAt survives the round trip as either a string or (via PS7's
    # ConvertFrom-Json hydration) a [DateTime] - normalise BEFORE stringifying.
    $harvestedParsed = [DateTime]::MinValue
    $harvestedAtText = $null
    if ($existing) {
        $prop = if ($existing -is [System.Collections.IDictionary]) {
            if ($existing.Contains('harvestedAt')) { $existing['harvestedAt'] } else { $null }
        } elseif ($existing.PSObject.Properties.Name -contains 'harvestedAt') {
            $existing.harvestedAt
        } else { $null }
        if ($prop -is [DateTime]) {
            $harvestedParsed = [DateTime]$prop
        } elseif ($prop) {
            [void][DateTime]::TryParse([string]$prop, [ref]$harvestedParsed)
        }
        if ($harvestedParsed -ne [DateTime]::MinValue) {
            $harvestedAtText = $harvestedParsed.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }

    Write-AppAcerSccmCatalogCache -Urls @($merged) -SourceUrl $script:AppAcerSccmXmlCatalogUrl `
        -ResolvedUrl $script:AppAcerSccmXmlCatalogUrl -Models @($xml.models) -HarvestedAt $harvestedAtText

    # Recommend a browser harvest when there has never been one, or it is older than 60
    # days - the XML cannot cover B/X-series or legacy packs, only the KB page can.
    $harvestAgeDays = $null
    if ($harvestedParsed -ne [DateTime]::MinValue) {
        $harvestAgeDays = [int]((Get-Date).ToUniversalTime() - $harvestedParsed.ToUniversalTime()).TotalDays
    }
    @{
        ok                 = $true
        xmlModelCount      = @($xml.models).Count
        xmlUrlCount        = @($xml.urls).Count
        mergedUrlCount     = $merged.Count
        harvestAgeDays     = $harvestAgeDays
        harvestRecommended = ($null -eq $harvestAgeDays -or $harvestAgeDays -gt 60)
    }
}

function Get-AppAcerSccmDriverUrlCatalog {
    param(
        [switch]$ForceRefresh,
        [switch]$CacheOnly,
        [string]$SourceUrl = $script:AppAcerSccmEntryUrl
    )
    $script:AppAcerSccmCatalogLastError = $null
    if (-not $ForceRefresh) {
        $cached = Read-AppAcerSccmCatalogCache
        $bundled = Read-AppAcerSccmBundledCatalog
        $best = Select-AppAcerSccmBestCatalogRecord -Cached $cached -Bundled $bundled
        if ($best -and $best.Record) {
            $fetchedAt = Get-AppAcerSccmCatalogRecordFetchedAt -Record $best.Record
            $stale = $false
            if ($fetchedAt) {
                $ageHours = ((Get-Date).ToUniversalTime() - $fetchedAt.ToUniversalTime()).TotalHours
                $stale = $ageHours -ge $script:AppAcerSccmCatalogCacheHours
            }
            if (-not $stale -or $CacheOnly) {
                $result = ConvertTo-AppAcerSccmCatalogResult -Record $best.Record -SourceUrl $SourceUrl -FromCache ([bool]$best.FromCache) -Stale $stale -Bundled ([bool]$best.Bundled)
                if ($result) {
                    $cachedUrls = @(Get-AppAcerSccmCatalogRecordUrls -Record $cached)
                    $bestUrls = @(Get-AppAcerSccmCatalogRecordUrls -Record $best.Record)
                    if ($best.Bundled -and $bestUrls.Count -gt $cachedUrls.Count) {
                        $resolvedUrl = if ($best.Record -is [System.Collections.IDictionary]) {
                            if ($best.Record.Contains('resolvedUrl')) { $best.Record['resolvedUrl'] } else { $null }
                        } elseif ($best.Record.PSObject.Properties.Name -contains 'resolvedUrl') {
                            $best.Record.resolvedUrl
                        } else { $null }
                        Write-AppAcerSccmCatalogCache -Urls $bestUrls -SourceUrl $SourceUrl -ResolvedUrl $resolvedUrl
                    }
                    return $result
                }
            }
        }
    }

    if ($CacheOnly) {
        $bundled = Read-AppAcerSccmBundledCatalog
        $result = ConvertTo-AppAcerSccmCatalogResult -Record $bundled -SourceUrl $SourceUrl -FromCache $false -Stale $false -Bundled $true
        if ($result) { return $result }
        $script:AppAcerSccmCatalogLastError = 'No Acer SCCM catalog in local cache or bundled packaging.'
        return $null
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    # AcerCatalog.xml first - the only Acer discovery source plain curl can still reach
    # (the HTML pages fingerprint-block/tarpit curl from any network). Union-merges the
    # XML's pack URLs into the cached list, so KB-harvested coverage is never lost.
    try {
        $null = Update-AppAcerSccmCatalogFromXml
        $refreshed = Read-AppAcerSccmCatalogCache
        $refreshedUrls = @(Get-AppAcerSccmCatalogRecordUrls -Record $refreshed)
        if ($refreshedUrls.Count -gt 0) {
            return @{
                sourceUrl   = $script:AppAcerSccmXmlCatalogUrl
                resolvedUrl = $script:AppAcerSccmXmlCatalogUrl
                fetchedAt   = [string]$refreshed.fetchedAt
                urls        = @($refreshedUrls)
                fromCache   = $false
                stale       = $false
            }
        }
    } catch {
        [void]$errors.Add("AcerCatalog.xml -> $($_.Exception.Message)")
    }

    $tryUrls = [System.Collections.Generic.List[string]]::new()
    if ($SourceUrl) { [void]$tryUrls.Add($SourceUrl) }
    foreach ($fallback in @($script:AppAcerSccmFallbackUrls)) {
        if ($fallback -and $tryUrls -notcontains $fallback) {
            [void]$tryUrls.Add($fallback)
        }
    }
    foreach ($fetchUrl in @($tryUrls)) {
        try {
            $resp = Invoke-AppAcerSccmHttpGet -Uri $fetchUrl
            $html = [string]$resp.Html
            $effectiveUrl = [string]$resp.EffectiveUrl
            $urls = @(Parse-AppAcerSccmDriverUrlsFromHtml -Html $html)
            if ($urls.Count -eq 0) {
                [void]$errors.Add("$fetchUrl -> no global-download URLs (landed $effectiveUrl)")
                continue
            }
            Write-AppAcerSccmCatalogCache -Urls $urls -SourceUrl $SourceUrl -ResolvedUrl $effectiveUrl
            return @{
                sourceUrl   = $SourceUrl
                resolvedUrl = $effectiveUrl
                fetchedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                urls        = $urls
                fromCache   = $false
                stale       = $false
            }
        } catch {
            [void]$errors.Add("$fetchUrl -> $($_.Exception.Message)")
        }
    }

    $script:AppAcerSccmCatalogLastError = ($errors -join '; ')
    $cached = Read-AppAcerSccmCatalogCache
    if ($cached -and $cached.urls) {
        Write-SidecarLog "Acer SCCM catalog: live fetch failed - $($script:AppAcerSccmCatalogLastError); using stale cache."
        return @{
            sourceUrl   = if ($cached.sourceUrl) { [string]$cached.sourceUrl } else { $SourceUrl }
            resolvedUrl = if ($cached.resolvedUrl) { [string]$cached.resolvedUrl } else { $null }
            fetchedAt   = [string]$cached.fetchedAt
            urls        = @([string[]]$cached.urls)
            fromCache   = $true
            stale       = $true
        }
    }
    throw "Acer SCCM catalog fetch failed: $($script:AppAcerSccmCatalogLastError)"
}
