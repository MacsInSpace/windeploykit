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
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)"
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
if ($failures -gt 0) {
    Write-Host "eval ISO catalog: $failures failure(s)"
    exit 1
}
Write-Host 'eval ISO catalog: all checks passed'
exit 0
