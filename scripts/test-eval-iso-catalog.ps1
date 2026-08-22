#requires -Version 7.0
<#
.SYNOPSIS
    Offline gate for the Evaluation Center parser (no network).
.DESCRIPTION
    Evaluation Center markup changes without notice and the download anchors carry
    no visible identity - only an aria-label. The fixtures under
    scripts/fixtures/eval-iso/ are the real anchors captured 2026-08-22; if a future
    page shape breaks the parser, this fails offline instead of in the field.
    Live check: scripts/refresh-eval-iso-catalog.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
. (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $SidecarRoot 'lib/Aria2Plugin.ps1')
. (Join-Path $SidecarRoot 'lib/EvalIsoCatalog.ps1')

$fixtureDir = Join-Path $PSScriptRoot 'fixtures/eval-iso'
$failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "  [OK  ] $Name"
    } catch {
        Write-Host "  [FAIL] $Name - $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        $script:failures++
    }
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Get-Fixture { param([string]$Name) Get-Content -LiteralPath (Join-Path $fixtureDir $Name) -Raw }
function Get-Rows {
    param([string]$Fixture, [string]$ProductId, [string]$ProductName)
    ,@(ConvertFrom-AppEvalIsoPage -Html (Get-Fixture -Name $Fixture) -ProductId $ProductId -ProductName $ProductName)
}
# What Update-AppEvalIsoCatalogCache keeps: en-US, x64, ISO.
# NOTE the leading comma on both helpers: a function returning a one-element array
# unrolls it to the element, and .Count on a hashtable is its KEY count (9), which
# silently turned "1 offered row" into "9". Returning ,@(...) keeps the array.
function Select-Offered { param($Rows) ,@($Rows | Where-Object { $_.media -eq 'ISO' -and $_.arch -eq 'x64' -and $_.culture -ieq 'en-US' }) }

Write-Host 'Evaluation Center page parser:'

Test-Case 'Windows 11 page yields Enterprise + Enterprise LTSC (en-US x64 ISO)' {
    $offered = Select-Offered (Get-Rows -Fixture 'win11-enterprise.html' -ProductId 'win11' -ProductName 'Windows 11 Enterprise')
    Assert-True ($offered.Count -eq 2) "expected 2 offered rows, got $($offered.Count)"
    Assert-True (@($offered | Where-Object { $_.id -eq 'win11' -and $_.edition -eq 'Standard' }).Count -eq 1) 'missing the Enterprise row (id win11)'
    Assert-True (@($offered | Where-Object { $_.id -eq 'win11-ltsc' -and $_.edition -eq 'LTSC' }).Count -eq 1) 'missing the LTSC row (id win11-ltsc)'
}

Test-Case 'Other cultures are parsed but not offered' {
    $all = Get-Rows -Fixture 'win11-enterprise.html' -ProductId 'win11' -ProductName 'Windows 11 Enterprise'
    Assert-True ($all.Count -gt 2) 'expected the page to carry more than the two en-US rows'
    Assert-True (@($all | Where-Object { $_.culture -ieq 'en-GB' }).Count -ge 1) 'expected an en-GB row in the raw parse'
    Assert-True (@(Select-Offered $all | Where-Object { $_.culture -ine 'en-US' }).Count -eq 0) 'a non en-US row survived the offer filter'
}

foreach ($server in @(
    @{ file = 'server-2016.html'; id = 'srv2016'; name = 'Windows Server 2016' },
    @{ file = 'server-2019.html'; id = 'srv2019'; name = 'Windows Server 2019' },
    @{ file = 'server-2022.html'; id = 'srv2022'; name = 'Windows Server 2022' },
    @{ file = 'server-2025.html'; id = 'srv2025'; name = 'Windows Server 2025' }
)) {
    Test-Case "$($server.name) yields exactly one en-US x64 ISO" {
        $offered = Select-Offered (Get-Rows -Fixture $server.file -ProductId $server.id -ProductName $server.name)
        Assert-True ($offered.Count -eq 1) "expected 1 offered row, got $($offered.Count)"
        Assert-True ($offered[0].id -eq $server.id) "expected id $($server.id), got $($offered[0].id)"
        Assert-True ($offered[0].url -match '^https://go\.microsoft\.com/fwlink/') 'url is not an fwlink'
        Assert-True ($offered[0].url -notmatch '&#\d+;') 'HTML entities were not decoded in the url'
    }
}

