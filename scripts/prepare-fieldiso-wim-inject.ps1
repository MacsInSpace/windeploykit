#requires -Version 5.1
<#
.SYNOPSIS
    Windows + ADK: add WinPE-PowerShell to a scratch mount and export into sidecar/pxe/fieldiso/wim-inject/.

.DESCRIPTION
    Run on a Windows PC with Windows ADK installed. Populates wim-inject/Windows/ with the
    PowerShell optional component tree (and dependencies). curl.exe + 7z.exe are copied from
    sidecar/pxe/fieldiso/tools/ into System32 in the same tree.

    MUST run under Windows PowerShell 5.1 (powershell.exe), not pwsh 7 - DISM cmdlets and
    dism.exe argument passing break under PowerShell Core on many hosts.

    Installs WinPE optional components in Microsoft order (each neutral + en-us cab):
    WinPE-WMI, WinPE-NetFx, WinPE-Scripting, WinPE-PowerShell.
    NetFx provides mscoree.dll; without it you only get ~128 PowerShell folder files and the engine will not start.

    After this, run ./scripts/build-fieldiso-wim.sh on macOS (or inject-fieldiso-winpe-tools.sh).

.EXAMPLE
    pwsh -File ./scripts/fetch-fieldiso-tools.ps1
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\prepare-fieldiso-wim-inject.ps1 -BaseWinPeWim C:\ADK\winpe.wim
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaseWinPeWim,
    [string] $OutRoot,
    [string] $AdkRoot,
    [switch] $KeepMount
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT' -and -not ($IsWindows -eq $true)) {
    throw 'Run this script on Windows with ADK (copype/Dism). Export wim-inject/ to macOS for wimlib build.'
}

# pwsh 7: re-launch under Windows PowerShell 5.1 where Dism module works.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPs)) {
        throw 'Windows PowerShell 5.1 not found - run from powershell.exe as Administrator.'
    }
    Write-Host '==> Re-launching under Windows PowerShell 5.1 (DISM does not work reliably in pwsh 7)' -ForegroundColor Yellow
    $forward = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path,
        '-BaseWinPeWim', $BaseWinPeWim
    )
    if ($OutRoot) { $forward += @('-OutRoot', $OutRoot) }
    if ($AdkRoot) { $forward += @('-AdkRoot', $AdkRoot) }
    if ($KeepMount) { $forward += '-KeepMount' }
    & $winPs @forward
    exit $LASTEXITCODE
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutRoot) { $OutRoot = Join-Path $RepoRoot 'sidecar\pxe\fieldiso\wim-inject' }
$toolsDir = Join-Path $RepoRoot 'sidecar\pxe\fieldiso\tools'

if (-not (Test-Path -LiteralPath $BaseWinPeWim)) {
    throw "Base WinPE WIM not found: $BaseWinPeWim"
}
$BaseWinPeWim = (Resolve-Path -LiteralPath $BaseWinPeWim).Path

function Test-IsAdmin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw 'Run Windows PowerShell as Administrator - DISM mount requires elevation.'
}

Import-Module Dism -ErrorAction Stop

function Mount-FieldIsoScratchWinPe {
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][string]$MountDir
    )
    Mount-WindowsImage -ImagePath $WimPath -Index 1 -Path $MountDir -ErrorAction Stop | Out-Null
    $systemHive = Join-Path $MountDir 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path -LiteralPath $systemHive)) {
        throw "Mount verification failed - expected $systemHive"
    }
}

function Add-FieldIsoWinPePackage {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$CabPath
    )
    Add-WindowsPackage -Path $MountDir -PackagePath $CabPath -ErrorAction Stop | Out-Null
}

function Dismount-FieldIsoScratchWinPe {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [switch]$Discard
    )
    if (-not (Test-Path -LiteralPath $MountDir)) { return }
    if ($Discard) {
        Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction Stop | Out-Null
    } else {
        Dismount-WindowsImage -Path $MountDir -Save -ErrorAction Stop | Out-Null
    }
}

function Get-FieldIsoWinPeMountFileIndex {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string[]]$RelativeRoots
    )
    $index = @{}
    foreach ($rel in $RelativeRoots) {
        $root = Join-Path $mountDir "Windows\$rel"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $key = ($rel.TrimEnd('\') + '\' + $_.FullName.Substring($root.Length).TrimStart('\')).Replace('/', '\')
            $index[$key] = $_.Length
        }
    }
    return $index
}

