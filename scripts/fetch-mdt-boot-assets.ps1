#requires -Version 7.0
<#
.SYNOPSIS
    Copy MDT LiteTouch UEFI boot assets into vendor/ for ImageDeployer wimboot packaging.

.PARAMETER SourceRoot
    MDT Boot/x64 folder (deployment share). Example: \\wds\DeployShare$\Boot\x64

.EXAMPLE
    pwsh -File ./scripts/fetch-mdt-boot-assets.ps1 -SourceRoot '/Volumes/DeployShare$/Boot/x64'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destDir = Join-Path $RepoRoot 'vendor/binaries/pxe-mdt-boot/x64'
$sidecarDir = Join-Path $RepoRoot 'sidecar/pxe/mdt-boot-x64'

$srcRoot = $SourceRoot.TrimEnd('\', '/')
$bcdCandidates = @(
    (Join-Path $srcRoot 'EFI/Microsoft/Boot/BCD')
    (Join-Path $srcRoot 'Boot/BCD')
)
$bootSdi = Join-Path $srcRoot 'Boot/boot.sdi'
$bootmgrCandidates = @(
    (Join-Path $srcRoot 'bootmgr.efi')
    (Join-Path $srcRoot 'EFI/Boot/bootmgfw.efi')
)

$bcdSrc = $null
foreach ($c in $bcdCandidates) {
    if (Test-Path -LiteralPath $c) { $bcdSrc = $c; break }
}
$bootmgrSrc = $null
foreach ($c in $bootmgrCandidates) {
    if (Test-Path -LiteralPath $c) { $bootmgrSrc = $c; break }
}

if (-not $bcdSrc) { throw "MDT BCD not found under $srcRoot (expected EFI/Microsoft/Boot/BCD)" }
if (-not (Test-Path -LiteralPath $bootSdi)) { throw "MDT boot.sdi not found: $bootSdi" }
if (-not $bootmgrSrc) { throw "MDT UEFI bootmgr not found under $srcRoot (expected bootmgr.efi)" }

if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force }
$null = New-Item -Path $destDir -ItemType Directory -Force

Copy-Item -LiteralPath $bcdSrc -Destination (Join-Path $destDir 'BCD') -Force
Copy-Item -LiteralPath $bootSdi -Destination (Join-Path $destDir 'boot.sdi') -Force
Copy-Item -LiteralPath $bootmgrSrc -Destination (Join-Path $destDir 'bootmgfw.efi') -Force

if (Test-Path -LiteralPath $sidecarDir) { Remove-Item -LiteralPath $sidecarDir -Recurse -Force }
$null = New-Item -Path $sidecarDir -ItemType Directory -Force
Copy-Item -LiteralPath (Join-Path $destDir 'BCD') -Destination (Join-Path $sidecarDir 'BCD') -Force
Copy-Item -LiteralPath (Join-Path $destDir 'boot.sdi') -Destination (Join-Path $sidecarDir 'boot.sdi') -Force
Copy-Item -LiteralPath (Join-Path $destDir 'bootmgfw.efi') -Destination (Join-Path $sidecarDir 'bootmgfw.efi') -Force

$hashes = @(
    "# MDT LiteTouch boot assets — source: $srcRoot"
    (Get-FileHash (Join-Path $destDir 'BCD') -Algorithm SHA256).Hash.ToLowerInvariant() + '  x64/BCD'
    (Get-FileHash (Join-Path $destDir 'boot.sdi') -Algorithm SHA256).Hash.ToLowerInvariant() + '  x64/boot.sdi'
    (Get-FileHash (Join-Path $destDir 'bootmgfw.efi') -Algorithm SHA256).Hash.ToLowerInvariant() + '  x64/bootmgfw.efi'
)
$hashes | Set-Content -LiteralPath (Join-Path $RepoRoot 'vendor/binaries/pxe-mdt-boot/SHA256SUMS.txt') -Encoding ASCII -Force

Write-Host '==> MDT boot assets vendored' -ForegroundColor Green
Write-Host "    vendor: $destDir"
Write-Host "    sidecar: $sidecarDir"
Write-Host '    git add vendor/binaries/pxe-mdt-boot/ sidecar/pxe/mdt-boot-x64/'