Test-Case 'Server pages offer a VHD that never reaches the catalog' {
    $all = Get-Rows -Fixture 'server-2022.html' -ProductId 'srv2022' -ProductName 'Windows Server 2022'
    Assert-True (@($all | Where-Object { $_.media -eq 'VHD' }).Count -ge 1) 'expected a VHD row in the raw parse'
    Assert-True (@(Select-Offered $all | Where-Object { $_.media -ne 'ISO' }).Count -eq 0) 'a VHD row survived the offer filter'
}

Test-Case 'Windows 10 page parses to nothing (evaluation retired, not an error)' {
    $all = Get-Rows -Fixture 'win10-enterprise.html' -ProductId 'win10' -ProductName 'Windows 10 Enterprise'
    Assert-True ($all.Count -eq 0) "expected 0 rows, got $($all.Count)"
}

Test-Case 'An ARM64 row would be offered the day Microsoft publishes one' {
    # Microsoft ships no ARM64 evaluation ISO today (checked 2026-08-22), so this is a
    # synthetic anchor in their exact shape - it proves the parser and the offer filter
    # are already ready rather than needing a change later.
    $html = '<a aria-label="64-bit edition: Download Windows 11 Enterprise ISO ARM64 (en-US)" href="https://go.microsoft.com/fwlink/?linkid=9999999&clcid=0x409&culture=en-us&country=us">ARM64 edition</a>'
    $rows = @(ConvertFrom-AppEvalIsoPage -Html $html -ProductId 'win11' -ProductName 'Windows 11 Enterprise')
    Assert-True ($rows.Count -eq 1) "expected 1 row, got $($rows.Count)"
    Assert-True ($rows[0].arch -eq 'arm64') "arch was '$($rows[0].arch)'"
    Assert-True ($rows[0].id -eq 'win11-arm64') "id was '$($rows[0].id)'"
    # The catalog filter takes x64 OR arm64 (do not pipe a helper's ,@() result: an
    # EMPTY protected array is emitted as one object, and $_.arch then throws).
    $catalogFilter = @($rows | Where-Object { $_.media -eq 'ISO' -and ($_.arch -eq 'x64' -or $_.arch -eq 'arm64') -and $_.culture -ieq 'en-US' })
    Assert-True ($catalogFilter.Count -eq 1) 'the catalog filter should accept arm64'
}

Test-Case 'Media Microsoft only ships to consumers is listed as a manual source' {
    $manual = @(Get-AppEvalIsoManualSources)
    Assert-True ($manual.Count -ge 2) "expected at least 2 manual sources, got $($manual.Count)"
    Assert-True (@($manual | Where-Object { $_.id -eq 'win11-arm64' }).Count -eq 1) 'expected an ARM64 manual source'
    foreach ($m in $manual) { Assert-True ([string]$m.url -match '^https://') "bad url for $($m.id)" }
}

Test-Case 'Empty or junk HTML is tolerated' {
    Assert-True ((@(ConvertFrom-AppEvalIsoPage -Html '' -ProductId 'x' -ProductName 'x')).Count -eq 0) 'empty html should yield no rows'
    Assert-True ((@(ConvertFrom-AppEvalIsoPage -Html '<html><body><a href="https://example.com">hi</a></body></html>' -ProductId 'x' -ProductName 'x')).Count -eq 0) 'junk html should yield no rows'
}

