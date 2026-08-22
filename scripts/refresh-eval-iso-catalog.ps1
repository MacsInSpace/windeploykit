#requires -Version 7.0
<#
.SYNOPSIS
    Refresh the Microsoft Evaluation Center catalog cache from the command line.
.DESCRIPTION
    Same code the app runs in its background child process. Useful to prove the
    parser against the LIVE pages after Microsoft changes their markup - the
    offline gate is scripts/test-eval-iso-catalog.ps1.
.PARAMETER Products
    Optional product ids to refresh (win11, win12, win10, srv2025, srv2022,
    srv2019, srv2016). Others keep their cached rows.
.PARAMETER ListOnly
    Print the current cache without touching the network.
.EXAMPLE
    pwsh -NoProfile -File scripts/refresh-eval-iso-catalog.ps1
    pwsh -NoProfile -File scripts/refresh-eval-iso-catalog.ps1 -Products win11,srv2025
#>
[CmdletBinding()]
param(
    [string[]]$Products = @(),
    [switch]$ListOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
. (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
function Write-SidecarLog { param([string]$Message, [switch]$Flush) Write-Host "  $Message" }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $SidecarRoot 'lib/Aria2Plugin.ps1')
. (Join-Path $SidecarRoot 'lib/EvalIsoCatalog.ps1')

Write-Host "cache: $(Get-AppEvalIsoCachePath)"
if (-not $ListOnly) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = if (@($Products).Count -gt 0) {
        Update-AppEvalIsoCatalogCache -ProductIds $Products
    } else {
        Update-AppEvalIsoCatalogCache
    }
    Write-Host "refreshed $($result.entries) download(s) across $($result.products) product(s) in $([int]$sw.Elapsed.TotalSeconds)s"
}

$catalog = Get-AppEvalIsoCatalog
Write-Host ''
Write-Host ("{0,-14} {1,-24} {2,-9} {3,-11} {4,10}  {5}" -f 'ID', 'PRODUCT', 'EDITION', 'RELEASE', 'SIZE', 'FILE')
foreach ($entry in @($catalog.entries)) {
    Write-Host ("{0,-14} {1,-24} {2,-9} {3,-11} {4,10}  {5}" -f
        $entry['id'],
        $entry['productName'],
        $entry['edition'],
        (@($entry['release'], $entry['build']) | Where-Object { $_ } | Select-Object -First 1),
        ('{0:N2} GB' -f ($entry['sizeBytes'] / 1GB)),
        $(if ($entry['downloaded']) { "[in Netboot] $($entry['fileName'])" } else { $entry['fileName'] }))
}
foreach ($product in @($catalog.products)) {
    if ([string]$product['status'] -and [string]$product['status'] -ne 'ok') {
        Write-Host ("  note: {0} - {1} ({2})" -f $product['name'], $product['status'], $product['message'])
    }
}
Write-Host ''
Write-Host "fetched $($catalog.fetchedAt) (age $($catalog.ageHours)h, ttl $($catalog.ttlHours)h, stale=$($catalog.stale))"