function ConvertTo-LongPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) {
        return '\\?\UNC\' + $full.Substring(2)
    }
    return '\\?\' + $full
}

function Ensure-FieldIsoExportDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $long = ConvertTo-LongPath -Path $Path
    if (-not [System.IO.Directory]::Exists($long)) {
        [void][System.IO.Directory]::CreateDirectory($long)
    }
}

function Copy-FieldIsoExportFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $srcLong = ConvertTo-LongPath -Path $Source
    if (-not [System.IO.File]::Exists($srcLong)) {
        throw (New-Object System.IO.FileNotFoundException("Source missing: $Source"))
    }
    $destDir = Split-Path -Parent $Destination
    Ensure-FieldIsoExportDirectory -Path $destDir
    $dstLong = ConvertTo-LongPath -Path $Destination
    [System.IO.File]::Copy($srcLong, $dstLong, $true)
}

function Export-FieldIsoWinPeMountDelta {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$OutWindows,
        [Parameter(Mandatory)][string[]]$RelativeRoots,
        [Parameter(Mandatory)][hashtable]$BeforeIndex
    )
    $count = 0
    $skipped = 0
    foreach ($rel in $RelativeRoots) {
        $srcRoot = Join-Path $MountDir "Windows\$rel"
        if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
        Get-ChildItem -LiteralPath $srcRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $relPath = ($rel.TrimEnd('\') + '\' + $_.FullName.Substring($srcRoot.Length).TrimStart('\')).Replace('/', '\')
            if ($BeforeIndex.ContainsKey($relPath) -and $BeforeIndex[$relPath] -eq $_.Length) { return }
            $dest = Join-Path $OutWindows $relPath
            try {
                Copy-FieldIsoExportFile -Source $_.FullName -Destination $dest
                $count++
            } catch {
                $skipped++
            }
        }
    }
    if ($skipped -gt 0) {
        Write-Warning "Delta export skipped $skipped files (long path, missing source, or access denied)."
    }
    return $count
}

$mountParent = Join-Path $env:SystemRoot 'Temp'
if (-not (Test-Path -LiteralPath $mountParent)) {
    $mountParent = $env:TEMP
}

function Find-AdkWinPeOcRoot {
    param([string]$Root)
    $candidates = @()
    if ($Root) { $candidates += $Root }
    $candidates += @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\x86\WinPE_OCs"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return (Resolve-Path -LiteralPath $path).Path }
    }
    throw 'ADK WinPE_OCs folder not found - install Windows ADK WinPE add-on.'
}

function Find-WinPeOcPackageCabs {
    param(
        [Parameter(Mandatory)][string]$OcRoot,
        [Parameter(Mandatory)][string]$ComponentBaseName,
        [string[]]$AlternateNames = @()
    )
    $searchNames = @($ComponentBaseName) + @($AlternateNames)
    $neutral = $null
    foreach ($name in $searchNames) {
        $hit = Get-ChildItem -LiteralPath $OcRoot -Filter "$name.cab" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) {
            $neutral = $hit.FullName
            break
        }
    }
    if (-not $neutral) {
        foreach ($name in $searchNames) {
            $hit = Get-ChildItem -LiteralPath $OcRoot -Filter "*$name*.cab" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '_en-us\.cab$' -and $_.DirectoryName -eq $OcRoot } |
                Select-Object -First 1
            if ($hit) {
                $neutral = $hit.FullName
                break
            }
        }
    }
    if (-not $neutral) { return $null }

    $neutralLeaf = [System.IO.Path]::GetFileNameWithoutExtension($neutral)
    $enUsDir = Join-Path $OcRoot 'en-us'
    $lang = $null
    if (Test-Path -LiteralPath $enUsDir) {
        foreach ($name in @($neutralLeaf, $ComponentBaseName) + $AlternateNames) {
            $candidate = Join-Path $enUsDir "$name`_en-us.cab"
            if (Test-Path -LiteralPath $candidate) {
                $lang = $candidate
                break
            }
        }
        if (-not $lang) {
            $langHit = Get-ChildItem -LiteralPath $enUsDir -Filter '*_en-us.cab' -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $base = $_.BaseName -replace '_en-us$',''
                    ($base -eq $neutralLeaf) -or ($searchNames -contains $base)
                } |
                Select-Object -First 1
            if ($langHit) { $lang = $langHit.FullName }
        }
    }

    return @{
        Neutral = $neutral
        Lang    = $lang
    }
}

