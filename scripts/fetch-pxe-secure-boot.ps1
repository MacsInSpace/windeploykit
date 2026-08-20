#requires -Version 7.0
<#
.SYNOPSIS
    Copy the ipxeboot deploy-menu Secure Boot TFTP tree into vendor/ and sidecar/pxe/ for Netboot bundling.

.DESCRIPTION
    Requires a built ipxeboot deploy-menu output tree containing tftp/x86_64-sb/shimx64.efi
    (signed shim + iPXE/snponly chain). Build from the ipxeboot repo:

        cd /path/to/ipxeboot/contrib/deploy-menu
        ./build-snponly.sh    # or full deploy-menu build that emits out/tftp/x86_64-sb/

.EXAMPLE
    pwsh -File ./scripts/fetch-pxe-secure-boot.ps1

.EXAMPLE
    pwsh -File ./scripts/fetch-pxe-secure-boot.ps1 -SourceDir D:\ipxeboot\contrib\deploy-menu\out\tftp\x86_64-sb
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$IpxeBootRoot = $env:IPXEBOOT_ROOT
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Get-AppPxeSecureBootSourceCandidates {
    param([string]$RepoRoot, [string]$IpxeBootRoot)

    $list = [System.Collections.Generic.List[string]]::new()
    if ($IpxeBootRoot) {
        [void]$list.Add((Join-Path $IpxeBootRoot 'contrib/deploy-menu/out/tftp/x86_64-sb'))
    }
    [void]$list.Add((Join-Path (Split-Path $RepoRoot -Parent) 'ipxeboot/contrib/deploy-menu/out/tftp/x86_64-sb'))
    [void]$list.Add((Join-Path $RepoRoot 'vendor/binaries/pxe-secure-boot-x64/x86_64-sb'))
    [void]$list.Add((Join-Path $RepoRoot 'sidecar/pxe/x86_64-sb'))
    if ($env:LOCALAPPDATA) {
        [void]$list.Add((Join-Path $env:LOCALAPPDATA 'WinDeployKit/plugins/pxe-boot/tftp/x86_64-sb'))
    }
    return @($list)
}

if (-not $SourceDir) {
    $checked = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in (Get-AppPxeSecureBootSourceCandidates -RepoRoot $RepoRoot -IpxeBootRoot $IpxeBootRoot)) {
        $resolved = $candidate -replace '/', [IO.Path]::DirectorySeparatorChar
        [void]$checked.Add($resolved)
        if ((Test-Path -LiteralPath $resolved -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $resolved 'shimx64.efi') -PathType Leaf)) {
            $SourceDir = (Resolve-Path -LiteralPath $resolved).Path
            break
        }
    }
} else {
    $checked = [System.Collections.Generic.List[string]]::new()
    [void]$checked.Add(($SourceDir -replace '/', [IO.Path]::DirectorySeparatorChar))
}

if (-not $SourceDir -or -not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    $lines = @(
        'Secure Boot TFTP source not found (needs shimx64.efi). Unlike wimboot, this tree is built from ipxeboot — it is not downloaded from the internet.'
        ''
        'Checked:'
    ) + @($checked | ForEach-Object { "  - $_" }) + @(
        ''
        'Build ipxeboot deploy-menu, then re-run:'
        '  cd /path/to/ipxeboot/contrib/deploy-menu'
        '  ./build-snponly.sh'
        '  pwsh -File ./scripts/fetch-pxe-secure-boot.ps1 -SourceDir <path/to/out/tftp/x86_64-sb>'
        ''
        'Or clone ipxeboot as a sibling checkout (D:\projects\ipxeboot) and build there.'
        'Set IPXEBOOT_ROOT if your checkout lives elsewhere.'
        ''
        'Dev workaround (Secure Boot off): use Option 67 snponly.efi instead of x86_64-sb/shimx64.efi.'
    )
    throw ($lines -join [Environment]::NewLine)
}

$marker = Join-Path $SourceDir 'shimx64.efi'
if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Source directory is missing shimx64.efi: $SourceDir"
}

$vendorDir = Join-Path $RepoRoot 'vendor/binaries/pxe-secure-boot-x64/x86_64-sb'
$sidecarDir = Join-Path $RepoRoot 'sidecar/pxe/x86_64-sb'

function Copy-AppPxeSecureBootTree {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    if (Test-Path -LiteralPath $To) {
        Remove-Item -LiteralPath $To -Recurse -Force
    }
    $parent = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
}

Copy-AppPxeSecureBootTree -From $SourceDir -To $vendorDir
Copy-AppPxeSecureBootTree -From $SourceDir -To $sidecarDir

$files = @(Get-ChildItem -LiteralPath $vendorDir -Recurse -File)
$hashes = foreach ($file in $files) {
    $rel = $file.FullName.Substring($vendorDir.Length).TrimStart('\', '/').Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $rel"
}
$hashes | Set-Content -LiteralPath (Join-Path $RepoRoot 'vendor/binaries/pxe-secure-boot-x64/SHA256SUMS.txt') -Encoding ASCII -Force

Write-Host "==> Secure Boot TFTP tree ($($files.Count) file(s))" -ForegroundColor Green
Write-Host "    source:  $SourceDir"
Write-Host "    vendor:  $vendorDir"
Write-Host "    sidecar: $sidecarDir"
Write-Host "    git add vendor/binaries/pxe-secure-boot-x64/ sidecar/pxe/x86_64-sb/"
