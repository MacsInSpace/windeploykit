# EvalIsoCatalog.ps1 - Microsoft Evaluation Center ISO discovery + fetch.
#
# Why this exists: the product needs a legal, no-account, zero-setup source of
# Windows media so a fresh install can be tested end to end. Evaluation Center
# ISOs are freely downloadable from Microsoft and time-limited (180 days for
# Server, 90 for client) - fine for lab, imaging tests and CI. Netboot mounts and
# serves whatever lands in the image library, so there is no WIM extraction step.
#
# Ported from Craig's GetWinISOs.ps1, then rebuilt 2026-08-22 after testing the
# original end to end against the live pages:
#   1. Cross-platform: Start-BitsTransfer (Windows-only) -> the shared direct-HTTP
#      rail, so this works on macOS and with the aria2 daemon stopped.
#   2. The original's filter clause was a parse error ("and (" with no dash) AND
#      its two predicates no longer match anything: link text is now just
#      "64-bit edition" (not "Download Windows ... (en-US)"), and country is
#      lower-case "us" on current pages.
#   3. No hardcoded E:\ISOs - lands in the image library iso/ folder, which is
#      what Caddy and the SMB share already serve.
#
# HOW THE PAGES ARE PARSED (this is the whole trick):
# Nothing visible identifies a download - every link's text is "64-bit edition".
# The one stable identity is the anchor's aria-label:
#     aria-label="64-bit edition: Download Windows 11 Enterprise ISO 64-bit (en-US)"
#     aria-label="Download Windows Server 2025 Preview VHD 64-bit (en-US)"
# so that is what ConvertFrom-AppEvalIsoPage matches. Verified against all six
# live pages on 2026-08-22; fixtures under scripts/fixtures/eval-iso/ keep the
# parser honest offline (scripts/test-eval-iso-catalog.ps1).
#
# Facts that cost real debugging - do not re-derive:
#   * Older product pages (2016/2019/2022) use /fwlink/p/?linkid= and HTML-encode
#     '=' as &#61;, so the href pattern and entity decoding must both be tolerant.
#   * Windows 10 Enterprise's page still exists but carries NO download anchors
#     (evaluation retired with Win10 servicing). That is 'unavailable', not an error.
#   * A slug that does not exist yet answers 403 behind Akamai, not 404 - so a
#     future product is simply "no entries yet". See the probe rows below.
#   * The fwlink is what we download (stable); the file it redirects to is not.
#     One HEAD chain per entry gives the real file name and size, which is also
#     the only way "already downloaded" can ever match on disk.
#   * Evaluation Center rejects some non-browser agents, so the page fetch sends a
#     browser user agent. The ISO fetch itself uses the product agent as usual.

