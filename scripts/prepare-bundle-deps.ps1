#requires -Version 7.0
<#
.SYNOPSIS
    Stage sidecar, PS modules, and portable PowerShell for Tauri bundle (macOS or Windows).

.DESCRIPTION
    Writes to packaging/staged/:
      sidecar/      - copy of repo sidecar/
      modules/      - PSOpenAD + WinDeployKitPS.psm1 + Posh-SSH (when vendor/Posh-SSH present)
      powershell/   - full portable PowerShell 7 install (optional; -BundlePowerShell)

    Lo-Fi mini player tools (yt-dlp + deno) download at first play - not staged here.

    Run on the SAME OS you will use for `tauri build` (Windows build -> -Platform Windows).

    Release installer filenames (WinDeployKit_* under dist/) are set by
    package-macos.sh / package-windows.ps1 - not by this staging script.

.PARAMETER Platform
    Windows | MacOS | Host (auto-detect from $IsWindows / $IsMacOS)

.PARAMETER Arch
    x64 | arm64 | Host - CPU family for PowerShell download (Windows arm64 = Surface etc.)

.PARAMETER PwshVersion
    PowerShell release to download (default 7.5.4).

.PARAMETER BundlePowerShell
    Download and stage portable PowerShell (~250 MB). Default packaging expects
    pwsh 7 on PATH on each workstation instead.

.PARAMETER SkipPowerShell
    Alias for not bundling PowerShell (default for release builds).
