<#
.SYNOPSIS
    Vendor the two PowerShell modules behind the shared secret vault into
    vendor/psmodules/ and pin them.

.DESCRIPTION
    Implements the vendoring half of docs/handover/SHARED_SECRET_VAULT_CONTRACT.md
    section 5: PSGallery is unreachable behind the F5 and in CI, so Install-Module at
    runtime is not an option. Each module is fetched here, staged into
    vendor/psmodules/<Name>/<Version>/, and pinned in vendor/psmodules.lock.json with
    a SHA-256 per file.

    Two sources:
      gallery  Microsoft.PowerShell.SecretManagement (the API) - a nupkg from the
               PowerShell Gallery; the lock also records the nupkg hash.
      git      SecretManagement.LocalVault (the vault) - a TAGGED RELEASE of its own
               repository, https://github.com/MacsInSpace/SecretManagement.LocalVault.
               The lock records the tag and the commit it resolved to. Exported with
               `git archive`, so uncommitted edits in a local checkout never leak in.
    Microsoft.PowerShell.SecretStore was deliberately dropped (contract section 4a).

    House pattern, matching vendor/mdmkit: a sync script, a lockfile with exact
    versions, and a -VerifyOnly drift check that exits non-zero and names what moved.
    WinDeployKit and PSOpenAD-FE carry this same file; keep the copies identical.

.PARAMETER VerifyOnly
    Do not download. Re-hash what is vendored and compare against the lockfile.
    CI-friendly: exits 1 listing anything missing, changed or unpinned.

.PARAMETER LocalRepoRoot
    Directory holding sibling checkouts (default: the parent of this repo). When
    <LocalRepoRoot>/<repo name> exists and already has the pinned tag, the git
    module is exported from it instead of cloned - works offline and produces the
    identical lock, because the tag's commit is what gets recorded either way.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [string]$Gallery = 'https://www.powershellgallery.com/api/v2/package',
    [string]$LocalRepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$vendorRoot = Join-Path $projectRoot 'vendor/psmodules'
$lockPath = Join-Path $projectRoot 'vendor/psmodules.lock.json'
if (-not $LocalRepoRoot) { $LocalRepoRoot = Split-Path -Parent $projectRoot }

# Pinned deliberately, not floated. Bumping a version is an edit here plus a rerun,
# so the change shows up in review rather than arriving silently from upstream.
$modules = @(
    @{ Name = 'Microsoft.PowerShell.SecretManagement'; Version = '1.1.2'; Source = 'gallery' }
    @{ Name = 'SecretManagement.LocalVault'; Version = '1.0.2'; Source = 'git'
       Repo = 'https://github.com/MacsInSpace/SecretManagement.LocalVault.git'; Tag = 'v1.0.2'
       Subdir = 'SecretManagement.LocalVault' }
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

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
    return $out
}

function Export-GitModuleTo {
    <#
    .SYNOPSIS
        Materialise <Subdir> of <Repo> at <Tag> into $Dest. Prefers a sibling
        checkout that already has the tag; clones shallowly otherwise.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][string]$Staging,
        [Parameter(Mandatory)][string]$Dest
    )
    $repoName = (($Spec.Repo -split '/')[-1]) -replace '\.git$', ''
    $work = $null
    $sibling = Join-Path $LocalRepoRoot $repoName
    if (Test-Path -LiteralPath (Join-Path $sibling '.git')) {
        & git -C $sibling rev-parse --verify --quiet "refs/tags/$($Spec.Tag)^{commit}" *> $null
        if ($LASTEXITCODE -eq 0) {
            $work = $sibling
            Write-Host "    from sibling checkout $sibling"
        }
    }
    if (-not $work) {
        $work = Join-Path $Staging "$($Spec.Name)-src"
        Write-Host "    cloning $($Spec.Repo) at $($Spec.Tag)"
        $null = Invoke-Git -Arguments @('clone', '--quiet', '--depth', '1', '--branch', $Spec.Tag, $Spec.Repo, $work)
    }
    $commit = ([string](Invoke-Git -Arguments @('-C', $work, 'rev-list', '-n', '1', $Spec.Tag))).Trim()
    $zip = Join-Path $Staging "$($Spec.Name).zip"
    $null = Invoke-Git -Arguments @('-C', $work, 'archive', '--format=zip', '-o', $zip, $Spec.Tag, $Spec.Subdir)
    $extract = Join-Path $Staging "$($Spec.Name)-x"
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $src = Join-Path $extract $Spec.Subdir
    if (-not (Test-Path -LiteralPath $src)) { throw "$($Spec.Name): $($Spec.Subdir) not found in $($Spec.Repo) at $($Spec.Tag)" }

    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    $null = New-Item -Path $Dest -ItemType Directory -Force
    Copy-Item -Path (Join-Path $src '*') -Destination $Dest -Recurse -Force
    return $commit
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
        $dest = Join-Path (Join-Path $vendorRoot $name) $version
        Write-Host "  fetching $name $version ($($spec.Source))"

        $entry = [ordered]@{ version = $version }
        switch ($spec.Source) {
            'gallery' {
                $url = "$Gallery/$name/$version"
                $nupkg = Join-Path $staging "$name.$version.nupkg"
                Invoke-WebRequest -Uri $url -OutFile $nupkg -MaximumRedirection 5 -TimeoutSec 120 -ErrorAction Stop
                Expand-NupkgTo -Nupkg $nupkg -Dest $dest
                $entry['source'] = $url
                $entry['nupkgSha256'] = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash
            }
            'git' {
                $commit = Export-GitModuleTo -Spec $spec -Staging $staging -Dest $dest
                $entry['source'] = "$($spec.Repo)#$($spec.Tag)"
                $entry['commit'] = $commit
            }
            default { throw "${name}: unknown source '$($spec.Source)'" }
        }

        $manifest = Join-Path $dest "$name.psd1"
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw "${name} ${version}: expected module manifest ${name}.psd1 not found after extract"
        }
        $declared = [string](Import-PowerShellDataFile -Path $manifest).ModuleVersion
        if ($declared -ne $version) {
            throw "${name}: pinned ${version} but the manifest at that source says ${declared}"
        }

        $entry['files'] = Get-FileHashMap -Root $dest
        $lockModules[$name] = $entry
        Write-Host ("    staged {0} file(s)" -f $entry.files.Count)
    }

    $lock = [ordered]@{
        note    = 'Pinned by scripts/sync-secret-vault-modules.ps1. See docs/handover/SHARED_SECRET_VAULT_CONTRACT.md section 5.'
        license = 'MIT. Microsoft.PowerShell.SecretManagement (Microsoft) and SecretManagement.LocalVault (Craig Hair), redistributed unmodified.'
        modules = $lockModules
    }
    ($lock | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $lockPath -Encoding UTF8 -Force
    Write-Host "psmodules: vendored and pinned -> $lockPath"
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
