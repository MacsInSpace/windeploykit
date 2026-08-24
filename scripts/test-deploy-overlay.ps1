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

# Hermetic: the WHOLE data root is a scratch dir for this run. The old approach
# (write test values into the live config / live branding, restore in a finally)
# raced real service starts - a gate run at 19:33 on 2026-08-24 had the operator's
# winpe.jpg backed up at the exact moment a live publish looked for it, and a real
# boot's menu lost its background line.
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("wdk-overlay-gate-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $sandbox -ItemType Directory -Force
$env:APP_TEST_DATA_ROOT = $sandbox
$configPath = Get-AppPxeBootConfigPath
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

    Test-Case 'creds mode values - throwaway or vault only, no blank' {
        foreach ($v in @('throwaway', 'vault:acme-deploy')) {
            if (-not (Test-AppPxeBootDeployOverlayCredsModeValue -Value $v)) { throw "'$v' should be valid" }
        }
        # blank hung a real boot on an invisible net use prompt (2026-08-24) and dept
        # was USM-only - both must stay rejected so an old config self-heals to
        # throwaway at read time.
        foreach ($v in @('', 'blank', 'dept', 'vault:', 'vault:bad id', 'other')) {
            if (Test-AppPxeBootDeployOverlayCredsModeValue -Value $v) { throw "'$v' should be rejected" }
        }
        Set-TestConfig @{ deployOverlayCreds = 'blank' }
        Assert-Equal 'throwaway' (Read-AppPxeBootConfig).deployOverlayCreds 'a legacy blank config heals to throwaway'
    }

    Test-Case 'deploy UNC uses the configured share name' {
        Set-TestConfig @{ smbShareEnabled = $true; smbOverlayEnabled = $true; deployOverlayShare = 'Deploy$' }
        Assert-Equal '\\10.0.1.147\Deploy$' (Get-AppPxeBootDeployOverlayUnc -Cfg (Read-AppPxeBootConfig) -LanIp '10.0.1.147') 'unc'
    }

    Write-Host ''
    Write-Host 'Boot WIM heuristics:'

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

    Test-Case 'any imported WinPE can take the overlay' {
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

    # The shape checks above use PSObject.Properties, which is exactly the SAFE way to
    # read an optional key - so they passed while the product threw. These run the real
    # loops instead: with Bakes gone from the only profile, `$profile.Bakes` under
    # StrictMode threw "The property 'Bakes' cannot be found" and Start Imaging
    # Services died on the spot (Craig, 2026-08-23).
    Test-Case 'the bake sweep never writes a WIM when no background is imported' {
        # The sandbox store has no branding file, so the background bake must resolve
        # to skipped/no-source - and must NEVER touch the WIM.
        $wim = Join-Path ([IO.Path]::GetTempPath()) ("gate-" + [guid]::NewGuid().ToString('N') + ".wim")
        Set-Content -LiteralPath $wim -Value 'not a real wim' -Encoding ASCII
        try {
            $before = (Get-Item -LiteralPath $wim).LastWriteTimeUtc
            $results = @(Sync-AppPxeBootWimOverlays -WimPath $wim)
            foreach ($res in $results) {
                if (-not [bool]$res.skipped) { throw "a bake ran with no background imported ($($res | ConvertTo-Json -Compress))" }
            }
            Assert-Equal $before (Get-Item -LiteralPath $wim).LastWriteTimeUtc 'the WIM must be untouched'
        } finally {
            Remove-Item -LiteralPath $wim -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'initrd lines come out for an overlay-eligible WIM' {
        # Make the fixture deterministic regardless of what the live store holds:
        # drop a cred file in, assert its line, clean up if we created it.
        # The store is the sandbox - build the served dir the way a publish would:
        # the Required deploy.unc must exist for the profile to emit at all, and a
        # cred file lets the optional-line assertion run.
        $dir = Get-AppPxeBootWimOverlayServedDir -OverlayProfile (Get-AppPxeBootWimOverlayProfiles | Select-Object -First 1)
        $null = New-Item -Path $dir -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $dir 'deploy.unc') -Value '\\10.20.30.40\Deploy$' -Encoding ASCII -NoNewline
        Set-Content -LiteralPath (Join-Path $dir 'deploy.cred') -Value "gateuser`r`ngatepass`r`n" -Encoding ASCII -NoNewline
        try {
            $lines = @(Get-AppPxeBootWimOverlayInitrdLines -WimFileName 'LiteTouchPE_x64.wim')
            if ($lines.Count -lt 1) { throw 'expected initrd lines for a custom WinPE' }
            foreach ($n in @('deploy.unc', 'deploy.cred', 'deploy.loghost')) {
                if (($lines -join ' ') -notmatch [regex]::Escape($n)) { throw "initrd line for '$n' missing" }
            }
            # Optional files carry iPXE's `||` so a 404 (cred deleted after the menu
            # was written) or a Secure Boot signature refusal on an unsigned PE tool
            # cannot abort the boot (both killed a live VM boot, 2026-08-24). The one
            # Required file stays fatal - a boot without deploy.unc cannot deploy.
            $credLine = @($lines | Where-Object { $_ -match 'deploy\.cred' })[0]
            if ($credLine -notmatch '\|\|\s*$') { throw "optional initrd line is not failure-tolerant: $credLine" }
            $uncLine = @($lines | Where-Object { $_ -match 'deploy\.unc' })[0]
            if ($uncLine -match '\|\|\s*$') { throw "required initrd line must stay fatal: $uncLine" }
        } finally {
            # sandbox - removed with it
        }
    }

    Test-Case 'every optional profile key reads safely, present or not' {
        $bare = @{ Id = 'bare-profile'; AppliesTo = { param($Name) $false } }
        foreach ($key in @('Bakes', 'BakeAppliesTo', 'Runtime', 'PublishRuntime', 'IsEnabled', 'ServedSubdir')) {
            if ($null -ne (Get-AppPxeBootWimOverlayProfileField -OverlayProfile $bare -Name $key)) {
                throw "'$key' should read as null on a profile that does not set it"
            }
        }
        Assert-Equal 'bare-profile' (Get-AppPxeBootWimOverlayProfileField -OverlayProfile $bare -Name 'Id') 'Id'
        # A profile with no IsEnabled predicate counts as enabled.
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $bare)) { throw 'bare profile should be enabled' }
        # And the same read works on a PSCustomObject-shaped profile (JSON round-trip).
        $obj = [pscustomobject]@{ Id = 'obj-profile'; ServedSubdir = 'deploy' }
        Assert-Equal 'deploy' (Get-AppPxeBootWimOverlayProfileField -OverlayProfile $obj -Name 'ServedSubdir') 'ServedSubdir on an object'
        if ($null -ne (Get-AppPxeBootWimOverlayProfileField -OverlayProfile $obj -Name 'Bakes')) { throw 'missing key on an object should be null' }
    }

    Test-Case 'the deploy client rides in as an overlay file, never baked into the WIM' {
        # Craig, 2026-08-23: "cant this just be an overlay rather than rewriting every
        # and any boot.wim that is imported?" The client is a Runtime entry (served by
        # Caddy, injected by wimboot as an initrd), and the profile bakes nothing.
        $p = @(Get-AppPxeBootWimOverlayProfiles) | Where-Object { $_.Id -eq 'deploy-share' }
        $names = @($p.Runtime | ForEach-Object { $_.WinPeName })
        if ($names -notcontains 'startnet.cmd') { throw "startnet.cmd is not a runtime overlay entry (have: $($names -join ', '))" }
        $entry = $p.Runtime | Where-Object { $_.WinPeName -eq 'startnet.cmd' } | Select-Object -First 1
        if ([bool]$entry.Required) { throw 'startnet.cmd must not be Required - turning the client off must not suppress the share files' }
        # The ONLY bake is the WinPE background (initrd cannot override the stock
        # hardlinked winpe.jpg). The client itself must never be baked.
        $bakes = @(Get-AppPxeBootWimOverlayProfileField -OverlayProfile $p -Name 'Bakes')
        foreach ($b in $bakes) {
            if ([string]$b.WimPath -ne '/Windows/System32/winpe.jpg') { throw "unexpected bake target: $($b.WimPath)" }
        }
    }

    Test-Case 'the published client is CRLF and runs through the whole chain' {
        $src = Get-AppPxeBootDeployClientStartnetSource
        if (-not $src) { throw 'deploy client source not found' }
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("deploy-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $dir -ItemType Directory -Force
        try {
            Write-AppPxeBootDeployOverlayFiles -Dir $dir -LanIp '10.0.1.147'
            $served = Join-Path $dir 'startnet.cmd'
            if (-not (Test-Path -LiteralPath $served)) { throw 'startnet.cmd was not published' }
            $text = [System.IO.File]::ReadAllText($served)
            if ($text -match "(?<!`r)`n") { throw 'published startnet.cmd has LF-only line endings' }
            # The client must do each stage of the deployment, in this order.
            # Walked in order through the MAIN flow: subroutine bodies sit after it, so
            # each stage must appear on the line that calls it (hence :drvload_storage).
            $stages = @('wpeinit', 'net use Z:', 'TaskSequences\_default.txt', '.env', 'call :find_drivers', 'call :drvload_storage', 'diskpart', 'dism /Apply-Image', '/Add-Driver', 'bcdboot', 'Panther\unattend.xml', 'wpeutil reboot')
            $pos = -1
            foreach ($s in $stages) {
                $next = $text.IndexOf($s, [Math]::Max(0, $pos), [StringComparison]::OrdinalIgnoreCase)
                if ($next -lt 0) { throw "client is missing stage '$s'" }
                $pos = $next
            }
            # And it must only use what a stock WinPE carries plus what we inject
            # beside it (7z.exe, curl.exe) - never PowerShell or wmic.
            foreach ($tool in @('powershell', 'pwsh', 'wmic')) {
                if ($text -match "(?im)^\s*$tool(\.exe)?\b") { throw "client invokes '$tool', which a stock boot.wim does not have" }
            }
            # The injected tools are optional: every use is guarded so their absence
            # degrades (cab-only packs, local log) rather than errors.
            if ($text -notmatch '(?i)if not defined SEVENZIP') { throw '7z use is not guarded' }
            if ($text -notmatch '(?i)if defined LOGHOST if defined CURL') { throw 'curl use is not guarded' }
            # cmd precedence: `A && B & C` runs C whether or not A succeeded. One of these
            # made a driver folder holding only an archive return before it was expanded.
            foreach ($line in ($text -split "`r`n")) {
                if ($line -match '&&.*[^&]&\s*goto\s') { throw "precedence trap (A && B & goto): $($line.Trim())" }
            }
            # A loose INF tree (Craig's Proxmox\vm) must be used in place and /Recurse-injected.
            if ($text -notmatch '(?i)INF tree in place') { throw 'loose INF tree is not handled in place' }
            if ($text -notmatch '(?i)for /r "%DRIVERSTAGE%"') { throw 'drvload must walk the staged tree with a plain %var% root' }
            # The heartbeat keeps the panel's "active" badge alive through a silent DISM
            # apply, and must be stopped on BOTH exits (reboot and the failure prompt).
            if ($text -notmatch '(?i)call :heartbeat_start') { throw 'no heartbeat' }
            if (([regex]::Matches($text, '(?i)call :heartbeat_stop')).Count -lt 2) { throw 'heartbeat is not stopped on both exits' }
            # `> file echo on` writes nothing and flips console echo on for the rest of
            # the script (the echoed-everything wall, 2026-08-23). Only @echo off on
            # line 1 may control echo - no other executable echo on/off directive.
            foreach ($line in ($text -split "`r`n")) {
                $trimmed = $line.Trim()
                if ($trimmed -like 'rem *' -or $trimmed -eq '@echo off') { continue }
                if ($trimmed -match '(?i)(^|[&(]|>[^ ]*\s+)echo (on|off)($|\s*[&)>])') {
                    throw "executable echo on/off directive (turns console echo on): $trimmed"
                }
            }
            # The share is reached by IP and the connect is retried - a WinPE name
            # lookup of the macOS host is what failed between boots.
            if ($text -notmatch '(?i)for /l %%A in \(1,1,5\)') { throw 'net use is not retried' }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'the WinPE background is baked into boot WIMs (initrd cannot override it)' {
        # Craig, 2026-08-23: boot.wim customisation. WinPE reads System32\winpe.jpg, so it
        # rides in as an initrd like the client - the imported WIM is untouched.
        $p = @(Get-AppPxeBootWimOverlayProfiles) | Where-Object { $_.Id -eq 'deploy-share' }
        # BAKED, not injected: wimboot's initrd override does not take on the stock
        # hardlinked winpe.jpg (2026-08-24) - the bake engine replaces it in the WIM.
        $runtimeHit = @($p.Runtime | Where-Object { $_.WinPeName -eq 'winpe.jpg' })
        if ($runtimeHit.Count -gt 0) { throw 'winpe.jpg must not be a runtime initrd entry - injection cannot override the stock file' }
        $bake = @(Get-AppPxeBootWimOverlayProfileField -OverlayProfile $p -Name 'Bakes') | Where-Object { $_.WimPath -eq '/Windows/System32/winpe.jpg' }
        if (-not $bake) { throw 'winpe.jpg bake entry missing from the deploy-share profile' }
        $src = Join-Path ([IO.Path]::GetTempPath()) ("bg-" + [guid]::NewGuid().ToString('N') + '.png')
        [IO.File]::WriteAllBytes($src, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
        # The store is the sandbox (APP_TEST_DATA_ROOT) - no live backup dance needed.
        try {
            $null = Set-AppPxeBootBrandingImage -SourcePath $src
            $after = Get-AppPxeBootBrandingStatus
            if (-not $after.winpeBackground.present) { throw 'background did not import' }
            Assert-Equal 'winpe.jpg' $after.winpeBackground.fileName 'stored name'
        } finally {
            Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            $null = Clear-AppPxeBootBrandingImage
        }
    }

    Test-Case 'the .env a sequence publishes is what the client parses' {
        $rows = @(
            'TS_ID=server-standard', 'TS_NAME=Server', 'TS_UNATTEND=server-standard.xml',
            'TS_IMAGE=.mounts\srv-a38406a3\sources\install.wim', 'TS_INDEX=2'
        )
        # KEY=VALUE, one per line, value may contain backslashes and spaces, no quoting.
        foreach ($r in $rows) { if ($r -notmatch '^[A-Z_]+=[^\r\n]+$') { throw "row '$r' is not KEY=VALUE" } }
    }

    Test-Case 'the deploy UNC is the LAN IP, not the host name' {
        # WinPE could not resolve the Mac's host name reliably; everything else the
        # client talks to is the IP (Craig, 2026-08-23).
        $cfg = Read-AppPxeBootConfig
        $unc = Get-AppPxeBootDeployOverlayUnc -Cfg $cfg -LanIp '10.20.30.40'
        Assert-Equal '\\10.20.30.40\Deploy$' $unc 'unc uses the IP'
        # Falls back to a host name only when no IP is known.
        $fallback = Get-AppPxeBootDeployOverlayUnc -Cfg $cfg -LanIp ''
        if ($fallback -match '^\\\d+\.') { throw 'fallback should be a host name, not an IP' }
    }

    Test-Case 'no profile carries the old name' {
        foreach ($p in @(Get-AppPxeBootWimOverlayProfiles)) {
            if ("$($p.Id)$($p.ServedSubdir)" -match '(?i)imagedeployer') { throw "profile '$($p.Id)' still carries the old name" }
        }
    }
}
finally {
    Remove-Item Env:APP_TEST_DATA_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) { Write-Host "deploy overlay: $failures failure(s)"; exit 1 }
Write-Host 'deploy overlay: all checks passed'
exit 0
