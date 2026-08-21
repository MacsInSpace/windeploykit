<#
.SYNOPSIS
    Vendor Microsoft.PowerShell.SecretManagement into vendor/psmodules/ and pin it.

.DESCRIPTION
    Implements the vendoring half of docs/handover/SHARED_SECRET_VAULT_CONTRACT.md
    section 5: PSGallery is unreachable behind the F5 and in CI, so Install-Module at
    runtime is not an option. The module is downloaded here, staged into
    vendor/psmodules/<Name>/<Version>/, and pinned in vendor/psmodules.lock.json with
    a SHA-256 per file and per nupkg.

    Only SecretManagement (the API). The vault behind it is first-party -
    sidecar/psmodules/SecretManagement.LocalVault - so nothing else is vendored.
    Microsoft.PowerShell.SecretStore was deliberately dropped (contract section 4a).

    House pattern, matching vendor/mdmkit: a sync script, a lockfile with exact
    versions, and a -VerifyOnly drift check that exits non-zero and names what moved.
    Authored in WinDeployKit (scripts/sync-secret-vault-modules.ps1) and taken back
    here as runtime core; keep the two files identical.

.PARAMETER VerifyOnly
    Do not download. Re-hash what is vendored and compare against the lockfile.
    CI-friendly: exits 1 listing anything missing, changed or unpinned.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [string]$Gallery = 'https://www.powershellgallery.com/api/v2/package'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$vendorRoot = Join-Path $projectRoot 'vendor/psmodules'
$lockPath = Join-Path $projectRoot 'vendor/psmodules.lock.json'

# Pinned deliberately, not floated. Bumping a version is an edit here plus a rerun,
# so the change shows up in review rather than arriving silently from the gallery.
$modules = @(
    @{ Name = 'Microsoft.PowerShell.SecretManagement'; Version = '1.1.2' }
)

function Get-FileHashMap {
    param([Parameter(Mandatory)][string]$Root)
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Root)) { return $map }
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, '/')
        $rel = $rel -replace '\\', '/'
        $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Expand-NupkgTo {
    param(
        [Parameter(Mandatory)][string]$Nupkg,
        [Parameter(Mandatory)][string]$Dest
    )
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    $null = New-Item -Path $Dest -ItemType Directory -Force
    Expand-Archive -LiteralPath $Nupkg -DestinationPath $Dest -Force
    # NuGet packaging cruft - not part of the module.
    foreach ($junk in @('_rels', 'package', '[Content_Types].xml')) {
        $p = Join-Path $Dest $junk
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    Get-ChildItem -LiteralPath $Dest -Filter '*.nuspec' -File | Remove-Item -Force
}

if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $lockPath)) {
        Write-Host 'psmodules: DRIFT - no lockfile; run without -VerifyOnly to create it'
        exit 1
    }
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($spec in $modules) {
        $entry = $lock.modules.PSObject.Properties[$spec.Name]
        if (-not $entry) { [void]$problems.Add("$($spec.Name) is not in the lockfile"); continue }
        if ([string]$entry.Value.version -ne $spec.Version) {
            [void]$problems.Add("$($spec.Name) pinned $($entry.Value.version) but script wants $($spec.Version)")
        }
        $dir = Join-Path (Join-Path $vendorRoot $spec.Name) $spec.Version
        if (-not (Test-Path -LiteralPath $dir)) {
            [void]$problems.Add("$($spec.Name) $($spec.Version) is not vendored at $dir")
            continue
        }
        $actual = Get-FileHashMap -Root $dir
        $expected = $entry.Value.files
        foreach ($rel in $expected.PSObject.Properties.Name) {
            if (-not $actual.Contains($rel)) { [void]$problems.Add("$($spec.Name): missing $rel"); continue }
            if ($actual[$rel] -ne [string]$expected.$rel) { [void]$problems.Add("$($spec.Name): changed $rel") }
        }
        foreach ($rel in $actual.Keys) {
            if (-not $expected.PSObject.Properties[$rel]) { [void]$problems.Add("$($spec.Name): unpinned extra file $rel") }
        }
    }

    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Host "  DRIFT  $p" }
        Write-Host ("psmodules: {0} drift item(s)" -f $problems.Count)
        exit 1
    }
    Write-Host ("psmodules: OK ({0} modules pinned and unchanged)" -f $modules.Count)
    exit 0
}

$null = New-Item -Path $vendorRoot -ItemType Directory -Force
$lockModules = [ordered]@{}
$staging = Join-Path ([IO.Path]::GetTempPath()) ("psmod-sync-" + [guid]::NewGuid())
$null = New-Item -Path $staging -ItemType Directory -Force

try {
    foreach ($spec in $modules) {
        $name = $spec.Name
        $version = $spec.Version
        $url = "$Gallery/$name/$version"
        $nupkg = Join-Path $staging "$name.$version.nupkg"

        Write-Host "  fetching $name $version"
        Invoke-WebRequest -Uri $url -OutFile $nupkg -MaximumRedirection 5 -TimeoutSec 120 -ErrorAction Stop

        $nupkgHash = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash
        $dest = Join-Path (Join-Path $vendorRoot $name) $version
        Expand-NupkgTo -Nupkg $nupkg -Dest $dest

        $manifest = Join-Path $dest "$name.psd1"
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw "${name} ${version}: expected module manifest ${name}.psd1 not found after extract"
        }

        $lockModules[$name] = [ordered]@{
            version   = $version
            source    = $url
            nupkgSha256 = $nupkgHash
            files     = Get-FileHashMap -Root $dest
        }
        Write-Host ("    staged {0} file(s)" -f $lockModules[$name].files.Count)
    }

    $lock = [ordered]@{
        note    = 'Pinned by scripts/sync-secret-vault-modules.ps1. See docs/handover/SHARED_SECRET_VAULT_CONTRACT.md section 5.'
        license = 'MIT (Microsoft). Redistributed unmodified.'
        modules = $lockModules
    }
    ($lock | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $lockPath -Encoding UTF8 -Force
    Write-Host "psmodules: vendored and pinned -> $lockPath"
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
