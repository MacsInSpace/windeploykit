<#
.SYNOPSIS
    Assert the storage split: small/fixed data in app data, multi-GB data in the
    image library (the Deploy$ base). See AGENT_NOTES.md section 3b.

.DESCRIPTION
    USM filled an SSD by writing a ~60 GB WIM to %LOCALAPPDATA%. This check exists so
    that cannot happen here. Run it after touching Get-AppPxeBootLayoutPaths,
    Get-AppAria2EffectiveDownloadDir, or anything in AppPaths.ps1.

    Exits non-zero and names the offending path if any category lands on the wrong
    side of the boundary, so it is usable as a CI gate.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$script:AppSidecarProjectRoot = $projectRoot
$script:AppState = @{ RuntimeConfig = @{} }

# The libs log through the sidecar; stub when dot-sourced standalone.
if (-not (Get-Command Write-SidecarLog -ErrorAction SilentlyContinue)) {
    function Write-SidecarLog { param($Message) }
}
if (-not (Get-Command Write-SidecarLogVerbose -ErrorAction SilentlyContinue)) {
    function Write-SidecarLogVerbose { param($Message) }
}

. (Join-Path $projectRoot 'sidecar/lib/AppPaths.ps1')
. (Join-Path $projectRoot 'sidecar/lib/AppPlatform.ps1')
. (Join-Path $projectRoot 'sidecar/lib/Aria2Plugin.ps1')
. (Join-Path $projectRoot 'sidecar/lib/PxeBootPlugin.ps1')

$appData = Get-AppDataRoot
$paths = Get-AppPxeBootLayoutPaths
$lib = Get-AppImageLibraryPaths

# Small, fixed, machine-local - belongs in app data.
$mustBeAppData = [ordered]@{
    'tftpRoot'      = $paths.tftpRoot
    'bootWimDir'    = $paths.wimDir
    'wimboot'       = $paths.wimboot
    'snponlyEfi'    = $paths.snponlyEfi
}

# Multi-GB - must never touch the system-drive app-data tree.
$mustNotBeAppData = [ordered]@{
    'isoDir'          = $paths.isoDir
    'imageWimsDir'    = $paths.imageWimsDir
    'isoMountDir'     = $paths.isoMountDir
    'driversDir'      = $lib.driversDir
    'aria2DownloadDir' = Get-AppAria2EffectiveDownloadDir
}

Write-Host "app data root : $appData"
Write-Host "image library : $($lib.root)"
Write-Host ''

$failures = [System.Collections.Generic.List[string]]::new()

Write-Host 'small - must be under app data:'
foreach ($name in $mustBeAppData.Keys) {
    $value = [string]$mustBeAppData[$name]
    $ok = $value.StartsWith($appData, [StringComparison]::Ordinal)
    if (-not $ok) { [void]$failures.Add("$name must be under app data but is '$value'") }
    Write-Host ("  [{0}] {1,-18} {2}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $name, $value)
}

Write-Host ''
Write-Host 'large - must NOT be under app data:'
foreach ($name in $mustNotBeAppData.Keys) {
    $value = [string]$mustNotBeAppData[$name]
    $ok = -not $value.StartsWith($appData, [StringComparison]::Ordinal)
    if (-not $ok) { [void]$failures.Add("$name would put multi-GB data on the system drive: '$value'") }
    Write-Host ("  [{0}] {1,-18} {2}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $name, $value)
}

Write-Host ''
if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "VIOLATION: $f" }
    Write-Host "storage policy: $($failures.Count) violation(s) - see AGENT_NOTES.md section 3b"
    exit 1
}
Write-Host "storage policy holds ($($mustBeAppData.Count + $mustNotBeAppData.Count) paths checked)"
exit 0