#>
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'MacOS', 'Host')]
    [string] $Platform = 'Host',

    [ValidateSet('x64', 'arm64', 'Host')]
    [string] $Arch = 'Host',

    [string] $PwshVersion = '7.5.4',

    [string] $PsOpenAdSrc,

    [switch] $SkipPsOpenAdBuild,

    [switch] $SkipPoshSshVendor,

    [switch] $BundlePowerShell,

    [switch] $SkipPowerShell
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'lib/BuildDownload.ps1')
$Staged = Join-Path $RepoRoot 'packaging/staged'
$SidecarSrc = Join-Path $RepoRoot 'sidecar'
$PsModuleSrcDir = Join-Path $RepoRoot 'modules/WinDeployKitPS'
$PsModuleSrc = Join-Path $PsModuleSrcDir 'WinDeployKitPS.psm1'
$PwshStage = Join-Path $Staged 'powershell'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Remove-AppStagedFieldIsoBuildArtifacts {
    <#
    FieldIso.wim is downloaded at runtime (asset-feed manifest). wim-inject/ and Windows
    fieldiso/tools/*.exe are maintainer-only inputs for build-fieldiso-wim.sh - not for the app bundle.
    #>
    param([Parameter(Mandatory)][string]$SidecarDest)

    $wimInject = Join-Path $SidecarDest 'pxe/fieldiso/wim-inject'
    if (Test-Path -LiteralPath $wimInject) {
        Remove-Item -LiteralPath $wimInject -Recurse -Force
        Write-Step 'Excluded sidecar/pxe/fieldiso/wim-inject from staged bundle (FieldIso build artifact only)'
    }

    $toolsDir = Join-Path $SidecarDest 'pxe/fieldiso/tools'
    if (Test-Path -LiteralPath $toolsDir) {
        $removed = 0
        foreach ($tool in Get-ChildItem -LiteralPath $toolsDir -File -ErrorAction SilentlyContinue) {
            if ($tool.Extension -match '^\.(exe|dll)$') {
                Remove-Item -LiteralPath $tool.FullName -Force
                $removed++
            }
        }
        if ($removed -gt 0) {
            Write-Step "Excluded $removed Windows fieldiso/tools binary(ies) from staged bundle"
        }
    }
}

function Assert-AppStagedEmailSignatureBanners {
    param(
        [Parameter(Mandatory)][string]$SidecarSrc,
        [Parameter(Mandatory)][string]$SidecarDest
    )

    $srcManifest = Join-Path $SidecarSrc 'templates/email/banners/manifest.json'
    if (-not (Test-Path -LiteralPath $srcManifest)) {
        throw @"
Email signature banners missing from repo sidecar.
Expected: $srcManifest
Add banners under sidecar/templates/email/banners/ (see docs/tools/email-notify/AGENT_NOTES_EMAIL_NOTIFY.md).
"@
    }

    $destBanners = Join-Path $SidecarDest 'templates/email/banners'
    $destManifest = Join-Path $destBanners 'manifest.json'
    if (-not (Test-Path -LiteralPath $destManifest)) {
        throw @"
Email signature banners were not copied into the staged sidecar.
Expected: $destManifest
"@
    }

    $raw = Get-Content -LiteralPath $destManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $expected = @($raw.banners).Count
    if ($expected -lt 1) {
        throw "Email signature banner manifest has no entries: $destManifest"
    }

    $missing = @($raw.banners | ForEach-Object {
        $file = Join-Path $destBanners ([string]$_.filename)
        if (-not (Test-Path -LiteralPath $file)) { [string]$_.filename }
    } | Where-Object { $_ })

    if ($missing.Count -gt 0) {
        $sample = ($missing | Select-Object -First 5) -join ', '
        throw "Staged email signature banners missing $($missing.Count) file(s): $sample"
    }

    Write-Step "Verified $expected DE email signature banners in staged sidecar/templates/email/banners/"
}

function Stage-AppPxeVendorBinaries {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Staged,
        [Parameter(Mandatory)][string]$Platform
    )

    if ($Platform -eq 'MacOS') {
        $universal = Join-Path $RepoRoot 'vendor/binaries/pxe-macos/dnsmasq-universal'
        $destDir = Join-Path $Staged 'binaries'
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        if (Test-Path -LiteralPath $universal) {
            Copy-Item -LiteralPath $universal -Destination (Join-Path $destDir 'dnsmasq-universal') -Force
            Write-Step 'Staged vendored dnsmasq-universal (Netboot TFTP)'
        } else {
            Write-Warning "Vendored dnsmasq missing: $universal - run ./scripts/build-dnsmasq-macos.sh"
        }
        $wimlibUni = Join-Path $RepoRoot 'vendor/binaries/pxe-macos/wimlib-imagex-universal'
        if (Test-Path -LiteralPath $wimlibUni) {
            Copy-Item -LiteralPath $wimlibUni -Destination (Join-Path $destDir 'wimlib-imagex-universal') -Force
            Write-Step 'Staged vendored wimlib-imagex-universal (Netboot boot assets)'
        } else {
            Write-Warning "Vendored wimlib missing: $wimlibUni - run ./scripts/fetch-wimlib.ps1"
        }
        $dialogUni = Join-Path $RepoRoot 'vendor/binaries/dialog-macos/windeploykit-dialog-universal'
        if (Test-Path -LiteralPath $dialogUni) {
            Copy-Item -LiteralPath $dialogUni -Destination (Join-Path $destDir 'windeploykit-dialog-universal') -Force
            Write-Step 'Staged vendored windeploykit-dialog-universal (native admin/password prompts)'
        } else {
            Write-Warning "Vendored windeploykit-dialog missing: $dialogUni - run ./scripts/build-windeploykit-dialog.sh (osascript fallback will be used)"
        }
        return
    }

    if ($Platform -eq 'Windows') {
        # tauri.conf.json always maps packaging/staged/binaries/ - directory must exist even when
        # optional PXE tools are absent (no Windows dnsmasq; wimlib fetched separately).
        $destDir = Join-Path $Staged 'binaries'
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        $src = Join-Path $RepoRoot 'vendor/binaries/pxe-windows/dnsmasq.exe'
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warning "Vendored Windows dnsmasq missing: $src - Netboot uses Tftpd64 on Windows (see vendor/binaries/pxe-windows/README.md)"
        } else {
            Copy-Item -LiteralPath $src -Destination (Join-Path $destDir 'dnsmasq.exe') -Force
            Write-Step 'Staged vendored dnsmasq.exe (Netboot TFTP fallback)'
        }
        $wimlibSrc = Join-Path $RepoRoot 'vendor/binaries/pxe-windows/wimlib'
        if (-not (Test-Path -LiteralPath $wimlibSrc)) {
            Write-Warning "Vendored Windows wimlib missing: $wimlibSrc - run pwsh -File ./scripts/fetch-wimlib.ps1 (optional; Netboot boot-asset extraction)"
            return
        }
        $wimlibDest = Join-Path $destDir 'wimlib'
        if (Test-Path -LiteralPath $wimlibDest) {
            Remove-Item -LiteralPath $wimlibDest -Recurse -Force
        }
        Copy-Item -LiteralPath $wimlibSrc -Destination $wimlibDest -Recurse -Force
        Write-Step 'Staged vendored wimlib-imagex (Netboot boot assets)'
    }
}

function Stage-AppIntuneVendorBinaries {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Staged,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$Arch,
        [Parameter(Mandatory)][string]$SidecarDest
    )

    if ($Platform -eq 'MacOS') {
        $suffix = if ($Arch -eq 'arm64') { 'aarch64-apple-darwin' } else { 'x86_64-apple-darwin' }
        $src = Join-Path $RepoRoot "vendor/binaries/intune-macos/$name"
        if (-not (Test-Path -LiteralPath $src)) {
            return
        }
        $destDir = Join-Path $Staged 'binaries'
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            Remove-Item -Force
        Copy-Item -LiteralPath $src -Destination (Join-Path $destDir $name) -Force
        Write-Step "Staged vendored Intune macOS packager: $name"
        return
    }

    if ($Platform -eq 'Windows') {
        if (-not (Test-Path -LiteralPath $src)) {
            return
        }
        $toolsDir = Join-Path $SidecarDest 'tools'
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }
}

function Test-AppVendoredPoshSshLayout {
    param([Parameter(Mandatory)][string]$VendorPoshSshRoot)
    if (-not (Test-Path -LiteralPath $VendorPoshSshRoot)) { return $false }
    return [bool](
        Get-ChildItem -LiteralPath $VendorPoshSshRoot -Filter 'Posh-SSH.psd1' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    )
}

function Normalize-AppVendoredPoshSshLayout {
    <#
        Save-Module writes vendor/Posh-SSH/<version>/Posh-SSH.psd1 - flatten to vendor/Posh-SSH/Posh-SSH.psd1
        so staging matches PSOpenAD (direct manifest under modules/Posh-SSH).
    #>
    param([Parameter(Mandatory)][string]$VendorPoshSshRoot)

    $direct = Join-Path $VendorPoshSshRoot 'Posh-SSH.psd1'
    if (Test-Path -LiteralPath $direct) { return $direct }

    $nested = Get-ChildItem -LiteralPath $VendorPoshSshRoot -Filter 'Posh-SSH.psd1' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object { $_.Directory.Name } -Descending |
        Select-Object -First 1
    if (-not $nested) { return $null }

    $versionDir = $nested.Directory.FullName
    Get-ChildItem -LiteralPath $versionDir -Force | ForEach-Object {
        $dest = Join-Path $VendorPoshSshRoot $_.Name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
    if ($versionDir -ne $VendorPoshSshRoot) {
        Remove-Item -LiteralPath $versionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $direct
}

function Ensure-AppVendoredPoshSsh {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $vendorRoot = Join-Path $RepoRoot 'vendor'
    $vendorMod = Join-Path $vendorRoot 'Posh-SSH'
    if (Test-AppVendoredPoshSshLayout -VendorPoshSshRoot $vendorMod) {
        Normalize-AppVendoredPoshSshLayout -VendorPoshSshRoot $vendorMod | Out-Null
        return $vendorMod
    }

    if ($SkipPoshSshVendor) { return $null }

    Write-Step 'vendor/Posh-SSH missing - saving from PSGallery for bundle staging'
    if (-not (Test-Path -LiteralPath $vendorRoot)) {
        New-Item -ItemType Directory -Path $vendorRoot -Force | Out-Null
    }
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $gallery) {
        Register-PSRepository -Default -ErrorAction SilentlyContinue
    }
    Save-Module -Name Posh-SSH -Path $vendorRoot -Force -Repository PSGallery
    $manifest = Normalize-AppVendoredPoshSshLayout -VendorPoshSshRoot $vendorMod
    if (-not $manifest -or -not (Test-Path -LiteralPath $manifest)) {
        throw "Save-Module did not produce Posh-SSH.psd1 under $vendorMod"
    }
    $ver = (Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion
    Write-Step "Posh-SSH $ver saved under vendor/Posh-SSH"
    return $vendorMod
}

if ($Platform -eq 'Host') {
    if ($IsWindows) { $Platform = 'Windows' }
    elseif ($IsMacOS) { $Platform = 'MacOS' }
    else { throw 'Could not detect OS. Pass -Platform Windows or MacOS.' }
}

if ($Arch -eq 'Host') {
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        $Arch = 'arm64'
    }
    else {
        $Arch = 'x64'
    }
}

$VendorPsOpenAd = Join-Path $RepoRoot 'vendor/PSOpenAD'
$VendorManifest = Join-Path $VendorPsOpenAd 'PSOpenAD.psd1'
$BuildPsOpenAdScript = Join-Path $RepoRoot 'scripts/build-psopenad.ps1'

if (-not $PsOpenAdSrc) {
    if (Test-Path -LiteralPath $VendorManifest) {
        $PsOpenAdSrc = $VendorPsOpenAd
    }
    elseif (-not $SkipPsOpenAdBuild -and (Test-Path -LiteralPath $BuildPsOpenAdScript)) {
        Write-Step 'vendor/PSOpenAD missing - building from vendor/psopenad.lock.json (requires git + dotnet SDK)'
        & $BuildPsOpenAdScript
        if (Test-Path -LiteralPath $VendorManifest) {
            $PsOpenAdSrc = $VendorPsOpenAd
        }
    }
}
if (-not $PsOpenAdSrc) {
    $PsOpenAdSrc = (Get-Module -ListAvailable PSOpenAD | Select-Object -First 1).ModuleBase
}
if (-not $PsOpenAdSrc -or -not (Test-Path -LiteralPath (Join-Path $PsOpenAdSrc 'PSOpenAD.psd1'))) {
    throw @"
PSOpenAD not found for bundling.

Preferred (CI / release):
  CI job build:psopenad, or locally:
  pwsh -File ./scripts/build-psopenad.ps1

Then re-run prepare-bundle-deps.ps1 (uses vendor/PSOpenAD automatically).

Fallback: Install-Module PSOpenAD -Scope CurrentUser -Force
Or pass -PsOpenAdSrc 'C:\path\to\built\PSOpenAD'
"@
}

if (-not (Test-Path -LiteralPath $PsModuleSrc)) {
    Write-Warning "Optional bundled module not present, skipping: $PsModuleSrc"
}

Write-Step "Platform=$Platform Arch=$Arch"

Write-Step 'Staging sidecar'
$sidecarDest = Join-Path $Staged 'sidecar'
New-Item -ItemType Directory -Path $Staged -Force | Out-Null
if (Test-Path -LiteralPath $sidecarDest) {
    try {
        Remove-Item -LiteralPath $sidecarDest -Recurse -Force -ErrorAction Stop
    }
    catch {
        $staleRoot = Join-Path $Staged 'stale'
        New-Item -ItemType Directory -Path $staleRoot -Force | Out-Null
        $staleName = 'sidecar-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        $stalePath = Join-Path $staleRoot $staleName
        try {
            Move-Item -LiteralPath $sidecarDest -Destination $stalePath -Force -ErrorAction Stop
            Write-Step "Previous staged sidecar could not be removed; moved aside to $stalePath"
        }
        catch {
            throw "Could not clear generated sidecar staging folder '$sidecarDest'. Remove or move it manually, then retry. $($_.Exception.Message)"
        }
    }
}

# Optional: bundle snponly.efi from sibling ipxeboot build into sidecar/pxe/
$pxeBundledDir = Join-Path $SidecarSrc 'pxe'
$pxeBundledEfi = Join-Path $pxeBundledDir 'snponly.efi'
if (-not (Test-Path -LiteralPath $pxeBundledEfi)) {
    $ipxeSnponlyCandidates = @(
        (Join-Path (Split-Path $RepoRoot -Parent) 'ipxeboot/src/bin-x86_64-efi/snponly.efi')
        (Join-Path (Split-Path $RepoRoot -Parent) 'ipxeboot/contrib/deploy-menu/out/tftp/snponly.efi')
    )
    foreach ($candidate in $ipxeSnponlyCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            if (-not (Test-Path -LiteralPath $pxeBundledDir)) {
                New-Item -ItemType Directory -Path $pxeBundledDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $candidate -Destination $pxeBundledEfi -Force
            Write-Step "Bundled snponly.efi from $candidate"
            break
        }
    }
}

$pxeBundledWimboot = Join-Path $pxeBundledDir 'wimboot'
$vendorWimboot = Join-Path $RepoRoot 'vendor/binaries/pxe-wimboot/wimboot'
if (Test-Path -LiteralPath $vendorWimboot) {
    if (-not (Test-Path -LiteralPath $pxeBundledDir)) {
        New-Item -ItemType Directory -Path $pxeBundledDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $vendorWimboot -Destination $pxeBundledWimboot -Force
    Write-Step 'Bundled wimboot from vendor/binaries/pxe-wimboot/'
} elseif (-not (Test-Path -LiteralPath $pxeBundledWimboot)) {
    Write-Warning 'wimboot missing - run pwsh -File ./scripts/fetch-wimboot.ps1 before release packaging'
}

$pxeSbBundled = Join-Path $pxeBundledDir 'x86_64-sb'
$vendorSb = Join-Path $RepoRoot 'vendor/binaries/pxe-secure-boot-x64/x86_64-sb'
if (Test-Path -LiteralPath (Join-Path $vendorSb 'shimx64.efi') -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $pxeBundledDir)) {
        New-Item -ItemType Directory -Path $pxeBundledDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $pxeSbBundled) {
        Remove-Item -LiteralPath $pxeSbBundled -Recurse -Force
    }
    Copy-Item -LiteralPath $vendorSb -Destination $pxeSbBundled -Recurse -Force
    Write-Step 'Bundled Secure Boot TFTP tree from vendor/binaries/pxe-secure-boot-x64/x86_64-sb'
} elseif (-not (Test-Path -LiteralPath (Join-Path $pxeSbBundled 'shimx64.efi') -PathType Leaf)) {
    $ipxeSbCandidates = @(
        (Join-Path (Split-Path $RepoRoot -Parent) 'ipxeboot/contrib/deploy-menu/out/tftp/x86_64-sb')
    )
    foreach ($candidate in $ipxeSbCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'shimx64.efi') -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $pxeBundledDir)) {
                New-Item -ItemType Directory -Path $pxeBundledDir -Force | Out-Null
            }
            if (Test-Path -LiteralPath $pxeSbBundled) {
                Remove-Item -LiteralPath $pxeSbBundled -Recurse -Force
            }
            Copy-Item -LiteralPath $candidate -Destination $pxeSbBundled -Recurse -Force
            Write-Step "Bundled Secure Boot TFTP tree from $candidate"
            break
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $pxeSbBundled 'shimx64.efi') -PathType Leaf)) {
        Write-Warning 'Secure Boot TFTP tree missing - run pwsh -File ./scripts/fetch-pxe-secure-boot.ps1 before release packaging'
    }
}

$pxeBundledMdtDir = Join-Path $pxeBundledDir 'mdt-boot-x64'
$vendorMdtDir = Join-Path $RepoRoot 'vendor/binaries/pxe-mdt-boot/x64'
if (Test-Path -LiteralPath (Join-Path $vendorMdtDir 'BCD')) {
    if (-not (Test-Path -LiteralPath $pxeBundledDir)) {
        New-Item -ItemType Directory -Path $pxeBundledDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $pxeBundledMdtDir)) {
        New-Item -ItemType Directory -Path $pxeBundledMdtDir -Force | Out-Null
    }
    foreach ($mdtFile in @('BCD', 'boot.sdi', 'bootmgfw.efi')) {
        Copy-Item -LiteralPath (Join-Path $vendorMdtDir $mdtFile) -Destination (Join-Path $pxeBundledMdtDir $mdtFile) -Force
    }
    Write-Step 'Bundled MDT boot assets from vendor/binaries/pxe-mdt-boot/x64'
} elseif (-not (Test-Path -LiteralPath (Join-Path $pxeBundledMdtDir 'BCD'))) {
    Write-Warning 'MDT boot assets missing - run pwsh -File ./scripts/fetch-mdt-boot-assets.ps1 before release packaging (LiteTouch wimboot)'
}

Copy-Item -LiteralPath $SidecarSrc -Destination $sidecarDest -Recurse -Force
Remove-AppStagedFieldIsoBuildArtifacts -SidecarDest $sidecarDest
Assert-AppStagedEmailSignatureBanners -SidecarSrc $SidecarSrc -SidecarDest $sidecarDest

$fieldTestSrc = Join-Path $RepoRoot 'scripts/test-bootstrap-field.ps1'
if (-not (Test-Path -LiteralPath $fieldTestSrc)) {
    throw "Bootstrap field test script missing: $fieldTestSrc"
}
$fieldTestDestDir = Join-Path $sidecarDest 'scripts'
New-Item -ItemType Directory -Path $fieldTestDestDir -Force | Out-Null
Copy-Item -LiteralPath $fieldTestSrc -Destination (Join-Path $fieldTestDestDir 'test-bootstrap-field.ps1') -Force
Write-Step 'Copied test-bootstrap-field.ps1 into staged sidecar/scripts'

$eduHubApiSrc = Join-Path $RepoRoot 'scripts/eduHubAPI_server.ps1'
if (-not (Test-Path -LiteralPath $eduHubApiSrc)) {
    throw "eduHub AFS gateway script missing: $eduHubApiSrc"
}
Copy-Item -LiteralPath $eduHubApiSrc -Destination (Join-Path $fieldTestDestDir 'eduHubAPI_server.ps1') -Force
Write-Step 'Copied eduHubAPI_server.ps1 into staged sidecar/scripts'

$eduHubModuleSrc = Join-Path $RepoRoot 'scripts/eduHubAPI_module.psm1'
if (-not (Test-Path -LiteralPath $eduHubModuleSrc)) {
    throw "eduHub client module missing: $eduHubModuleSrc"
}
Copy-Item -LiteralPath $eduHubModuleSrc -Destination (Join-Path $fieldTestDestDir 'eduHubAPI_module.psm1') -Force
Write-Step 'Copied eduHubAPI_module.psm1 into staged sidecar/scripts'

# eduHub CSV data module (pwsh 7 - parse/join/match) - Import-AppEduHubModule resolves it at
# sidecar/scripts/eduHub/EduHubData.psm1 in installed builds (scripts/eduHub/ in dev checkouts).
# Field bug 2026-07-23: it was never staged, so every installed build threw
# "eduHub module not found: ...\scripts\eduHub\EduHubData.psm1".
$eduHubDataSrc = Join-Path $RepoRoot 'scripts/eduHub/EduHubData.psm1'
if (-not (Test-Path -LiteralPath $eduHubDataSrc)) {
    throw "eduHub data module missing: $eduHubDataSrc"
}
$eduHubDataDestDir = Join-Path $fieldTestDestDir 'eduHub'
New-Item -ItemType Directory -Path $eduHubDataDestDir -Force | Out-Null
Copy-Item -LiteralPath $eduHubDataSrc -Destination (Join-Path $eduHubDataDestDir 'EduHubData.psm1') -Force
Write-Step 'Copied EduHubData.psm1 into staged sidecar/scripts/eduHub'

$mergeScript = Join-Path $RepoRoot 'scripts/merge-infrastructure-manifests.ps1'
if (Test-Path -LiteralPath $mergeScript) {
    & $mergeScript | Out-Null
}
$manifestSrc = Join-Path $RepoRoot 'packaging/infrastructure-manifest.json'
if (-not (Test-Path -LiteralPath $manifestSrc)) {
    throw "Infrastructure manifest missing: $manifestSrc"
}
Copy-Item -LiteralPath $manifestSrc -Destination (Join-Path $sidecarDest 'infrastructure-manifest.json') -Force
Write-Step 'Copied infrastructure-manifest.json into staged sidecar'

$aria2PackagingDest = Join-Path $sidecarDest 'packaging'
New-Item -ItemType Directory -Path $aria2PackagingDest -Force | Out-Null
$aria2TrackerSrc = Join-Path $RepoRoot 'packaging/aria2-tracker.json'
if (Test-Path -LiteralPath $aria2TrackerSrc) {
    Copy-Item -LiteralPath $aria2TrackerSrc -Destination (Join-Path $aria2PackagingDest 'aria2-tracker.json') -Force
}
$aria2ToolsSrc = Join-Path $RepoRoot 'packaging/aria2-tools.json'
if (Test-Path -LiteralPath $aria2ToolsSrc) {
    Copy-Item -LiteralPath $aria2ToolsSrc -Destination (Join-Path $aria2PackagingDest 'aria2-tools.json') -Force
    Write-Step 'Copied aria2-tools.json into staged sidecar/packaging (offline binary manifest fallback)'
}
$aria2TorrentsSrc = Join-Path $RepoRoot 'packaging/torrents'
$aria2TorrentsDest = Join-Path $aria2PackagingDest 'torrents'
if (Test-Path -LiteralPath $aria2TorrentsSrc) {
    if (Test-Path -LiteralPath $aria2TorrentsDest) { Remove-Item -LiteralPath $aria2TorrentsDest -Recurse -Force }
    Copy-Item -LiteralPath $aria2TorrentsSrc -Destination $aria2TorrentsDest -Recurse -Force
    Write-Step 'Copied aria2 DE torrent catalog into staged sidecar/packaging/torrents'
}
foreach ($driverCatalog in @('acer-sccm-catalog.json', 'lenovo-sccm-catalog.json', 'dell-sccm-catalog.json', 'hp-sccm-catalog.json', 'microsoft-sccm-catalog.json')) {
    $src = Join-Path $RepoRoot "packaging/$driverCatalog"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $aria2PackagingDest $driverCatalog) -Force
        Write-Step "Copied $driverCatalog into staged sidecar/packaging"
    }
}

Write-Step "Staging PSOpenAD from $PsOpenAdSrc"
$openAdDest = Join-Path $Staged 'modules/PSOpenAD'
if (Test-Path -LiteralPath $openAdDest) { Remove-Item -LiteralPath $openAdDest -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $Staged 'modules') -Force | Out-Null
Copy-Item -LiteralPath $PsOpenAdSrc -Destination $openAdDest -Recurse -Force

Write-Step 'Staging WinDeployKitPS (core + full)'
$psModuleDest = Join-Path $Staged 'modules/WinDeployKitPS'
if (Test-Path -LiteralPath $psModuleDest) { Remove-Item -LiteralPath $psModuleDest -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $Staged 'modules') -Force | Out-Null
if (-not (Test-Path -LiteralPath $PsModuleSrcDir)) {
    throw "WinDeployKitPS module dir missing: $PsModuleSrcDir"
}
Copy-Item -LiteralPath $PsModuleSrcDir -Destination $psModuleDest -Recurse -Force
# Monolith archive is optional - omit from release bundle to save space
$monolith = Join-Path $psModuleDest 'WinDeployKitPS.Monolith.psm1'
if (Test-Path -LiteralPath $monolith) {
    Remove-Item -LiteralPath $monolith -Force
}

# Shared secret vault - Microsoft.PowerShell.SecretManagement (the API) and
# SecretManagement.LocalVault (the vault, a tagged release of its own repository),
# both vendored under vendor/psmodules by scripts/sync-secret-vault-modules.ps1 and
# pinned by SHA-256. Staged as modules/<Name>/<Version>/ so PowerShell's
# versioned-folder discovery finds them on the bundled PSModulePath.
# Drift from the lockfile fails the build: a tampered or half-synced module must
# not ship in front of every credential the app holds.
Write-Step 'Verifying vendor/psmodules against psmodules.lock.json'
$psmodVerify = Join-Path $RepoRoot 'scripts/sync-secret-vault-modules.ps1'
& pwsh -NoProfile -File $psmodVerify -VerifyOnly
if ($LASTEXITCODE -ne 0) {
    throw "vendor/psmodules drifted from vendor/psmodules.lock.json (see DRIFT lines above). Fix: pwsh ./scripts/sync-secret-vault-modules.ps1  (then commit vendor/psmodules)"
}
$PsModulesVendorRoot = Join-Path $RepoRoot 'vendor/psmodules'
foreach ($modDir in Get-ChildItem -LiteralPath $PsModulesVendorRoot -Directory) {
    $modDest = Join-Path $Staged "modules/$($modDir.Name)"
    if (Test-Path -LiteralPath $modDest) { Remove-Item -LiteralPath $modDest -Recurse -Force }
    Copy-Item -LiteralPath $modDir.FullName -Destination $modDest -Recurse -Force
    $versions = (Get-ChildItem -LiteralPath $modDest -Directory | ForEach-Object Name) -join ', '
    Write-Step "Staging $($modDir.Name) ($versions) from vendor/psmodules"
}
foreach ($required in @('Microsoft.PowerShell.SecretManagement', 'SecretManagement.LocalVault')) {
    $stagedManifest = Get-ChildItem -LiteralPath (Join-Path $Staged "modules/$required") -Filter "$required.psd1" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $stagedManifest) {
        throw "$required did not make it into the staged modules/ (run scripts/sync-secret-vault-modules.ps1 and commit vendor/psmodules)"
    }
}
Write-Step 'Verified SecretManagement + SecretManagement.LocalVault in staged modules/'

$VendorPoshSsh = Ensure-AppVendoredPoshSsh -RepoRoot $RepoRoot

Stage-AppPxeVendorBinaries -RepoRoot $RepoRoot -Staged $Staged -Platform $Platform
Stage-AppIntuneVendorBinaries -RepoRoot $RepoRoot -Staged $Staged -Platform $Platform -Arch $Arch -SidecarDest $sidecarDest
$PoshSshManifest = if ($VendorPoshSsh) { Join-Path $VendorPoshSsh 'Posh-SSH.psd1' } else { $null }
if ($VendorPoshSsh -and (Test-AppVendoredPoshSshLayout -VendorPoshSshRoot $VendorPoshSsh)) {
    Write-Step "Staging Posh-SSH from $VendorPoshSsh"
    $poshDest = Join-Path $Staged 'modules/Posh-SSH'
    if (Test-Path -LiteralPath $poshDest) { Remove-Item -LiteralPath $poshDest -Recurse -Force }
    Copy-Item -LiteralPath $VendorPoshSsh -Destination $poshDest -Recurse -Force
}
else {
    throw @"
Posh-SSH is required for release bundles (WLC Snapshot, switch CLI, ASM/Oliver SFTP).

Preferred:
  pwsh -File ./scripts/install-deps.ps1 -InstallPoshSSH -SavePoshSSH
  (prepare-bundle-deps also auto-saves from PSGallery when online)

Or pass -SkipPoshSshVendor only for local experiments without SSH features.
"@
}

# macOS release signing: package-macos.sh signs the staged Mach-O helpers, but this
# script ALSO runs from Tauri's beforeBuildCommand (tauri.conf.json since 3032681), so
# the fresh re-stage lands AFTER that signing and right before bundling - Apple then
# rejects notarization with 'binary is not signed' for every staged helper and the
# PSWSMan dylibs (first hit: the 0.5.2 build). When the packager exports
# DEPLOYKIT_MACOS_SIGN_IDENTITY, re-sign here so staged copies end signed no matter who
# staged them. Dev builds (no env var) skip this - adhoc signatures are fine locally.
# Repo copies are never touched (pswsman stays byte-identical to upstream SHA256SUMS).
# NOTE: runs before the pwsh-staging section below because that section `exit 0`s on
# the default no-bundled-pwsh path.
if ($IsMacOS -and $env:DEPLOYKIT_MACOS_SIGN_IDENTITY) {
    $signIdentity = $env:DEPLOYKIT_MACOS_SIGN_IDENTITY
    $signTargets = @()
    $binDir = Join-Path $Staged 'binaries'
    if (Test-Path -LiteralPath $binDir) {
        $signTargets += @(Get-ChildItem -LiteralPath $binDir -File)
    }
    $pswsmanDir = Join-Path $Staged 'sidecar/vendor/pswsman'
    if (Test-Path -LiteralPath $pswsmanDir) {
        $signTargets += @(Get-ChildItem -LiteralPath $pswsmanDir -Recurse -File -Filter '*.dylib')
    }
    foreach ($signFile in $signTargets) {
        $fileType = & file -b $signFile.FullName 2>$null
        if ("$fileType" -notmatch 'Mach-O') { continue }
        Write-Step "Codesign staged Mach-O: $($signFile.Name)"
        & codesign --force --options runtime --timestamp --sign $signIdentity $signFile.FullName
        if ($LASTEXITCODE -ne 0) { throw "codesign failed for $($signFile.FullName)" }
    }
}

if (-not $BundlePowerShell -or $SkipPowerShell) {
    Write-Step 'PowerShell not bundled - app will use pwsh 7+ on PATH (install separately)'
    exit 0
}

$marker = Join-Path $PwshStage ".staged-$Platform-$Arch"
$hasPwsh = (Test-Path -LiteralPath (Join-Path $PwshStage 'pwsh.exe')) -or
    (Test-Path -LiteralPath (Join-Path $PwshStage 'pwsh'))
if ($hasPwsh -and (Test-Path -LiteralPath $marker)) {
    Write-Step "PowerShell already staged: $PwshStage"
    exit 0
}

$zipName = switch ($Platform) {
    'Windows' {
        if ($Arch -eq 'arm64') { "PowerShell-$PwshVersion-win-arm64.zip" }
        else { "PowerShell-$PwshVersion-win-x64.zip" }
    }
    'MacOS' {
        if ($Arch -eq 'arm64') { "powershell-$PwshVersion-osx-arm64.tar.gz" }
        else { "powershell-$PwshVersion-osx-x64.tar.gz" }
    }
}

$url = "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/$zipName"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("windeploykit-pwsh-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    Write-Step "Downloading $url"
    $archive = Join-Path $tmp $zipName
    Invoke-BuildFileDownload -Uri $url -OutFile $archive

  Write-Step "Extracting to $PwshStage"
    if (Test-Path -LiteralPath $PwshStage) { Remove-Item -LiteralPath $PwshStage -Recurse -Force }
    New-Item -ItemType Directory -Path $PwshStage -Force | Out-Null

    if ($zipName.EndsWith('.zip')) {
        Expand-Archive -LiteralPath $archive -DestinationPath $tmp -Force
        if (Test-Path -LiteralPath (Join-Path $tmp 'pwsh.exe')) {
            Get-ChildItem -LiteralPath $tmp -Force |
                Where-Object { $_.FullName -ne $archive } |
                Copy-Item -Destination $PwshStage -Recurse -Force
        }
        else {
            $sub = Get-ChildItem -LiteralPath $tmp -Directory |
                Where-Object { $_.Name -notin '__MACOSX', 'node_modules' } |
                Select-Object -First 1
            if (-not $sub) { throw 'Unexpected PowerShell zip layout (no pwsh.exe at root)' }
            Get-ChildItem -LiteralPath $sub.FullName -Force |
                Copy-Item -Destination $PwshStage -Recurse -Force
        }
    }
    else {
        tar -xzf $archive -C $tmp
        Get-ChildItem -LiteralPath $tmp -Force |
            Where-Object { $_.FullName -ne $archive } |
            Copy-Item -Destination $PwshStage -Recurse -Force
    }

    $pwshExe = Join-Path $PwshStage 'pwsh.exe'
    $pwshUnix = Join-Path $PwshStage 'pwsh'
    if (Test-Path -LiteralPath $pwshExe) { }
    elseif (Test-Path -LiteralPath $pwshUnix) {
        if ($Platform -ne 'Windows') { & chmod '+x' $pwshUnix }
    }
    else { throw 'pwsh executable not found after extract' }

    Get-Date -Format 'o' | Set-Content -LiteralPath $marker -Encoding utf8
    $sizeMb = [math]::Round((Get-ChildItem -LiteralPath $PwshStage -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB)
    Write-Step "PowerShell staged (~${sizeMb} MB) at $PwshStage"
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Step 'Bundle deps ready under packaging/staged/'