# Standalone-load shim: scripts dot-source lib subsets in any order, and this lib
# calls Test-AppSidecarCommand (the fast Get-Command). Full version in AppPaths.ps1;
# this fallback is plain Get-Command, correct just slower. Same pattern as the
# Write-SidecarLog no-op shims.
if (-not (Get-Command Test-AppSidecarCommand -ErrorAction SilentlyContinue)) {
    function Test-AppSidecarCommand {
        param([Parameter(Mandatory)][string]$Name)
        [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }
}

if (-not (Get-Command Get-AppDataRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppPaths.ps1')
}

$script:AppEvalIsoCacheHours = 336          # 14 days, same policy as the driver catalogs
$script:AppEvalIsoCacheSchema = 1
$script:AppEvalIsoCacheName = 'eval-iso-catalog.json'
$script:AppEvalIsoBaseUrl = 'https://www.microsoft.com/en-us/evalcenter/'
$script:AppEvalIsoCulture = 'en-US'
$script:AppEvalIsoPageAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
$script:AppEvalIsoRefreshJob = $null

# Data-driven: a new release is one row. probe = expected to return nothing until
# Microsoft publishes the page; it must never surface as a failure.
$script:AppEvalIsoProducts = @(
    [ordered]@{ id = 'win11';   name = 'Windows 11 Enterprise'; kind = 'client'; slug = 'download-windows-11-enterprise'; probe = $false }
    [ordered]@{ id = 'win12';   name = 'Windows 12 Enterprise'; kind = 'client'; slug = 'download-windows-12-enterprise'; probe = $true }
    [ordered]@{ id = 'win10';   name = 'Windows 10 Enterprise'; kind = 'client'; slug = 'download-windows-10-enterprise'; probe = $false }
    [ordered]@{ id = 'srv2025'; name = 'Windows Server 2025';   kind = 'server'; slug = 'download-windows-server-2025';   probe = $false }
    [ordered]@{ id = 'srv2022'; name = 'Windows Server 2022';   kind = 'server'; slug = 'download-windows-server-2022';   probe = $false }
    [ordered]@{ id = 'srv2019'; name = 'Windows Server 2019';   kind = 'server'; slug = 'download-windows-server-2019';   probe = $false }
    [ordered]@{ id = 'srv2016'; name = 'Windows Server 2016';   kind = 'server'; slug = 'download-windows-server-2016';   probe = $false }
)

# Media Microsoft only ships through the consumer download page, which cannot be
# automated: the session API lists language SKUs fine, then the link call is refused
# with "Sentinel marked this request as rejected" (anti-bot). Verified 2026-08-22.
# These are surfaced as links so a tech can fetch and import by hand in one click.
$script:AppEvalIsoManualSources = @(
    [ordered]@{
        id     = 'win11-arm64'
        name   = 'Windows 11 ARM64'
        url    = 'https://www.microsoft.com/en-us/software-download/windows11arm64'
        reason = 'no ARM64 evaluation ISO is published - consumer media, download and import'
    }
    [ordered]@{
        id     = 'win10-retail'
        name   = 'Windows 10 22H2'
        url    = 'https://www.microsoft.com/en-us/software-download/windows10ISO'
        reason = 'evaluation retired - consumer media, download and import'
    }
)

function Get-AppEvalIsoManualSources {
    @($script:AppEvalIsoManualSources | ForEach-Object { [ordered]@{
        id = [string]$_.id; name = [string]$_.name; url = [string]$_.url; reason = [string]$_.reason
    } })
}

function Get-AppEvalIsoProducts {
    @($script:AppEvalIsoProducts | ForEach-Object { [ordered]@{
        id    = [string]$_.id
        name  = [string]$_.name
        kind  = [string]$_.kind
        probe = [bool]$_.probe
        page  = $script:AppEvalIsoBaseUrl + [string]$_.slug
    } })
}

function Get-AppEvalIsoCachePath {
    $root = if (Test-AppSidecarCommand Get-AppAria2StoreRoot) {
        Get-AppAria2StoreRoot
    } else {
        Get-AppPluginDir -Plugin 'aria2'
    }
    Join-Path $root $script:AppEvalIsoCacheName
}

function Read-AppEvalIsoCache {
    # $null on missing/blank/corrupt - never throws, never blocks.
    $path = Get-AppEvalIsoCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-AppEvalIsoCache {
    # Atomic: a killed refresh must never leave a half-written catalog behind.
    param([Parameter(Mandatory)]$Payload)
    $path = Get-AppEvalIsoCachePath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    $tmp = "$path.tmp"
    ($Payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Get-AppEvalIsoProp {
    # StrictMode-safe optional read (ConvertFrom-Json omits absent keys, so a bare
    # $json.maybe throws). Local on purpose: the refresh child loads this file alone.
    param($Item, [string]$Name)
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-AppEvalIsoCacheAgeHours {
    param($Cache)
    $fetched = Get-AppEvalIsoProp -Item $Cache -Name 'fetchedAt'
    if (-not $fetched) { return $null }
    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParse([string]$fetched, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)
    if (-not $ok) { return $null }
    return [math]::Round(((Get-Date).ToUniversalTime() - $parsed).TotalHours, 1)
}

function ConvertFrom-AppEvalIsoPage {
    <#
    .SYNOPSIS
        Pure: one product page's HTML -> download rows. No network, no state, so
        the parser is unit-tested offline against captured fixtures.
    #>
    param(
        [string]$Html,
        [string]$ProductId,
        [string]$ProductName
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrWhiteSpace($Html)) { return @($rows) }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # aria-label and href appear in either order depending on the page generation.
    $patterns = @(
        '<a\b[^>]*?aria-label="(?<label>[^"]*?Download[^"]*?)"[^>]*?href="(?<href>https://go\.microsoft\.com/fwlink/[^"]+)"',
        '<a\b[^>]*?href="(?<href>https://go\.microsoft\.com/fwlink/[^"]+)"[^>]*?aria-label="(?<label>[^"]*?Download[^"]*?)"'
    )
    foreach ($rx in $patterns) {
        foreach ($m in [regex]::Matches($Html, $rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $label = [System.Net.WebUtility]::HtmlDecode($m.Groups['label'].Value).Trim()
            $href = [System.Net.WebUtility]::HtmlDecode($m.Groups['href'].Value).Trim()
            if ([string]::IsNullOrWhiteSpace($href)) { continue }
            # Strip a leading call-to-action ("64-bit edition: Download ...").
            $core = $label
            if ($core -match '^[^:]{1,40}:\s*(?<rest>Download\b.*)$') { $core = $matches['rest'] }
            if ($core -notmatch '^Download\s+(?<name>.+?)\s+(?<media>ISO|VHD)\s+(?<extra>.*?)\((?<culture>[A-Za-z]{2}-[A-Za-z]{2})\)\s*$') { continue }
            $name = $matches['name'].Trim()
            $media = $matches['media'].ToUpperInvariant()
            $extra = $matches['extra'].Trim()
            $culture = $matches['culture']
            $edition = if ($name -match '(?i)\bLTSC\b' -or $extra -match '(?i)\bLTSC\b') { 'LTSC' } else { 'Standard' }
            $arch = if ($extra -match '(?i)ARM64') { 'arm64' } elseif ($extra -match '32-bit') { 'x86' } else { 'x64' }
            $name = ($name -replace '(?i)\s*\bISO\b\s*$', '').Trim()
            if (-not $seen.Add($href)) { continue }
            $suffix = ''
            if ($edition -eq 'LTSC') { $suffix += '-ltsc' }
            if ($media -eq 'VHD') { $suffix += '-vhd' }
            if ($arch -ne 'x64') { $suffix += "-$arch" }
            [void]$rows.Add([ordered]@{
                id          = ([string]$ProductId + $suffix).ToLowerInvariant()
                productId   = [string]$ProductId
                productName = [string]$ProductName
                title       = $name
                media       = $media
                edition     = $edition
                arch        = $arch
                culture     = $culture
                url         = $href
            })
        }
    }
    return @($rows)
}

function Get-AppEvalIsoReleaseFromFileName {
    <#
    .SYNOPSIS
        Best-effort build/release out of Microsoft's eval file names, display only:
          26200.6584.250915-1905.25h2_ge_release_..._en-us.iso -> 26200.6584 / 25H2
          Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO -> 14393
    #>
    param([string]$FileName)
    $out = [ordered]@{ build = ''; release = '' }
    if ([string]::IsNullOrWhiteSpace($FileName)) { return $out }
    if ($FileName -match '^(?<build>\d{5}\.\d+)') { $out.build = $matches['build'] }
    elseif ($FileName -match '_(?<build>\d{5})_') { $out.build = $matches['build'] }
    if ($FileName -match '(?i)[\._-](?<rel>\d{2}h[12])[\._]') { $out.release = $matches['rel'].ToUpperInvariant() }
    return $out
}

function Resolve-AppEvalIsoDownload {
    <#
    .SYNOPSIS
        One HEAD chain per link: the real file name, byte size and (where the
        redirect passes through one) the aka.ms alias that names the release.
        Returns $null when the link no longer resolves - the row is then still
        offered, just without size/name detail.
    #>
    param([Parameter(Mandatory)][string]$Uri)
    try {
        $resp = Invoke-WebRequest -Uri $Uri -Method Head -MaximumRedirection 8 -TimeoutSec 60 -ErrorAction Stop
    } catch {
        return $null
    }
    $fileName = ''
    $size = [long]0
    try {
        $disp = [string]($resp.Headers['Content-Disposition'] | Select-Object -First 1)
        if ($disp -and $disp -match 'filename\*?=(?:UTF-8'''')?"?(?<n>[^";]+)"?') {
            $fileName = [System.Net.WebUtility]::UrlDecode($matches['n'].Trim())
        }
    } catch { }
    try {
        $len = [string]($resp.Headers['Content-Length'] | Select-Object -First 1)
        if ($len) { $size = [long]$len }
    } catch { }
    $final = ''
    try { $final = [string]$resp.BaseResponse.RequestMessage.RequestUri } catch { }
    if ([string]::IsNullOrWhiteSpace($fileName) -and $final) {
        try { $fileName = [IO.Path]::GetFileName(([Uri]$final).LocalPath) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $null }
    return [ordered]@{
        fileName    = $fileName
        sizeBytes   = $size
        resolvedUrl = $final
    }
}

function Update-AppEvalIsoCatalogCache {
    <#
    .SYNOPSIS
        Fetch every product page, parse, resolve, write the cache atomically.
        NETWORK: minutes of it - never call this on the dispatch thread, use
        Start-AppEvalIsoCatalogRefreshJob (child pwsh).
    #>
    param([string[]]$ProductIds = @())
    $wanted = @($ProductIds | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $products = [System.Collections.Generic.List[hashtable]]::new()
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $previous = Read-AppEvalIsoCache

    foreach ($product in $script:AppEvalIsoProducts) {
        $productId = [string]$product.id
        if ($wanted.Count -gt 0 -and $wanted -notcontains $productId) {
            # Not in this pass: carry the previous rows forward rather than dropping them.
            $keep = @()
            if ($previous) {
                $keep = @(@(Get-AppEvalIsoProp -Item $previous -Name 'entries') | Where-Object { [string](Get-AppEvalIsoProp -Item $_ -Name 'productId') -eq $productId })
                $prevProduct = @(@(Get-AppEvalIsoProp -Item $previous -Name 'products') | Where-Object { [string](Get-AppEvalIsoProp -Item $_ -Name 'id') -eq $productId })[0]
                if ($prevProduct) { [void]$products.Add((ConvertTo-AppEvalIsoHashtable -Item $prevProduct)) }
            }
            foreach ($k in $keep) { [void]$entries.Add((ConvertTo-AppEvalIsoHashtable -Item $k)) }
            continue
        }
        $page = $script:AppEvalIsoBaseUrl + [string]$product.slug
        $status = 'ok'
        $message = ''
        $html = ''
        try {
            $resp = Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = $script:AppEvalIsoPageAgent } -ErrorAction Stop
            $html = [string]$resp.Content
        } catch {
            $status = if ([bool]$product.probe) { 'not-published' } else { 'error' }
            $message = $_.Exception.Message
        }
        $rows = @()
        if ($html) {
            # arm64 is accepted on sight: Microsoft publishes no ARM evaluation ISO today
            # (checked 2026-08-22 - zero ARM anchors on every product page), but the parser
            # already classifies it, so the row appears by itself the day they do.
            $rows = @(ConvertFrom-AppEvalIsoPage -Html $html -ProductId $productId -ProductName ([string]$product.name) |
                Where-Object {
                    $_.media -eq 'ISO' -and ($_.arch -eq 'x64' -or $_.arch -eq 'arm64') -and $_.culture -ieq $script:AppEvalIsoCulture
                })
            if ($rows.Count -eq 0) {
                $status = if ([bool]$product.probe) { 'not-published' } else { 'unavailable' }
                if (-not $message) {
                    $message = if ([bool]$product.probe) {
                        'not published yet'
                    } else {
                        'Microsoft no longer offers an evaluation download on this page'
                    }
                }
            }
        }
        # NEVER BLANK (same policy as the driver catalogs): a page that fails to fetch, or
        # whose markup changed under us, must not delete downloads the panel was offering
        # a minute ago. Keep the previous rows and let staleness show instead of absence.
        # A product that genuinely has nothing (Windows 10, the probe rows) had nothing
        # cached either, so this only ever preserves real entries.
        if ($rows.Count -eq 0 -and $previous) {
            $kept = @(@(Get-AppEvalIsoProp -Item $previous -Name 'entries') |
                Where-Object { [string](Get-AppEvalIsoProp -Item $_ -Name 'productId') -eq $productId })
            if (@($kept).Count -gt 0) {
                foreach ($keptRow in $kept) { [void]$entries.Add((ConvertTo-AppEvalIsoHashtable -Item $keptRow)) }
                $status = 'kept'
                $message = "kept $(@($kept).Count) cached download(s) - this refresh found none ($message)"
                Write-SidecarLog "eval ISO: $($product.name) - keeping $(@($kept).Count) cached download(s); this refresh found none"
            }
        }
        foreach ($row in $rows) {
            $resolved = Resolve-AppEvalIsoDownload -Uri ([string]$row.url)
            $fileName = ''
            $size = [long]0
            $resolvedUrl = ''
            if ($resolved) {
                $fileName = [string]$resolved.fileName
                $size = [long]$resolved.sizeBytes
                $resolvedUrl = [string]$resolved.resolvedUrl
            }
            $release = Get-AppEvalIsoReleaseFromFileName -FileName $fileName
            [void]$entries.Add([ordered]@{
                id          = [string]$row.id
                productId   = [string]$row.productId
                productName = [string]$row.productName
                title       = [string]$row.title
                edition     = [string]$row.edition
                media       = [string]$row.media
                arch        = [string]$row.arch
                culture     = [string]$row.culture
                url         = [string]$row.url
                resolvedUrl = $resolvedUrl
                fileName    = $fileName
                sizeBytes   = $size
                build       = [string]$release.build
                release     = [string]$release.release
                page        = $page
            })
        }
        [void]$products.Add([ordered]@{
            id      = $productId
            name    = [string]$product.name
            kind    = [string]$product.kind
            probe   = [bool]$product.probe
            page    = $page
            status  = $status
            message = $message
            count   = $rows.Count
        })
        $reported = if ($status -eq 'kept') {
            @($entries | Where-Object { [string]$_['productId'] -eq $productId }).Count
        } else { $rows.Count }
        Write-SidecarLog "eval ISO: $($product.name) - $status ($reported download(s))"
    }

    $payload = [ordered]@{
        schema    = $script:AppEvalIsoCacheSchema
        fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        culture   = $script:AppEvalIsoCulture
        products  = @($products)
        entries   = @($entries)
    }
    $path = Write-AppEvalIsoCache -Payload $payload
    return [ordered]@{
        ok        = $true
        path      = $path
        products  = $products.Count
        entries   = $entries.Count
        fetchedAt = [string]$payload.fetchedAt
    }
}

function ConvertTo-AppEvalIsoHashtable {
    # ConvertFrom-Json gives PSCustomObjects; normalise so carried-forward rows and
    # freshly parsed rows are the same shape.
    param($Item)
    $out = [ordered]@{}
    if ($null -eq $Item) { return $out }
    if ($Item -is [System.Collections.IDictionary]) {
        foreach ($k in @($Item.Keys)) { $out[[string]$k] = $Item[$k] }
        return $out
    }
    foreach ($p in @($Item.PSObject.Properties)) { $out[[string]$p.Name] = $p.Value }
    return $out
}

function Get-AppEvalIsoCatalog {
    <#
    .SYNOPSIS
        Cache-only view for the UI: never touches the network, so it is safe on
        the dispatch thread. Adds live disk state (downloaded / local size) and
        says how old the cache is so the panel can offer a refresh.
    #>
    $cache = Read-AppEvalIsoCache
    $isoDir = $null
    try { $isoDir = (Get-AppImageLibraryPaths).isoDir } catch { $isoDir = $null }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    if ($cache) {
        $rows = @()
        $rows = @(Get-AppEvalIsoProp -Item $cache -Name 'entries')
        foreach ($row in $rows) {
            $entry = ConvertTo-AppEvalIsoHashtable -Item $row
            $fileName = [string]$entry['fileName']
            $localPath = if ($isoDir -and $fileName) { Join-Path $isoDir $fileName } else { $null }
            $have = [bool]($localPath -and (Test-Path -LiteralPath $localPath))
            $entry['downloaded'] = $have
            $entry['localSizeBytes'] = if ($have) { (Get-Item -LiteralPath $localPath).Length } else { [long]0 }
            [void]$entries.Add($entry)
        }
    }
    $products = @()
    if ($cache) {
        $products = @(@(Get-AppEvalIsoProp -Item $cache -Name 'products') | ForEach-Object { ConvertTo-AppEvalIsoHashtable -Item $_ })
    }
    if (@($products).Count -eq 0) { $products = @(Get-AppEvalIsoProducts) }

    $ageHours = Get-AppEvalIsoCacheAgeHours -Cache $cache
    [ordered]@{
        entries       = @($entries)
        products      = @($products)
        manualSources = @(Get-AppEvalIsoManualSources)
        cached      = [bool]$cache
        fetchedAt   = if ($cache) { [string](Get-AppEvalIsoProp -Item $cache -Name 'fetchedAt') } else { '' }
        ageHours    = $ageHours
        ttlHours    = $script:AppEvalIsoCacheHours
        stale       = [bool](-not $cache -or ($null -eq $ageHours) -or ($ageHours -ge $script:AppEvalIsoCacheHours))
        refreshing  = [bool]$script:AppEvalIsoRefreshJob
        isoDir      = [string]$isoDir
    }
}

$script:AppEvalIsoRefreshRunner = @'
param(
    [Parameter(Mandatory)][string]$SidecarRoot,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$Products = ''
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
    if (-not (Get-Command Write-SidecarLog -ErrorAction SilentlyContinue)) {
        function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
    }
    if (-not (Get-Command Write-SidecarLogVerbose -ErrorAction SilentlyContinue)) {
        function Write-SidecarLogVerbose { param([string]$Message) }
    }
    . (Join-Path $SidecarRoot 'lib/Aria2Plugin.ps1')
    . (Join-Path $SidecarRoot 'lib/EvalIsoCatalog.ps1')
    $list = @(($Products -split ',') | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $out = if ($list.Count -gt 0) { Update-AppEvalIsoCatalogCache -ProductIds $list } else { Update-AppEvalIsoCatalogCache }
    ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    (@{ error = $_.Exception.Message } | ConvertTo-Json) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
'@

function Start-AppEvalIsoCatalogRefreshJob {
    <#
    .SYNOPSIS
        Refresh in a child pwsh: seven page fetches plus a HEAD per download is
        minutes of network, and the dispatch loop is single-threaded.
    #>
    param(
        [string[]]$ProductIds = @(),
        [switch]$Automatic
    )
    if ($script:AppEvalIsoRefreshJob) {
        return @{ accepted = $true; background = $true; alreadyRunning = $true; automatic = [bool]$script:AppEvalIsoRefreshJob.automatic }
    }
    $stamp = [Guid]::NewGuid().ToString('N')
    $runnerPath = Join-Path ([IO.Path]::GetTempPath()) "$(Get-AppProductSlug)-eval-iso-refresh-$stamp.ps1"
    $resultPath = Join-Path ([IO.Path]::GetTempPath()) "$(Get-AppProductSlug)-eval-iso-refresh-$stamp.json"
    Set-Content -LiteralPath $runnerPath -Value $script:AppEvalIsoRefreshRunner -Encoding UTF8
    $pwsh = if ([string]::IsNullOrWhiteSpace([string][Environment]::ProcessPath)) { 'pwsh' } else { [string][Environment]::ProcessPath }
    $procArgs = @('-NoProfile', '-NonInteractive', '-File', $runnerPath, '-SidecarRoot', [string]$script:SidecarRoot, '-ResultPath', $resultPath)
    if (@($ProductIds).Count -gt 0) { $procArgs += @('-Products', (@($ProductIds) -join ',')) }
    $proc = Start-AppNativeProcess -FilePath $pwsh -Arguments $procArgs
    $script:AppEvalIsoRefreshJob = @{
        process    = $proc
        resultPath = $resultPath
        runnerPath = $runnerPath
        startedAt  = Get-Date
        automatic  = [bool]$Automatic
    }
    Write-SidecarLog "eval ISO: catalog refresh started (child pwsh$(if ($Automatic) { ', automatic' }))"
    @{ accepted = $true; background = $true; automatic = [bool]$Automatic }
}

function Sync-AppEvalIsoCatalogRefreshJob {
    # Housekeeping tick: reap the finished child, emit the completion event.
    $job = $script:AppEvalIsoRefreshJob
    if (-not $job) { return }
    $proc = $job.process
    if ($proc -and -not $proc.HasExited) {
        if (((Get-Date) - $job.startedAt).TotalMinutes -gt 15) {
            Write-SidecarLog 'eval ISO: catalog refresh watchdog kill (15 min)'
            try { $proc.Kill($true) } catch { }
        }
        return
    }
    $script:AppEvalIsoRefreshJob = $null
    $payload = $null
    try {
        if (Test-Path -LiteralPath $job.resultPath) {
            $payload = Get-Content -LiteralPath $job.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    } catch { $payload = $null }
    Remove-Item -LiteralPath $job.resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $job.runnerPath -Force -ErrorAction SilentlyContinue
    if (-not $payload) {
        Write-SidecarLog 'eval ISO: catalog refresh ended with no result'
        Write-SidecarEvent -EventName 'eval-iso-catalog-refresh' -Data @{ error = 'refresh process ended without a result (killed or crashed)'; automatic = [bool]$job.automatic }
        return
    }
    Write-SidecarLog "eval ISO: catalog refresh finished$(if ($job.automatic) { ' (automatic)' })"
    $payload | Add-Member -NotePropertyName automatic -NotePropertyValue ([bool]$job.automatic) -Force
    Write-SidecarEvent -EventName 'eval-iso-catalog-refresh' -Data $payload
}

function Stop-AppEvalIsoCatalogRefreshJob {
    $job = $script:AppEvalIsoRefreshJob
    if (-not $job) { return }
    $script:AppEvalIsoRefreshJob = $null
    try { if ($job.process -and -not $job.process.HasExited) { $job.process.Kill($true) } } catch { }
    Remove-Item -LiteralPath $job.resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $job.runnerPath -Force -ErrorAction SilentlyContinue
}

$script:AppEvalIsoAutoCheckLastEvalUtc = $null
$script:AppEvalIsoAutoCheckEveryMinutes = 30
$script:AppEvalIsoAutoCheckFirstDelayMinutes = 3
$script:AppEvalIsoAutoCheckStartedUtc = (Get-Date).ToUniversalTime()

function Start-AppEvalIsoCatalogRefreshIfDue {
    <#
    .SYNOPSIS
        Two-week policy on the housekeeping tick. The tick runs every ~50ms, so the
        decision is throttled hard: nothing at all for the first 3 minutes of a boot
        (the sidecar has better things to do), then at most one cache read every 30
        minutes. Quiet (automatic) so the panel just updates - no toasts.
    #>
    if ($script:AppEvalIsoRefreshJob) { return }
    $now = (Get-Date).ToUniversalTime()
    if (($now - $script:AppEvalIsoAutoCheckStartedUtc).TotalMinutes -lt $script:AppEvalIsoAutoCheckFirstDelayMinutes) { return }
    if ($script:AppEvalIsoAutoCheckLastEvalUtc -and
        ($now - $script:AppEvalIsoAutoCheckLastEvalUtc).TotalMinutes -lt $script:AppEvalIsoAutoCheckEveryMinutes) { return }
    $script:AppEvalIsoAutoCheckLastEvalUtc = $now
    $cache = Read-AppEvalIsoCache
    if ($cache) {
        $age = Get-AppEvalIsoCacheAgeHours -Cache $cache
        if ($null -ne $age -and $age -lt $script:AppEvalIsoCacheHours) { return }
    }
    Write-SidecarLog 'eval ISO: catalog is missing or older than two weeks - refreshing in the background'
    $null = Start-AppEvalIsoCatalogRefreshJob -Automatic
}

$script:AppEvalIsoPendingQueue = [System.Collections.Generic.List[string]]::new()

function Get-AppEvalIsoPendingQueue {
    @($script:AppEvalIsoPendingQueue)
}

function Clear-AppEvalIsoPendingQueue {
    $script:AppEvalIsoPendingQueue.Clear()
}

function Start-AppEvalIsoDownloadAll {
    <#
    .SYNOPSIS
        Queue every offered ISO that is not already in the store, ONE AT A TIME.
    .NOTES
        Deliberately sequential: six evaluation ISOs is ~35 GB, and six concurrent
        multi-GB streams on a school link means none of them finish. The first one
        starts now; Sync-AppEvalIsoDownloadQueue starts the next as each finishes.
    #>
    $catalog = Get-AppEvalIsoCatalog
    $wanted = @($catalog.entries | Where-Object {
            -not [bool]$_['downloaded'] -and -not [string]::IsNullOrWhiteSpace([string]$_['url'])
        })
    if (@($wanted).Count -eq 0) {
        return [ordered]@{ accepted = $true; started = 0; queued = 0; skipped = @($catalog.entries).Count; message = 'every offered ISO is already in the store' }
    }
    $script:AppEvalIsoPendingQueue.Clear()
    $first = $null
    foreach ($row in $wanted) {
        $id = [string]$row['id']
        if (-not $first) { $first = $id; continue }
        [void]$script:AppEvalIsoPendingQueue.Add($id)
    }
    $totalBytes = ($wanted | ForEach-Object { [long]$_['sizeBytes'] } | Measure-Object -Sum).Sum
    Write-SidecarLog "eval ISO: download all - $(@($wanted).Count) ISO(s), $([math]::Round($totalBytes / 1GB, 1)) GB, one at a time"
    $null = Start-AppEvalIsoDownload -Id $first
    return [ordered]@{
        accepted   = $true
        started    = 1
        queued     = $script:AppEvalIsoPendingQueue.Count
        totalBytes = [long]$totalBytes
        skipped    = @($catalog.entries).Count - @($wanted).Count
    }
}

function Sync-AppEvalIsoDownloadQueue {
    # Housekeeping tick: start the next queued ISO once no eval download is running.
    if ($script:AppEvalIsoPendingQueue.Count -eq 0) { return }
    if (-not (Test-AppSidecarCommand Test-AppAria2DirectDownloadActive)) { return }
    $catalog = Get-AppEvalIsoCatalog
    foreach ($row in @($catalog.entries)) {
        if (Test-AppAria2DirectDownloadActive -Key ("eval|$([string]$row['id'])")) { return }
    }
    $next = $script:AppEvalIsoPendingQueue[0]
    $script:AppEvalIsoPendingQueue.RemoveAt(0)
    # Someone may have fetched it by hand in the meantime.
    $row = @($catalog.entries | Where-Object { [string]$_['id'] -eq $next })[0]
    if ($row -and [bool]$row['downloaded']) {
        Write-SidecarLog "eval ISO: $next is already in the store - skipping the rest of its turn"
        return
    }
    try {
        $null = Start-AppEvalIsoDownload -Id $next
    } catch {
        Write-SidecarLog "eval ISO: queued download failed to start ($next) - $($_.Exception.Message)"
    }
}

function Start-AppEvalIsoDownload {
    <#
    .SYNOPSIS
        Queue an Evaluation Center ISO into the image library over the direct HTTP
        rail (works with the aria2 daemon stopped, emits driver-download-progress
        under the key eval|<id>, and promotes into Netboot's iso/ store on finish).
    #>
    param([Parameter(Mandatory)][string]$Id)

    $catalog = Get-AppEvalIsoCatalog
    $entry = @($catalog.entries | Where-Object { [string]$_['id'] -eq $Id })
    if ($entry.Count -eq 0) {
        if (-not $catalog.cached) {
            throw "Eval ISO: the catalog has not been fetched yet - use Check for updates first."
        }
        throw "Eval ISO: unknown id '$Id'."
    }
    $row = $entry[0]
    $url = [string]$row['url']
    if ([string]::IsNullOrWhiteSpace($url)) { throw "Eval ISO: no download URL for '$Id'." }
    $fileName = [string]$row['fileName']

    Write-SidecarLog "eval ISO: $($row['productName']) $($row['edition']) -> $url"
    return Add-AppAria2DirectHttpDownload `
        -Uris @($url) `
        -AssetKind 'iso' `
        -FileNameHint $fileName `
        -ProgressKey ("eval|$Id") `
        -TimeoutSec 21600
}
