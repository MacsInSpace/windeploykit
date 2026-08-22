#requires -Version 7.0
<#
.SYNOPSIS
    Offline gate for the deploy-share overlay: config keys, legacy migration, and the
    boot-WIM heuristics that decide how a WIM is chained.
.DESCRIPTION
    The overlay used to be named after a third-party WinPE client this product does not
    ship (2026-08-22 rename). Two things had to survive that rename:

      1. Configs written before it still carry imageDeployerOverlayCreds/Share. A read
         must migrate them, and a new-shaped key must win when both are present.
      2. The name-matching that decided "this WIM needs the bundled MDT boot files and
         its bootmgr kept inside the WIM" now keys on MDT LiteTouch instead. A plain
         boot.wim pulled out of a Windows ISO (Server2025-boot.wim - the one that boots
         on Craig's Proxmox host) must NOT pick up those flags.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
$script:AppState = @{ IsReady = $true }
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
. (Join-Path $SidecarRoot 'lib/AppProductIdentity.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootTaskSequences.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootPlugin.ps1')

$failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "  [OK  ] $Name" }
    catch { Write-Host "  [FAIL] $Name - $($_.Exception.Message)"; $script:failures++ }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -ne "$Actual") { throw "$What - expected '$Expected', got '$Actual'" }
}