function Add-WinPeOptionalComponent {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$OcRoot,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ComponentBaseName,
        [string[]]$AlternateNames = @(),
        [switch]$Required
    )
    $cabs = Find-WinPeOcPackageCabs -OcRoot $OcRoot -ComponentBaseName $ComponentBaseName -AlternateNames $AlternateNames
    if (-not $cabs -or -not $cabs.Neutral) {
        if ($Required) {
            $sample = @(Get-ChildItem -LiteralPath $OcRoot -Filter '*.cab' -File -ErrorAction SilentlyContinue |
                Select-Object -First 15 -ExpandProperty Name)
            throw @"
Required WinPE package '$Label' not found under $OcRoot
  looked for: $ComponentBaseName.cab $(if ($AlternateNames) { "($($AlternateNames -join ', '))" })
  sample cabs in folder: $($sample -join ', ')
Install/repair Windows ADK WinPE add-on (amd64 WinPE_OCs).
"@
        }
        Write-Warning "Skipping $Label - no matching cab in $OcRoot"
        return
    }

    Write-Host "==> Add-Package $Label (neutral): $(Split-Path -Leaf $cabs.Neutral)" -ForegroundColor Cyan
    Add-FieldIsoWinPePackage -MountDir $MountDir -CabPath $cabs.Neutral
    if ($cabs.Lang) {
        Write-Host "==> Add-Package $Label (en-us): $(Split-Path -Leaf $cabs.Lang)" -ForegroundColor Cyan
        Add-FieldIsoWinPePackage -MountDir $MountDir -CabPath $cabs.Lang
    } else {
        Write-Warning "${Label}: no en-us language cab under $OcRoot\en-us (NetFx/PowerShell may be incomplete)"
    }
}