Write-Host ''
Write-Host 'Release/build parsing from Microsoft file names:'
Test-Case 'Client eval file name yields build + release' {
    $r = Get-AppEvalIsoReleaseFromFileName -FileName '26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
    Assert-True ($r.build -eq '26200.6584') "build was '$($r.build)'"
    Assert-True ($r.release -eq '25H2') "release was '$($r.release)'"
}
Test-Case 'Server 2016 style file name yields a build' {
    $r = Get-AppEvalIsoReleaseFromFileName -FileName 'Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO'
    Assert-True ($r.build -eq '14393') "build was '$($r.build)'"
}
Test-Case 'Unparseable name yields blanks, not an error' {
    $r = Get-AppEvalIsoReleaseFromFileName -FileName 'something.iso'
    Assert-True ($r.build -eq '' -and $r.release -eq '') 'expected blank build/release'
}

Write-Host ''
Write-Host 'Product table:'
Test-Case 'Every product has a unique id and a page URL' {
    $products = @(Get-AppEvalIsoProducts)
    Assert-True ($products.Count -ge 6) "expected at least 6 products, got $($products.Count)"
    $ids = @($products | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    Assert-True ($ids.Count -eq $products.Count) 'duplicate product id'
    foreach ($p in $products) { Assert-True ([string]$p.page -match '^https://www\.microsoft\.com/en-us/evalcenter/') "bad page url for $($p.id)" }
}
Test-Case 'A future release is carried as a probe row' {
    Assert-True (@(Get-AppEvalIsoProducts | Where-Object { $_.probe }).Count -ge 1) 'expected at least one probe product (e.g. Windows 12)'
}

Write-Host ''
Write-Host 'Never blank:'
Test-Case 'A refresh that finds nothing keeps the cached downloads' {
    # Microsoft unreachable, or the markup changed under us: the panel must not lose the
    # downloads it was offering a minute ago. Same policy as the driver catalogs.
    $tmpHome = Join-Path ([IO.Path]::GetTempPath()) ("eval-nb-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmpHome -Force | Out-Null
    try {
        function Get-AppEvalIsoCachePath { Join-Path $tmpHome 'eval-iso-catalog.json' }
        $seed = [ordered]@{
            schema    = 1
            fetchedAt = '2026-08-01T00:00:00Z'
            products  = @([ordered]@{ id = 'srv2025'; name = 'Windows Server 2025'; kind = 'server'; probe = $false; page = 'https://example.invalid'; status = 'ok'; message = ''; count = 1 })
            entries   = @([ordered]@{ id = 'srv2025'; productId = 'srv2025'; productName = 'Windows Server 2025'; title = 'Windows Server 2025'; edition = 'Standard'; media = 'ISO'; arch = 'x64'; culture = 'en-US'; url = 'https://example.invalid/x'; resolvedUrl = ''; fileName = 'server2025.iso'; sizeBytes = 8GB; build = '26100'; release = ''; page = 'https://example.invalid' })
        }
        $null = Write-AppEvalIsoCache -Payload $seed
        function Invoke-WebRequest { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) throw 'simulated: network down' }
        $null = Update-AppEvalIsoCatalogCache
        $after = Read-AppEvalIsoCache
        $kept = @(@($after.entries) | Where-Object { [string]$_.productId -eq 'srv2025' })
        Assert-True ($kept.Count -eq 1) "expected the cached row to survive, got $($kept.Count)"
        Assert-True ([string]$kept[0].fileName -eq 'server2025.iso') "file name was '$($kept[0].fileName)'"
        $product = @(@($after.products) | Where-Object { [string]$_.id -eq 'srv2025' })[0]
        Assert-True ([string]$product.status -eq 'kept') "status was '$($product.status)'"
    } finally {
        Remove-Item -LiteralPath $tmpHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Download all (sequential queue):' 
# Stubs from here down - these override the real catalog/download rail on purpose, so
# keep this section last.
$script:fakeRows = @(
    [ordered]@{ id = 'win11'; productName = 'Windows 11 Enterprise'; edition = 'Standard'; url = 'https://example.invalid/1'; fileName = 'a.iso'; sizeBytes = 7GB; downloaded = $false }
    [ordered]@{ id = 'srv2025'; productName = 'Windows Server 2025'; edition = 'Standard'; url = 'https://example.invalid/2'; fileName = 'b.iso'; sizeBytes = 8GB; downloaded = $false }
    [ordered]@{ id = 'srv2022'; productName = 'Windows Server 2022'; edition = 'Standard'; url = 'https://example.invalid/3'; fileName = 'c.iso'; sizeBytes = 5GB; downloaded = $true }
)
function Get-AppEvalIsoCatalog { [ordered]@{ entries = @($script:fakeRows); cached = $true } }
$script:fakeActive = @{}
$script:fakeStarted = [System.Collections.Generic.List[string]]::new()
function Test-AppAria2DirectDownloadActive { param([string]$Key) [bool]$script:fakeActive[$Key] }
function Add-AppAria2DirectHttpDownload {
    param([string[]]$Uris, [string]$AssetKind = 'auto', [string]$ModelAlias, [string]$Vendor, [string]$Folder,
        [string]$FileNameHint, [int]$TimeoutSec = 7200, [string]$ProgressKey, [string]$ExpectedHash, [string]$ExpectedHashAlgorithm)
    [void]$script:fakeStarted.Add($ProgressKey)
    $script:fakeActive[$ProgressKey] = $true
    @{ accepted = $true; key = $ProgressKey }
}

Test-Case 'Download all starts one and queues the rest, skipping what is present' {
    Clear-AppEvalIsoPendingQueue
    $script:fakeStarted.Clear()
    $script:fakeActive = @{}
    $result = Start-AppEvalIsoDownloadAll
    Assert-True ($result.started -eq 1) "expected 1 started, got $($result.started)"
    Assert-True ($result.queued -eq 1) "expected 1 queued, got $($result.queued)"
    Assert-True ($result.skipped -eq 1) "expected the downloaded row to be skipped, got $($result.skipped)"
    Assert-True ($script:fakeStarted.Count -eq 1) 'more than one download was started at once'
    Assert-True ($script:fakeStarted[0] -eq 'eval|win11') "started '$($script:fakeStarted[0])'"
}

Test-Case 'A tick while a download runs does not start another' {
    Sync-AppEvalIsoDownloadQueue
    Assert-True ($script:fakeStarted.Count -eq 1) "a second download started while one was active ($($script:fakeStarted -join ', '))"
}

Test-Case 'The next ISO starts once the running one finishes' {
    $script:fakeActive['eval|win11'] = $false
    Sync-AppEvalIsoDownloadQueue
    Assert-True ($script:fakeStarted.Count -eq 2) "expected 2 started, got $($script:fakeStarted.Count)"
    Assert-True ($script:fakeStarted[1] -eq 'eval|srv2025') "started '$($script:fakeStarted[1])'"
    Assert-True ((@(Get-AppEvalIsoPendingQueue)).Count -eq 0) 'queue should be empty'
    Assert-True ($script:fakeStarted -notcontains 'eval|srv2022') 'an already-downloaded ISO was queued'
}

Test-Case 'Download all is a no-op when every ISO is already in the store' {
    foreach ($row in $script:fakeRows) { $row['downloaded'] = $true }
    $script:fakeStarted.Clear()
    $result = Start-AppEvalIsoDownloadAll
    Assert-True ($result.started -eq 0) "expected 0 started, got $($result.started)"
    Assert-True ($script:fakeStarted.Count -eq 0) 'a download was started with nothing to do'
    Assert-True ([string]$result.message -match 'already') 'expected an explanatory message'
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "eval ISO catalog: $failures failure(s)"
    exit 1
}
Write-Host 'eval ISO catalog: all checks passed'
exit 0