# Read-AppPxeBootConfig reads a real path; point it at a scratch store for the run.
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("wdk-overlay-gate-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $sandbox -ItemType Directory -Force
$configPath = Get-AppPxeBootConfigPath
$backup = $null
if (Test-Path -LiteralPath $configPath) {
    $backup = Join-Path $sandbox 'config.original.json'
    Copy-Item -LiteralPath $configPath -Destination $backup -Force
}
function Set-TestConfig {
    param([hashtable]$Body)
    ($Body | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $configPath -Encoding UTF8
}

try {
    Write-Host 'Config keys and legacy migration:'

    Test-Case 'legacy imageDeployer* keys migrate on read' {
        Set-TestConfig @{ httpPort = 8080; imageDeployerOverlayCreds = 'vault:acme-deploy'; imageDeployerOverlayShare = 'Legacy$' }
        $cfg = Read-AppPxeBootConfig
        Assert-Equal 'vault:acme-deploy' $cfg.deployOverlayCreds 'creds'
        Assert-Equal 'Legacy$' $cfg.deployOverlayShare 'share'
    }

    Test-Case 'new key wins when both are present' {
        Set-TestConfig @{ imageDeployerOverlayShare = 'Legacy$'; deployOverlayShare = 'Deploy$' }
        Assert-Equal 'Deploy$' (Read-AppPxeBootConfig).deployOverlayShare 'share'
    }

    Test-Case 'unknown creds mode falls back to throwaway' {
        Set-TestConfig @{ deployOverlayCreds = 'nonsense mode' }
        Assert-Equal 'throwaway' (Read-AppPxeBootConfig).deployOverlayCreds 'creds'
    }

    Test-Case 'creds mode values' {
        foreach ($v in @('throwaway', 'blank', 'dept', 'vault:acme-deploy')) {
            if (-not (Test-AppPxeBootDeployOverlayCredsModeValue -Value $v)) { throw "'$v' should be valid" }
        }
        foreach ($v in @('', 'vault:', 'vault:bad id', 'other')) {
            if (Test-AppPxeBootDeployOverlayCredsModeValue -Value $v) { throw "'$v' should be rejected" }
        }
    }

    Test-Case 'deploy UNC uses the configured share name' {
        Set-TestConfig @{ smbShareEnabled = $true; smbOverlayEnabled = $true; deployOverlayShare = 'Deploy$' }
        Assert-Equal '\\10.0.1.147\Deploy$' (Get-AppPxeBootDeployOverlayUnc -Cfg (Read-AppPxeBootConfig) -LanIp '10.0.1.147') 'unc'
    }

    Write-Host ''
    Write-Host 'Boot WIM heuristics:'

    Test-Case 'FieldIso is recognised and takes no overlay' {
        if (-not (Test-AppPxeBootWimIsFieldIso -FileName 'FieldIso.wim')) { throw 'FieldIso.wim not recognised' }
        if (Test-AppPxeBootWimUsesDeployOverlay -FileName 'FieldIso.wim') { throw 'FieldIso should not take the overlay' }
    }

    Test-Case 'MDT LiteTouch WIMs are recognised' {
        foreach ($n in @('LiteTouchPE_x64.wim', 'litetouchpe_x86.wim', 'Site-LiteTouch.wim')) {
            if (-not (Test-AppPxeBootWimIsMdtLiteTouch -FileName $n)) { throw "$n not recognised" }
        }
    }

    Test-Case 'a boot.wim from a Windows ISO is NOT treated as LiteTouch' {
        foreach ($n in @('Server2025-boot.wim', 'boot.wim', 'Win11-24H2-boot.wim')) {
            if (Test-AppPxeBootWimIsMdtLiteTouch -FileName $n) { throw "$n should not match" }
            if (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $n) { throw "$n should not want MDT boot files" }
            if (Test-AppPxeBootWimExtractBootmgrFromWim -WimFileName $n) { throw "$n should not extract bootmgr from the WIM" }
        }
    }

    Test-Case 'any non-FieldIso WIM can take the overlay' {
        foreach ($n in @('LiteTouchPE_x64.wim', 'TechTools.wim', 'Server2025-boot.wim')) {
            if (-not (Test-AppPxeBootWimUsesDeployOverlay -FileName $n)) { throw "$n should be overlay-eligible" }
        }
        if (Test-AppPxeBootWimUsesDeployOverlay -FileName 'notes.txt') { throw 'non-WIM should be rejected' }
    }

    Test-Case 'recipes: LiteTouch gets MDT boot assets, plain boot.wim does not' {
        $lt = Get-AppPxeBootWimbootRecipe -WimFileName 'LiteTouchPE_x64.wim'
        if (-not (Test-AppPxeBootRecipeFlag -Recipe $lt -Key 'useBootAssets')) { throw 'LiteTouch should useBootAssets' }
        if (-not (Test-AppPxeBootRecipeFlag -Recipe $lt -Key 'extractBootmgrFromWim')) { throw 'LiteTouch should extract bootmgr' }
        $srv = Get-AppPxeBootWimbootRecipe -WimFileName 'Server2025-boot.wim'
        Assert-Equal 1 $srv['index'] 'server index'
        if (Test-AppPxeBootRecipeFlag -Recipe $srv -Key 'useBootAssets') { throw 'plain boot.wim should not useBootAssets' }
        if (Test-AppPxeBootRecipeFlag -Recipe $srv -Key 'extractBootmgrFromWim') { throw 'plain boot.wim should not extract bootmgr' }
    }

    Write-Host ''
    Write-Host 'Overlay profile registry:'

    Test-Case 'the deploy-share profile serves http/deploy with the runtime trio' {
        $profiles = @(Get-AppPxeBootWimOverlayProfiles)
        $p = $profiles | Where-Object { $_.Id -eq 'deploy-share' }
        if (-not $p) { throw "no deploy-share profile (ids: $(($profiles | ForEach-Object { $_.Id }) -join ', '))" }
        Assert-Equal 'deploy' $p.ServedSubdir 'served subdir'
        $names = @($p.Runtime | ForEach-Object { $_.WinPeName })
        foreach ($n in @('deploy.unc', 'deploy.cred', 'deploy.loghost')) {
            if ($names -notcontains $n) { throw "runtime entry '$n' missing (have: $($names -join ', '))" }
        }
        if ($p.PSObject.Properties['Bakes'] -and @($p.Bakes).Count -gt 0) {
            throw 'this product bakes nothing into user WIMs'
        }
    }

    Test-Case 'no profile carries the old name' {
        foreach ($p in @(Get-AppPxeBootWimOverlayProfiles)) {
            if ("$($p.Id)$($p.ServedSubdir)" -match '(?i)imagedeployer') { throw "profile '$($p.Id)' still carries the old name" }
        }
    }
}
finally {
    if ($backup) { Move-Item -LiteralPath $backup -Destination $configPath -Force }
    elseif (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) { Write-Host "deploy overlay: $failures failure(s)"; exit 1 }
Write-Host 'deploy overlay: all checks passed'
exit 0