function Find-FieldIsoWinPeAutomationDll {
    param(
        [Parameter(Mandatory)][string]$WindowsRoot
    )
    $direct = Join-Path $WindowsRoot 'System32\WindowsPowerShell\v1.0\System.Management.Automation.dll'
    if (Test-Path -LiteralPath $direct) { return $direct }

    $gacRoot = Join-Path $WindowsRoot 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation'
    if (Test-Path -LiteralPath $gacRoot) {
        $hit = Get-ChildItem -LiteralPath $gacRoot -Recurse -Filter 'System.Management.Automation.dll' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    $legacyGac = Join-Path $WindowsRoot 'assembly\GAC_MSIL\System.Management.Automation'
    if (Test-Path -LiteralPath $legacyGac) {
        $hit = Get-ChildItem -LiteralPath $legacyGac -Recurse -Filter 'System.Management.Automation.dll' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

function Test-FieldIsoWinPeMountHasEngine {
    param([Parameter(Mandatory)][string]$MountDir)
    $windowsRoot = Join-Path $MountDir 'Windows'
    $missing = @()
    foreach ($rel in @(
        'System32\mscoree.dll',
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $windowsRoot $rel))) {
            $missing += "Windows\$rel"
        }
    }
    if (-not (Find-FieldIsoWinPeAutomationDll -WindowsRoot $windowsRoot)) {
        $missing += 'Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\...\System.Management.Automation.dll'
    }
    return $missing
}

$ocRoot = Find-AdkWinPeOcRoot -Root $AdkRoot
Write-Host "==> WinPE_OCs: $ocRoot" -ForegroundColor Cyan

# Microsoft order: WMI -> NetFx -> Scripting -> PowerShell (+ en-us cab for each).
$requiredPackages = @(
    @{ Label = 'WMI';        Base = 'WinPE-WMI';        Alt = @() }
    @{ Label = 'NetFx';      Base = 'WinPE-NetFx';      Alt = @('WinPE-NetFX') }
    @{ Label = 'Scripting';  Base = 'WinPE-Scripting';  Alt = @() }
    @{ Label = 'PowerShell'; Base = 'WinPE-PowerShell'; Alt = @() }
)

$mountDir = Join-Path $mountParent 'windeploykit-fieldiso-mnt'
if (Test-Path -LiteralPath $mountDir) {
    Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
$outWindows = Join-Path $OutRoot 'Windows'
if (Test-Path -LiteralPath $outWindows) {
    Remove-Item -LiteralPath $outWindows -Recurse -Force
}
New-Item -ItemType Directory -Path $outWindows -Force | Out-Null

Write-Host "==> Export root: $OutRoot" -ForegroundColor Cyan
if ($OutRoot.Length -gt 80) {
    Write-Host '    Tip: deep export path - if copy fails, use -OutRoot C:\fi-out' -ForegroundColor Yellow
}

Write-Host "==> Mounting $BaseWinPeWim -> $mountDir" -ForegroundColor Cyan
Mount-FieldIsoScratchWinPe -WimPath $BaseWinPeWim -MountDir $mountDir

$deltaRoots = @('System32', 'Sysnative', 'Microsoft.NET', 'assembly')
$beforeIndex = Get-FieldIsoWinPeMountFileIndex -MountDir $mountDir -RelativeRoots $deltaRoots
$deltaCount = 0

try {
    foreach ($pkg in $requiredPackages) {
        Add-WinPeOptionalComponent -MountDir $mountDir -OcRoot $ocRoot `
            -Label $pkg.Label -ComponentBaseName $pkg.Base -AlternateNames $pkg.Alt -Required
    }

    $missingOnMount = Test-FieldIsoWinPeMountHasEngine -MountDir $mountDir
    if ($missingOnMount.Count -gt 0) {
        throw @"
WinPE mount missing engine files after Add-Package:
  $($missingOnMount -join "`n  ")
Confirm all eight Add-Package lines succeeded. Use fresh ADK winpe.wim:
  ...\amd64\en-us\winpe.wim
Re-run with -KeepMount and inspect the mount if this persists.
"@
    }

    # WinPE optional components drop files outside WindowsPowerShell\ (mscoree.dll, .NET tree, etc.).
    Write-Host '==> Exporting WinPE optional-component delta (new/changed files vs base winpe.wim)' -ForegroundColor Cyan
    $deltaCount = Export-FieldIsoWinPeMountDelta -MountDir $mountDir -OutWindows $outWindows -RelativeRoots $deltaRoots -BeforeIndex $beforeIndex
    Write-Host "  exported $deltaCount delta files under Windows" -ForegroundColor Green

    foreach ($rel in @('System32\WindowsPowerShell', 'Sysnative\WindowsPowerShell')) {
        $src = Join-Path $mountDir "Windows\$rel"
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dest = Join-Path $outWindows $rel
        Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $relFile = $_.FullName.Substring($src.Length).TrimStart('\')
            $destFile = Join-Path $dest $relFile
            try {
                Copy-FieldIsoExportFile -Source $_.FullName -Destination $destFile
            } catch {
                Write-Verbose "Skipped PowerShell tree export: Windows\$rel\$relFile"
            }
        }
        Write-Host "  exported Windows\$rel (full tree)" -ForegroundColor Green
    }

    foreach ($tool in @('curl.exe', '7z.exe', '7za.dll', '7zxa.dll')) {
        $src = Join-Path $toolsDir $tool
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warning "Missing $tool - run fetch-fieldiso-tools.ps1 first"
            continue
        }
        $dest = Join-Path $outWindows "System32\$tool"
        Copy-FieldIsoExportFile -Source $src -Destination $dest
        Write-Host "  copied System32\$tool" -ForegroundColor Green
    }
}
finally {
    if ($KeepMount) {
        Write-Host "Mount left at $mountDir (-KeepMount)" -ForegroundColor Yellow
    } else {
        Write-Host '==> Unmounting (commit discard - export only)' -ForegroundColor Cyan
        Dismount-FieldIsoScratchWinPe -MountDir $mountDir -Discard
    }
}

$psExe = Join-Path $outWindows 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mscoree = Join-Path $outWindows 'System32\mscoree.dll'
$smaPath = Find-FieldIsoWinPeAutomationDll -WindowsRoot $outWindows
if (-not (Test-Path -LiteralPath $psExe)) {
    throw "WinPE PowerShell export incomplete - missing $psExe"
}
if (-not (Test-Path -LiteralPath $mscoree)) {
    throw "WinPE export incomplete - missing $mscoree (WinPE-NetFx did not export; delta was $deltaCount files)"
}
if (-not $smaPath) {
    throw "WinPE export incomplete - System.Management.Automation.dll not found under export (delta was $deltaCount files)"
}
$smaRel = $smaPath.Substring($outWindows.Length).TrimStart('\')
$fileCount = @(Get-ChildItem -LiteralPath $OutRoot -Recurse -File).Count
Write-Host "wim-inject ready: $OutRoot - $fileCount files, powershell.exe + mscoree.dll + $smaRel OK" -ForegroundColor Green
Write-Host 'Next: ./scripts/build-fieldiso-wim.sh  (macOS) or inject-fieldiso-winpe-tools.sh on existing FieldIso.wim'
