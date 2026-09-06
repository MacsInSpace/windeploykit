# Field PXE boot helper - local HTTP (WIM/wimboot) + TFTP (snponly.efi).
# Optional WAN menu/catalog: deploy.example.com (hidden when local-HTTP-only). See docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md.

# Laptop/workstation field PXE only - no deploy.example.com chains in menus or snponly fallback.
# Set $false to re-enable WAN catalog items and deploy_base fallbacks.
# Standalone-load shim: scripts dot-source lib subsets in any order, and this lib
# calls Test-AppSidecarCommand (the fast Get-Command). Full version in AppPaths.ps1;
# this fallback is plain Get-Command, correct just slower. Same pattern as the
# Write-SidecarLog no-op shims.
if (-not (Get-Command Test-AppSidecarCommand -ErrorAction SilentlyContinue)) {
    function Test-AppSidecarCommand {
        param([Parameter(Mandatory)][string]$Name)
        [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }
}

$script:AppPxeBootLocalHttpOnly = $true
$script:AppPxeBootDefaultTftpBootFile = 'x86_64-sb/shimx64.efi'

function Test-AppPxeBootWanDeployMenuEnabled {
    -not $script:AppPxeBootLocalHttpOnly
}

$script:AppPxeBootState = @{
    StoreInitDeferred    = $false
    HttpProcess          = $null
    TftpProcess          = $null
    StartedAt            = $null
    LastHttpPath         = $null
    LastHttpAt           = $null
    LastTftpFile         = $null
    LastTftpAt           = $null
    HttpLastError        = $null
    TftpLastError        = $null
    TftpElevatedCommand  = $null
    TftpElevated         = $false
    TftpElevatedPid      = $null
    LastDriverSyncUtc    = $null
    # base (iso filename w/o ext) -> @{ isoFileName; isoPath; mountInfo; sourcesDir; installWim; base; httpPath; smbLink }
    IsoMounts            = @{}
    # Imaging-log ingest: loopback TcpListener behind the Caddy /imaging-log/* reverse_proxy.
    # @{ Listener; Runspace; PowerShell; Port } while running, else $null.
    LogIngest            = $null
    # Last "user|mode" the overlay credential publish logged at info level (repeat
    # publishes of the same identity log verbose - they fire on every menu regen).
    LastOverlayCredPublishKey = $null
}

$script:AppPxeBootStoreInitializing = $false
# Keep in sync with packaging/p7zip-tools.json (runtime install - not bundled in signed macOS pkg).
$script:AppPxeBootP7zipPinnedVersion = '25.01'   # upstream 7-Zip (7zz), not the Homebrew p7zip repack
$script:AppPxeBootP7zipInstallInProgress = $false
$script:AppPxeBootOptionalAssetsManifestCache = $null
$script:AppPxeBootOptionalAssetsManifestCacheAt = $null
$script:AppPxeBootWindowsSmbAclRoot = $null
$script:AppPxeBootWindowsSmbAclUser = $null

function Get-AppPxeBootStoreRoot {
    if (-not (Test-AppSidecarCommand Get-AppPluginDir)) {
        . (Join-Path $PSScriptRoot 'AppPaths.ps1')
    }
    Get-AppPluginDir -Plugin 'pxe-boot'
}

function Get-AppPxeBootBundledSnponlyPath {
    if (-not $SidecarRoot) { return $null }
    $path = Join-Path $SidecarRoot 'pxe/snponly.efi'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppPxeBootBundledWimbootPath {
    if ($SidecarRoot) {
        $path = Join-Path $SidecarRoot 'pxe/wimboot'
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/wimboot', 'vendor/binaries/pxe-wimboot/wimboot')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootBundledSecureBootTftpRoot {
    $marker = 'shimx64.efi'
    if ($SidecarRoot) {
        $dir = Join-Path $SidecarRoot 'pxe/x86_64-sb'
        if ((Test-Path -LiteralPath $dir -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $dir $marker) -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @(
            'sidecar/pxe/x86_64-sb'
            'vendor/binaries/pxe-secure-boot-x64/x86_64-sb'
        )) {
        $dir = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if ((Test-Path -LiteralPath $dir -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $dir $marker) -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }
    return $null
}

function Get-AppPxeBootConfigPath {
    Join-Path (Get-AppPxeBootStoreRoot) 'config.json'
}

function Get-AppPxeBootDefaultDeployMenuUrl {
    'http://deploy.example.com/deploy/os/'
}

function Read-AppPxeBootConfig {
    $defaults = [ordered]@{
        httpPort          = 8080
        interfaceId       = $null
        deployMenuUrl     = (Get-AppPxeBootDefaultDeployMenuUrl)
        tftpd64Path       = $null
        tftpMode          = 'router'
        tftpBootFile      = $script:AppPxeBootDefaultTftpBootFile
        defaultBootWim       = $null
        autoBootDefault      = $false
        smbShareEnabled      = $false
        smbOverlayEnabled    = $false
        deployOverlayCreds = 'throwaway'
        deployOverlayShare = 'Deploy$'
        deployClientInject = $true
        isoMountServe        = $true
        updatedAt            = $null
    }
    $path = Get-AppPxeBootConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]$defaults
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]$defaults
        }
        $obj = $raw | ConvertFrom-Json
        foreach ($key in @($defaults.Keys)) {
            if ($null -ne $obj.PSObject.Properties[$key]) {
                $defaults[$key] = $obj.$key
            }
        }
        # Pre-2026-08-22 configs stored these under imageDeployer* names.
        foreach ($pair in @(@('imageDeployerOverlayCreds', 'deployOverlayCreds'), @('imageDeployerOverlayShare', 'deployOverlayShare'))) {
            if ($null -eq $obj.PSObject.Properties[$pair[1]] -and $null -ne $obj.PSObject.Properties[$pair[0]]) {
                $defaults[$pair[1]] = $obj.($pair[0])
            }
        }
        # ISO mount + in-place install.wim serving is now default behavior (the toggle
        # was removed from the UI). Ignore any stale persisted false so the mounter and
        # the WIMs/ install.wim symlinks always run when HTTP starts.
        $defaults.isoMountServe = $true
        # deploy overlay creds: blank | throwaway | dept | vault:<id>
        if (-not (Test-AppPxeBootDeployOverlayCredsModeValue -Value ([string]$defaults.deployOverlayCreds))) {
            $defaults.deployOverlayCreds = 'throwaway'
        }
        if ([string]::IsNullOrWhiteSpace([string]$defaults.deployOverlayShare)) {
            $defaults.deployOverlayShare = 'Deploy$'
        }
        return [pscustomobject]$defaults
    } catch {
        Write-SidecarLog "PXE boot: config read failed - $($_.Exception.Message)"
        return [pscustomobject]$defaults
    }
}

function Write-AppPxeBootConfig {
    param(
        [int]$HttpPort = 8080,
        [string]$InterfaceId,
        [string]$DeployMenuUrl,
        [string]$Tftpd64Path,
        [string]$TftpMode = 'router',
        [string]$TftpBootFile,
        [string]$DefaultBootWim,
        [bool]$AutoBootDefault,
        [bool]$SmbShareEnabled,
        [bool]$SmbOverlayEnabled,
        [string]$DeployOverlayCreds,
        [string]$DeployOverlayShare,
        [bool]$DeployClientInject,
        [bool]$IsoMountServe
    )
    $existing = Read-AppPxeBootConfig
    # Use a distinct name - PowerShell treats $TftpBootFile and $tftpBootFile as the same variable.
    $storedTftpBootFile = if ($existing.tftpBootFile) { [string]$existing.tftpBootFile } else { $script:AppPxeBootDefaultTftpBootFile }
    if ($PSBoundParameters.ContainsKey('TftpBootFile')) {
        if ([string]::IsNullOrWhiteSpace($TftpBootFile)) {
            $storedTftpBootFile = $script:AppPxeBootDefaultTftpBootFile
        } else {
            $storedTftpBootFile = Get-AppPxeBootSafeTftpBootFileName -FileName $TftpBootFile
            if (-not (Test-AppPxeBootTftpBootFileExists -RelativePath $storedTftpBootFile)) {
                Write-SidecarLog "PXE boot: Option 67 boot file not on disk yet - saved tftp/$storedTftpBootFile to config"
            }
        }
    }
    $defaultWim = $existing.defaultBootWim
    if ($PSBoundParameters.ContainsKey('DefaultBootWim')) {
        if ([string]::IsNullOrWhiteSpace($DefaultBootWim)) {
            $defaultWim = $null
        } else {
            $defaultWim = Get-AppPxeBootSafeWimFileName -FileName $DefaultBootWim
        }
    }
    $cfg = [ordered]@{
        httpPort       = $HttpPort
        interfaceId    = if ([string]::IsNullOrWhiteSpace($InterfaceId)) { $null } else { $InterfaceId.Trim() }
        deployMenuUrl  = if ([string]::IsNullOrWhiteSpace($DeployMenuUrl)) {
            (Get-AppPxeBootDefaultDeployMenuUrl)
        } else {
            $DeployMenuUrl.Trim().TrimEnd('/')
        }
        tftpd64Path    = if ([string]::IsNullOrWhiteSpace($Tftpd64Path)) { $null } else { $Tftpd64Path.Trim() }
        tftpMode       = if ($TftpMode -in @('router', 'standalone', 'proxy')) { $TftpMode } else { 'router' }
        tftpBootFile   = $storedTftpBootFile
        defaultBootWim     = $defaultWim
        autoBootDefault    = if ($PSBoundParameters.ContainsKey('AutoBootDefault')) {
            [bool]$AutoBootDefault
        } elseif ($null -ne $existing.autoBootDefault) {
            [bool]$existing.autoBootDefault
        } else {
            $false
        }
        smbShareEnabled    = if ($PSBoundParameters.ContainsKey('SmbShareEnabled')) {
            [bool]$SmbShareEnabled
        } elseif ($null -ne $existing.smbShareEnabled) {
            [bool]$existing.smbShareEnabled
        } else {
            $false
        }
        smbOverlayEnabled  = if ($PSBoundParameters.ContainsKey('SmbOverlayEnabled')) {
            [bool]$SmbOverlayEnabled
        } elseif ($null -ne $existing.smbOverlayEnabled) {
            [bool]$existing.smbOverlayEnabled
        } else {
            $false
        }
        deployOverlayCreds = if ($PSBoundParameters.ContainsKey('DeployOverlayCreds')) {
            $next = ([string]$DeployOverlayCreds).Trim()
            if (Test-AppPxeBootDeployOverlayCredsModeValue -Value $next) { $next } else { 'throwaway' }
        } elseif (Test-AppPxeBootDeployOverlayCredsModeValue -Value ([string]$existing.deployOverlayCreds)) {
            ([string]$existing.deployOverlayCreds).Trim()
        } else {
            'throwaway'
        }
        deployClientInject = if ($PSBoundParameters.ContainsKey('DeployClientInject')) {
            [bool]$DeployClientInject
        } elseif ($null -ne $existing.PSObject.Properties['deployClientInject']) {
            [bool]$existing.deployClientInject
        } else {
            $true
        }
        deployOverlayShare = if ($PSBoundParameters.ContainsKey('DeployOverlayShare')) {
            if ([string]::IsNullOrWhiteSpace($DeployOverlayShare)) { 'Deploy$' } else { ([string]$DeployOverlayShare).Trim() }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$existing.deployOverlayShare)) {
            ([string]$existing.deployOverlayShare).Trim()
        } else {
            'Deploy$'
        }
        isoMountServe      = if ($PSBoundParameters.ContainsKey('IsoMountServe')) {
            [bool]$IsoMountServe
        } elseif ($null -ne $existing.isoMountServe) {
            [bool]$existing.isoMountServe
        } else {
            $true
        }
        updatedAt          = (Get-Date).ToString('o')
    }
    ($cfg | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Get-AppPxeBootConfigPath) -Encoding UTF8 -Force
    [pscustomobject]$cfg
}

function Get-AppPxeBootLayoutPaths {
    $root = Get-AppPxeBootStoreRoot
    # STORAGE POLICY (see AGENT_NOTES.md section 'Where data lives'):
    #   app-data store ($root)   -> TFTP root, boot WIMs, wimboot, configs. SMALL.
    #   image library (Deploy$)  -> ISOs, imageable/SOE WIMs, driver packs. LARGE.
    # The store sits on the SYSTEM DRIVE (%LOCALAPPDATA% / ~/Library/Application
    # Support), so nothing multi-GB may resolve into it. USM filled an SSD by writing
    # a ~60 GB WIM to %LOCALAPPDATA%; that is the bug this split exists to prevent.
    $libIso = $null; $libWims = $null
    try {
        # -NoCreate: merely resolving layout paths must not create the default
        # library folder before the frontend pushes the user's chosen root.
        $libRoot = Get-AppImageLibraryRoot -NoCreate
        $lib = Get-AppImageLibraryPaths -Root $libRoot
        $libIso = $lib.isoDir
        $libWims = $lib.wimsDir
    } catch {
        # Was a bare catch {} - it silently routed ISOs into the app-data store.
        Write-SidecarLog "PXE boot: image library unavailable, falling back to the default library root - $($_.Exception.Message)"
    }
    if (-not $libIso -or -not $libWims) {
        # Fall back to the image library DEFAULT root, never to $root. The default is
        # deliberately off the app-data tree (~/Public on macOS, ~/Downloads on
        # Windows) so a fallback still keeps GBs out of Application Support.
        $fallbackRoot = Get-AppImageLibraryDefaultRoot
        if (-not $libIso) { $libIso = Join-Path $fallbackRoot 'iso' }
        if (-not $libWims) { $libWims = Join-Path $fallbackRoot 'WIMs' }
    }
    @{
        storeRoot   = $root
        tftpRoot    = Join-Path $root 'tftp'
        httpRoot    = Join-Path $root 'http'
        snponlyEfi  = Join-Path $root 'tftp/snponly.efi'
        wimboot     = Join-Path $root 'http/wimboot/wimboot'
        wimDir          = Join-Path $root 'http/wim'
        imageWimsDir    = $libWims
        # ISOs mount here (inside the image-library tree, sibling of WIMs/) so the
        # install.wim symlinks dropped in WIMs/ are RELATIVE and stay within the
        # Deploy$ share. Apple smbd refuses to serve symlinks that escape the share,
        # so a /tmp mount + absolute link is invisible to Windows WinPE.
        isoMountDir     = Join-Path (Split-Path -Parent $libWims) '.mounts'
        isoDir          = $libIso
        caddyBinaryDir  = Join-Path $root 'binaries/caddy'
        tftpd64BinaryDir = Join-Path $root 'binaries/tftpd64'
        caddyfile       = Join-Path $root 'Caddyfile'
        bootChain       = Join-Path $root 'http/boot.ipxe'
        menuIpxe        = Join-Path $root 'http/menu.ipxe'
        brandingDir     = Join-Path $root 'http/branding'
        shareDir            = Join-Path $root 'http/share'
        dnsmasqConf = Join-Path $root 'dnsmasq-tftp.conf'
    }
}

function Test-AppPxeBootPluginEnabled {
    $rc = $script:AppState['RuntimeConfig']
    if ($rc -and $rc.Contains('pxeBootPluginEnabled')) {
        return [bool]$rc['pxeBootPluginEnabled']
    }
    return $false
}

function Set-AppPxeBootPluginRuntimeEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    if (-not $script:AppState['RuntimeConfig']) {
        $script:AppState['RuntimeConfig'] = @{}
    }
    $prev = $null
    if ($script:AppState['RuntimeConfig'].Contains('pxeBootPluginEnabled')) {
        $prev = [bool]$script:AppState['RuntimeConfig']['pxeBootPluginEnabled']
    }
    $script:AppState['RuntimeConfig']['pxeBootPluginEnabled'] = $Enabled
    if ($Enabled) {
        if ($script:AppState -and -not [bool]$script:AppState['IsReady']) {
            # Pre-login ApplyRuntimeConfig (bootstrap) - no disk work yet; store init runs
            # from Invoke-AppPostBootstrapPluginInit once the app is ready.
            $script:AppPxeBootState['StoreInitDeferred'] = $true
            Write-SidecarLogVerbose 'Netboot: plug-in enabled - store init deferred until after bootstrap.'
        } else {
            $script:AppPxeBootState['StoreInitDeferred'] = $false
            Ensure-AppPxeBootStoreLayoutLite | Out-Null
            Sync-AppPxeBootBundledBootAssets | Out-Null
            if ($null -eq $prev -or -not $prev) {
                Write-SidecarLog 'Netboot: pxe-boot store ready (http/iso, branding, drivers, share/)'
            }
        }
    } elseif ($null -ne $prev -and $prev -and -not $Enabled) {
        $script:AppPxeBootState['StoreInitDeferred'] = $false
        try {
            Stop-AppPxeBootServices -SkipAdminKill | Out-Null
        } catch {
            Write-SidecarLog "Netboot: stop on plugin disable - $($_.Exception.Message)"
        }
    }
}

function Complete-AppPxeBootDeferredStoreInit {
    <#
    .SYNOPSIS
        Run the store init skipped by a pre-login Set-AppPxeBootPluginRuntimeEnabled.
        Called from Invoke-AppPostBootstrapPluginInit after the app is ready.
    #>
    if (-not (Test-AppPxeBootPluginEnabled)) { return }
    if (-not [bool]$script:AppPxeBootState['StoreInitDeferred']) { return }
    $script:AppPxeBootState['StoreInitDeferred'] = $false
    Ensure-AppPxeBootStoreLayoutLite | Out-Null
    Sync-AppPxeBootBundledBootAssets | Out-Null
    Write-SidecarLog 'Netboot: pxe-boot store ready (http/iso, branding, drivers, share/)'
}

function Write-AppPxeBootStoreReadmeIfMissing {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ReadmeLines
    )
    # Refreshes on content change too - README text written once and never
    # updated left stale layout docs in the store (pre-image-library wording).
    $want = ($ReadmeLines -join "`n") + "`n"
    if (Test-Path -LiteralPath $Path) {
        $have = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ($have -eq $want) { return }
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }
    $want | Set-Content -LiteralPath $Path -Encoding UTF8 -NoNewline
}

function Test-AppPxeBootDriverSyncDue {
    param([int]$MinIntervalSeconds = 300)

    if (-not (Test-Path -LiteralPath (Get-AppPxeBootDriversIndexPath))) {
        return $true
    }
    $last = $script:AppPxeBootState.LastDriverSyncUtc
    if (-not $last) {
        return $true
    }
    return ((Get-Date).ToUniversalTime() - $last).TotalSeconds -ge $MinIntervalSeconds
}

function Ensure-AppPxeBootStoreLayoutLite {
    <#
    .SYNOPSIS
        Create store directories and default config only - no driver seeding, bundled sync, or menu writes.
        Used on plug-in enable and fast panel config reads.
    #>
    $paths = Get-AppPxeBootLayoutPaths
    foreach ($dir in @(
            $paths.tftpRoot
            (Join-Path $paths.httpRoot 'wimboot')
            $paths.wimDir
            (Join-Path $paths.httpRoot 'wim-boot')
            $paths.isoDir
            $paths.imageWimsDir
            $paths.brandingDir
            $paths.shareDir
            $paths.caddyBinaryDir
            $paths.tftpd64BinaryDir
        )) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }

    Write-AppPxeBootStoreReadmeIfMissing -Path (Join-Path $paths.isoDir 'README.txt') -ReadmeLines @(
        'Source ISOs for Netboot (this is the active iso/ folder - normally the image'
        'library at Settings > Downloads location). Caddy serves it at /iso/.'
        'Each ISO is mounted read-only and its install.wim served live at'
        '/iso-wim/<name>/install.wim - nothing is extracted or duplicated on disk.'
        'Add ISOs via Netboot > Add ISO, or drop .iso files here.'
    )
    Write-AppPxeBootStoreReadmeIfMissing -Path (Join-Path $paths.brandingDir 'README.txt') -ReadmeLines @(
        'PXE menu background PNGs for boot.ipxe and ISOs/menu.ipxe.'
        'Preferred: det-branding-1920x1080.png (also 1024x768 supported).'
    )
    Write-AppPxeBootStoreReadmeIfMissing -Path (Join-Path $paths.shareDir 'README.md') -ReadmeLines @(
        '# Share (reserved)'
        ' '
        'Future: peer/torrent plug-in to seed OOBD driver archives and DE official ISOs to other'
        "$(Get-AppProductDisplayName) laptops on the LAN. Not active yet - folder created when Netboot is enabled."
    )

    if (-not (Test-Path -LiteralPath (Get-AppPxeBootConfigPath))) {
        Write-AppPxeBootConfig | Out-Null
    }
    $paths
}

function Ensure-AppPxeBootStoreLayout {
    <#
    .SYNOPSIS
        Create the full Netboot HTTP/TFTP store tree (idempotent). Called before starting PXE services
        or mutating boot assets - not on every panel status poll.
    #>
    $paths = Ensure-AppPxeBootStoreLayoutLite

    # Extraction-era leftover: http/iso-wim/ held multi-GB install.wim extracts before
    # the mount-and-serve cut-over. /iso-wim/ is URL-namespace-only now (Caddy routes
    # onto the read-only ISO mounts under <library>/.mounts), so the physical folder
    # must not exist - a stale extract here would be silently served whenever the
    # matching mount was absent (prune per Craig, 2026-08-20).
    $legacyIsoWim = Join-Path $paths.httpRoot 'iso-wim'
    if (Test-Path -LiteralPath $legacyIsoWim) {
        Remove-Item -LiteralPath $legacyIsoWim -Recurse -Force -ErrorAction SilentlyContinue
        Write-SidecarLog 'PXE boot: pruned legacy http/iso-wim extraction folder (mount-and-serve only)'
    }

    if (Test-AppPxeBootDriverSyncDue) {
        Sync-AppPxeBootDriverStore | Out-Null
        $script:AppPxeBootState.LastDriverSyncUtc = (Get-Date).ToUniversalTime()
    }
    Sync-AppPxeBootBundledBootAssets | Out-Null
    Ensure-AppPxeBootAutoexecIfMissing | Out-Null
    Write-AppPxeBootTftpAutoexecScript | Out-Null
    $paths
}

function Initialize-AppPxeBootStore {
    if ($script:AppPxeBootStoreInitializing) {
        return Get-AppPxeBootLayoutPaths
    }
    $script:AppPxeBootStoreInitializing = $true
    try {
        return Initialize-AppPxeBootStoreCore
    } finally {
        $script:AppPxeBootStoreInitializing = $false
    }
}

function Initialize-AppPxeBootStoreCore {
    Ensure-AppPxeBootStoreLayout
}

function Sync-AppPxeBootBundledSnponly {
    $paths = Get-AppPxeBootLayoutPaths
    $bundled = Get-AppPxeBootBundledSnponlyPath
    if (-not $bundled) { return $false }
    if (-not (Test-Path -LiteralPath $paths.snponlyEfi)) {
        Copy-Item -LiteralPath $bundled -Destination $paths.snponlyEfi -Force
        Write-SidecarLog 'PXE boot: copied bundled snponly.efi to store'
        return $true
    }
    $bundledHash = (Get-FileHash -LiteralPath $bundled -Algorithm SHA256).Hash
    $storeHash = (Get-FileHash -LiteralPath $paths.snponlyEfi -Algorithm SHA256).Hash
    if ($bundledHash -eq $storeHash) { return $false }
    Copy-Item -LiteralPath $bundled -Destination $paths.snponlyEfi -Force
    Write-SidecarLog 'PXE boot: updated snponly.efi from app bundle'
    return $true
}

function Sync-AppPxeBootBundledWimboot {
    $paths = Get-AppPxeBootLayoutPaths
    $bundled = Get-AppPxeBootBundledWimbootPath
    if (-not $bundled) { return $false }
    if (-not (Test-Path -LiteralPath $paths.wimboot)) {
        Copy-Item -LiteralPath $bundled -Destination $paths.wimboot -Force
        Write-SidecarLog 'PXE boot: copied bundled wimboot to store'
        return $true
    }
    $bundledHash = (Get-FileHash -LiteralPath $bundled -Algorithm SHA256).Hash
    $storeHash = (Get-FileHash -LiteralPath $paths.wimboot -Algorithm SHA256).Hash
    if ($bundledHash -eq $storeHash) { return $false }
    Copy-Item -LiteralPath $bundled -Destination $paths.wimboot -Force
    Write-SidecarLog 'PXE boot: updated wimboot from app bundle'
    return $true
}

function Get-AppPxeBootBundledArchNames {
    # Every arch tree we stage. 'sb' is an ALIAS of x86_64-sb: upstream ships it as a
    # symlink and some firmware asks for sb/shimx64.efi. Staged as a real copy so the
    # served tree is symlink-free for Windows checkouts and TFTP daemons.
    @('x86_64', 'x86_64-sb', 'sb', 'i386', 'arm32', 'arm64', 'arm64-sb', 'riscv32', 'riscv64', 'loong64')
}

function Get-AppPxeBootArchSourceDirName {
    param([Parameter(Mandatory)][string]$ArchName)
    if ($ArchName -eq 'sb') { return 'x86_64-sb' }
    return $ArchName
}

function Get-AppPxeBootBundledArchRoot {
    <#
        Root holding the per-architecture iPXE trees. Unlike USM (single location) we
        carry two candidates, so require at least one recognised arch dir before
        accepting a root - sidecar/pxe/ also holds wimboot and snponly.efi.
    #>
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($SidecarRoot) { [void]$candidates.Add((Join-Path $SidecarRoot 'pxe')) }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if ($root) {
        foreach ($rel in @('sidecar/pxe', 'vendor/binaries/pxe-secure-boot-x64')) {
            [void]$candidates.Add((Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)))
        }
    }
    foreach ($dir in $candidates) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($arch in Get-AppPxeBootBundledArchNames) {
            $probe = Join-Path $dir (Get-AppPxeBootArchSourceDirName -ArchName $arch)
            if (Test-Path -LiteralPath $probe -PathType Container) {
                return (Resolve-Path -LiteralPath $dir).Path
            }
        }
    }
    return $null
}

function Sync-AppPxeBootBundledArchTftpTrees {
    <#
    .SYNOPSIS
        Stage EVERY bundled per-architecture iPXE tree into tftp/<arch>/ so any client's
        DHCP-offered path resolves. Previously only x86_64-sb was staged, and only when
        its shim hash changed, so a Secure Boot client asking for x86_64-sb/shimx64.efi
        404'd outright (USM 640f5bb; handover 2026-08-21).

        NEVER touches the TFTP ROOT files. tftp/snponly.efi is the BYTE-PATCHED build
        (embedded unofficial.wan fallback removed) and upstream ships root-level symlinks
        pointing at the UNPATCHED x86_64/snponly.efi - staging the root would silently
        re-arm the exact behaviour the patch removes. Root assets stay owned by
        Sync-AppPxeBootBundledSnponly.
    #>
    $srcRoot = Get-AppPxeBootBundledArchRoot
    if (-not $srcRoot) { return $false }
    $tftpRoot = (Get-AppPxeBootLayoutPaths).tftpRoot
    $changed = $false
    $staged = [System.Collections.Generic.List[string]]::new()

    foreach ($arch in Get-AppPxeBootBundledArchNames) {
        $srcDir = Join-Path $srcRoot (Get-AppPxeBootArchSourceDirName -ArchName $arch)
        if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { continue }
        $destDir = Join-Path $tftpRoot $arch
        $archChanged = $false

        foreach ($file in @(Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq '.DS_Store') { continue }
            $rel = $file.FullName.Substring($srcDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar, '/')
            $dest = Join-Path $destDir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
            # Upstream ships in-tree symlinks (x86_64-sb/ipxe-shim.efi -> shimx64.efi).
            # Stage the RESOLVED target: a copied file never matches the link's own
            # metadata, so an unresolved compare re-copies that tree on every poll.
            $srcInfo = $file
            if ($file.LinkTarget) {
                try {
                    $target = $file.ResolveLinkTarget($true)
                    if ($target) {
                        $resolved = Get-Item -LiteralPath $target.FullName -Force -ErrorAction SilentlyContinue
                        if ($resolved) { $srcInfo = $resolved }
                    }
                } catch {
                    Write-SidecarLogVerbose "PXE boot: could not resolve symlink $($file.FullName) - $($_.Exception.Message)"
                }
            }
            # Size+mtime check (Copy-Item preserves LastWriteTime): an unchanged tree
            # costs a stat per file instead of hashing ~21 MB on every poll.
            $destItem = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            if ($destItem -and $destItem.Length -eq $srcInfo.Length -and $destItem.LastWriteTimeUtc -eq $srcInfo.LastWriteTimeUtc) {
                continue
            }
            $parent = Split-Path -Parent $dest
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                $null = New-Item -Path $parent -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $srcInfo.FullName -Destination $dest -Force
            $archChanged = $true
        }
        if ($archChanged) {
            $changed = $true
            [void]$staged.Add($arch)
        }
    }

    if ($changed) {
        Write-SidecarLog "PXE boot: staged bundled iPXE arch trees into tftp/ ($($staged -join ', '))"
    }
    return $changed
}

function Sync-AppPxeBootBundledSecureBootTftp {
    # Back-compat shim: Secure Boot staging is now part of the all-arch sync.
    return (Sync-AppPxeBootBundledArchTftpTrees)
}

function Sync-AppPxeBootBundledBootAssets {
    <#
        Copy snponly.efi (patched, TFTP root), wimboot, and EVERY bundled per-arch iPXE
        tree from the app bundle into the user store.
        Called when Netboot is enabled, on full store layout, and at Start Imaging Services.
    #>
    $snponly = Sync-AppPxeBootBundledSnponly
    $wimboot = Sync-AppPxeBootBundledWimboot
    $archTrees = Sync-AppPxeBootBundledArchTftpTrees
    if ($archTrees) {
        Write-AppPxeBootTftpAutoexecScript | Out-Null
    }
    return ($snponly -or $wimboot -or $archTrees)
}

function Test-AppPxeBootWimIsMdtLiteTouch {
    <#
    .SYNOPSIS
        True for an MDT LiteTouch-built WinPE (LiteTouchPE_x64.wim and friends).
    .NOTES
        These ship without a coherent in-WIM BCD, so they boot from the bundled MDT
        boot files and keep bootmgfw inside the WIM for Secure Boot. A WIM under any
        other name can opt in through sidecar/pxe/wimboot-recipes.json.
    #>
    param([Parameter(Mandatory)][string]$FileName)
    return ([string]$FileName -match '(?i)litetouch')
}

function Test-AppPxeBootWimUsesDeployOverlay {
    <#
    .SYNOPSIS
        True for a boot WIM that can consume the Deploy$ overlay we inject at boot.
    .NOTES
        Any imported WinPE. Injection only happens when the overlay is enabled
        (Test-AppPxeBootDeployOverlayEnabled).
    #>
    param([Parameter(Mandatory)][string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FileName)) { return $false }
    return ([string]$FileName -match '(?i)\.wim$')
}

function Get-AppPxeBootDirectBootWimName {
    $cfg = Read-AppPxeBootConfig
    if (-not $cfg.defaultBootWim) { return $null }
    $defaultPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $cfg.defaultBootWim
    if (-not (Test-Path -LiteralPath $defaultPath)) { return $null }
    return [string]$cfg.defaultBootWim
}

function Get-AppPxeBootBootChainMode {
    $direct = Get-AppPxeBootDirectBootWimName
    if ($direct) { return "wimboot:$direct" }
    return 'deploy-iso'
}

function Get-AppPxeBootMenuDefaultChooseTarget {
    param(
        [string]$DirectBootWim,
        [array]$BootableWims,
        # Linux ISO rows (Get-AppPxeBootLinuxBootInventory). Only the default when there
        # is no WIM at all - Windows imaging stays the product's first answer.
        [array]$LinuxEntries
    )
    if ($DirectBootWim) { return 'boot_default' }
    $first = @($BootableWims | Select-Object -First 1)
    if ($first.Count -gt 0) {
        return Get-AppPxeBootMenuItemId -FileName ([string]$first[0].fileName)
    }
    $firstLinux = @($LinuxEntries | Select-Object -First 1)
    if ($firstLinux.Count -gt 0) {
        return [string]$firstLinux[0].id
    }
    return 'shell'
}

function Get-AppPxeBootBundledWimbootRecipesPath {
    $sidecarRoot = $script:SidecarRoot
    if (-not $sidecarRoot) { return $null }
    foreach ($rel in @('pxe/wimboot-recipes.json', 'sidecar/pxe/wimboot-recipes.json')) {
        $path = Join-Path $sidecarRoot $rel
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Read-AppPxeBootBundledWimbootRecipes {
    $path = Get-AppPxeBootBundledWimbootRecipesPath
    $map = @{}
    if (-not $path) { return $map }
    try {
        $data = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json -AsHashTable
        $recipes = $data['recipes']
        if ($recipes -is [System.Collections.IDictionary]) {
            foreach ($key in $recipes.Keys) {
                $map[[string]$key] = $recipes[$key]
            }
        }
    } catch {
        Write-SidecarLog "PXE boot: wimboot-recipes.json read failed - $($_.Exception.Message)"
    }
    return $map
}

function Get-AppPxeBootWimBootAssetsDir {
    param([Parameter(Mandatory)][string]$WimFileName)
    $stem = [IO.Path]::GetFileNameWithoutExtension($WimFileName)
    if ([string]::IsNullOrWhiteSpace($stem)) { return $null }
    $dir = Join-Path (Get-AppPxeBootLayoutPaths).httpRoot "wim-boot/$stem"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    foreach ($bcdName in @('BCD', 'bcd')) {
        if (Test-Path -LiteralPath (Join-Path $dir $bcdName)) { return $dir }
    }
    return $null
}

function Get-AppPxeBootWimBootAssetHttpRel {
    param(
        [Parameter(Mandatory)][string]$AssetsDir,
        [Parameter(Mandatory)][string]$HttpRoot,
        [string[]]$Candidates
    )
    foreach ($name in $Candidates) {
        $path = Join-Path $AssetsDir $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $rel = $path.Substring($HttpRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            return ($rel -replace '\\', '/')
        }
    }
    return $null
}

function Get-AppPxeBootRecipeValue {
    param(
        [hashtable]$Recipe,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not $Recipe.ContainsKey($Key)) { return $null }
    return $Recipe[$Key]
}

function Test-AppPxeBootRecipeFlag {
    param(
        [hashtable]$Recipe,
        [Parameter(Mandatory)][string]$Key
    )
    return $Recipe.ContainsKey($Key) -and [bool]$Recipe[$Key]
}

function Test-AppPxeBootWimExtractBootmgrFromWim {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [hashtable]$Recipe = $null
    )
    if ($Recipe -and (Test-AppPxeBootRecipeFlag -Recipe $Recipe -Key 'extractBootmgrFromWim')) { return $true }
    return (Test-AppPxeBootWimIsMdtLiteTouch -FileName $WimFileName)
}

function Get-AppPxeBootWimBootmgrAssetCandidates {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [hashtable]$Recipe = $null
    )
    if (Test-AppPxeBootWimExtractBootmgrFromWim -WimFileName $WimFileName -Recipe $Recipe) {
        return @()
    }
    if (Test-AppPxeBootWimIsMdtLiteTouch -FileName $WimFileName) {
        $assetsDir = Get-AppPxeBootWimBootAssetsDir -WimFileName $WimFileName
        if ($assetsDir -and (Test-Path -LiteralPath (Join-Path $assetsDir 'BCD'))) {
            return @('bootmgfw.efi', 'bootmgr', 'bootmgr.exe')
        }
        return @('wdsmgfw.efi', 'bootmgfw.efi', 'bootmgr', 'bootmgr.exe')
    }
    return @('bootmgfw.efi', 'bootmgr', 'bootmgr.exe')
}

function Get-AppPxeBootWimbootRecipe {
    param([Parameter(Mandatory)][string]$WimFileName)
    $recipe = @{
        index = 1
        gui   = $true
    }
    $bundled = Read-AppPxeBootBundledWimbootRecipes
    if ($bundled.ContainsKey($WimFileName)) {
        $src = $bundled[$WimFileName]
        if ($src -is [System.Collections.IDictionary]) {
            foreach ($key in $src.Keys) { $recipe[[string]$key] = $src[$key] }
        } else {
            foreach ($p in $src.PSObject.Properties) { $recipe[$p.Name] = $p.Value }
        }
    } elseif (($WimFileName -match '(?i)techtools') -or (Test-AppPxeBootWimIsMdtLiteTouch -FileName $WimFileName)) {
        $recipe['useBootAssets'] = $true
        $recipe['index'] = 1
        $recipe['gui'] = $true
        if (Test-AppPxeBootWimIsMdtLiteTouch -FileName $WimFileName) {
            $recipe['extractBootmgrFromWim'] = $true
        }
    }

    $useAssets = $false
    if (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'useBootAssets') { $useAssets = $true }
    if (Get-AppPxeBootWimBootAssetsDir -WimFileName $WimFileName) { $useAssets = $true }
    if ($useAssets) {
        $paths = Get-AppPxeBootLayoutPaths
        $assetsDir = Get-AppPxeBootWimBootAssetsDir -WimFileName $WimFileName
        if ($assetsDir) {
            if (-not (Test-AppPxeBootWimExtractBootmgrFromWim -WimFileName $WimFileName -Recipe $recipe)) {
                $bootmgr = Get-AppPxeBootWimBootAssetHttpRel -AssetsDir $assetsDir -HttpRoot $paths.httpRoot `
                    -Candidates (Get-AppPxeBootWimBootmgrAssetCandidates -WimFileName $WimFileName -Recipe $recipe)
                if ($bootmgr) { $recipe['bootmgr'] = $bootmgr }
            }
            $bcd = Get-AppPxeBootWimBootAssetHttpRel -AssetsDir $assetsDir -HttpRoot $paths.httpRoot `
                -Candidates @('BCD', 'bcd')
            $sdi = Get-AppPxeBootWimBootAssetHttpRel -AssetsDir $assetsDir -HttpRoot $paths.httpRoot `
                -Candidates @('boot.sdi')
            if ($bcd) { $recipe['bcd'] = $bcd }
            if ($sdi) { $recipe['bootsdi'] = $sdi }
        } elseif (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'useBootAssets') {
            $recipe['bootAssetsMissing'] = $true
        }
    }
    return $recipe
}

function Format-AppPxeBootWimbootKernelOptions {
    param([hashtable]$Recipe)
    $opts = [System.Collections.Generic.List[string]]::new()
    if ($Recipe.ContainsKey('index') -and $null -ne $Recipe['index']) {
        [void]$opts.Add("index=$($Recipe['index'])")
    }
    foreach ($flag in @('quiet', 'gui', 'rawbcd', 'rawwim', 'linear')) {
        if (Test-AppPxeBootRecipeFlag -Recipe $Recipe -Key $flag) { [void]$opts.Add($flag) }
    }
    if ($opts.Count -eq 0) { return '' }
    return ' ' + ($opts -join ' ')
}

function Format-AppPxeBootWimbootInitrdLine {
    param(
        [Parameter(Mandatory)][string]$EfiName,
        [Parameter(Mandatory)][string]$HttpRel,
        [Parameter(Mandatory)][string]$LegacyName
    )
    # iPXE tokenizes commands on spaces, so the URL path must be percent-encoded:
    # "wim/LiteTouchPE_x64 (1).wim" truncated at the space and 404'd at boot.
    $encoded = (@(([string]$HttpRel) -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    "initrd -n $EfiName `${http_base}/$encoded $LegacyName"
}

function Format-AppPxeBootIpxeMenuItemLine {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label
    )
    # iPXE: item id and label must be separated by a real tab (0x09).
    # Single-quoted 'item id`tLabel' writes literal backtick-t (0x60 0x74) -> choose sets ${target} to
    # "id`tPartialLabel" -> goto ${target} fails (iPXE backtick escaping) -> instant return to menu.
    # See docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md section "iPXE menu items - PowerShell tab quirk".
    "item $Id`t$Label"
}

function Get-AppPxeBootWimbootIpxeBlock {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [string]$EchoLabel
    )
    $block = [System.Collections.Generic.List[string]]::new()
    $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $WimFileName
    if ($EchoLabel) {
        [void]$block.Add("echo $EchoLabel")
    } elseif (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'bootAssetsMissing') {
        [void]$block.Add("echo WARN: $WimFileName boot files missing - re-add the WIM in Netboot")
    }
    [void]$block.Add('imgfree')
    $optStr = Format-AppPxeBootWimbootKernelOptions -Recipe $recipe
    [void]$block.Add("kernel `${http_base}/wimboot/wimboot$optStr")
    $bootmgr = Get-AppPxeBootRecipeValue -Recipe $recipe -Key 'bootmgr'
    if ($bootmgr) {
        [void]$block.Add((Format-AppPxeBootWimbootInitrdLine -EfiName 'bootmgfw.efi' -HttpRel $bootmgr -LegacyName 'bootmgr'))
    }
    $bcd = Get-AppPxeBootRecipeValue -Recipe $recipe -Key 'bcd'
    if ($bcd) {
        [void]$block.Add((Format-AppPxeBootWimbootInitrdLine -EfiName 'BCD' -HttpRel $bcd -LegacyName 'bcd'))
    }
    $bootsdi = Get-AppPxeBootRecipeValue -Recipe $recipe -Key 'bootsdi'
    if ($bootsdi) {
        [void]$block.Add((Format-AppPxeBootWimbootInitrdLine -EfiName 'boot.sdi' -HttpRel $bootsdi -LegacyName 'boot.sdi'))
    }
    foreach ($overlayLine in (Get-AppPxeBootWimOverlayInitrdLines -WimFileName $WimFileName)) {
        [void]$block.Add($overlayLine)
    }
    [void]$block.Add((Format-AppPxeBootWimbootInitrdLine -EfiName 'boot.wim' -HttpRel "wim/$WimFileName" -LegacyName 'boot.wim'))
    [void]$block.Add('boot')
    [void]$block.Add('imgfree')
    return @($block)
}

function Get-AppPxeBootWimOverlayProfiles {
    <#
    .SYNOPSIS
        Declarative, reusable WIM-overlay registry. Each profile describes how to enrich a
        family of boot WIMs in two independent, portable ways:

          * Bakes    - files baked into the WIM on disk via wimlib `add` (idempotent,
                       hash-markered). Use for static or generated payloads that belong
                       inside the image, e.g. a script or an unattend.xml.
          * Runtime  - small files published by Caddy and injected into WinPE System32 via
                       iPXE `initrd` at boot. Use for dynamic, rotation-friendly content
                       (connection details, tokens) so the WIM stays generic + secret-free.

        Add a new hashtable here to reuse the whole mechanism for another WIM - nothing
        else in the boot/HTTP pipeline needs to change.

        Profile keys (all optional unless noted):
          Id             string  - stable identifier (used in logs).
          ServedSubdir   string  - folder under http/ that holds this profile's runtime
                                    files (also the URL path). Required if Runtime is set.
          AppliesTo      {param($Name) ...} - predicate: does this WIM get the runtime
                                    injection? (Mandatory.)
          BakeAppliesTo  {param($Name) ...} - predicate for baking; defaults to AppliesTo.
                                    Often stricter (e.g. only the stock WIM, never variants).
          IsEnabled      {...}    - gate for both bake + runtime; profile is inert when $false.
          Bakes          @(@{ MarkerName; WimPath; Source })  - Source is a literal path or
                                    a {scriptblock} returning one. WimPath is the in-WIM dest.
          Runtime        @(@{ ServedName; WinPeName; Required })  - files to inject. A missing
                                    Required file suppresses that profile's whole injection
                                    (a missing initrd source would fail the iPXE boot).
          PublishRuntime {param($Dir,$LanIp) ...} - writes/refreshes the Runtime files into
                                    $Dir when enabled (the engine handles dir creation and
                                    removal-when-disabled).
    #>
    @(
        @{
            Id            = 'deploy-share'
            ServedSubdir  = 'deploy'
            # Any imported WinPE - the deploy client reads its install.wim URL from
            # iPXE and needs no injection. A custom deploy client reads these files from
            # its own root at boot.
            AppliesTo     = { param($Name) Test-AppPxeBootWimUsesDeployOverlay -FileName $Name }
            # Deploy source (smbOverlayEnabled) picks the UNC target; credentials are
            # independent. This machine needs the local Deploy$ share; an on-site WDS
            # only needs the runtime UNC/cred injection.
            IsEnabled     = { Test-AppPxeBootDeployOverlayEnabled }
            # The whole corporate story, and not one byte written into the user's WIM:
            # wimboot serves these as initrd files and WinPE sees them in System32,
            # startnet.cmd included - so a stock Windows boot.wim (which has dism,
            # diskpart, bcdboot and net, but no PowerShell and no curl) runs our
            # cmd-only client instead of `wpeinit` and a prompt. The WIM on disk stays
            # exactly as imported, and editing the client is a file copy, not a rebake.
            Runtime       = @(
                @{ ServedName = 'startnet.cmd'; WinPeName = 'startnet.cmd'; Required = $false }
                # The two things a stock WinPE cannot do: expand a vendor .exe/.zip/.7z
                # driver pack, and talk HTTP. Both LGPL/MIT-licensed, both already in
                # the repo, both now shipped in the app bundle. None is
                # Required - the client degrades (cab-only, local log) without them.
                @{ ServedName = '7z.exe';   WinPeName = '7z.exe';   Required = $false }
                @{ ServedName = '7za.dll';  WinPeName = '7za.dll';  Required = $false }
                @{ ServedName = '7zxa.dll'; WinPeName = '7zxa.dll'; Required = $false }
                @{ ServedName = 'curl.exe'; WinPeName = 'curl.exe'; Required = $false }
                # The deploy background. Server 2025's WinPE no longer paints
                # System32\winpe.jpg (proven 2026-08-24: a custom jpg BAKED into the
                # WIM still booted to a black desktop), so the background is drawn by
                # our own tiny viewer - a fullscreen bottom-most window behind the
                # console. Pure GDI + BMP so it works on ANY WinPE, and it rides the
                # overlay like everything else: the WIM is never modified (Craig:
                # "work with any wim without touching it"). Unsigned PE, so Secure
                # Boot clients pick it up from Z:\Tools like 7z/curl.
                @{ ServedName = 'wdk-bg.exe'; WinPeName = 'wdk-bg.exe'; Required = $false }
                @{ ServedName = 'deploy-bg.bmp'; WinPeName = 'deploy-bg.bmp'; Required = $false }
                # The deploy status panel: a floating C/GDI window over the
                # wallpaper that replaces the console as the face when present -
                # startnet.cmd feeds it via files (deploy.state, the log tail, a
                # confirm req/ack pair) and keeps the console as the engine and
                # fallback. C like wdk-bg, never Go: a bare Go runtime exe hard-
                # resets WinPE 26100 (proven 2026-08-25, boot-chain VM). The
                # deploy-ui.cfg colours (accent=/panel=) are edited in the panel.
                @{ ServedName = 'wdk-panel.exe'; WinPeName = 'wdk-panel.exe'; Required = $false }
                @{ ServedName = 'deploy-ui.cfg'; WinPeName = 'deploy-ui.cfg'; Required = $false }
                # Optional console-UI customisation: one line of header text, and an
                # ASCII logo drawn above it. Both absent by default.
                @{ ServedName = 'deploy.title'; WinPeName = 'deploy.title'; Required = $false }
                @{ ServedName = 'deploy-logo.txt'; WinPeName = 'deploy-logo.txt'; Required = $false }
                @{ ServedName = 'deploy.unc';  WinPeName = 'deploy.unc';  Required = $true }
                @{ ServedName = 'deploy.cred'; WinPeName = 'deploy.cred'; Required = $false }
                @{ ServedName = 'loghost';     WinPeName = 'deploy.loghost'; Required = $false }
            )
            PublishRuntime = { param($Dir, $LanIp) Write-AppPxeBootDeployOverlayFiles -Dir $Dir -LanIp $LanIp }
        }
        # Example (future): bake a static unattend.xml into a custom install WIM -
        # @{
        #     Id = 'soe-unattend'
        #     AppliesTo = { param($Name) $Name -ieq 'Install.wim' }
        #     Bakes = @(@{ MarkerName = '.soe-unattend'; WimPath = '/Windows/Panther/unattend.xml'; Source = { Get-AppPxeBootUnattendXmlSource } })
        # }
    )
}

function Get-AppPxeBootWimOverlayProfileField {
    <#
    .SYNOPSIS
        Read one optional key off an overlay profile.
    .NOTES
        StrictMode throws "The property 'X' cannot be found on this object" for a
        missing hashtable key read with dot notation, and every key in this registry
        except Id and AppliesTo is optional. Dropping Bakes from the deploy-share
        profile therefore broke Start Imaging Services outright (2026-08-23) - the
        `if (-not $profile.Bakes)` guard threw instead of skipping. Read optional keys
        through here, never with a dot.
    #>
    param(
        [Parameter(Mandatory)]$OverlayProfile,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $OverlayProfile) { return $null }
    if ($OverlayProfile -is [System.Collections.IDictionary]) {
        if ($OverlayProfile.Contains($Name)) { return $OverlayProfile[$Name] }
        return $null
    }
    $prop = $OverlayProfile.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-AppPxeBootWimOverlayProfileEnabled {
    param([Parameter(Mandatory)][hashtable]$OverlayProfile)
    $isEnabled = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $OverlayProfile -Name 'IsEnabled'
    if (-not $isEnabled) { return $true }
    return [bool](& $isEnabled)
}

function Get-AppPxeBootWimOverlayServedDir {
    param([Parameter(Mandatory)][hashtable]$OverlayProfile)
    $subdir = [string](Get-AppPxeBootWimOverlayProfileField -OverlayProfile $OverlayProfile -Name 'ServedSubdir')
    if ([string]::IsNullOrWhiteSpace($subdir)) { return $null }
    Join-Path (Get-AppPxeBootLayoutPaths).httpRoot $subdir
}

function Get-AppPxeBootWimOverlayInitrdLines {
    <#
    .SYNOPSIS
        iPXE `initrd` lines that inject a WIM's enabled runtime-overlay files into WinPE
        System32 at boot. Files are served fresh by Caddy (rotation needs no WIM rebake);
        the WIM on disk stays generic. A missing Required file suppresses that profile's
        injection so the boot never fails on a missing initrd source.
    #>
    param([Parameter(Mandatory)][string]$WimFileName)
    $lines = @()
    foreach ($overlayProfile in Get-AppPxeBootWimOverlayProfiles) {
        $runtime = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'Runtime'
        if (-not $runtime) { continue }
        $appliesTo = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'AppliesTo'
        if (-not $appliesTo) { continue }
        if (-not (& $appliesTo $WimFileName)) { continue }
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $overlayProfile)) { continue }
        $dir = Get-AppPxeBootWimOverlayServedDir -OverlayProfile $overlayProfile
        if (-not $dir) { continue }
        $profileLines = @()
        $ok = $true
        $servedSubdir = [string](Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'ServedSubdir')
        foreach ($entry in $runtime) {
            if ($entry.Required) {
                # A missing Required file suppresses the whole profile - a boot without
                # deploy.unc cannot deploy, so the menu must not promise it.
                if (-not (Test-Path -LiteralPath (Join-Path $dir $entry.ServedName))) {
                    $ok = $false
                    break
                }
                $profileLines += ('initrd -n {0} ${{http_base}}/{1}/{2} {0}' -f $entry.WinPeName, $servedSubdir, $entry.ServedName)
            } else {
                # Optional files are listed UNCONDITIONALLY with iPXE's `||` ignore-failure
                # idiom. Emitting them only-when-present made the menu a snapshot of a
                # moving directory: winpe.jpg was mid-republish during a service start and
                # the menu silently lost its line - Craig's VM booted with no background
                # (2026-08-24, third sighting of the same race). A 404 at boot now just
                # degrades, same as a Secure Boot refusal of an unsigned PE tool, and
                # startnet.cmd already copes with any absent file.
                $profileLines += ('initrd -n {0} ${{http_base}}/{1}/{2} {0} ||' -f $entry.WinPeName, $servedSubdir, $entry.ServedName)
            }
        }
        if ($ok) { $lines += $profileLines }
    }
    return $lines
}

function Get-AppPxeBootWimlibImagexPath {
    $bundled = Get-AppPxeBootBundledWimlibImagexPath
    if ($bundled) { return $bundled }
    foreach ($name in @('wimlib-imagex', 'wimlib-imagex.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    # No Homebrew / MacPorts probe (Craig, 2026-08-29: treat Homebrew as not installed -
    # the bundled binary is the only supported macOS source).
    return $null
}

function Get-AppPxeBootBundledWimlibImagexPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }

    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
            'aarch64'
        } else {
            'x86_64'
        }
        foreach ($rel in @(
            "binaries\wimlib\$arch\wimlib-imagex.exe"
            "binaries\wimlib\wimlib-imagex.exe"
            "vendor\binaries\pxe-windows\wimlib\$arch\wimlib-imagex.exe"
        )) {
            $path = Join-Path $root $rel
            if (Test-Path -LiteralPath $path) {
                return (Resolve-Path -LiteralPath $path).Path
            }
        }
        return $null
    }

    if ($IsMacOS) {
        $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
        $suffix = if ($isArm) { 'aarch64-apple-darwin' } else { 'x86_64-apple-darwin' }
        $candidates = [System.Collections.Generic.List[string]]::new()
        [void]$candidates.Add((Join-Path $root 'binaries/wimlib-imagex-universal'))
        [void]$candidates.Add((Join-Path $root "binaries/wimlib-imagex-$suffix"))
        [void]$candidates.Add((Join-Path $root 'vendor/binaries/pxe-macos/wimlib-imagex-universal'))
        [void]$candidates.Add((Join-Path $root "vendor/binaries/pxe-macos/wimlib-imagex-$suffix"))
        foreach ($path in $candidates) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            Set-AppPxeBootWimlibExecutable -Path $path
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Set-AppPxeBootWimlibExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not ($IsMacOS -or $IsDarwin)) { return }
    $null = & chmod '+x' $Path 2>$null
    $null = & xattr -d com.apple.quarantine $Path 2>$null
}

function Get-AppPxeBootWimlibRuntimeDirectory {
    param([Parameter(Mandatory)][string]$ImagexPath)
    Split-Path -Parent $ImagexPath
}

function Get-AppPxeBootWimBootAssetWimPaths {
    @(
        '/Windows/Boot/EFI/bootmgfw.efi'
        '/Windows/Boot/PXE/wdsmgfw.efi'
        '/Windows/Boot/DVD/EFI/BCD'
        '/Windows/Boot/DVD/EFI/boot.sdi'
        '/Windows/Boot/DVD/PCAT/BCD'
        '/Windows/Boot/DVD/PCAT/boot.sdi'
        '/Windows/Boot/PCAT/bootmgr'
        '/Windows/Boot/PXE/bootmgr.exe'
    )
}

function Get-AppPxeBootWimBootAssetBorrowPaths {
    @(
        '/Windows/Boot/DVD/EFI/BCD'
        '/Windows/Boot/DVD/EFI/boot.sdi'
        '/Windows/Boot/DVD/PCAT/BCD'
        '/Windows/Boot/DVD/PCAT/boot.sdi'
    )
}

function Invoke-AppPxeBootWimlibExtract {
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string[]]$WimPaths
    )
    $wimlib = Get-AppPxeBootWimlibImagexPath
    if (-not $wimlib) {
        throw "PXE boot: WIM tools are missing from this app install - reinstall $(Get-AppProductDisplayName) or contact support."
    }
    if (-not (Test-Path -LiteralPath $DestDir)) {
        $null = New-Item -Path $DestDir -ItemType Directory -Force
    }
    $argList = @(
        'extract', $WimPath, [string]$ImageIndex,
        "--dest-dir=$DestDir", '--no-acls', '--nullglob'
    ) + @($WimPaths)
    $runtimeDir = Get-AppPxeBootWimlibRuntimeDirectory -ImagexPath $wimlib
    Push-Location -LiteralPath $runtimeDir
    try {
        & $wimlib @argList 2>&1 | Out-String | ForEach-Object {
            if ($_ -match '\[ERROR\]|ERROR:') {
                Write-SidecarLog "PXE boot: wimlib $_".Trim()
            }
        }
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 49) {
        throw "PXE boot: wimlib-imagex extract failed (exit $LASTEXITCODE)."
    }
}



function Sync-AppPxeBootWimOverlays {
    <#
    .SYNOPSIS
        Bake every enabled overlay profile's files into the given WIM (generic, reusable).
        The engine filters by each profile's BakeAppliesTo/IsEnabled, so callers can hand it
        any WIM path and let the registry decide. Each bake is idempotent via its own hash
        marker beside the WIM, so no tech ever hand-runs wimlib.
    #>
    param([Parameter(Mandatory)][string]$WimPath)
    if (-not (Test-Path -LiteralPath $WimPath)) { return @() }
    $wimName = Split-Path -Leaf $WimPath
    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($overlayProfile in Get-AppPxeBootWimOverlayProfiles) {
        $bakes = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'Bakes'
        if (-not $bakes) { continue }
        $bakePredicate = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'BakeAppliesTo'
        if (-not $bakePredicate) { $bakePredicate = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'AppliesTo' }
        if (-not $bakePredicate) { continue }
        if (-not (& $bakePredicate $wimName)) { continue }
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $overlayProfile)) { continue }
        $profileId = [string](Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'Id')
        foreach ($bake in $bakes) {
            [void]$results.Add((Invoke-AppPxeBootWimOverlayBake -WimPath $WimPath -ProfileId $profileId -Bake $bake))
        }
    }
    return @($results)
}

function Invoke-AppPxeBootWimOverlayBake {
    <#
    .SYNOPSIS
        Bake one overlay source file into a WIM via wimlib `add` at $Bake.WimPath. Idempotent:
        a hash marker ($Bake.MarkerName) beside the WIM means it only re-bakes when the source
        changes or the WIM is replaced (mtime past the marker).
    #>
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [string]$ProfileId,
        [Parameter(Mandatory)][hashtable]$Bake
    )
    $src = if ($Bake.Source -is [scriptblock]) { & $Bake.Source } else { [string]$Bake.Source }
    if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src)) {
        return @{ skipped = $true; reason = 'no-source'; profile = $ProfileId }
    }

    $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    $wimDir = Split-Path -Parent $WimPath
    # Marker is per-WIM: with numbered stock copies bake-eligible, a shared
    # directory-level marker would let one WIM's bake suppress the other's.
    $marker = Join-Path $wimDir ("$($Bake.MarkerName)-" + (Split-Path -Leaf $WimPath))
    $markerItem = Get-Item -LiteralPath $marker -ErrorAction SilentlyContinue
    if ($markerItem) {
        $stored = [string](Get-Content -LiteralPath $marker -TotalCount 1 -ErrorAction SilentlyContinue)
        $wimItem = Get-Item -LiteralPath $WimPath -ErrorAction Stop
        if ($stored -eq $hash -and $markerItem.LastWriteTime -ge $wimItem.LastWriteTime) {
            return @{ skipped = $true; reason = 'current'; profile = $ProfileId }
        }
    }

    $wimlib = Get-AppPxeBootWimlibImagexPath
    if (-not $wimlib) {
        Write-SidecarLog "PXE boot: overlay bake skipped ($ProfileId) - wimlib-imagex missing"
        return @{ skipped = $true; reason = 'no-wimlib'; profile = $ProfileId }
    }

    # Optional compatibility gate: only bake into WIMs that already carry the listed paths
    # (e.g. the 1.10 external XAML). Skips - never writes the marker - so a later WIM
    # re-download is picked up on the next sync.
    # @() around the if: assignment from an if-expression unwraps empty arrays to $null.
    $requiresWimPaths = @(if ($Bake.ContainsKey('RequiresWimPaths')) { $Bake.RequiresWimPaths } else { })
    foreach ($required in $requiresWimPaths) {
        if ([string]::IsNullOrWhiteSpace([string]$required)) { continue }
        $runtimeDir = Get-AppPxeBootWimlibRuntimeDirectory -ImagexPath $wimlib
        Push-Location -LiteralPath $runtimeDir
        try {
            & $wimlib dir $WimPath 1 --path=$required 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            $hint = if ($Bake.ContainsKey('RequiresHint') -and $Bake.RequiresHint) { [string]$Bake.RequiresHint } else { "WIM lacks $required" }
            Write-SidecarLog "PXE boot: overlay bake skipped ($ProfileId) for $(Split-Path -Leaf $WimPath) - $hint"
            return @{ skipped = $true; reason = 'wim-incompatible'; profile = $ProfileId; missing = [string]$required }
        }
    }

    # WIMs imported from ISO media inherit the ISO's read-only mode (555) and wimlib
    # update refuses them (exit 71). The store's WIMs are ours to service - make it
    # writable before baking (found on Server2025-boot.wim, 2026-08-24).
    try {
        $wimItem = Get-Item -LiteralPath $WimPath
        if ($wimItem.IsReadOnly) { $wimItem.IsReadOnly = $false }
    } catch { }

    $updateFile = Join-Path ([IO.Path]::GetTempPath()) ("sm-pxe-wim-overlay-$([Guid]::NewGuid().ToString('N')).txt")
    try {
        Set-Content -LiteralPath $updateFile -Value "add `"$src`" $($Bake.WimPath) --no-acls" -Encoding ASCII -Force
        $runtimeDir = Get-AppPxeBootWimlibRuntimeDirectory -ImagexPath $wimlib
        Push-Location -LiteralPath $runtimeDir
        try {
            Get-Content -LiteralPath $updateFile -Raw | & $wimlib update $WimPath 1 2>&1 | Out-String | ForEach-Object {
                if ($_ -match '\[ERROR\]|ERROR:') {
                    Write-SidecarLog "PXE boot: overlay bake wimlib ($ProfileId) $_".Trim()
                }
            }
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            throw "wimlib update failed (exit $LASTEXITCODE)"
        }
        Set-Content -LiteralPath $marker -Value $hash -Encoding ASCII -Force
        Write-SidecarLog "PXE boot: baked overlay ($ProfileId) $($Bake.WimPath) into $(Split-Path -Leaf $WimPath)"
        return @{ patched = $true; profile = $ProfileId }
    } catch {
        Write-SidecarLog "PXE boot: overlay bake failed ($ProfileId) - $($_.Exception.Message)"
        return @{ patched = $false; error = $_.Exception.Message; profile = $ProfileId }
    } finally {
        Remove-Item -LiteralPath $updateFile -Force -ErrorAction SilentlyContinue
    }
}

$script:AppPxeBootDriversOs = 'Win11x64'
$script:AppPxeBootDriverPackExtensions = @('.7z', '.cab', '.exe', '.zip')

function Get-AppPxeBootDriversBundledSeedPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/driver-seed/models.seed.json', 'pxe/driver-seed/models.seed.json')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootDriversBundledReadmePath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/driver-seed/README.md', 'pxe/driver-seed/README.md')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Read-AppPxeBootDriversSeed {
    $path = Get-AppPxeBootDriversBundledSeedPath
    if (-not $path) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-SidecarLog "PXE boot: driver seed read failed - $($_.Exception.Message)"
        return $null
    }
}

function Get-AppPxeBootDriversOsRoot {
    # User-relocatable driver root: <image library>/Drivers/<Make>/<Model>/ -
    # the MDT-style publish/search convention (Win32_ComputerSystem
    # Manufacturer + Model; its cache-hit search is -Recurse -Depth 1 under
    # Deploy$\Drivers). Vendor folder names come from models.seed.json keys,
    # which are Manufacturer-style (Acer, LENOVO).
    (Get-AppImageLibraryPaths).driversDir
}

function Get-AppPxeBootDriversIndexPath {
    Join-Path (Get-AppPxeBootDriversOsRoot) 'index.json'
}

function Test-AppPxeBootDriverPackExtension {
    param([Parameter(Mandatory)][string]$Extension)
    $script:AppPxeBootDriverPackExtensions -contains $Extension.ToLowerInvariant()
}

function Get-AppPxeBootDriverPackInFolder {
    param([Parameter(Mandatory)][string]$FolderPath)
    $packs = @(Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue |
        Where-Object { Test-AppPxeBootDriverPackExtension -Extension $_.Extension } |
        Sort-Object Length -Descending)
    if ($packs.Count -gt 0) {
        return [string]$packs[0].Name
    }
    return $null
}

function Get-AppPxeBootDriverSeedStringProp {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Name
    )
    $prop = $Model.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return $null }
    [string]$prop.Value
}

function Get-AppPxeBootDriverSeedArrayProp {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Name
    )
    $prop = $Model.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return @() }
    $value = $prop.Value
    if ($value -is [System.Array]) {
        return @($value | Where-Object { $_ })
    }
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return @() }
    return @([string]$value)
}

function Get-AppPxeBootDriverNsspCatalogLabels {
    param([Parameter(Mandatory)]$Model)
    $labels = @(Get-AppPxeBootDriverSeedArrayProp -Model $Model -Name 'nsspCatalogLabels')
    if ($labels.Count -gt 0) { return $labels }
    @(Get-AppPxeBootDriverSeedArrayProp -Model $Model -Name 'nsspModelNames')
}

function Sync-AppPxeBootDriverStore {
    <#
    .SYNOPSIS
        Ensure OOBD driver folders exist (seed layout) and regenerate index.json.
    #>
    $osRoot = Get-AppPxeBootDriversOsRoot
    foreach ($dir in @($osRoot, (Join-Path $osRoot '_default'))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }

    $readmeSrc = Get-AppPxeBootDriversBundledReadmePath
    $readmeDest = Join-Path $osRoot 'README.md'
    if ($readmeSrc -and (-not (Test-Path -LiteralPath $readmeDest))) {
        Copy-Item -LiteralPath $readmeSrc -Destination $readmeDest -Force
    }

    $seed = Read-AppPxeBootDriversSeed

    # Layout is <Drivers>/<Make>/<Model>/ - the MDT-style publish/search
    # convention (its cache-hit search is -Recurse -Depth 1, so pre-seeded packs and
    # client-downloaded packs coexist in one tree). Beta call (Craig, 2026-08-18):
    # legacy flat <Drivers>/<model>/ dirs are trashed, not migrated - any child dir
    # that is not _default or a seed vendor folder is removed. Skipped when the seed
    # fails to load, so a transient read error can never wipe the vendor tree.
    if ($seed -and $seed.vendors) {
        $keepDirs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$keepDirs.Add('_default')
        foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
            [void]$keepDirs.Add([string]$vendorProp.Name)
        }
        # Catalog vendors are legitimate Make dirs even when absent from the seed -
        # without these, promoting a Dell/HP/Microsoft pack created Drivers/Dell/...
        # and the store sync the promote itself triggers deleted the pack seconds
        # later (only Acer/LENOVO survived by riding the seed's vendor list).
        foreach ($catalogVendor in @('Acer', 'LENOVO', 'Dell', 'HP', 'Microsoft')) {
            [void]$keepDirs.Add($catalogVendor)
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $osRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($keepDirs.Contains($child.Name)) { continue }
            # Only a FLAT legacy model folder (files, no subdirs) is trash. A dir with
            # model SUBDIRS is a Make container - MDT-style clients publish under raw
            # WMI Manufacturer names ('Dell Inc.', 'Microsoft Corporation') and techs
            # mirror remote deploy-share trees the same way; v1 silently deleted those (review
            # finding, 2026-08-20).
            $hasSubdirs = @(Get-ChildItem -LiteralPath $child.FullName -Directory -Force -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasSubdirs) {
                Write-SidecarLogVerbose "PXE boot: keeping non-catalog make folder '$($child.Name)' (has model subfolders)"
                continue
            }
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-SidecarLog "PXE boot: removed legacy flat driver folder '$($child.Name)' (layout is now Drivers/<Make>/<Model>)"
        }
    }

    $folderCount = 0
    if ($seed -and $seed.vendors) {
        foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
            $vendorDir = Join-Path $osRoot ([string]$vendorProp.Name)
            $models = @($vendorProp.Value.models)
            foreach ($model in $models) {
                $folderName = [string]$model.folder
                if ([string]::IsNullOrWhiteSpace($folderName)) { continue }
                $modelDir = Join-Path $vendorDir $folderName
                if (-not (Test-Path -LiteralPath $modelDir)) {
                    $null = New-Item -Path $modelDir -ItemType Directory -Force
                }
                $hintPath = Join-Path $modelDir 'DROP-ARCHIVE-HERE.txt'
                if (-not (Test-Path -LiteralPath $hintPath)) {
                    @(
                        "Drop the Win11 x64 OOBD driver pack here (.cab, .exe, .7z, or .zip)."
                        "The deploy client expands it at boot (7z) - or drop the INF tree itself, no repack needed."
                        "Or use aria2 Tracker -> OOBD drivers (Acer/Lenovo SCCM catalogs)."
                    ) | Set-Content -LiteralPath $hintPath -Encoding UTF8
                }
                $folderCount++
            }
        }
        # A seeded placeholder the seed no longer names (only DROP-ARCHIVE-HERE.txt in
        # it) goes away, so a renamed seed folder does not leave an empty twin behind -
        # Proxmox/VirtIO Q35 became Proxmox/vm on 2026-08-23. Anything with real
        # content is never touched.
        foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
            $vendorDir = Join-Path $osRoot ([string]$vendorProp.Name)
            if (-not (Test-Path -LiteralPath $vendorDir)) { continue }
            $seededFolders = @($vendorProp.Value.models | ForEach-Object { [string]$_.folder } | Where-Object { $_ })
            foreach ($modelDir in @(Get-ChildItem -LiteralPath $vendorDir -Directory -ErrorAction SilentlyContinue)) {
                if ($seededFolders -contains $modelDir.Name) { continue }
                $contents = @(Get-ChildItem -LiteralPath $modelDir.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.DS_Store' })
                $placeholderOnly = ($contents.Count -eq 0) -or (($contents.Count -eq 1) -and ($contents[0].Name -eq 'DROP-ARCHIVE-HERE.txt'))
                if (-not $placeholderOnly) { continue }
                Remove-Item -LiteralPath $modelDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-SidecarLog "PXE boot: removed empty seeded driver folder '$($vendorProp.Name)/$($modelDir.Name)' (no longer in the seed)"
            }
        }
    }

    $index = Write-AppPxeBootDriversIndex
    # aliases.json for the deploy client (model names / machine types / seed
    # wmiPatterns -> installed pack folders); no-ops unless the installed set changed.
    if (Test-AppSidecarCommand Write-AppPxeBootDriverAliasMap) {
        try { Write-AppPxeBootDriverAliasMap } catch {
            Write-SidecarLogVerbose "PXE boot: alias map write failed - $($_.Exception.Message)"
        }
    }
    @{
        osRoot       = $osRoot
        modelFolders = $folderCount
        indexPath    = Get-AppPxeBootDriversIndexPath
        readyCount   = if ($index) { [int]$index.readyCount } else { 0 }
        modelCount   = if ($index) { [int]$index.modelCount } else { 0 }
    }
}

function Write-AppPxeBootDriversIndex {
    $osRoot = Get-AppPxeBootDriversOsRoot
    $seed = Read-AppPxeBootDriversSeed
    $generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $readyCount = 0
    $modelCount = 0
    $vendorsOut = [ordered]@{}

    if ($seed -and $seed.vendors) {
        foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
            $vendorName = [string]$vendorProp.Name
            $entries = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($model in @($vendorProp.Value.models)) {
                $folderName = [string]$model.folder
                if ([string]::IsNullOrWhiteSpace($folderName)) { continue }
                $modelCount++
                # <Drivers>/<Make>/<Model>/ - served via the Caddy /drivers/* route
                # (handle_path re-roots onto the library, so the tree depth is free).
                $modelDir = Join-Path (Join-Path $osRoot $vendorName) $folderName
                $archive = Get-AppPxeBootDriverPackInFolder -FolderPath $modelDir
                $ready = -not [string]::IsNullOrWhiteSpace($archive)
                if ($ready) { $readyCount++ }
                [void]$entries.Add(@{
                        folder            = $folderName
                        vendor            = $vendorName
                        relPath           = "drivers/$vendorName/$folderName"
                        archive           = $archive
                        archiveReady      = $ready
                        nsspCatalogLabels = @(Get-AppPxeBootDriverNsspCatalogLabels -Model $model)
                        wmiPatterns       = @(Get-AppPxeBootDriverSeedArrayProp -Model $model -Name 'wmiPatterns')
                    })
            }
            $vendorsOut[$vendorName] = @($entries)
        }
    }

    $defaultDir = Join-Path $osRoot '_default'
    $defaultArchive = Get-AppPxeBootDriverPackInFolder -FolderPath $defaultDir
    $defaultReady = -not [string]::IsNullOrWhiteSpace($defaultArchive)

    $doc = [ordered]@{
        schema       = 1
        generated    = $generated
        os           = $script:AppPxeBootDriversOs
        modelCount   = $modelCount
        readyCount   = $readyCount
        default      = @{
            relPath      = 'drivers/_default'
            archive      = $defaultArchive
            archiveReady = $defaultReady
        }
        vendors      = $vendorsOut
    }

    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Get-AppPxeBootDriversIndexPath) -Encoding UTF8 -Force
    $doc
}

function Get-AppPxeBootDriversSummary {
    Sync-AppPxeBootDriverStore | Out-Null
    $indexPath = Get-AppPxeBootDriversIndexPath
    if (-not (Test-Path -LiteralPath $indexPath)) {
        return @{
            osRoot     = Get-AppPxeBootDriversOsRoot
            indexPath  = $indexPath
            modelCount = 0
            readyCount = 0
            httpPath   = 'drivers/index.json'
        }
    }
    try {
        $idx = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @{
            osRoot       = Get-AppPxeBootDriversOsRoot
            indexPath    = $indexPath
            modelCount   = [int](Get-AppSidecarJsonProp -Item $idx -Name 'modelCount')
            readyCount   = [int](Get-AppSidecarJsonProp -Item $idx -Name 'readyCount')
            defaultReady = [bool](Get-AppSidecarJsonProp -Item (Get-AppSidecarJsonProp -Item $idx -Name 'default') -Name 'archiveReady')
            generated    = [string](Get-AppSidecarJsonProp -Item $idx -Name 'generated')
            httpPath     = 'drivers/index.json'
        }
    } catch {
        @{
            osRoot     = Get-AppPxeBootDriversOsRoot
            indexPath  = $indexPath
            modelCount = 0
            readyCount = 0
            httpPath   = 'drivers/index.json'
        }
    }
}

function Move-AppPxeBootWimBootAssetsToRoot {
    param(
        [Parameter(Mandatory)][string]$AssetsDir,
        [string[]]$Extracted = @()
    )
    $promoted = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $AssetsDir -Recurse -File -ErrorAction SilentlyContinue)) {
        $baseName = [string]$file.Name
        $destName = switch -Regex ($baseName) {
            '^(?i)bootmgfw\.efi$' { 'bootmgfw.efi'; break }
            '^(?i)wdsmgfw\.efi$'  { 'bootmgfw.efi'; break }
            '^(?i)bcd$'           { 'BCD'; break }
            '^(?i)boot\.sdi$'     { 'boot.sdi'; break }
            '^(?i)bootmgr\.exe$'  { 'bootmgr.exe'; break }
            '^(?i)bootmgr$'       { 'bootmgr'; break }
            default               { $null }
        }
        if (-not $destName) { continue }
        $destPath = Join-Path $AssetsDir $destName
        if ((Test-Path -LiteralPath $destPath) -and $file.FullName -ne $destPath) { continue }
        if ($file.FullName -ne $destPath) {
            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
        }
        if ($promoted -notcontains $destName) { [void]$promoted.Add($destName) }
    }
    $windowsDir = Join-Path $AssetsDir 'Windows'
    if (Test-Path -LiteralPath $windowsDir) {
        Remove-Item -LiteralPath $windowsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in @($Extracted)) {
        if ($promoted -notcontains $name) { [void]$promoted.Add($name) }
    }
    return @($promoted)
}

function Test-AppPxeBootWimUsesBundledMdtBootAssets {
    param([Parameter(Mandatory)][string]$WimFileName)
    return (Test-AppPxeBootWimIsMdtLiteTouch -FileName $WimFileName)
}

function Get-AppPxeBootBundledMdtBootAssetsDir {
    if ($SidecarRoot) {
        $sidecarDir = Join-Path $SidecarRoot 'pxe/mdt-boot-x64'
        if ((Test-Path -LiteralPath (Join-Path $sidecarDir 'BCD')) -and
            (Test-Path -LiteralPath (Join-Path $sidecarDir 'boot.sdi')) -and
            (Test-Path -LiteralPath (Join-Path $sidecarDir 'bootmgfw.efi'))) {
            return (Resolve-Path -LiteralPath $sidecarDir).Path
        }
    }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @(
        'sidecar/pxe/mdt-boot-x64'
        'pxe/mdt-boot-x64'
        'vendor/binaries/pxe-mdt-boot/x64'
    )) {
        $dir = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'BCD'))) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'boot.sdi'))) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'bootmgfw.efi'))) { continue }
        return (Resolve-Path -LiteralPath $dir).Path
    }
    return $null
}

function Copy-AppPxeBootBundledMdtBootAssets {
    param(
        [Parameter(Mandatory)][string]$DestDir
    )
    $srcDir = Get-AppPxeBootBundledMdtBootAssetsDir
    if (-not $srcDir) { return @() }
    # BCD + boot.sdi only - bootmgfw.efi must come from inside the WIM (wimboot UEFI extract).
    return @(Copy-AppPxeBootWimBootAssetsFromDir -SourceDir $srcDir -DestDir $DestDir `
        -Names @('BCD', 'boot.sdi'))
}

function Resolve-AppPxeBootMdtBootAssetSourceDir {
    param([Parameter(Mandatory)][string]$SourceDirectory)
    $flatBcd = Join-Path $SourceDirectory 'BCD'
    if ((Test-Path -LiteralPath $flatBcd) -and (Test-Path -LiteralPath (Join-Path $SourceDirectory 'boot.sdi'))) {
        return $SourceDirectory
    }
    foreach ($rel in @(
        'EFI/Microsoft/Boot'
        'Boot'
        'Boot/x64/EFI/Microsoft/Boot'
        'Boot/x64/Boot'
        'x64/EFI/Microsoft/Boot'
        'x64/Boot'
    )) {
        $dir = Join-Path $SourceDirectory $rel
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        if (Test-Path -LiteralPath (Join-Path $dir 'BCD')) { return $dir }
        if (Test-Path -LiteralPath (Join-Path $dir 'bcd')) { return $dir }
    }
    $bootSdi = Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Filter 'boot.sdi' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($bootSdi) { return $bootSdi.Directory.FullName }
    return $SourceDirectory
}

function Resolve-AppPxeBootMdtBootAssetFiles {
    param([Parameter(Mandatory)][string]$SourceDirectory)
    $dir = Resolve-AppPxeBootMdtBootAssetSourceDir -SourceDirectory $SourceDirectory
    $root = $SourceDirectory
    $map = @{}
    foreach ($bcdName in @('BCD', 'bcd')) {
        $p = Join-Path $dir $bcdName
        if (Test-Path -LiteralPath $p) { $map['BCD'] = $p; break }
    }
    foreach ($sdiName in @('boot.sdi')) {
        $p = Join-Path $dir $sdiName
        if (Test-Path -LiteralPath $p) { $map['boot.sdi'] = $p; break }
    }
    foreach ($mgrRel in @('bootmgfw.efi', 'bootmgr.efi')) {
        $p = Join-Path $dir $mgrRel
        if (Test-Path -LiteralPath $p) { $map['bootmgfw.efi'] = $p; break }
    }
    if (-not $map.ContainsKey('bootmgfw.efi')) {
        foreach ($mgrRel in @('bootmgr.efi', 'bootmgfw.efi')) {
            $p = Join-Path $root $mgrRel
            if (Test-Path -LiteralPath $p) { $map['bootmgfw.efi'] = $p; break }
        }
    }
    return $map
}

function Test-AppPxeBootWimBootAssetsCoherent {
    param([Parameter(Mandatory)][string]$AssetsDir)
    $bcdPath = Join-Path $AssetsDir 'BCD'
    $bootmgrPath = Join-Path $AssetsDir 'bootmgfw.efi'
    $sdiPath = Join-Path $AssetsDir 'boot.sdi'
    if (-not (Test-Path -LiteralPath $bcdPath)) { return $false }
    if (-not (Test-Path -LiteralPath $bootmgrPath)) { return $false }
    if (-not (Test-Path -LiteralPath $sdiPath)) { return $false }
    $bcdDate = (Get-Item -LiteralPath $bcdPath).LastWriteTime.Date
    $mgrDate = (Get-Item -LiteralPath $bootmgrPath).LastWriteTime.Date
    return ($bcdDate -eq $mgrDate)
}

function Get-AppPxeBootWimBootAssetBorrowDir {
    param(
        [Parameter(Mandatory)][string]$Stem,
        [Parameter(Mandatory)][string]$BootRoot
    )
    if (-not (Test-Path -LiteralPath $BootRoot)) { return $null }
    $peers = @(Get-ChildItem -LiteralPath $BootRoot -Directory -ErrorAction SilentlyContinue | Sort-Object {
            if ($_.Name -match '(?i)techtools') { 0 } else { 1 }
        }, Name)
    foreach ($peer in $peers) {
        if ($peer.Name -eq $Stem) { continue }
        if (-not (Test-AppPxeBootWimBootAssetsCoherent -AssetsDir $peer.FullName)) { continue }
        return $peer.FullName
    }
    return $null
}

function Copy-AppPxeBootWimBootAssetsFromDir {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string[]]$Names
    )
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Names) {
        $candidates = if ($name -eq 'BCD') { @('BCD', 'bcd') } else { @($name) }
        foreach ($candidate in $candidates) {
            $src = Join-Path $SourceDir $candidate
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
            Copy-Item -LiteralPath $src -Destination (Join-Path $DestDir $name) -Force
            if ($copied -notcontains $name) { [void]$copied.Add($name) }
            break
        }
    }
    return @($copied)
}

function Test-AppPxeBootWimBootAssetsComplete {
    param([Parameter(Mandatory)][string]$WimFileName)
    $stem = [IO.Path]::GetFileNameWithoutExtension($WimFileName)
    $destDir = Join-Path (Get-AppPxeBootLayoutPaths).httpRoot "wim-boot/$stem"
    if (-not (Test-Path -LiteralPath $destDir -PathType Container)) { return $false }
    $hasBcd = (Test-Path -LiteralPath (Join-Path $destDir 'BCD')) -or (Test-Path -LiteralPath (Join-Path $destDir 'bcd'))
    $hasSdi = Test-Path -LiteralPath (Join-Path $destDir 'boot.sdi')
    if (-not $hasBcd -or -not $hasSdi) { return $false }
    $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $WimFileName
    if (Test-AppPxeBootWimExtractBootmgrFromWim -WimFileName $WimFileName -Recipe $recipe) {
        $wimPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $WimFileName
        return Test-Path -LiteralPath $wimPath
    }
    $hasBootmgr = @('bootmgfw.efi', 'bootmgr', 'bootmgr.exe') | Where-Object {
        Test-Path -LiteralPath (Join-Path $destDir $_)
    }
    return ($hasBootmgr.Count -gt 0)
}

function Get-AppPxeBootWimBootAssetsFailureMessage {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [hashtable]$ExportResult = @{}
    )
    if (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $WimFileName) {
        if (-not (Get-AppPxeBootBundledMdtBootAssetsDir)) {
            return "PXE boot: this app install is missing MDT boot files. Reinstall $(Get-AppProductDisplayName) or contact support."
        }
        return "PXE boot: could not install MDT boot files for $WimFileName."
    }
    if (-not (Get-AppPxeBootWimlibImagexPath)) {
        return "PXE boot: this app install is missing WIM tools needed to prepare boot files. Reinstall $(Get-AppProductDisplayName) or contact support."
    }
    return "PXE boot: could not prepare boot files (BCD, boot.sdi, boot manager) from $WimFileName. The WIM may be corrupt or unsupported."
}

function Ensure-AppPxeBootWimBootAssets {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [switch]$SkipMenuRegen
    )
    try {
        $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $WimFileName
        if (-not (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'useBootAssets')) {
            return @{ complete = $true; skipped = $true }
        }
        if (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $WimFileName) {
            # Always refresh LiteTouch WIMs from the bundled MDT boot files (cheap; keeps stack coherent).
        } elseif (Test-AppPxeBootWimBootAssetsComplete -WimFileName $WimFileName) {
            return @{ complete = $true; skipped = $true }
        }
        $export = Export-AppPxeBootWimBootAssets -WimFileName $WimFileName -SkipMenuRegen:$SkipMenuRegen
        if (-not $export.complete) {
            throw (Get-AppPxeBootWimBootAssetsFailureMessage -WimFileName $WimFileName -ExportResult $export)
        }
        return $export
    } finally {
        # Apply any enabled WIM overlays (the deploy UNC/cred files a custom deploy
        # client reads) on import too (idempotent), so they are ready before first boot.
        # The registry decides which WIMs each overlay targets.
        $overlayWim = Join-Path (Get-AppPxeBootLayoutPaths).wimDir (Get-AppPxeBootSafeWimFileName -FileName $WimFileName)
        if (Test-Path -LiteralPath $overlayWim) {
            Sync-AppPxeBootWimOverlays -WimPath $overlayWim | Out-Null
        }
    }
}

function Export-AppPxeBootWimBootAssets {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [int]$ImageIndex = 0,
        [switch]$Quiet,
        [switch]$SkipMenuRegen
    )
    $name = Get-AppPxeBootSafeWimFileName -FileName $WimFileName
    $paths = Get-AppPxeBootLayoutPaths
    $wimPath = Join-Path $paths.wimDir $name
    if (-not (Test-Path -LiteralPath $wimPath)) {
        throw "PXE boot: boot WIM not found: $name"
    }
    $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $name
    $index = if ($ImageIndex -gt 0) { $ImageIndex } else {
        $idx = Get-AppPxeBootRecipeValue -Recipe $recipe -Key 'index'
        if ($null -eq $idx) { 1 } else { [int]$idx }
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $destDir = Join-Path $paths.httpRoot "wim-boot/$stem"
    if (Test-Path -LiteralPath $destDir) {
        Remove-Item -LiteralPath $destDir -Recurse -Force
    }
    $null = New-Item -Path $destDir -ItemType Directory -Force

    $extracted = [System.Collections.Generic.List[string]]::new()
    $borrowed = [System.Collections.Generic.List[string]]::new()
    $packaged = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $name)) {
        try {
            Invoke-AppPxeBootWimlibExtract -WimPath $wimPath -ImageIndex $index `
                -DestDir $destDir -WimPaths (Get-AppPxeBootWimBootAssetWimPaths)
            foreach ($item in (Move-AppPxeBootWimBootAssetsToRoot -AssetsDir $destDir)) {
                if ($extracted -notcontains $item) { [void]$extracted.Add($item) }
            }
        } catch {
            if (-not $Quiet) { throw }
            Write-SidecarLog "PXE boot: boot asset extract for $name - $($_.Exception.Message)"
        }
    }

    if (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $name) {
        foreach ($item in (Copy-AppPxeBootBundledMdtBootAssets -DestDir $destDir)) {
            if ($packaged -notcontains $item) { [void]$packaged.Add($item) }
        }
        if ($packaged.Count -eq 0 -and -not $Quiet) {
            throw (Get-AppPxeBootWimBootAssetsFailureMessage -WimFileName $name)
        }
    }

    $needBorrow = @()
    if (-not (Test-Path -LiteralPath (Join-Path $destDir 'BCD'))) { $needBorrow += 'BCD' }
    if (-not (Test-Path -LiteralPath (Join-Path $destDir 'boot.sdi'))) { $needBorrow += 'boot.sdi' }
    if ($needBorrow.Count -gt 0 -and -not (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $name)) {
        # BCD/boot.sdi must match bootmgfw - mixing one WIM's bootmgr with another WIM's BCD causes 0xc000000f.
        $borrowNames = @($needBorrow + @('bootmgfw.efi'))
        $bootRoot = Join-Path $paths.httpRoot 'wim-boot'
        $borrowDir = Get-AppPxeBootWimBootAssetBorrowDir -Stem $stem -BootRoot $bootRoot
        if ($borrowDir) {
            foreach ($item in (Copy-AppPxeBootWimBootAssetsFromDir -SourceDir $borrowDir -DestDir $destDir -Names $borrowNames)) {
                if ($borrowed -notcontains $item) { [void]$borrowed.Add($item) }
            }
        } else {
            foreach ($peerWim in @(Get-ChildItem -LiteralPath $paths.wimDir -Filter '*.wim' -File -ErrorAction SilentlyContinue)) {
                if ($peerWim.Name -eq $name) { continue }
                try {
                    $peerTmp = Join-Path ([IO.Path]::GetTempPath()) ("sm-pxe-boot-borrow-$([Guid]::NewGuid().ToString('N'))")
                    Invoke-AppPxeBootWimlibExtract -WimPath $peerWim.FullName -ImageIndex 1 `
                        -DestDir $peerTmp -WimPaths (Get-AppPxeBootWimBootAssetBorrowPaths + '/Windows/Boot/EFI/bootmgfw.efi')
                    Move-AppPxeBootWimBootAssetsToRoot -AssetsDir $peerTmp | Out-Null
                    if (-not (Test-AppPxeBootWimBootAssetsCoherent -AssetsDir $peerTmp)) { continue }
                    foreach ($item in (Copy-AppPxeBootWimBootAssetsFromDir -SourceDir $peerTmp -DestDir $destDir -Names $borrowNames)) {
                        if ($borrowed -notcontains $item) { [void]$borrowed.Add($item) }
                    }
                    Remove-Item -LiteralPath $peerTmp -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath (Join-Path $destDir 'BCD')) -or
                        -not (Test-Path -LiteralPath (Join-Path $destDir 'boot.sdi'))) {
                        continue
                    }
                    break
                } catch {
                    Remove-Item -LiteralPath $peerTmp -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    $hasBootmgr = @('bootmgfw.efi', 'bootmgr', 'bootmgr.exe') | Where-Object {
        Test-Path -LiteralPath (Join-Path $destDir $_)
    }
    $hasBcd = (Test-Path -LiteralPath (Join-Path $destDir 'BCD')) -or (Test-Path -LiteralPath (Join-Path $destDir 'bcd'))
    $hasSdi = Test-Path -LiteralPath (Join-Path $destDir 'boot.sdi')
    if (Test-AppPxeBootWimExtractBootmgrFromWim -WimFileName $name) {
        $complete = ($hasBcd -and $hasSdi)
    } else {
        $complete = ($hasBootmgr.Count -gt 0) -and $hasBcd -and $hasSdi
    }

    if ($complete) {
        $srcParts = [System.Collections.Generic.List[string]]::new()
        if ($extracted.Count -gt 0) { [void]$srcParts.Add("extracted: $($extracted -join ', ')") }
        if ($packaged.Count -gt 0) { [void]$srcParts.Add("bundled-mdt: $($packaged -join ', ')") }
        if ($borrowed.Count -gt 0) { [void]$srcParts.Add("borrowed: $($borrowed -join ', ')") }
        $detail = if ($srcParts.Count -gt 0) { $srcParts -join '; ' } else { 'ok' }
        Write-SidecarLog "PXE boot: boot assets for $name -> wim-boot/$stem ($detail)"
    } elseif (-not $Quiet) {
        throw "PXE boot: could not build boot assets for $name (need bootmgr + BCD + boot.sdi)."
    } else {
        Write-SidecarLog "PXE boot: incomplete boot assets for $name - BCD/boot.sdi still missing"
    }

    if (-not $SkipMenuRegen) { Write-AppPxeBootMenuFiles }
    @{
        wimFileName = $name
        destDir     = $destDir
        extracted   = @($extracted)
        packaged    = @($packaged)
        borrowed    = @($borrowed)
        complete    = [bool]$complete
        library     = (Get-AppPxeBootWimLibraryResponse)
    }
}

function Sync-AppPxeBootWimBootAssets {
    $changed = $false
    foreach ($wim in @(Get-AppPxeBootWimInventory)) {
        # Apply any enabled WIM overlays (the deploy UNC/cred files a custom deploy
        # client reads) so Deploy$ auto-mounts without a tech hand-running wimlib.
        # The registry decides which WIMs each overlay targets.
        $overlayWim = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $wim.fileName
        if (Test-Path -LiteralPath $overlayWim) {
            Sync-AppPxeBootWimOverlays -WimPath $overlayWim | Out-Null
        }
        $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $wim.fileName
        if (-not (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'useBootAssets')) { continue }
        if (Test-AppPxeBootWimBootAssetsComplete -WimFileName $wim.fileName) { continue }
        try {
            $result = Export-AppPxeBootWimBootAssets -WimFileName $wim.fileName -Quiet -SkipMenuRegen
            if ($result.complete) { $changed = $true }
        } catch {
            Write-SidecarLog "PXE boot: auto-export boot assets for $($wim.fileName) failed - $($_.Exception.Message)"
        }
    }
    return $changed
}

function Import-AppPxeBootWimBootAssets {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [Parameter(Mandatory)][string]$SourceDirectory
    )
    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw 'PXE boot: boot assets source folder not found.'
    }
    $name = Get-AppPxeBootSafeWimFileName -FileName $WimFileName
    $wimPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $name
    if (-not (Test-Path -LiteralPath $wimPath)) {
        throw "PXE boot: import boot WIM first - $name not in store."
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $destDir = Join-Path (Get-AppPxeBootLayoutPaths).httpRoot "wim-boot/$stem"
    if (-not (Test-Path -LiteralPath $destDir)) {
        $null = New-Item -Path $destDir -ItemType Directory -Force
    }
    $copied = [System.Collections.Generic.List[string]]::new()
    $fileMap = Resolve-AppPxeBootMdtBootAssetFiles -SourceDirectory $SourceDirectory
    foreach ($destName in @('BCD', 'boot.sdi', 'bootmgfw.efi')) {
        if (-not $fileMap.ContainsKey($destName)) { continue }
        Copy-Item -LiteralPath $fileMap[$destName] -Destination (Join-Path $destDir $destName) -Force
        [void]$copied.Add($destName)
    }
    foreach ($candidate in @('bootmgr', 'bootmgr.exe')) {
        if ($copied.Count -ge 3) { break }
        $src = Join-Path $SourceDirectory $candidate
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        Copy-Item -LiteralPath $src -Destination (Join-Path $destDir $candidate) -Force
        if ($copied -notcontains $candidate) { [void]$copied.Add($candidate) }
    }
    if ($copied.Count -eq 0) {
        throw 'PXE boot: no bootmgr/BCD/boot.sdi found (use MDT Boot/x64, TechTools ISO boot/, or flat folder).'
    }
    Write-AppPxeBootMenuFiles
    Write-SidecarLog "PXE boot: copied boot assets for $name -> wim-boot/$stem ($($copied -join ', '))"
    @{
        wimFileName = $name
        destDir     = $destDir
        copied      = @($copied)
        library     = (Get-AppPxeBootWimLibraryResponse)
    }
}

function Test-AppPxeBootAutoBootDefaultOnPxe {
    param($Config)
    # The Boot WIMs selection is now the single control: a default target (WIM or
    # default-boot ISO) selected => auto-boot it; "No default" => menu-first. The old
    # standalone autoBootDefault toggle was removed from the UI. This predicate is only
    # consulted on code paths where a default target already exists, so auto-boot is on
    # whenever something is chosen and the menu is shown otherwise.
    return $true
}

function Get-AppPxeBootIpxeMenuUtilityItemLines {
    @(
        'item --gap -- ------------------------------'
        (Format-AppPxeBootIpxeMenuItemLine -Id 'localdisk' -Label 'Boot from local disk')
        (Format-AppPxeBootIpxeMenuItemLine -Id 'shell' -Label '_iPXE shell')
        (Format-AppPxeBootIpxeMenuItemLine -Id 'retry' -Label 'Refresh menu')
    )
}

function Get-AppPxeBootIpxeLocalDiskHandlerLines {
    @(
        ':localdisk'
        'echo Booting from local disk (leaving PXE)...'
        'sanboot --no-describe --drive 0x80 || exit'
        ''
    )
}

function Get-AppPxeBootMenuItemId {
    param([Parameter(Mandatory)][string]$FileName)
    $stem = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $slug = ($stem -replace '[^a-zA-Z0-9]+', '_').Trim('_').ToLower()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'wim' }
    "wim_$slug"
}

function Get-AppPxeBootLinuxMenuItemId {
    param([Parameter(Mandatory)][string]$FileName)
    # Same slug rule as the WIM items, different prefix, so a WIM and an ISO that share
    # a stem never collide in ${target}.
    $stem = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $slug = ($stem -replace '[^a-zA-Z0-9]+', '_').Trim('_').ToLower()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'iso' }
    "lnx_$slug"
}

function Get-AppPxeBootLinuxBootInventory {
    <#
    .SYNOPSIS
        The Linux ISOs the menu can boot right now: mounted, recognised, kernel and initrd
        still readable. Live state only (the mount map), so the menu never promises an
        ISO that has left the library or whose mount went away.
    #>
    $rows = [System.Collections.Generic.List[object]]::new()
    $paths = Get-AppPxeBootLayoutPaths
    foreach ($mount in @($script:AppPxeBootState.IsoMounts.Values)) {
        if ([string]$mount.kind -ne 'linux') { continue }
        $linux = $mount.linux
        if (-not $linux) { continue }
        if (-not (Test-Path -LiteralPath ([string]$mount.isoPath) -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath ([string]$linux.kernelPath) -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath ([string]$linux.initrdPath) -PathType Leaf)) { continue }
        $token = [string]$mount.base
        $initrdHttpRel = "iso-mount/$token/$([string]$linux.initrdRel)"
        $kernelArgs = [string]$linux.kernelArgs
        $installMode = 'iso'
        $note = ''
        $platform = if ([string]$linux.platform) { [string]$linux.platform } else { 'debian' }
        if ($platform -eq 'ubuntu') {
            # casper boots the live installer off this ISO and fetches the ISO itself over
            # HTTP (url=) - a complete install source, so the task-sequence submenu applies.
            $installMode = 'casper'
            $note = 'Installer: Ubuntu live server - the ISO streams from this machine, packages from the Ubuntu archive'
        }
        # Debian installer media: the ISO's own initrd is the CD-ROM flavour and cannot find
        # its media over PXE. With the matching netboot initrd fetched, boot THAT initrd
        # (kernel still off the ISO) and point the installer at the Debian mirror - the
        # ISO is only the kernel; drivers and packages come from the internet, current.
        $netboot = $linux.netboot
        if ($netboot -and $netboot.ready -and (Test-Path -LiteralPath (Join-Path $paths.httpRoot ([string]$netboot.httpRel)) -PathType Leaf)) {
            $initrdHttpRel = [string]$netboot.httpRel
            $kernelArgs = Add-AppPxeBootDebianInstallerKernelArgs -KernelArgs $kernelArgs -Codename ([string]$linux.codename)
            $installMode = 'netboot'
            $note = "Installer: netboot initrd (d-i $([string]$netboot.diVersion)), drivers and packages from $([string](Get-AppPxeBootDebianMirrorHostDirectory).host)"
        } elseif ($netboot) {
            $note = "NOTE: installer files not fetched ($([string]$netboot.reason)) - the installer will stop at media detection"
        }
        $rows.Add(@{
                id            = Get-AppPxeBootLinuxMenuItemId -FileName ([string]$mount.isoFileName)
                isoFileName   = [string]$mount.isoFileName
                label         = [string]$linux.label
                kernelHttpRel = "iso-mount/$token/$([string]$linux.kernelRel)"
                initrdHttpRel = $initrdHttpRel
                kernelArgs    = $kernelArgs
                installMode   = $installMode
                note          = $note
                codename      = [string]$linux.codename
                arch          = [string]$linux.arch
                platform      = $platform
            }) | Out-Null
    }
    # ISO-less Debian: the netboot pairs kept in the store (Add-AppPxeBootDebianNetboot).
    foreach ($pair in @(Get-AppPxeBootDebianNetbootPairs)) {
        $rows.Add((ConvertTo-AppPxeBootDebianNetbootInventoryRow -Pair $pair)) | Out-Null
    }
    return @($rows | Sort-Object { [string]$_.isoFileName })
}

function ConvertTo-AppPxeBootDebianNetbootInventoryRow {
    <#
    .SYNOPSIS
        One menu inventory row for a store-resident netboot pair - same keys as an ISO
        row, so Get-AppPxeBootLinuxMenuHandlerLines treats both alike (submenu included).
    #>
    param([Parameter(Mandatory)]$Pair)
    $codename = [string]$Pair.codename
    $arch = [string]$Pair.arch
    $baseArgs = if ($arch -eq 'amd64') { 'vga=788 --- quiet' } else { '--- quiet' }
    $mirrorHost = [string](Get-AppPxeBootDebianMirrorHostDirectory).host
    @{
        id            = Get-AppPxeBootLinuxMenuItemId -FileName "debian-$codename-$arch"
        isoFileName   = "debian-$codename-$arch"
        label         = "$(Get-AppPxeBootDebianReleaseLabel -Codename $codename) $arch installer (network)"
        kernelHttpRel = [string]$Pair.linuxHttpRel
        initrdHttpRel = [string]$Pair.initrdHttpRel
        kernelArgs    = Add-AppPxeBootDebianInstallerKernelArgs -KernelArgs $baseArgs -Codename $codename
        installMode   = 'netboot'
        note          = "Installer: netboot d-i $([string]$Pair.diVersion), drivers and packages from $mirrorHost"
        codename      = $codename
        arch          = $arch
        platform      = 'debian'
    }
}

function Get-AppPxeBootLocalHttpHostPort {
    # "10.0.1.147:8080", or "${next-server}:8080" for iPXE to expand when no LAN IP is known.
    # d-i's mirror/http/hostname takes host[:port] with no scheme.
    $base = Get-AppPxeBootLocalHttpBaseUrl
    return ($base -replace '^https?://', '')
}

function Get-AppPxeBootDebianMirrorHostDirectory {
    # "https://deb.debian.org/debian" -> @{ host = 'deb.debian.org'; directory = '/debian' }.
    # d-i takes the mirror as host + directory; protocol is passed separately.
    $base = Get-AppPxeBootDebianMirrorBase
    if ($base -match '^[a-z]+://([^/]+)(/.*)?$') {
        $dir = [string]$Matches[2]
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '/' }
        return @{ host = [string]$Matches[1]; directory = $dir.TrimEnd('/') + $(if ($dir.TrimEnd('/') -eq '') { '/' } else { '' }) }
    }
    return @{ host = 'deb.debian.org'; directory = '/debian' }
}

function Add-AppPxeBootDebianInstallerKernelArgs {
    param(
        [string]$KernelArgs,
        [string]$Codename
    )
    # Installer parameters go BEFORE '---': d-i copies whatever follows '---' into the
    # installed system's bootloader config, and a mirror URL has no business there.
    #
    # The mirror is the Debian mirror on the internet, not the mounted ISO (Craig,
    # 2026-09-05: "drop the premise - the ISOs are freely available, and it is always
    # up to date"). The ISO route (/iso-mount/<token>/) stays for the kernel, but a
    # netinst tree cannot feed the netboot initrd anyway: it omits the storage-driver
    # udebs (sata-modules, scsi-modules, ...) that its own CD-ROM initrd has built in,
    # so d-i reached partitioning with no disk. The signed mirror also means no
    # allow_unauthenticated - every udeb and .deb is verified.
    #   mirror/country=manual        without it choose-mirror ignores the preseeded
    #                                hostname and picks the locale's country mirror
    #   mirror/http/proxy=           answer the proxy question with "none"
    #   netcfg/choose_interface=auto the NIC that PXE-booted is the one to use
    $mirror = Get-AppPxeBootDebianMirrorHostDirectory
    $parts = @(
        'mirror/country=manual'
        'mirror/protocol=http'
        "mirror/http/hostname=$([string]$mirror.host)"
        "mirror/http/directory=$([string]$mirror.directory)"
        'mirror/http/proxy='
    )
    if (-not [string]::IsNullOrWhiteSpace($Codename)) { $parts += "mirror/suite=$Codename" }
    $parts += 'netcfg/choose_interface=auto'
    return (Add-AppPxeBootKernelArgsBeforeSeparator -KernelArgs $KernelArgs -Extra ($parts -join ' '))
}

function Add-AppPxeBootKernelArgsBeforeSeparator {
    # Insert installer parameters BEFORE '---'. d-i copies whatever follows '---' into the
    # installed system's bootloader config; mirror URLs and preseed URLs stay on the
    # installer side of it.
    param(
        [string]$KernelArgs,
        [Parameter(Mandatory)][string]$Extra
    )
    $existing = [string]$KernelArgs
    if ($existing -match '^(.*?)\s*---\s*(.*)$') {
        $before = $Matches[1].Trim()
        $after = $Matches[2].Trim()
        $head = if ($before) { "$before $Extra" } else { $Extra }
        return "$head --- $after".Trim()
    }
    if ([string]::IsNullOrWhiteSpace($existing)) { return $Extra }
    return "$($existing.Trim()) $Extra"
}

function Add-AppPxeBootDebianPreseedKernelArgs {
    <#
    .SYNOPSIS
        Point d-i at a published task sequence: the preseed URL, plus the two switches
        that make it unattended.
    .NOTES
        auto=true defers the locale and keyboard questions until the network is up and
        the preseed fetched; priority=critical asks nothing the preseed answers. Never
        emit auto=true without a URL - d-i then stops to ask for one (seen 2026-09-04).
        ${http_base} is iPXE's variable, expanded on the kernel line at boot, so the
        URL follows whatever the menu resolved (LAN IP or ${next-server}).
    #>
    param(
        [string]$KernelArgs,
        [Parameter(Mandatory)][string]$PreseedHttpRel
    )
    $extra = 'auto=true priority=critical preseed/url=${http_base}/' + $PreseedHttpRel.TrimStart('/')
    return (Add-AppPxeBootKernelArgsBeforeSeparator -KernelArgs $KernelArgs -Extra $extra)
}

function Add-AppPxeBootUbuntuAutoinstallKernelArgs {
    <#
    .SYNOPSIS
        Arm Subiquity: `autoinstall`, and the cloud-init NoCloud seed directory that holds
        user-data + meta-data (ds=nocloud-net;s=<url>/ - the trailing slash is required).
    #>
    param(
        [string]$KernelArgs,
        [Parameter(Mandatory)][string]$SeedHttpRel
    )
    $seed = $SeedHttpRel.TrimStart('/')
    if (-not $seed.EndsWith('/')) { $seed += '/' }
    # Drop the entry's placeholder cloud-config-url: the seed's user-data is the real one.
    $base = ([string]$KernelArgs -replace '\s*cloud-config-url=\S+', '')
    $extra = 'autoinstall ds=nocloud-net;s=${http_base}/' + $seed + ' cloud-config-url=${http_base}/' + $seed + 'user-data'
    return (Add-AppPxeBootKernelArgsBeforeSeparator -KernelArgs $base -Extra $extra)
}

function Get-AppPxeBootLinuxTaskSequenceChoices {
    <#
    .SYNOPSIS
        The Debian task sequences the Linux submenu can offer: enabled, platform debian,
        and the published <id>.cfg actually on the share (Caddy serves it at
        /TaskSequences/<id>.cfg). isDefault marks the store's default sequence when it is
        one of these; a Windows default leaves Interactive preselected - an unattended
        install wipes a disk, so it is never the default by accident.
    .NOTES
        PxeBootTaskSequences.ps1 loads after this lib; guarded like the sync call in
        Write-AppPxeBootMenuFiles.
    #>
    if (-not (Test-AppSidecarCommand Read-AppPxeBootTaskSequences)) { return @() }
    $dir = $null
    try { $dir = Get-AppPxeBootTaskSequenceLibraryDir } catch { $dir = $null }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $default = ''
    try { $default = ([string](Get-AppPxeBootTaskSequenceDefaultId)).Trim() } catch { $default = '' }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($seq in @(Read-AppPxeBootTaskSequences)) {
        if ($null -eq $seq) { continue }
        $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $seq
        if ($null -eq $rec -or -not [bool]$rec.enabled) { continue }
        $platform = [string]$rec.platform
        if ($platform -notin @('debian', 'ubuntu')) { continue }
        $id = [string]$rec.id
        # What publish wrote: a preseed file, or an autoinstall seed directory.
        if ($platform -eq 'ubuntu') {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $dir 'autoinstall') $id) 'user-data') -PathType Leaf)) { continue }
        } elseif (-not (Test-Path -LiteralPath (Join-Path $dir "$id.cfg") -PathType Leaf)) { continue }
        # installer: the panel's "Linux installer" binding, debian-<codename>-<arch>, or ''
        # for "any Debian entry". Decides which entries' submenus list this sequence.
        $installer = ''
        $flds = $rec.fields
        if ($flds -and $flds.Contains('linuxInstaller')) { $installer = ([string]$flds['linuxInstaller']).Trim().ToLowerInvariant() }
        $rows.Add(@{
                id         = $id
                name       = [string]$rec.name
                platform   = $platform
                # Debian: the preseed URL. Ubuntu: the NoCloud seed DIRECTORY (trailing slash).
                cfgHttpRel = if ($platform -eq 'ubuntu') { "TaskSequences/autoinstall/$id/" } else { "TaskSequences/$id.cfg" }
                isDefault  = ($default -and ($id -eq $default))
                installer  = $installer
            }) | Out-Null
    }
    return $rows.ToArray()
}

function Get-AppPxeBootLinuxIpxeBlock {
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$EchoLabel
    )
    # A Linux ISO boots the distro's own kernel + initrd straight off the mounted ISO
    # (Caddy /iso-mount/<token>/ route) - no wimboot, no extraction. initrd=<name> on the
    # kernel line is for older EFI stubs that look the initrd up by name; current
    # kernels take it from iPXE's LoadFile2 handoff and ignore it. BIOS iPXE passes the
    # initrd through the boot protocol either way.
    $block = [System.Collections.Generic.List[string]]::new()
    if ($EchoLabel) { [void]$block.Add("echo $EchoLabel") }
    [void]$block.Add('imgfree')
    $initrdName = [IO.Path]::GetFileName([string]$Entry.initrdHttpRel)
    $kernelArgs = ([string]$Entry.kernelArgs).Trim()
    $argStr = if ($kernelArgs) { " $kernelArgs" } else { '' }
    [void]$block.Add("kernel `${http_base}/$([string]$Entry.kernelHttpRel) initrd=$initrdName$argStr")
    [void]$block.Add("initrd `${http_base}/$([string]$Entry.initrdHttpRel)")
    [void]$block.Add('boot')
    [void]$block.Add('imgfree')
    return @($block)
}

function Get-AppPxeBootLinuxMenuItemLines {
    # One separator, then one item per Linux ISO. Nothing when there are none.
    param([array]$Entries)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        if ($lines.Count -eq 0) { [void]$lines.Add('item --gap -- ------------------------------') }
        [void]$lines.Add((Format-AppPxeBootIpxeMenuItemLine -Id ([string]$entry.id) -Label ([string]$entry.label)))
    }
    return $lines.ToArray()
}

function Get-AppPxeBootLinuxBootFailureLines {
    param([Parameter(Mandatory)][string]$Label)
    @(
        'echo'
        "echo Boot of $Label failed."
        # The bundled shim trusts the iPXE CA, not a distro's kernel signing key.
        'echo If Secure Boot is on, turn it off for Linux - this chain cannot verify a distro kernel.'
        'goto start'
        ''
    )
}

function Get-AppPxeBootLinuxSequenceMenuItemId {
    # <entry>__ts_<sequence slug>: unique per ISO x sequence, and a plain iPXE label.
    param(
        [Parameter(Mandatory)][string]$EntryId,
        [Parameter(Mandatory)][string]$SequenceId
    )
    $slug = ($SequenceId -replace '[^a-zA-Z0-9]+', '_').Trim('_').ToLower()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'ts' }
    return "${EntryId}__ts_$slug"
}

function Get-AppPxeBootLinuxMenuHandlerLines {
    <#
    .SYNOPSIS
        The :lnx_* handler blocks. An install-capable entry (netboot initrd in place) with
        published Debian sequences becomes a submenu - one item per sequence, an
        Interactive item, Back - and one handler per item; the sequence handlers carry
        preseed/url=. Boot-only entries and Live media stay a straight boot.
    .NOTES
        Selection has to happen HERE: d-i reads preseed/url= off the kernel line, so the
        menu entry decides which sequence a machine gets (there is no WinPE-style picker
        after boot). One entry per ISO with a submenu keeps 3 ISOs x 8 sequences at 3
        top-level items, not 24.
    #>
    param(
        [array]$Entries,
        # Get-AppPxeBootLinuxTaskSequenceChoices rows: id, name, cfgHttpRel, isDefault.
        [array]$Sequences
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $seqs = @($Sequences | Where-Object { $null -ne $_ })
    foreach ($entry in $Entries) {
        $label = [string]$entry.label
        $entryId = [string]$entry.id
        $note = [string]$entry.note
        # A sequence appears under entries of ITS platform (a preseed never under an Ubuntu
        # entry); one bound to an installer (<platform>-<codename>-<arch>) only under that
        # entry, an unbound one under every entry of the platform.
        $entryPlatform = if ($entry.ContainsKey('platform') -and [string]$entry.platform) { [string]$entry.platform } else { 'debian' }
        $entryKey = "$entryPlatform-$([string]$entry.codename)-$([string]$entry.arch)".ToLowerInvariant()
        $seqsFor = @($seqs | Where-Object {
                $seqPlatform = if ($_.ContainsKey('platform') -and [string]$_.platform) { [string]$_.platform } else { 'debian' }
                ($seqPlatform -eq $entryPlatform) -and (-not [string]$_.installer -or ([string]$_.installer -eq $entryKey))
            })
        # Install-capable: a Debian entry with its netboot initrd, or an Ubuntu casper entry.
        $useSubmenu = (([string]$entry.installMode) -in @('netboot', 'casper')) -and ($seqsFor.Count -gt 0)
        if (-not $useSubmenu) {
            [void]$lines.Add(":$entryId")
            if ($note) { [void]$lines.Add("echo $note") }
            foreach ($bootLine in (Get-AppPxeBootLinuxIpxeBlock -Entry $entry -EchoLabel "Booting $label...")) {
                [void]$lines.Add($bootLine)
            }
            foreach ($l in (Get-AppPxeBootLinuxBootFailureLines -Label $label)) { [void]$lines.Add($l) }
            continue
        }

        $manualId = "${entryId}__manual"
        $defaultTarget = $manualId
        [void]$lines.Add(":$entryId")
        [void]$lines.Add("menu $label - task sequence")
        [void]$lines.Add('item --gap -- ------------------------------')
        foreach ($seq in $seqsFor) {
            $itemId = Get-AppPxeBootLinuxSequenceMenuItemId -EntryId $entryId -SequenceId ([string]$seq.id)
            [void]$lines.Add((Format-AppPxeBootIpxeMenuItemLine -Id $itemId -Label ([string]$seq.name)))
            if ([bool]$seq.isDefault) { $defaultTarget = $itemId }
        }
        [void]$lines.Add((Format-AppPxeBootIpxeMenuItemLine -Id $manualId -Label 'Interactive install (no task sequence)'))
        [void]$lines.Add('item --gap -- ------------------------------')
        [void]$lines.Add((Format-AppPxeBootIpxeMenuItemLine -Id 'start' -Label 'Back'))
        [void]$lines.Add("choose --default $defaultTarget target || goto start")
        [void]$lines.Add('goto ${target}')
        [void]$lines.Add('')

        foreach ($seq in $seqsFor) {
            $itemId = Get-AppPxeBootLinuxSequenceMenuItemId -EntryId $entryId -SequenceId ([string]$seq.id)
            $seqName = [string]$seq.name
            $seeded = @{} + $entry
            $seeded.kernelArgs = if ($entryPlatform -eq 'ubuntu') {
                Add-AppPxeBootUbuntuAutoinstallKernelArgs -KernelArgs ([string]$entry.kernelArgs) -SeedHttpRel ([string]$seq.cfgHttpRel)
            } else {
                Add-AppPxeBootDebianPreseedKernelArgs -KernelArgs ([string]$entry.kernelArgs) -PreseedHttpRel ([string]$seq.cfgHttpRel)
            }
            [void]$lines.Add(":$itemId")
            if ($note) { [void]$lines.Add("echo $note") }
            [void]$lines.Add("echo Task sequence: $seqName - unattended, the disk named in the sequence will be wiped.")
            foreach ($bootLine in (Get-AppPxeBootLinuxIpxeBlock -Entry $seeded -EchoLabel "Booting $label...")) {
                [void]$lines.Add($bootLine)
            }
            foreach ($l in (Get-AppPxeBootLinuxBootFailureLines -Label $label)) { [void]$lines.Add($l) }
        }

        [void]$lines.Add(":$manualId")
        if ($note) { [void]$lines.Add("echo $note") }
        foreach ($bootLine in (Get-AppPxeBootLinuxIpxeBlock -Entry $entry -EchoLabel "Booting $label...")) {
            [void]$lines.Add($bootLine)
        }
        foreach ($l in (Get-AppPxeBootLinuxBootFailureLines -Label $label)) { [void]$lines.Add($l) }
    }
    return $lines.ToArray()
}

function Write-AppPxeBootMenuFiles {
    <#
    .SYNOPSIS
        Write http/boot.ipxe (+ menu.ipxe) for field PXE.
        - defaultBootWim set -> auto-boot that WIM (WDS-style); :start menu if boot returns
        - defaultBootWim unset -> choose menu of the imported boot WIMs
        - nothing imported -> WAN deploy chain when configured, else guidance + shell
    #>

    param(
        # The caller just ran Sync-AppPxeBootTaskSequenceStore itself (Update Deployment
        # Share wants its count) - skip the second, identical pass.
        [switch]$SkipTaskSequenceSync
    )

    # Task-sequence unattends ride the same regen cadence (save / start / import) so
    # Z:\TaskSequences always matches the panel. Guarded: lib loads after this one.
    if (-not $SkipTaskSequenceSync -and (Test-AppSidecarCommand Sync-AppPxeBootTaskSequenceStore)) {
        try { Sync-AppPxeBootTaskSequenceStore | Out-Null } catch {
            Write-SidecarLogVerbose "PXE boot: task-sequence sync skipped - $($_.Exception.Message)"
        }
    }

    $paths = Get-AppPxeBootLayoutPaths
    foreach ($dir in @($paths.httpRoot, $paths.tftpRoot)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }
    $cfg = Read-AppPxeBootConfig
    # The empty cloud-config an Interactive Ubuntu entry hands cloud-init (see the casper
    # layout row): without it cloud-init fetches the ISO named by url= as its config.
    try {
        $ccDir = Join-Path $paths.httpRoot 'linux/ubuntu'
        if (-not (Test-Path -LiteralPath $ccDir)) { $null = New-Item -Path $ccDir -ItemType Directory -Force }
        $ccFile = Join-Path $ccDir 'cloud-config-none'
        $ccBody = "#cloud-config`n{}`n"
        $ccHave = if (Test-Path -LiteralPath $ccFile) { Get-Content -LiteralPath $ccFile -Raw -ErrorAction SilentlyContinue } else { $null }
        if ($ccHave -ne $ccBody) { [System.IO.File]::WriteAllText($ccFile, $ccBody, (New-Object System.Text.UTF8Encoding $false)) }
    } catch {
        Write-SidecarLog "PXE boot: cloud-config-none not written - $($_.Exception.Message)"
    }

    # The deploy overlay (deploy.unc, deploy.cred, loghost, startnet.cmd, tools) is
    # decided here too: Get-AppPxeBootWimOverlayInitrdLines only injects a profile whose
    # Required files exist, so they must be published BEFORE the menu lines below are
    # built. This call lived in the FieldIso asset sync until c5bb958 deleted that
    # function (2026-08-24); from then on a fresh store never got an overlay at all and
    # an imported WIM booted to a bare WinPE prompt - it kept working on the dev box
    # only because the files already existed and the housekeeping tick refreshed them.
    try {
        Write-AppPxeBootWimOverlayRuntimeAssets -LanIp ([string](Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId))
    } catch {
        Write-SidecarLog "PXE boot: deploy overlay publish failed - $($_.Exception.Message)"
    }
    $port = [int]$cfg.httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $deployBase = Get-AppPxeBootWanIsoCatalogUrl
    $wanDeployEnabled = Test-AppPxeBootWanDeployMenuEnabled
    $generated = (Get-Date).ToString('o')

    $directBootWim = Get-AppPxeBootDirectBootWimName
    $wims = @(Get-AppPxeBootWimInventory)
    $linuxEntries = @(Get-AppPxeBootLinuxBootInventory)
    # Published Debian sequences: the task-sequence sync above already wrote their .cfg.
    $linuxSequences = @(Get-AppPxeBootLinuxTaskSequenceChoices)

    $bootMenuLines = [System.Collections.Generic.List[string]]::new()
    $httpBaseLiteral = Get-AppPxeBootLocalHttpBaseUrl
    [void]$bootMenuLines.Add('#!ipxe')
    [void]$bootMenuLines.Add("set http_port $port")
    if ($wanDeployEnabled) {
        [void]$bootMenuLines.Add("set deploy_base $deployBase")
    }
    [void]$bootMenuLines.Add("set http_base $httpBaseLiteral")
    $autoBoot = Test-AppPxeBootAutoBootDefaultOnPxe -Config $cfg

    if ($directBootWim) {
        $defaultMenuId = 'boot_default'
        [void]$bootMenuLines.Add("# Netboot field PXE - auto-boot $directBootWim - generated $generated")
        if ($autoBoot) {
            [void]$bootMenuLines.Add('goto boot_default_run')
        } else {
            [void]$bootMenuLines.Add('goto start')
        }
        [void]$bootMenuLines.Add('')
        [void]$bootMenuLines.Add(":boot_default")
        [void]$bootMenuLines.Add('chain ${http_base}/boot.ipxe?t=${buildsign} || goto boot_default_run')
        [void]$bootMenuLines.Add('')
        [void]$bootMenuLines.Add(":boot_default_run")
        foreach ($bootLine in (Get-AppPxeBootWimbootIpxeBlock -WimFileName $directBootWim -EchoLabel "Booting default: $directBootWim...")) {
            [void]$bootMenuLines.Add($bootLine)
        }
        [void]$bootMenuLines.Add('echo')
        [void]$bootMenuLines.Add("echo Auto-boot of $directBootWim failed - opening local menu.")
        [void]$bootMenuLines.Add('echo Pick Default (local) to retry, or another boot image.')
        [void]$bootMenuLines.Add('goto start')
        [void]$bootMenuLines.Add('')
        [void]$bootMenuLines.Add(':start')
        foreach ($line in @(Get-AppPxeBootMenuBrandingConsoleIpxeLines)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add('menu Field PXE - choose boot image')
        foreach ($line in @(Get-AppPxeBootMenuBrandingSubtitleIpxeLines)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add('item --gap -- ------------------------------')
        [void]$bootMenuLines.Add("item $defaultMenuId`tDefault (local): $directBootWim")
        foreach ($wim in $wims) {
            $name = [string]$wim.fileName
            if ($name -eq $directBootWim) { continue }
            $id = Get-AppPxeBootMenuItemId -FileName $name
            [void]$bootMenuLines.Add("item $id`t$name")
        }
        foreach ($line in @(Get-AppPxeBootLinuxMenuItemLines -Entries $linuxEntries)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add('item --gap -- ------------------------------')
        foreach ($line in @(Get-AppPxeBootIpxeMenuUtilityItemLines)) { [void]$bootMenuLines.Add([string]$line) }
        $defaultTarget = Get-AppPxeBootMenuDefaultChooseTarget -DirectBootWim $directBootWim -BootableWims $wims
        [void]$bootMenuLines.Add("choose --default $defaultTarget target || goto start")
        [void]$bootMenuLines.Add('goto ${target}')
        [void]$bootMenuLines.Add('')
        foreach ($wim in $wims) {
            $name = [string]$wim.fileName
            if ($name -eq $directBootWim) { continue }
            $id = Get-AppPxeBootMenuItemId -FileName $name
            [void]$bootMenuLines.Add(":$id")
            foreach ($bootLine in (Get-AppPxeBootWimbootIpxeBlock -WimFileName $name -EchoLabel "Booting $name...")) {
                [void]$bootMenuLines.Add($bootLine)
            }
            [void]$bootMenuLines.Add('echo')
            [void]$bootMenuLines.Add("echo Boot of $name failed.")
            [void]$bootMenuLines.Add('goto start')
            [void]$bootMenuLines.Add('')
        }
        foreach ($line in @(Get-AppPxeBootLinuxMenuHandlerLines -Entries $linuxEntries -Sequences $linuxSequences)) { [void]$bootMenuLines.Add([string]$line) }
        foreach ($line in @(Get-AppPxeBootIpxeLocalDiskHandlerLines)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add(':retry')
        [void]$bootMenuLines.Add('chain ${http_base}/boot.ipxe?t=${buildsign} || chain ${http_base}/boot.ipxe || goto start')
        [void]$bootMenuLines.Add('')
        [void]$bootMenuLines.Add(':shell')
        [void]$bootMenuLines.Add('shell')
        [void]$bootMenuLines.Add('goto start')
        $kernelOpts = Format-AppPxeBootWimbootKernelOptions -Recipe (Get-AppPxeBootWimbootRecipe -WimFileName $directBootWim)
        if ($autoBoot) {
            Write-SidecarLog "PXE boot: boot.ipxe auto-boots $directBootWim ($($kernelOpts.Trim())) (menu at :start if wimboot returns)"
        } else {
            Write-SidecarLog "PXE boot: boot.ipxe menu-first - default $directBootWim highlighted (autoBootDefault off)"
        }
    } elseif ($wims.Count -gt 0 -or $linuxEntries.Count -gt 0) {
        [void]$bootMenuLines.Add("# Netboot field PXE - local menu - generated $generated")
        [void]$bootMenuLines.Add('goto start')
        [void]$bootMenuLines.Add('')
        [void]$bootMenuLines.Add(':start')
        foreach ($line in @(Get-AppPxeBootMenuBrandingConsoleIpxeLines)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add('menu Field PXE - choose boot image')
        foreach ($line in @(Get-AppPxeBootMenuBrandingSubtitleIpxeLines)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add('item --gap -- ------------------------------')
        foreach ($wim in $wims) {
            $name = [string]$wim.fileName
            $id = Get-AppPxeBootMenuItemId -FileName $name
            [void]$bootMenuLines.Add("item $id`t$name")
        }
        foreach ($line in @(Get-AppPxeBootLinuxMenuItemLines -Entries $linuxEntries)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add('item --gap -- ------------------------------')
        foreach ($line in @(Get-AppPxeBootIpxeMenuUtilityItemLines)) { [void]$bootMenuLines.Add([string]$line) }
        $defaultTarget = Get-AppPxeBootMenuDefaultChooseTarget -DirectBootWim $null -BootableWims $wims -LinuxEntries $linuxEntries
        [void]$bootMenuLines.Add("choose --default $defaultTarget target || goto start")
        [void]$bootMenuLines.Add('goto ${target}')
        [void]$bootMenuLines.Add('')
        foreach ($wim in $wims) {
            $name = [string]$wim.fileName
            $id = Get-AppPxeBootMenuItemId -FileName $name
            [void]$bootMenuLines.Add(":$id")
            foreach ($bootLine in (Get-AppPxeBootWimbootIpxeBlock -WimFileName $name -EchoLabel "Booting $name...")) {
                [void]$bootMenuLines.Add($bootLine)
            }
            [void]$bootMenuLines.Add('echo')
            [void]$bootMenuLines.Add("echo Boot of $name failed.")
            [void]$bootMenuLines.Add('goto start')
            [void]$bootMenuLines.Add('')
        }
        foreach ($line in @(Get-AppPxeBootLinuxMenuHandlerLines -Entries $linuxEntries -Sequences $linuxSequences)) { [void]$bootMenuLines.Add([string]$line) }
        foreach ($line in @(Get-AppPxeBootIpxeLocalDiskHandlerLines)) { [void]$bootMenuLines.Add([string]$line) }
        [void]$bootMenuLines.Add(':retry')
        [void]$bootMenuLines.Add('chain ${http_base}/boot.ipxe?t=${buildsign} || chain ${http_base}/boot.ipxe || goto start')
        [void]$bootMenuLines.Add('')
        [void]$bootMenuLines.Add(':shell')
        [void]$bootMenuLines.Add('shell')
        [void]$bootMenuLines.Add('goto start')
        Write-SidecarLog "PXE boot: boot.ipxe local menu ($($wims.Count) WIM(s), $($linuxEntries.Count) Linux ISO(s), $($linuxSequences.Count) Debian sequence(s))"
    } else {
        if ($wanDeployEnabled) {
            [void]$bootMenuLines.Add("# Netboot field PXE - deploy chain - generated $generated")
            [void]$bootMenuLines.Add('echo Loading deploy menu...')
            [void]$bootMenuLines.Add('chain ${deploy_base}/menu.ipxe?t=${buildsign} || chain ${deploy_base}/menu.ipxe || goto failed')
            [void]$bootMenuLines.Add(':failed')
            [void]$bootMenuLines.Add('echo Could not load PXE menu from deploy server.')
            [void]$bootMenuLines.Add('shell')
            Write-SidecarLog "PXE boot: boot.ipxe chains deploy server ($deployBase)"
        } else {
            [void]$bootMenuLines.Add("# Netboot field PXE - no local boot assets - generated $generated")
            [void]$bootMenuLines.Add('echo No boot WIM or Linux ISO on this workstation.')
            [void]$bootMenuLines.Add("echo Open Netboot in $(Get-AppProductDisplayName) and add a boot WIM (import from a Windows ISO) or a Linux ISO.")
            [void]$bootMenuLines.Add('echo Enable HTTP + TFTP, then reboot the client.')
            [void]$bootMenuLines.Add('shell')
            Write-SidecarLog 'PXE boot: boot.ipxe has no local menu assets (add a boot WIM in Netboot)'
        }
    }

    $chainText = $bootMenuLines -join "`n"
    $chainText | Set-Content -LiteralPath $paths.bootChain -Encoding UTF8 -Force
    $chainText | Set-Content -LiteralPath $paths.menuIpxe -Encoding UTF8 -Force
    Sync-AppPxeBootTftpBootMenu -BootChainText $chainText
}

function Sync-AppPxeBootTftpBootMenu {
    param([Parameter(Mandatory)][string]$BootChainText)
    $paths = Get-AppPxeBootLayoutPaths
    $tftpBoot = Join-Path $paths.tftpRoot 'boot.ipxe'
    Set-Content -LiteralPath $tftpBoot -Value $BootChainText -Encoding UTF8 -Force
    Write-AppPxeBootTftpAutoexecScript | Out-Null
}

function Get-AppPxeBootAutoexecMirrorDirs {
    $tftpRoot = (Get-AppPxeBootLayoutPaths).tftpRoot
    $dirs = [System.Collections.Generic.List[string]]::new()
    [void]$dirs.Add($tftpRoot)
    foreach ($name in @('x86_64-sb', 'sb', 'x86_64', 'arm64-sb')) {
        $dir = Join-Path $tftpRoot $name
        if ((Test-Path -LiteralPath $dir -PathType Container) -and ($dirs -notcontains $dir)) {
            [void]$dirs.Add((Resolve-Path -LiteralPath $dir).Path)
        }
    }
    @($dirs)
}

function Get-AppPxeBootAutoexecScriptText {
    $cfg = Read-AppPxeBootConfig
    $port = [int]$cfg.httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $deployBase = Get-AppPxeBootWanIsoCatalogUrl
    $wanDeployEnabled = Test-AppPxeBootWanDeployMenuEnabled
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId
    $httpLiteral = if ($lanIp) { "http://${lanIp}:$port/boot.ipxe" } else { $null }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('#!ipxe')
    [void]$lines.Add('# Netboot - TFTP/HTTP autoexec (regenerated on menu sync)')
    if ($wanDeployEnabled) {
        [void]$lines.Add("set deploy_base $deployBase")
    }
    if ($httpLiteral) {
        [void]$lines.Add("set http_menu $httpLiteral")
    }
    [void]$lines.Add('chain tftp://${next-server}/boot.ipxe?t=${buildsign} || chain tftp://${next-server}/boot.ipxe || goto http_menu')
    if ($httpLiteral) {
        [void]$lines.Add(':http_menu')
        if ($wanDeployEnabled) {
            [void]$lines.Add('chain ${http_menu}?t=${buildsign} || chain ${http_menu} || goto wan_menu')
        } else {
            [void]$lines.Add('chain ${http_menu}?t=${buildsign} || chain ${http_menu} || goto failed')
        }
    } else {
        [void]$lines.Add(':http_menu')
        if ($wanDeployEnabled) {
            [void]$lines.Add(('chain http://${next-server}:' + $port + '/boot.ipxe?t=${buildsign} || chain http://${next-server}:' + $port + '/boot.ipxe || goto wan_menu'))
        } else {
            [void]$lines.Add(('chain http://${next-server}:' + $port + '/boot.ipxe?t=${buildsign} || chain http://${next-server}:' + $port + '/boot.ipxe || goto failed'))
        }
    }
    if ($wanDeployEnabled) {
        [void]$lines.Add(':wan_menu')
        [void]$lines.Add('chain ${deploy_base}/menu.ipxe?t=${buildsign} || chain ${deploy_base}/menu.ipxe')
    } else {
        [void]$lines.Add(':failed')
        [void]$lines.Add('echo Could not fetch PXE menu from this workstation (TFTP/HTTP).')
        [void]$lines.Add('echo Enable HTTP + TFTP in Netboot and add boot WIMs or ISOs.')
        [void]$lines.Add('prompt Press Ctrl-B for shell in 5 seconds... && shell || exit')
    }
    ($lines -join "`n")
}

function Set-AppPxeBootAutoexecScriptContent {
    param([Parameter(Mandatory)][string]$Content)
    $paths = Get-AppPxeBootLayoutPaths
    $written = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @(Get-AppPxeBootAutoexecMirrorDirs)) {
        $dest = Join-Path $dir 'autoexec.ipxe'
        Set-Content -LiteralPath $dest -Value $Content -Encoding UTF8 -Force
        [void]$written.Add($dest)
    }
    $httpDest = Join-Path $paths.httpRoot 'autoexec.ipxe'
    Set-Content -LiteralPath $httpDest -Value $Content -Encoding UTF8 -Force
    [void]$written.Add($httpDest)
    @($written)
}

function Ensure-AppPxeBootAutoexecIfMissing {
    <#
    .SYNOPSIS
        Create autoexec.ipxe wherever iPXE may load from (tftp root, x86_64-sb/, http/) if any copy is missing.
    #>
    $paths = Get-AppPxeBootLayoutPaths
    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @(Get-AppPxeBootAutoexecMirrorDirs)) {
        [void]$targets.Add((Join-Path $dir 'autoexec.ipxe'))
    }
    [void]$targets.Add((Join-Path $paths.httpRoot 'autoexec.ipxe'))
    $missing = @($targets | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -eq 0) { return $false }
    Write-SidecarLog "PXE boot: autoexec.ipxe missing ($($missing.Count) path(s)) - writing placeholder"
    $port = [int](Read-AppPxeBootConfig).httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $stub = @(
        '#!ipxe'
        '# Netboot - placeholder autoexec (full script written on menu sync / Start PXE)'
        'chain tftp://${next-server}/boot.ipxe || chain http://${next-server}:' + $port + '/boot.ipxe || shell'
    ) -join "`n"
    Set-AppPxeBootAutoexecScriptContent -Content $stub | Out-Null
    return $true
}

function Write-AppPxeBootTftpAutoexecScript {
    <#
    .SYNOPSIS
        TFTP/HTTP autoexec - iPXE loads this when no embedded script (incl. Secure Boot shim in x86_64-sb/).
        Mirrored to tftp/, tftp/x86_64-sb/, and http/ so TFTP-subdir and HTTP /autoexec.ipxe both work.
    #>
    $content = Get-AppPxeBootAutoexecScriptText
    Set-AppPxeBootAutoexecScriptContent -Content $content | Out-Null
}

function Get-AppPxeBootSafeWimFileName {
    param([Parameter(Mandatory)][string]$FileName)
    $base = [IO.Path]::GetFileName($FileName.Trim())
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw 'PXE boot: invalid WIM file name.'
    }
    if ($base -notmatch '\.wim$') { $base = "$base.wim" }
    if ($base -match '[\\/:*?"<>|]') {
        throw 'PXE boot: WIM file name contains invalid characters.'
    }
    return $base
}

function Get-AppPxeBootWimInventory {
    $paths = Get-AppPxeBootLayoutPaths
    $cfg = Read-AppPxeBootConfig
    $defaultName = if ($cfg.defaultBootWim) { [string]$cfg.defaultBootWim } else { $null }
    $files = @(Get-ChildItem -LiteralPath $paths.wimDir -Filter '*.wim' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    @($files | ForEach-Object {
        @{
            fileName   = $_.Name
            sizeBytes  = [long]$_.Length
            modifiedAt = $_.LastWriteTimeUtc.ToString('o')
            isDefault  = ($defaultName -and ($_.Name -eq $defaultName))
            httpPath   = "wim/$($_.Name)"
        }
    })
}

function Get-AppPxeBootIsoMenuItemId {
    param([Parameter(Mandatory)][string]$FileName)
    $safeName = Get-AppPxeBootSafeIsoFileName -FileName $FileName
    $stem = [IO.Path]::GetFileNameWithoutExtension($safeName)
    $slug = ($stem -replace '[^a-zA-Z0-9]+', '_').Trim('_').ToLower()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'iso' }
    if ($slug.Length -gt 24) { $slug = $slug.Substring(0, 24).Trim('_') }
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'iso' }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stem.ToLowerInvariant()))
    } finally {
        $sha.Dispose()
    }
    $hash = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
    "iso_${slug}_$hash"
}

function Get-AppPxeBootSafeIsoFileName {
    param([Parameter(Mandatory)][string]$FileName)
    $base = [IO.Path]::GetFileName($FileName.Trim())
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw 'PXE boot: invalid ISO file name.'
    }
    if ($base -notmatch '\.iso$') { $base = "$base.iso" }
    if ($base -match '[\\/:*?"<>|]') {
        throw 'PXE boot: ISO file name contains invalid characters.'
    }
    return $base
}

function Get-AppPxeBootIsoMountToken {
    param([Parameter(Mandatory)][string]$IsoFileName)
    # Deterministic, filesystem- AND Caddyfile/URL-safe folder token for an ISO's in-share
    # mount (.mounts/<token>) and its /iso-wim/<token>/ HTTP route. Why not the raw filename:
    # ISO names legally contain spaces and parentheses (e.g. "Windows 11 (24H2).iso") which
    # break the unquoted Caddyfile path and produce mismatched URLs. Why deterministic and not
    # a random UUID: mounting is idempotent and runs on every Start - a stable token reuses the
    # same mount and never orphans .mounts dirs, while the 8-char hash of the full name still
    # guarantees two distinct ISOs never collide (even if sanitisation maps their names together).
    $name = [IO.Path]::GetFileNameWithoutExtension(([IO.Path]::GetFileName($IsoFileName)).Trim())
    $safe = ($name -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-'
    $safe = $safe.Trim('-.')
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'iso' }
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40).Trim('-.') }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($name.ToLowerInvariant()))
    } finally {
        $sha.Dispose()
    }
    $hash = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
    "$safe-$hash"
}

function Get-AppPxeBootIsoUrlRel {
    param([Parameter(Mandatory)][string]$FileName)
    $slug = (Get-AppPxeBootIsoMenuItemId -FileName $FileName) -replace '^iso_', ''
    "ISOs/urls/$slug.iso.url"
}

function Get-AppPxeBootIsoHttpUrl {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][int]$Port,
        [string]$LanIp
    )
    $encodedName = [Uri]::EscapeDataString($FileName)
    if ([string]::IsNullOrWhiteSpace($LanIp)) {
        return "http://`${next-server}:$Port/iso/$encodedName"
    }
    return "http://${LanIp}:$Port/iso/$encodedName"
}

function Get-AppPxeBootInstallWimHttpUrl {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][int]$Port,
        [string]$LanIp
    )
    $safeName = Get-AppPxeBootSafeIsoFileName -FileName $FileName
    # Must match the live-mount route token (Mount-AppPxeBootInstallWimIsos / Caddy handle_path)
    # so a mounted ISO shadows any stale extracted copy at the same /iso-wim/<token>/ path.
    $encodedBase = Get-AppPxeBootIsoMountToken -IsoFileName $safeName
    if ([string]::IsNullOrWhiteSpace($LanIp)) {
        return "http://`${next-server}:$Port/iso-wim/$encodedBase/install.wim"
    }
    return "http://${LanIp}:$Port/iso-wim/$encodedBase/install.wim"
}

function Get-AppPxeBootInstallWimUrlRel {
    param([Parameter(Mandatory)][string]$FileName)
    $slug = (Get-AppPxeBootIsoMenuItemId -FileName $FileName) -replace '^iso_', ''
    "ISOs/urls/$slug.install.wim.url"
}

function Get-AppPxeBootP7zipToolsDir {
    $dir = Join-Path (Get-AppPxeBootStoreRoot) 'tools/p7zip'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    return $dir
}

function Get-AppPxeBootP7zipMarkerPath {
    Join-Path (Get-AppPxeBootP7zipToolsDir) '.p7zip-version'
}

function Test-AppPxeBootP7zipInstalled {
    param([switch]$RequirePinnedVersion)
    $dir = Get-AppPxeBootP7zipToolsDir
    # Upstream 7-Zip ships one self-contained universal binary, 7zz (no 7z.so).
    $sevenZz = Join-Path $dir '7zz'
    if (-not (Test-Path -LiteralPath $sevenZz -PathType Leaf)) {
        return $false
    }
    if ($RequirePinnedVersion) {
        $marker = Get-AppPxeBootP7zipMarkerPath
        if (-not (Test-Path -LiteralPath $marker)) { return $false }
        $installed = [string](Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
        if ($installed -ne $script:AppPxeBootP7zipPinnedVersion) { return $false }
    }
    return $true
}

function Get-AppPxeBootP7zipManifestDefaultUrl {
    if ($env:APP_P7ZIP_MANIFEST_URL) {
        return [string]$env:APP_P7ZIP_MANIFEST_URL
    }
    return (Get-AppProductAssetFeedUrl -Name 'p7zip-tools.json')
}

function Get-AppPxeBootP7zipBundledManifestPath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($script:SidecarRoot) {
        [void]$candidates.Add((Join-Path $script:SidecarRoot 'packaging/p7zip-tools.json'))
    }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if ($root) {
        [void]$candidates.Add((Join-Path $root 'packaging/p7zip-tools.json'))
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

function Get-AppPxeBootP7zipPlatformKey {
    if ($IsMacOS -or $IsDarwin) {
        $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
        if ($isArm) { return 'macos_arm64' }
        return 'macos_amd64'
    }
    return $null
}

function Read-AppPxeBootP7zipManifestObject {
    param([Parameter(Mandatory)]$Obj)
    $schemaVal = Get-AppAria2JsonProp -Item $Obj -Name 'schema'
    if ($schemaVal -and [int]$schemaVal -ne 1) { return $null }
    $version = [string](Get-AppAria2JsonProp -Item $Obj -Name 'version')
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    $platformsRaw = Get-AppAria2JsonProp -Item $Obj -Name 'platforms'
    if (-not $platformsRaw) { return $null }
    $platforms = @{}
    foreach ($prop in $platformsRaw.PSObject.Properties) {
        $entry = $prop.Value
        $archiveName = [string](Get-AppAria2JsonProp -Item $entry -Name 'archiveName')
        $archiveKind = [string](Get-AppAria2JsonProp -Item $entry -Name 'archiveKind')
        $shaProp = Get-AppAria2JsonProp -Item $entry -Name 'sha256'
        $urlProp = Get-AppAria2JsonProp -Item $entry -Name 'downloadUrl'
        $sizeProp = Get-AppAria2JsonProp -Item $entry -Name 'sizeBytes'
        $membersProp = Get-AppAria2JsonProp -Item $entry -Name 'members'
        if ([string]::IsNullOrWhiteSpace($archiveName)) { continue }
        $members = @()
        if ($membersProp) {
            $members = @($membersProp | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
        if ($members.Count -eq 0) { $members = @('7zz') }
        $platforms[$prop.Name] = @{
            archiveName = $archiveName
            archiveKind = if ($archiveKind) { $archiveKind } else { 'tar.gz' }
            members     = $members
            sha256      = if ($shaProp) { [string]$shaProp } else { '' }
            downloadUrl = if ($urlProp) { [string]$urlProp } else { '' }
            sizeBytes   = if ($null -ne $sizeProp) { [long]$sizeProp } else { 0 }
        }
    }
    if ($platforms.Count -eq 0) { return $null }
    @{
        version     = $version
        platforms   = $platforms
        manifestUrl = Get-AppPxeBootP7zipManifestDefaultUrl
    }
}

function Get-AppPxeBootP7zipManifest {
    $manifestUrl = Get-AppPxeBootP7zipManifestDefaultUrl
    # This product publishes no asset feed: skip the (always failing) remote fetch and
    # read the bundled manifest, whose downloadUrl points at the upstream project.
    if (-not [string]::IsNullOrWhiteSpace([string]$manifestUrl)) {
        try {
            $remote = Invoke-RestMethod -Uri $manifestUrl -Method Get -UseBasicParsing -TimeoutSec 45
            $parsed = Read-AppPxeBootP7zipManifestObject -Obj $remote
            if ($parsed) { return $parsed }
        } catch {
            Write-SidecarLogVerbose "PXE boot: p7zip manifest fetch failed ($manifestUrl): $($_.Exception.Message)"
        }
    }
    $bundledPath = Get-AppPxeBootP7zipBundledManifestPath
    if ($bundledPath) {
        try {
            $local = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsed = Read-AppPxeBootP7zipManifestObject -Obj $local
            if ($parsed) { return $parsed }
        } catch {
            Write-SidecarLogVerbose "PXE boot: bundled p7zip manifest read failed: $($_.Exception.Message)"
        }
    }
    throw 'PXE boot: p7zip manifest unavailable (no asset feed configured and no bundled copy).'
}

function Invoke-AppPxeBootP7zipArtifactDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing `
        -UserAgent (Get-AppUserAgent) -MaximumRedirection 5
}

function Test-AppPxeBootP7zipArchiveFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256,
        [long]$ExpectedSizeBytes = 0
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ($ExpectedSizeBytes -gt 0) {
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -ne $ExpectedSizeBytes) { return $false }
    }
    if ($ExpectedSha256 -and $ExpectedSha256.Trim()) {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $ExpectedSha256.ToLowerInvariant()) { return $false }
    }
    return $true
}

function Expand-AppPxeBootP7zipArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$ArchiveKind,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string[]]$Members
    )
    if (-not (Test-Path -LiteralPath $DestDir)) {
        $null = New-Item -Path $DestDir -ItemType Directory -Force
    }
    if ($ArchiveKind -eq 'tar.gz') {
        & tar -xzf $Archive -C $DestDir @($Members)
        if ($LASTEXITCODE -ne 0) {
            throw "PXE boot: p7zip tar extract failed for $(Split-Path -Leaf $Archive)"
        }
    } elseif ($ArchiveKind -eq 'tar.xz') {
        # Upstream 7-Zip's macOS archive (7z<ver>-mac.tar.xz); macOS tar reads xz natively.
        & tar -xJf $Archive -C $DestDir @($Members)
        if ($LASTEXITCODE -ne 0) {
            throw "PXE boot: 7-Zip tar.xz extract failed for $(Split-Path -Leaf $Archive)"
        }
    } else {
        throw "PXE boot: unknown p7zip archive kind $ArchiveKind"
    }
    foreach ($member in @($Members)) {
        if (-not (Test-Path -LiteralPath (Join-Path $DestDir $member))) {
            throw "PXE boot: p7zip member missing after extract: $member"
        }
    }
}

function Ensure-AppPxeBootP7zipTools {
    <#
    .SYNOPSIS
        7-Zip (7zz) on macOS: the installed pinned copy, else a 7z already on PATH, else -
        ONLY with -Download - fetch upstream 7-Zip from 7-zip.org per packaging/p7zip-tools.json.
    .NOTES
        Craig, 2026-08-22: "WDK should not download anything from gitlab" - the old p7zip
        came from the product asset feed (a placeholder host here) and every first ISO read
        paid ~10s of DNS failure. Nothing needs 7z for ISOs: macOS mounts them with hdiutil
        and Windows with Mount-DiskImage. So the default stays no-download; the setup
        wizard's "Download tools" (Handle-EnsureTools) passes -Download and the archive comes
        from the upstream project, verified by SHA-256. Homebrew is never probed (Craig,
        2026-08-29) - a plain Get-Command on PATH is the only outside lookup.
    #>
    param([switch]$Download)
    if (-not ($IsMacOS -or $IsDarwin)) {
        return @{ ok = $true; skipped = $true; reason = 'not_macos' }
    }
    if (Test-AppPxeBootP7zipInstalled -RequirePinnedVersion) {
        return @{
            ok      = $true
            skipped = $true
            reason  = 'installed'
            dir     = (Get-AppPxeBootP7zipToolsDir)
            path    = (Join-Path (Get-AppPxeBootP7zipToolsDir) '7zz')
            version = $script:AppPxeBootP7zipPinnedVersion
        }
    }
    foreach ($candidate in @('7zz', '7z', '7za')) {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) {
            return @{ ok = $true; skipped = $true; reason = 'system_7z'; path = [string]$found.Source }
        }
    }
    if (-not $Download) {
        return @{ ok = $false; skipped = $true; reason = 'no_download'; message = 'No 7-Zip on this Mac - ISOs are read by mounting them instead. Setup > Download tools installs it from 7-zip.org.' }
    }
    if ($script:AppPxeBootP7zipInstallInProgress) {
        return @{ ok = $false; installing = $true; skipped = $true; reason = 'install_in_progress' }
    }
    $platformKey = Get-AppPxeBootP7zipPlatformKey
    if (-not $platformKey) {
        return @{ ok = $false; message = 'p7zip install is supported on macOS only.' }
    }

    $manifest = Get-AppPxeBootP7zipManifest
    if (-not $manifest.platforms.ContainsKey($platformKey)) {
        return @{ ok = $false; message = "p7zip manifest has no entry for $platformKey." }
    }
    $entry = $manifest.platforms[$platformKey]
    if ([string]::IsNullOrWhiteSpace($entry.downloadUrl)) {
        return @{ ok = $false; message = '7-Zip manifest entry has no downloadUrl (expected the upstream 7-zip.org archive).' }
    }

    $toolsDir = Get-AppPxeBootP7zipToolsDir
    $sizeMb = if ($entry.sizeBytes -gt 0) { [math]::Round($entry.sizeBytes / 1MB, 1) } else { 6 }
    Write-SidecarLog "PXE boot: installing 7-Zip $($manifest.version) from the upstream project ($platformKey, ~${sizeMb} MB) to $toolsDir"

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sm-pxe-p7zip-" + [guid]::NewGuid().ToString())
    $archivePath = Join-Path $tmpRoot $entry.archiveName
    $null = New-Item -Path $tmpRoot -ItemType Directory -Force

    $script:AppPxeBootP7zipInstallInProgress = $true
    try {
        $downloaded = $false
        $lastError = $null
        $downloadCandidates = [System.Collections.Generic.List[string]]::new()
        if ($entry.downloadUrl) { [void]$downloadCandidates.Add([string]$entry.downloadUrl) }
        $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
        if ($root) {
            $localArchive = Join-Path $root ("vendor/p7zip-tools/$($entry.archiveName)" -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $localArchive) {
                Copy-Item -LiteralPath $localArchive -Destination $archivePath -Force
                if (Test-AppPxeBootP7zipArchiveFile -Path $archivePath -ExpectedSha256 $entry.sha256 -ExpectedSizeBytes $entry.sizeBytes) {
                    $downloaded = $true
                } else {
                    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if (-not $downloaded) {
            foreach ($url in @($downloadCandidates)) {
                try {
                    if (Test-Path -LiteralPath $archivePath) {
                        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                    }
                    Invoke-AppPxeBootP7zipArtifactDownload -Uri $url -OutFile $archivePath
                    if (Test-AppPxeBootP7zipArchiveFile -Path $archivePath -ExpectedSha256 $entry.sha256 -ExpectedSizeBytes $entry.sizeBytes) {
                        $downloaded = $true
                        break
                    }
                    $lastError = 'SHA256 or size mismatch after download'
                } catch {
                    $lastError = $_.Exception.Message
                    Write-SidecarLogVerbose "PXE boot: p7zip download failed from $url - $lastError"
                }
            }
        }
        if (-not $downloaded) {
            throw "p7zip download failed - $lastError"
        }
        Expand-AppPxeBootP7zipArchive `
            -Archive $archivePath `
            -ArchiveKind $entry.archiveKind `
            -DestDir $toolsDir `
            -Members @($entry.members)
        Set-AppPxeBootWimlibExecutable -Path (Join-Path $toolsDir '7zz')
        Set-Content -LiteralPath (Get-AppPxeBootP7zipMarkerPath) -Value $script:AppPxeBootP7zipPinnedVersion -Encoding ASCII -Force
        Write-SidecarLog "PXE boot: 7-Zip $($script:AppPxeBootP7zipPinnedVersion) ready at $toolsDir"
        return @{
            ok      = $true
            skipped = $false
            dir     = $toolsDir
            version = $script:AppPxeBootP7zipPinnedVersion
        }
    } catch {
        Write-SidecarLog "PXE boot: p7zip install failed - $($_.Exception.Message)"
        return @{ ok = $false; message = $_.Exception.Message }
    } finally {
        $script:AppPxeBootP7zipInstallInProgress = $false
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-AppPxeBootWindows7zToolsDir {
    # Same bundled pxe/tools payload the deploy client injects.
    $toolsDir = Get-AppPxeBootDeployClientToolsDir
    if ($toolsDir -and (Test-Path -LiteralPath (Join-Path $toolsDir '7z.exe'))) {
        return $toolsDir
    }
    return $null
}

function Get-AppPxeBootHost7zPath {
    if ($IsMacOS -or $IsDarwin) {
        if (Test-AppPxeBootP7zipInstalled) {
            return (Join-Path (Get-AppPxeBootP7zipToolsDir) '7zz')
        }
        foreach ($candidate in @('7zz', '7z', '7za')) {
            $found = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($found -and $found.Source) { return [string]$found.Source }
        }
        return $null
    }

    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $toolsDir = Get-AppPxeBootWindows7zToolsDir
        if ($toolsDir) {
            return (Join-Path $toolsDir '7z.exe')
        }
    }
    return $null
}

function Get-AppPxeBoot7zWorkDirectory {
    param([Parameter(Mandatory)][string]$SevenZPath)
    if ($IsMacOS -or $IsDarwin) {
        if (Test-AppPxeBootP7zipInstalled) {
            return (Get-AppPxeBootP7zipToolsDir)
        }
    }
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $toolsDir = Get-AppPxeBootWindows7zToolsDir
        if ($toolsDir) { return $toolsDir }
    }
    $parent = Split-Path -Parent $SevenZPath
    if ($parent -and (Test-Path -LiteralPath $parent)) { return $parent }
    return $null
}

function Invoke-AppPxeBoot7zExtractMember {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$MemberPath,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if ($IsMacOS -or $IsDarwin) {
        $ensure = Ensure-AppPxeBootP7zipTools
        if (-not $ensure.ok) { return $false }
    }

    $sevenZ = Get-AppPxeBootHost7zPath
    if (-not $sevenZ) { return $false }

    $workDir = Get-AppPxeBoot7zWorkDirectory -SevenZPath $sevenZ
    Push-Location -LiteralPath $(if ($workDir) { $workDir } else { (Get-Location).Path })
    try {
        & $sevenZ x -y "-o$OutputDirectory" $ArchivePath $MemberPath 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function Write-AppPxeBootIsoUrlFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$IsoHttpUrl
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $IsoHttpUrl.Trim() + "`n", $utf8NoBom)
}

function Write-AppPxeBootWimOverlayRuntimeAssets {
    <#
    .SYNOPSIS
        Publish (or clear) every overlay profile's runtime files for Caddy. When a profile is
        enabled its PublishRuntime writer refreshes the served files; when disabled the engine
        removes them so stale connection details / tokens never linger. Generic - iterates the
        registry, so new profiles are picked up automatically.
    #>
    param([string]$LanIp)
    foreach ($overlayProfile in Get-AppPxeBootWimOverlayProfiles) {
        $runtime = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'Runtime'
        if (-not $runtime) { continue }
        $dir = Get-AppPxeBootWimOverlayServedDir -OverlayProfile $overlayProfile
        if (-not $dir) { continue }
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $overlayProfile)) {
            foreach ($entry in $runtime) {
                $f = Join-Path $dir $entry.ServedName
                if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
        $publish = Get-AppPxeBootWimOverlayProfileField -OverlayProfile $overlayProfile -Name 'PublishRuntime'
        if ($publish) { & $publish $dir $LanIp }
    }
}

function Get-AppPxeBootDeployClientStartnetSource {
    <#
    .SYNOPSIS
        Path to the cmd-only deploy client that gets baked in as startnet.cmd.
    #>
    # Test-Path on a script: variable, not a bare read - StrictMode throws on the
    # latter when the sidecar has not set it (the gates dot-source the libs alone).
    $root = if (Test-Path variable:script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($SidecarRoot) { Split-Path -Parent $SidecarRoot } else { $null }
    $candidates = @()
    if ($SidecarRoot) { $candidates += (Join-Path $SidecarRoot 'pxe/deploy-client/startnet.cmd') }
    if ($root) {
        $candidates += (Join-Path $root 'sidecar/pxe/deploy-client/startnet.cmd')
        $candidates += (Join-Path $root 'pxe/deploy-client/startnet.cmd')
    }
    foreach ($rel in $candidates) {
        $path = ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootDeployClientToolsDir {
    # Windows binaries injected beside the client (fetched by scripts/fetch-winpe-tools.ps1,
    # shipped in the bundle since 2026-08-23) - without them a corporate install has no
    # way to expand a vendor driver pack or push a log line.
    $candidates = @()
    if ($SidecarRoot) { $candidates += (Join-Path $SidecarRoot 'pxe/tools') }
    if (Test-Path variable:script:AppSidecarProjectRoot) {
        if ($script:AppSidecarProjectRoot) { $candidates += (Join-Path $script:AppSidecarProjectRoot 'sidecar/pxe/tools') }
    }
    foreach ($c in $candidates) {
        $path = ($c -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath (Join-Path $path '7z.exe')) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Test-AppPxeBootDeployClientInjectEnabled {
    <#
    .SYNOPSIS
        Whether imported boot WIMs get the deploy client baked into them.
    .NOTES
        On by default: without it an imported boot.wim boots to a WinPE prompt and
        this product does nothing at all (Craig, 2026-08-23 - "how is the install.wim
        installed via the boot.wim"). The panel can turn it off for anyone who boots
        their own client and only wants the share and the published sequences.
    #>
    param($Cfg = $(Read-AppPxeBootConfig))
    if ($null -eq $Cfg) { return $true }
    $prop = $Cfg.PSObject.Properties['deployClientInject']
    if (-not $prop) { return $true }
    return [bool]$prop.Value
}

function Test-AppPxeBootDeployOverlayCredsModeValue {
    param([string]$Value)
    $v = ([string]$Value).Trim()
    # No blank mode: a credential-less client cannot open the guest-off Deploy$,
    # and "blank" only ever got into a config via a frontend downgrade bug (it hung
    # a real boot at net use, 2026-08-24). The deploy credential always defaults.
    if ($v -eq 'throwaway') { return $true }
    if ($v -match '^vault:[A-Za-z0-9_-]+$') { return $true }
    return $false
}

function Get-AppPxeBootDeployOverlayCredsMode {
    param($Cfg = $(Read-AppPxeBootConfig))
    $v = if ($Cfg) { [string]$Cfg.deployOverlayCreds } else { '' }
    if (Test-AppPxeBootDeployOverlayCredsModeValue -Value $v) { return $v.Trim() }
    return 'throwaway'
}

function Test-AppPxeBootDeployOverlayEnabled {
    param($Cfg = $(Read-AppPxeBootConfig))
    if ([bool]$Cfg.smbOverlayEnabled) {
        return [bool]$Cfg.smbShareEnabled
    }
    return $true
}

function Get-AppPxeBootDeployOverlayUnc {
    param(
        [Parameter(Mandatory)]$Cfg,
        [string]$LanIp
    )
    $shareName = if (-not [string]::IsNullOrWhiteSpace([string]$Cfg.deployOverlayShare)) {
        ([string]$Cfg.deployOverlayShare).Trim()
    } else {
        [string]$script:AppPxeBootImageLibraryShareName
    }
    # ALWAYS the LAN IP when we know it, never the hostname. WinPE resolves a macOS
    # host name over the network unreliably (mDNS/NetBIOS both patchy) - a deploy that
    # connected once then failed the next boot on a stale name lookup (Craig, 2026-08-23,
    # \\5573-fgmv7wt1pc). install.wim and the log push already use the IP; hostname is
    # only the fallback when no IP was resolved. (smbOverlayEnabled just picks the host
    # differently for an on-site WDS; here both paths want this machine.)
    $hostPart = if (-not [string]::IsNullOrWhiteSpace($LanIp)) {
        [string]$LanIp
    } else {
        try { [System.Net.Dns]::GetHostName() } catch { 'localhost' }
    }
    return "\\$hostPart\$shareName"
}

function Get-AppPxeBootDeployOverlayCredentialPair {
    <#
    .SYNOPSIS
        Resolve overlay credential user + password for the configured creds mode.
        Returns @{ User; Pass } or $null when blank / unavailable.
    #>
    param([string]$CredsMode)
    $mode = if (Test-AppPxeBootDeployOverlayCredsModeValue -Value $CredsMode) {
        ([string]$CredsMode).Trim()
    } else {
        'throwaway'
    }
    if ($mode -eq 'throwaway') {
        $cred = $null
        if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
            try {
                $root = if (Test-AppSidecarCommand Get-AppImageLibraryRoot) {
                    Get-AppImageLibraryRoot -NoCreate
                } else { $null }
                if (-not $root -and (Test-AppSidecarCommand Get-AppImageLibraryRoot)) {
                    $root = Get-AppImageLibraryRoot
                }
                if ($root) {
                    $cred = Ensure-AppPxeBootWindowsSmbThrowawayCredential -Root ([string]$root)
                }
            } catch {
                Write-SidecarLog "PXE boot: throwaway SMB credential ensure failed - $($_.Exception.Message)"
            }
            if (-not $cred) {
                $candidate = Read-AppPxeBootSmbThrowawayCred
                if ($candidate -and (Test-AppPxeBootWindowsUserExists -Name ([string]$candidate.User))) {
                    $cred = $candidate
                } elseif ($candidate) {
                    Write-SidecarLog "PXE boot: throwaway SMB credential skipped - local user '$([string]$candidate.User)' does not exist on Windows host."
                }
            }
        } elseif ($IsMacOS -or $IsDarwin) {
            $cred = Read-AppPxeBootSmbThrowawayCred
        }
        if ($cred -and -not [string]::IsNullOrWhiteSpace($cred.User) -and -not [string]::IsNullOrWhiteSpace($cred.Pass)) {
            $userTrim = ([string]$cred.User).Trim()
            $account = if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
                if ($env:COMPUTERNAME) { "$($env:COMPUTERNAME)\$userTrim" } else { $userTrim }
            } else {
                "WORKGROUP\$userTrim"
            }
            return @{ User = $account; Pass = ([string]$cred.Pass).Trim() }
        }
        return $null
    }

    if ($mode -match '^vault:(.+)$') {
        $id = $Matches[1]
        try {
            if (-not (Test-AppSidecarCommand Test-AppInfraSshCredentialExists)) { return $null }
            if (-not (Test-AppInfraSshCredentialExists -Id $id)) {
                Write-SidecarLog "PXE boot: vault credential '$id' not configured for deploy overlay"
                return $null
            }
            if (-not (Test-AppSidecarCommand Get-AppInfraSshCredentialLoginNameById)) { return $null }
            if (-not (Test-AppSidecarCommand Get-AppInfraSshPlainPassword)) { return $null }
            $user = Get-AppInfraSshCredentialLoginNameById -Id $id
            $pass = Get-AppInfraSshPlainPassword -Id $id
            if (-not [string]::IsNullOrWhiteSpace($user) -and -not [string]::IsNullOrWhiteSpace($pass)) {
                return @{ User = $user.Trim(); Pass = ([string]$pass).Trim() }
            }
        } catch {
            Write-SidecarLog "PXE boot: vault credential '$id' for deploy overlay unavailable - $($_.Exception.Message)"
        }
        return $null
    }

    return $null
}

function Write-AppPxeBootDeployOverlayFiles {
    <#
    .SYNOPSIS
        Deploy$ overlay content writer (the 'deploy-share' profile's
        PublishRuntime). Writes deploy.unc (local Deploy$ or on-site WDS) and deploy.cred
        (throwaway, DE, or vault credential) so the deploy client auto-maps Z: when both
        user and password are present. The engine only calls this when the profile is enabled.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$LanIp
    )
    # The deploy client itself. Not Required in the profile: with the toggle off this
    # file is absent, the initrd line is skipped, and WinPE runs its own startnet.cmd
    # (the plain prompt) while the share and credential files still land.
    $startnetFile = Join-Path $Dir 'startnet.cmd'
    if (Test-AppPxeBootDeployClientInjectEnabled) {
        $startnetSource = Get-AppPxeBootDeployClientStartnetSource
        if ($startnetSource) {
            # CRLF on the wire, whatever git did to the source: cmd.exe skips `goto`
            # labels and leaves a stray CR in `for /f` tokens on an LF-only batch file.
            $want = (([System.IO.File]::ReadAllText($startnetSource) -replace "`r`n", "`n") -replace "`n", "`r`n")
            $have = if (Test-Path -LiteralPath $startnetFile) { [System.IO.File]::ReadAllText($startnetFile) } else { $null }
            if ($have -ne $want) {
                [System.IO.File]::WriteAllText($startnetFile, $want, (New-Object System.Text.UTF8Encoding $false))
                Write-SidecarLog 'PXE boot: published the deploy client (startnet.cmd) for imported boot WIMs'
            }
        } else {
            Write-SidecarLog 'PXE boot: deploy client source missing - imported boot WIMs will boot to a WinPE prompt'
        }
    } elseif (Test-Path -LiteralPath $startnetFile) {
        Remove-Item -LiteralPath $startnetFile -Force -ErrorAction SilentlyContinue
    }
    # Tools the client needs that WinPE lacks, served beside it. Copied once
    # (size+mtime), removed with the toggle so nothing stale is ever injected.
    $toolsSrcDir = Get-AppPxeBootDeployClientToolsDir
    foreach ($tool in @('7z.exe', '7za.dll', '7zxa.dll', 'curl.exe', 'wdk-bg.exe', 'wdk-panel.exe')) {
        $dst = Join-Path $Dir $tool
        $src = if ($toolsSrcDir) { Join-Path $toolsSrcDir $tool } else { $null }
        if ((Test-AppPxeBootDeployClientInjectEnabled) -and $src -and (Test-Path -LiteralPath $src)) {
            $s = Get-Item -LiteralPath $src
            $d = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue
            if (-not $d -or $d.Length -ne $s.Length -or $d.LastWriteTimeUtc -lt $s.LastWriteTimeUtc) {
                Copy-Item -LiteralPath $src -Destination $dst -Force
            }
        } elseif (Test-Path -LiteralPath $dst) {
            Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        }
    }
    # Same four tools into <library>/Tools on the Deploy$ share. A Secure Boot client
    # cannot take unsigned PE files as initrd ("Security Policy Violation"), so
    # startnet.cmd copies them from Z:\Tools after the share connects instead.
    try {
        $shareRoot = Get-AppImageLibraryRoot
        if ($shareRoot -and (Test-Path -LiteralPath $shareRoot) -and (Test-AppPxeBootDeployClientInjectEnabled) -and $toolsSrcDir) {
            $shareTools = Join-Path $shareRoot 'Tools'
            if (-not (Test-Path -LiteralPath $shareTools)) { New-Item -ItemType Directory -Path $shareTools -Force | Out-Null }
            foreach ($tool in @('7z.exe', '7za.dll', '7zxa.dll', 'curl.exe', 'wdk-bg.exe', 'wdk-panel.exe')) {
                $src = Join-Path $toolsSrcDir $tool
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $dst = Join-Path $shareTools $tool
                $s = Get-Item -LiteralPath $src
                $d = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue
                if (-not $d -or $d.Length -ne $s.Length -or $d.LastWriteTimeUtc -lt $s.LastWriteTimeUtc) {
                    Copy-Item -LiteralPath $src -Destination $dst -Force
                }
            }
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: share tools publish failed - $($_.Exception.Message)"
    }
    # Console-UI customisation: header line and optional ASCII logo.
    foreach ($pair in @(
            @{ src = (Get-AppPxeBootDeployUiTitlePath); name = 'deploy.title' },
            @{ src = (Get-AppPxeBootDeployUiLogoPath); name = 'deploy-logo.txt' },
            @{ src = (Get-AppPxeBootDeployUiCfgPath); name = 'deploy-ui.cfg' }
        )) {
        $dstFile = Join-Path $Dir $pair.name
        if (Test-Path -LiteralPath $pair.src) {
            Copy-Item -LiteralPath $pair.src -Destination $dstFile -Force
        } elseif (Test-Path -LiteralPath $dstFile) {
            Remove-Item -LiteralPath $dstFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Deploy background: the operator's imported image, converted to BMP for the
    # wdk-bg viewer (pure GDI = BMP only; no decoder gamble on stripped WinPEs).
    # Imported picture if there is one, else the bundled default. Regenerated when the
    # source file, its mtime or the size policy changes (stamp in the store root - NOT
    # under http/, where a local path would be served to the LAN). The stamp is what
    # lets "Use default" and a changed default both take effect without a Clear having
    # to know about the served copy.
    $bg = Get-AppPxeBootWinPeBackgroundSource
    $bgSrc = [string]$bg.path
    $bgBmp = Join-Path $Dir 'deploy-bg.bmp'
    $bgStampFile = Join-Path (Get-AppPxeBootStoreRoot) 'deploy-bg.stamp'
    if ($bgSrc -and (Test-Path -LiteralPath $bgSrc)) {
        $s = Get-Item -LiteralPath $bgSrc
        $want = '{0}|{1}|{2}' -f $bg.source, $s.LastWriteTimeUtc.Ticks, $script:AppPxeBootDeployBackgroundMaxWidth
        $have = if (Test-Path -LiteralPath $bgStampFile) { [string](Get-Content -LiteralPath $bgStampFile -Raw -ErrorAction SilentlyContinue) } else { '' }
        if (-not (Test-Path -LiteralPath $bgBmp) -or $have.Trim() -ne $want) {
            if (Convert-AppPxeBootImageFile -Source $bgSrc -Destination $bgBmp -Format 'bmp' -MaxWidth $script:AppPxeBootDeployBackgroundMaxWidth) {
                [System.IO.File]::WriteAllText($bgStampFile, $want, (New-Object System.Text.UTF8Encoding $false))
                $bmpItem = Get-Item -LiteralPath $bgBmp -ErrorAction SilentlyContinue
                $bmpKb = if ($bmpItem) { [int]($bmpItem.Length / 1024) } else { 0 }
                Write-SidecarLog "PXE boot: published the deploy background (deploy-bg.bmp, $($bg.source), $bmpKb KB)"
            }
        }
    } else {
        if (Test-Path -LiteralPath $bgBmp) { Remove-Item -LiteralPath $bgBmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $bgStampFile) { Remove-Item -LiteralPath $bgStampFile -Force -ErrorAction SilentlyContinue }
    }

    if ((Test-AppPxeBootDeployClientInjectEnabled) -and -not (Test-Path -LiteralPath (Join-Path $Dir '7z.exe'))) {
        Write-SidecarLogVerbose 'PXE boot: deploy client tools (7z/curl) not found - .cab packs only, no live log'
    }

    $uncFile = Join-Path $Dir 'deploy.unc'
    $credFile = Join-Path $Dir 'deploy.cred'
    $logHostFile = Join-Path $Dir 'loghost'
    $cfg = Read-AppPxeBootConfig

    $unc = Get-AppPxeBootDeployOverlayUnc -Cfg $cfg -LanIp $LanIp
    Set-Content -LiteralPath $uncFile -Value $unc -Encoding ASCII -NoNewline -Force

    # Imaging-log push target: the baked script POSTs Write-Log lines to
    # http://<host>:<port>/imaging-log/ingest (Caddy reverse-proxies to the sidecar's
    # loopback listener) so the Netboot panel can live-tail every device being imaged.
    if (-not [string]::IsNullOrWhiteSpace($LanIp)) {
        $logHostUrl = "http://$($LanIp):$([int]$cfg.httpPort)"
        Set-Content -LiteralPath $logHostFile -Value $logHostUrl -Encoding ASCII -NoNewline -Force
    } elseif (Test-Path -LiteralPath $logHostFile) {
        Remove-Item -LiteralPath $logHostFile -Force -ErrorAction SilentlyContinue
    }

    $credsMode = Get-AppPxeBootDeployOverlayCredsMode -Cfg $cfg
    $pair = Get-AppPxeBootDeployOverlayCredentialPair -CredsMode $credsMode
    if ($pair -and -not [string]::IsNullOrWhiteSpace($pair.User) -and -not [string]::IsNullOrWhiteSpace($pair.Pass)) {
        $credText = ('{0}{2}{1}{2}' -f $pair.User, $pair.Pass, "`r`n")
        Set-Content -LiteralPath $credFile -Value $credText -Encoding ASCII -NoNewline -Force
        # Runs on every menu/overlay regen - log at info only when the identity changes,
        # verbose otherwise (this line was drowning the sidecar log).
        $publishKey = "$($pair.User)|$credsMode"
        if ($script:AppPxeBootState.LastOverlayCredPublishKey -ne $publishKey) {
            $script:AppPxeBootState.LastOverlayCredPublishKey = $publishKey
            Write-SidecarLog "PXE boot: published deploy overlay credential ($($pair.User), mode=$credsMode)"
        } else {
            Write-SidecarLogVerbose "PXE boot: refreshed deploy overlay credential ($($pair.User), mode=$credsMode)"
        }
    } elseif (Test-Path -LiteralPath $credFile) {
        Remove-Item -LiteralPath $credFile -Force -ErrorAction SilentlyContinue
        $script:AppPxeBootState.LastOverlayCredPublishKey = $null
        Write-SidecarLog "PXE boot: deploy overlay credential not published (mode=$credsMode)"
    }
}

function Get-AppPxeBootWanIsoCatalogUrl {
    $cfg = Read-AppPxeBootConfig
    $url = [string]$cfg.deployMenuUrl
    if ([string]::IsNullOrWhiteSpace($url)) {
        $url = Get-AppPxeBootDefaultDeployMenuUrl
    }
    return $url.Trim().TrimEnd('/')
}

$script:AppPxeBootWinPeBackgroundName = 'winpe.jpg'
# Served deploy-bg.bmp is bounded to this width: wdk-bg StretchBlts it to the screen, so
# anything past 1080p is initrd bytes for nothing (Craig's 4772-px import made a 40 MB BMP).
$script:AppPxeBootDeployBackgroundMaxWidth = 1920

function Get-AppPxeBootDeployUiTitlePath {
    Join-Path (Get-AppPxeBootLayoutPaths).brandingDir 'deploy.title'
}

function Get-AppPxeBootDeployUiLogoPath {
    Join-Path (Get-AppPxeBootLayoutPaths).brandingDir 'deploy-logo.txt'
}

function Get-AppPxeBootDeployUiCfgPath {
    Join-Path (Get-AppPxeBootLayoutPaths).brandingDir 'deploy-ui.cfg'
}

function Set-AppPxeBootDeployUiColors {
    <#
    .SYNOPSIS
        Colours for the wdk-ui deploy panel (deploy-ui.cfg: accent= and panel=,
        RRGGBB). Both empty clears the file and the panel falls back to its
        built-in dark navy / light blue.
    #>
    param(
        [AllowEmptyString()][string]$Accent,
        [AllowEmptyString()][string]$Panel
    )
    $clean = @{}
    foreach ($pair in @(@{ k = 'accent'; v = $Accent }, @{ k = 'panel'; v = $Panel })) {
        $v = ([string]$pair.v).Trim().TrimStart('#')
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if ($v -notmatch '^[0-9A-Fa-f]{6}$') { throw "Not an RRGGBB colour: $($pair.v)" }
        $clean[$pair.k] = $v.ToUpperInvariant()
    }
    $paths = Get-AppPxeBootLayoutPaths
    $path = Get-AppPxeBootDeployUiCfgPath
    if ($clean.Count -eq 0) {
        foreach ($f in @($path, (Join-Path (Join-Path $paths.httpRoot 'deploy') 'deploy-ui.cfg'))) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        Write-SidecarLog 'PXE boot: deploy panel colours cleared'
    } else {
        if (-not (Test-Path -LiteralPath $paths.brandingDir)) { $null = New-Item -Path $paths.brandingDir -ItemType Directory -Force }
        $lines = @($clean.Keys | Sort-Object | ForEach-Object { "$_=$($clean[$_])" })
        # CRLF for the same reason as deploy.title - a WinPE-side reader.
        [System.IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
        Write-SidecarLog "PXE boot: deploy panel colours set ($($lines -join ', '))"
    }
    Get-AppPxeBootBrandingStatus
}

function Set-AppPxeBootDeployUiTitle {
    <#
    .SYNOPSIS
        The header line the deploy client prints above the stage list. Empty clears it
        (the client falls back to the product name).
    #>
    param([AllowEmptyString()][string]$Title)
    $paths = Get-AppPxeBootLayoutPaths
    if (-not (Test-Path -LiteralPath $paths.brandingDir)) { $null = New-Item -Path $paths.brandingDir -ItemType Directory -Force }
    $path = Get-AppPxeBootDeployUiTitlePath
    $clean = ([string]$Title) -replace '[\r\n]', ' '
    $clean = $clean.Trim()
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60).Trim() }
    if ([string]::IsNullOrWhiteSpace($clean)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        $served = Join-Path (Join-Path $paths.httpRoot 'deploy') 'deploy.title'
        if (Test-Path -LiteralPath $served) { Remove-Item -LiteralPath $served -Force -ErrorAction SilentlyContinue }
        Write-SidecarLog 'PXE boot: deploy header cleared'
    } else {
        # CRLF and no trailing newline games: cmd's set /p reads the first line.
        [System.IO.File]::WriteAllText($path, $clean + "`r`n", (New-Object System.Text.UTF8Encoding $false))
        Write-SidecarLog "PXE boot: deploy header set to '$clean'"
    }
    Get-AppPxeBootBrandingStatus
}

function Get-AppPxeBootWinPeBackgroundPath {
    # The WinPE wallpaper. WinPE shows %SystemRoot%\System32\winpe.jpg behind the
    # deploy client, so this file is injected as an overlay initrd - the imported boot
    # WIM is never modified (Craig, 2026-08-23: boot "image customisations").
    Join-Path (Get-AppPxeBootLayoutPaths).brandingDir $script:AppPxeBootWinPeBackgroundName
}

function Get-AppPxeBootBundledDefaultBackgroundPath {
    <#
    .SYNOPSIS
        The background that ships with the product - used whenever nothing has been
        imported. Craig's pebbles-on-stone picture (2026-08-26: "package that WIM
        background as the default BG but allow changing it. It fits so well"), scaled
        to 1920 px so the served BMP is ~6.5 MB per boot instead of the 40 MB the
        4772-px original made.
    #>
    $candidates = @()
    if ($SidecarRoot) { $candidates += (Join-Path $SidecarRoot 'pxe/deploy-client/default-bg.jpg') }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if ($root) { $candidates += (Join-Path $root 'sidecar/pxe/deploy-client/default-bg.jpg') }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootWinPeBackgroundSource {
    <#
    .SYNOPSIS
        The picture that will be served as deploy-bg.bmp: the imported one when there is
        one, else the bundled default. @{ path; source } with source custom|default|none.
    #>
    $custom = Get-AppPxeBootWinPeBackgroundPath
    if (Test-Path -LiteralPath $custom) { return @{ path = $custom; source = 'custom' } }
    $default = Get-AppPxeBootBundledDefaultBackgroundPath
    if ($default) { return @{ path = $default; source = 'default' } }
    return @{ path = $null; source = 'none' }
}

function Convert-AppPxeBootImageFile {
    <#
    .SYNOPSIS
        Copy $Source to $Destination, converting to jpeg/png when the extension differs.
    .NOTES
        macOS has sips built in; Windows has System.Drawing. Neither is downloaded. A
        source already in the wanted format is just copied.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateSet('jpeg', 'png', 'bmp')][string]$Format,
        # > 0: bound the longer side to this many pixels (sips -Z / a resampled Bitmap).
        # The same-format copy shortcut is skipped when a bound is asked for.
        [int]$MaxWidth = 0
    )
    $srcExt = ([IO.Path]::GetExtension($Source)).ToLowerInvariant()
    $wantExt = switch ($Format) { 'jpeg' { @('.jpg', '.jpeg') } 'png' { @('.png') } 'bmp' { @('.bmp') } }
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    if ($srcExt -in $wantExt -and $MaxWidth -le 0) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return $true
    }
    if ($IsMacOS -or $IsDarwin) {
        $sipsArgs = @()
        if ($MaxWidth -gt 0) { $sipsArgs += @('-Z', [string]$MaxWidth) }
        $sipsArgs += @('-s', 'format', $Format, $Source, '--out', $Destination)
        & sips @sipsArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination)) { return $true }
        Write-SidecarLog "PXE boot: could not convert $([IO.Path]::GetFileName($Source)) to $Format (sips)"
        return $false
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $img = [System.Drawing.Image]::FromFile($Source)
        try {
            $fmt = switch ($Format) {
                'jpeg' { [System.Drawing.Imaging.ImageFormat]::Jpeg }
                'png' { [System.Drawing.Imaging.ImageFormat]::Png }
                'bmp' { [System.Drawing.Imaging.ImageFormat]::Bmp }
            }
            $longest = [Math]::Max([int]$img.Width, [int]$img.Height)
            if ($MaxWidth -gt 0 -and $longest -gt $MaxWidth) {
                $scale = $MaxWidth / [double]$longest
                $w = [Math]::Max(1, [int][Math]::Round($img.Width * $scale))
                $h = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
                $scaled = New-Object System.Drawing.Bitmap $w, $h
                try {
                    $g = [System.Drawing.Graphics]::FromImage($scaled)
                    try {
                        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $g.DrawImage($img, 0, 0, $w, $h)
                    } finally { $g.Dispose() }
                    $scaled.Save($Destination, $fmt)
                } finally { $scaled.Dispose() }
            } else {
                $img.Save($Destination, $fmt)
            }
        } finally { $img.Dispose() }
        return (Test-Path -LiteralPath $Destination)
    } catch {
        Write-SidecarLog "PXE boot: could not convert to $Format - $($_.Exception.Message)"
        return $false
    }
}

function Set-AppPxeBootBrandingImage {
    <#
    .SYNOPSIS
        Import the WinPE background for imported boot WIMs. Converted to jpg with tools
        already on the machine (sips on macOS, System.Drawing on Windows) because that
        is what WinPE reads.
    .NOTES
        Shown by the overlay's wdk-bg viewer (a fullscreen bottom-most window behind
        the deploy console) - Server 2025's WinPE no longer paints System32\winpe.jpg
        at all, proven 2026-08-24 by baking a custom jpg into the WIM and still
        booting to a black desktop. Published as deploy-bg.bmp beside the client;
        the boot WIM is never modified.
    #>
    param([Parameter(Mandatory)][string]$SourcePath)
    if (-not (Test-Path -LiteralPath $SourcePath)) { throw "PXE boot: picture not found - $SourcePath" }
    $ext = ([IO.Path]::GetExtension($SourcePath)).ToLowerInvariant()
    if ($ext -notin @('.jpg', '.jpeg', '.png', '.bmp')) {
        throw 'PXE boot: use a .jpg, .png or .bmp picture.'
    }
    $paths = Get-AppPxeBootLayoutPaths
    if (-not (Test-Path -LiteralPath $paths.brandingDir)) { $null = New-Item -Path $paths.brandingDir -ItemType Directory -Force }
    $dest = Get-AppPxeBootWinPeBackgroundPath
    if (-not (Convert-AppPxeBootImageFile -Source $SourcePath -Destination $dest -Format 'jpeg')) {
        throw 'PXE boot: could not prepare the WinPE background (jpg conversion failed).'
    }
    Write-SidecarLog "PXE boot: WinPE background set from $([IO.Path]::GetFileName($SourcePath))"
    Get-AppPxeBootBrandingStatus
}

function Clear-AppPxeBootBrandingImage {
    param()
    $paths = Get-AppPxeBootLayoutPaths
    $p = Get-AppPxeBootWinPeBackgroundPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    # Drop the served copies (current bmp + any legacy jpg).
    foreach ($servedName in @('deploy-bg.bmp', $script:AppPxeBootWinPeBackgroundName)) {
        $served = Join-Path (Join-Path $paths.httpRoot 'deploy') $servedName
        if (Test-Path -LiteralPath $served) { Remove-Item -LiteralPath $served -Force -ErrorAction SilentlyContinue }
    }
    if (Get-AppPxeBootBundledDefaultBackgroundPath) {
        Write-SidecarLog 'PXE boot: WinPE background reset to the bundled default'
    } else {
        Write-SidecarLog 'PXE boot: WinPE background cleared'
    }
    Get-AppPxeBootBrandingStatus
}

function Get-AppPxeBootBrandingStatus {
    # What the Boot Images panel shows for the boot WIM background: the picture that
    # will actually be served (imported, else the bundled default).
    $bg = Get-AppPxeBootWinPeBackgroundSource
    $item = if ($bg.path -and (Test-Path -LiteralPath $bg.path)) { Get-Item -LiteralPath $bg.path } else { $null }
    $titlePath = Get-AppPxeBootDeployUiTitlePath
    $title = ''
    if (Test-Path -LiteralPath $titlePath) {
        try { $title = ([string](Get-Content -LiteralPath $titlePath -TotalCount 1 -ErrorAction Stop)).Trim() } catch { $title = '' }
    }
    $uiColors = @{ accent = ''; panel = '' }
    $cfgPath = Get-AppPxeBootDeployUiCfgPath
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            foreach ($line in @(Get-Content -LiteralPath $cfgPath -ErrorAction Stop)) {
                $k, $v = ([string]$line).Split('=', 2)
                if ($null -ne $v -and $uiColors.ContainsKey($k.Trim())) { $uiColors[$k.Trim()] = $v.Trim() }
            }
        } catch { }
    }
    @{
        winpeBackground = @{
            present   = [bool]$item
            source    = [string]$bg.source
            custom    = ($bg.source -eq 'custom')
            fileName  = if ($item) { [string]$item.Name } else { $null }
            sizeBytes = if ($item) { [long]$item.Length } else { 0 }
            updatedAt = if ($item) { $item.LastWriteTimeUtc.ToString('o') } else { $null }
        }
        deployTitle     = $title
        logoPresent     = [bool](Test-Path -LiteralPath (Get-AppPxeBootDeployUiLogoPath))
        uiAccent        = $uiColors['accent']
        uiPanel         = $uiColors['panel']
    }
}

function Get-AppPxeBootBrandingPictureFileName {
    $dir = (Get-AppPxeBootLayoutPaths).brandingDir
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($name in @('det-branding-1920x1080.png', 'det-branding-1024x768.png')) {
        $path = Join-Path $dir $name
        if (Test-Path -LiteralPath $path) { return $name }
    }
    $fallback = @(Get-ChildItem -LiteralPath $dir -Filter '*.png' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($fallback) { return [string]$fallback.Name }
    return $null
}

function Get-AppPxeBootMenuBrandingConsoleIpxeLines {
    <#
    .SYNOPSIS
        Optional iPXE menu picture (drawn behind the boot menu), when a PNG has been
        dropped into the branding folder.
    .NOTES
        The trailing "||" is not decoration. Checked 2026-08-23 against the iPXE builds
        this product actually serves: they carry the --picture OPTION string but NO png
        / jpeg / pnm decoder and no framebuffer console, so `console --picture` FAILS on
        them. A failing command aborts an iPXE script, and this line sits at :start
        immediately before `menu` - so a stray PNG in branding/ would have taken out the
        whole boot menu. "||" makes iPXE ignore the failure and carry on to the menu.
        Making the picture actually render needs iPXE rebuilt with IMAGE_PNG and a
        framebuffer console; the Secure Boot binaries are signed, so that rebuild is not
        a drop-in (it would break the shim chain).
    #>
    $fileName = Get-AppPxeBootBrandingPictureFileName
    if (-not $fileName) { return @() }
    @(
        "console --picture `${http_base}/branding/$fileName --left 110 --top 90 --right 90 --bottom 70 ||"
    )
}

function Get-AppPxeBootMenuBrandingSubtitleIpxeLines {
    @(
        'item --gap -- "It''s not WDS. We checked with legal."'
        'item --gap --'
    )
}

function Get-AppPxeBootLocalHttpBaseUrl {
    param([switch]$ForIpxe)
    $cfg = Read-AppPxeBootConfig
    $port = [int]$cfg.httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId
    if ($ForIpxe -or [string]::IsNullOrWhiteSpace($lanIp)) {
        return "http://`${next-server}:$port"
    }
    return "http://${lanIp}:$port"
}

function Get-AppPxeBootOptionalAssetsManifestDefaultUrl {
    if ($env:APP_PXE_OPTIONAL_ASSETS_MANIFEST_URL) {
        return [string]$env:APP_PXE_OPTIONAL_ASSETS_MANIFEST_URL
    }
    return (Get-AppProductAssetFeedUrl -Name 'pxe-optional-assets.json')
}

function Get-AppPxeBootOptionalAssetsBundledManifestPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    $path = Join-Path $root 'packaging/pxe-optional-assets.json'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppPxeBootOptionalAssetManifestProp {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    return $Item.$Name
}

function Read-AppPxeBootOptionalAssetObject {
    param([Parameter(Mandatory)]$Obj)
    $id = [string](Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'id')
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $kind = [string](Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'kind')
    if ($kind -notin @('wim', 'iso')) { return $null }
    $fileName = [string](Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'fileName')
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $null }
    $labelProp = Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'label'
    $sizeProp = Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'sizeBytes'
    $shaProp = Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'sha256'
    $urlProp = Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'downloadUrl'
    @{
        id          = $id.Trim()
        kind        = $kind
        fileName    = $fileName.Trim()
        label       = if ($labelProp) { [string]$labelProp } else { $fileName }
        sizeBytes   = if ($null -ne $sizeProp) { [long]$sizeProp } else { 0 }
        sha256      = if ($shaProp) { [string]$shaProp } else { $null }
        downloadUrl = if ($urlProp) { [string]$urlProp } else { $null }
    }
}

function Read-AppPxeBootOptionalAssetsManifestObject {
    param([Parameter(Mandatory)]$Obj)
    $schemaVal = Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'schema'
    if ($schemaVal -and [int]$schemaVal -ne 1) { return $null }
    $assets = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @(Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'assets')) {
        $parsed = Read-AppPxeBootOptionalAssetObject -Obj $entry
        if ($parsed) { [void]$assets.Add($parsed) }
    }
    if ($assets.Count -eq 0) { return $null }
    $updatedProp = Get-AppPxeBootOptionalAssetManifestProp -Item $Obj -Name 'updated'
    @{
        schema    = 1
        updated   = if ($updatedProp) { [string]$updatedProp } else { $null }
        manifestUrl = Get-AppPxeBootOptionalAssetsManifestDefaultUrl
        assets    = @($assets)
        source    = 'unknown'
    }
}

function Get-AppPxeBootOptionalAssetsManifest {
    param([switch]$UseCache)

    if ($UseCache -and $null -ne $script:AppPxeBootOptionalAssetsManifestCache -and $script:AppPxeBootOptionalAssetsManifestCacheAt) {
        $age = ((Get-Date) - $script:AppPxeBootOptionalAssetsManifestCacheAt).TotalSeconds
        if ($age -lt 300) {
            return $script:AppPxeBootOptionalAssetsManifestCache
        }
    }

    $manifestUrl = Get-AppPxeBootOptionalAssetsManifestDefaultUrl
    $result = $null
    try {
        $remote = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $parsed = Read-AppPxeBootOptionalAssetsManifestObject -Obj $remote
        if ($parsed) {
            $parsed.source = 'remote'
            $parsed.manifestUrl = $manifestUrl
            $result = $parsed
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: optional assets manifest fetch failed ($manifestUrl): $($_.Exception.Message)"
    }
    if (-not $result) {
        $bundledPath = Get-AppPxeBootOptionalAssetsBundledManifestPath
        if ($bundledPath) {
            try {
                $local = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $parsed = Read-AppPxeBootOptionalAssetsManifestObject -Obj $local
                if ($parsed) {
                    $parsed.source = 'bundled'
                    $parsed.manifestUrl = $manifestUrl
                    $result = $parsed
                }
            } catch {
                Write-SidecarLogVerbose "PXE boot: bundled optional assets manifest read failed: $($_.Exception.Message)"
            }
        }
    }
    if (-not $result) {
        $result = @{
            schema      = 1
            updated     = $null
            manifestUrl = $manifestUrl
            assets      = @()
            source      = 'default'
        }
    }
    $script:AppPxeBootOptionalAssetsManifestCache = $result
    $script:AppPxeBootOptionalAssetsManifestCacheAt = Get-Date
    return $result
}

function Test-AppPxeBootOptionalAssetFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    $minSize = if ($Kind -eq 'iso') { 104857600 } else { 1048576 }
    if ($item.Length -lt $minSize) { return $false }
    if ($ExpectedSha256) {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $ExpectedSha256.ToLower()) { return $false }
    }
    return $true
}

function Get-AppPxeBootOptionalAssetStorePath {
    param(
        [Parameter(Mandatory)][hashtable]$Asset
    )
    $paths = Get-AppPxeBootLayoutPaths
    if ([string]$Asset.kind -eq 'iso') {
        $name = Get-AppPxeBootSafeIsoFileName -FileName ([string]$Asset.fileName)
        return @{
            fileName = $name
            dest     = Join-Path $paths.isoDir $name
        }
    }
    $wimName = Get-AppPxeBootSafeWimFileName -FileName ([string]$Asset.fileName)
    return @{
        fileName = $wimName
        dest     = Join-Path $paths.wimDir $wimName
    }
}

function Get-AppPxeBootOptionalAssetsStatus {
    param([switch]$SkipHash)
    $manifest = Get-AppPxeBootOptionalAssetsManifest -UseCache:$SkipHash
    $out = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($asset in @($manifest.assets)) {
        $store = Get-AppPxeBootOptionalAssetStorePath -Asset $asset
        $sizeBytes = $null
        $present = $false
        if (Test-Path -LiteralPath $store.dest) {
            $item = Get-Item -LiteralPath $store.dest
            $sizeBytes = [long]$item.Length
            if ($SkipHash) {
                $expected = [long]$asset.sizeBytes
                $present = ($expected -le 0) -or ($sizeBytes -eq $expected)
            } else {
                $present = Test-AppPxeBootOptionalAssetFile -Path $store.dest -Kind ([string]$asset.kind) -ExpectedSha256 ([string]$asset.sha256)
            }
        }
        [void]$out.Add(@{
                id             = [string]$asset.id
                kind           = [string]$asset.kind
                label          = [string]$asset.label
                fileName       = [string]$store.fileName
                present        = $present
                sizeBytes      = $sizeBytes
                expectedSize   = [long]$asset.sizeBytes
                expectedSha256 = [string]$asset.sha256
                downloadUrl    = [string]$asset.downloadUrl
            })
    }
    @{
        manifestUrl    = [string]$manifest.manifestUrl
        manifestSource = [string]$manifest.source
        updated        = if ($manifest.updated) { [string]$manifest.updated } else { $null }
        assets         = @($out)
    }
}

function Download-AppPxeBootOptionalAsset {
    param(
        [Parameter(Mandatory)][string]$AssetId,
        [switch]$ReplaceExisting
    )
    $manifest = Get-AppPxeBootOptionalAssetsManifest
    $asset = @($manifest.assets | Where-Object { [string]$_.id -eq $AssetId.Trim() })[0]
    if (-not $asset) {
        throw "PXE boot: unknown optional asset '$AssetId'."
    }

    $paths = Initialize-AppPxeBootStore
    $store = Get-AppPxeBootOptionalAssetStorePath -Asset $asset
    $targetName = [string]$store.fileName
    $dest = [string]$store.dest
    $kind = [string]$asset.kind

    if ((Test-Path -LiteralPath $dest) -and -not $ReplaceExisting) {
        if (Test-AppPxeBootOptionalAssetFile -Path $dest -Kind $kind -ExpectedSha256 ([string]$asset.sha256)) {
            return @{
                assetId  = [string]$asset.id
                kind     = $kind
                fileName = $targetName
                sizeBytes = [long](Get-Item -LiteralPath $dest).Length
                skipped  = $true
                library  = (Get-AppPxeBootWimLibraryResponse)
            }
        }
        throw "PXE boot: $targetName already exists - use replace to re-download."
    }

    $downloadUrl = [string]$asset.downloadUrl
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        throw "PXE boot: download URL not configured for $($asset.id)."
    }

    $tmp = Join-Path $paths.storeRoot ("download-$targetName.part")
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $sizeMb = if ($asset.sizeBytes -gt 0) { [math]::Round($asset.sizeBytes / 1MB, 0) } else { 0 }
    Write-SidecarLog "PXE boot: downloading $targetName (~${sizeMb} MB) ($($asset.id))..."
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 7200 -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw "PXE boot: download failed for $targetName - $($_.Exception.Message)"
    }

    if (-not (Test-AppPxeBootOptionalAssetFile -Path $tmp -Kind $kind -ExpectedSha256 ([string]$asset.sha256))) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "PXE boot: downloaded $targetName failed validation (size or SHA256)."
    }

    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-SidecarLog "PXE boot: installed $targetName ($([math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1)) MB)"

    if ($kind -eq 'wim') {
        Ensure-AppPxeBootWimBootAssets -WimFileName $targetName | Out-Null
    }

    Write-AppPxeBootMenuFiles
    @{
        assetId   = [string]$asset.id
        kind      = $kind
        fileName  = $targetName
        sizeBytes = [long](Get-Item -LiteralPath $dest).Length
        skipped   = $false
        library   = (Get-AppPxeBootWimLibraryResponse)
    }
}

function Get-AppPxeBootIsoInventory {
    $paths = Get-AppPxeBootLayoutPaths
    $files = @(Get-ChildItem -LiteralPath $paths.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    # bootKind/bootLabel come from the live mount map: 'windows' (install.wim served),
    # 'linux' (kernel + initrd served, menu entry present), or $null when the ISO is not
    # mounted right now (services stopped, or media nothing recognises).
    $mounts = $script:AppPxeBootState.IsoMounts
    @($files | ForEach-Object {
        $name = $_.Name
        $token = Get-AppPxeBootIsoMountToken -IsoFileName $name
        $mount = if ($mounts.ContainsKey($token)) { $mounts[$token] } else { $null }
        @{
            fileName   = $name
            sizeBytes  = [long]$_.Length
            modifiedAt = $_.LastWriteTimeUtc.ToString('o')
            httpPath   = "iso/$name"
            label      = ([IO.Path]::GetFileNameWithoutExtension($name) -replace '_', ' ')
            bootKind   = if ($mount) { [string]$mount.kind } else { $null }
            bootLabel  = if ($mount -and $mount.linux) { [string]$mount.linux.label } else { $null }
            bootNote   = if ($mount -and $mount.linux) { Get-AppPxeBootLinuxInstallNote -Linux $mount.linux } else { $null }
        }
    })
}

function Get-AppPxeBootLinuxInstallNote {
    # One line for the ISO list: what booting this entry will actually do.
    param([Parameter(Mandatory)]$Linux)
    if ([string]$Linux.platform -eq 'ubuntu') { return 'installs from this ISO (Ubuntu live server; a task sequence makes it unattended)' }
    $netboot = $Linux.netboot
    if (-not $netboot) { return $null }
    if ($netboot.ready) { return "installs from $([string](Get-AppPxeBootDebianMirrorHostDirectory).host) (netboot initrd d-i $([string]$netboot.diVersion))" }
    return "boots to the installer only - netboot initrd not fetched: $([string]$netboot.reason)"
}

function Test-AppPxeBootLayout {
    # Memoised: this is a file-existence sweep over the whole store and it was the
    # single biggest cost in the 8s status poll (258 ms measured, 2026-08-23). 6s keeps
    # it fresh enough that an import or a delete shows up on the next poll.
    param([switch]$SkipStoreInit)
    # Both paths memoised: the status poll takes the NON-skip path, which also re-runs
    # Initialize-AppPxeBootStore (mkdir + README sweep) every 8 seconds for nothing.
    if ($SkipStoreInit) {
        return Get-AppPxeBootMemo -Key 'layout-test-skipinit' -Seconds 6 -Producer { Test-AppPxeBootLayoutUncached -SkipStoreInit }
    }
    return Get-AppPxeBootMemo -Key 'layout-test' -Seconds 6 -Producer { Test-AppPxeBootLayoutUncached }
}

function Test-AppPxeBootLayoutUncached {
    param([switch]$SkipStoreInit)

    $paths = if ($SkipStoreInit) { Get-AppPxeBootLayoutPaths } else { Initialize-AppPxeBootStore }
    $missing = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $paths.snponlyEfi)) {
        if (Get-AppPxeBootBundledSnponlyPath) {
            [void]$warnings.Add('tftp/snponly.efi - bundled copy pending (enable Netboot or start imaging services)')
        } else {
            [void]$missing.Add('tftp/snponly.efi')
        }
    }
    $configuredBootFile = Get-AppPxeBootConfiguredTftpBootFile
    if (-not (Test-AppPxeBootTftpBootFileExists -RelativePath $configuredBootFile)) {
        $relNorm = ($configuredBootFile -replace '\\', '/').ToLowerInvariant()
        if (Get-AppPxeBootBundledSecureBootTftpRoot -and $relNorm -like 'x86_64-sb/*') {
            [void]$warnings.Add("tftp/$configuredBootFile - bundled Secure Boot tree pending (enable Netboot or start imaging services)")
        } else {
            [void]$warnings.Add("tftp/$configuredBootFile - Option 67 boot file missing (choose another under PXE on this host)")
        }
    } elseif ($configuredBootFile -ne 'snponly.efi' -and (Test-AppPxeBootTftpBootFileSecureBoot -RelativePath $configuredBootFile)) {
        if (-not (Test-AppPxeBootTftpBootFileIsSecureBootShimEntry -RelativePath $configuredBootFile)) {
            [void]$warnings.Add(
                "tftp/$configuredBootFile - Secure Boot will fail (hash not allowed / DB); Option 67 must be x86_64-sb/shimx64.efi, not ipxe/snponly in -sb/"
            )
        }
    }
    if (-not (Test-Path -LiteralPath $paths.wimboot)) {
        if (Get-AppPxeBootBundledWimbootPath) {
            [void]$warnings.Add('http/wimboot/wimboot - bundled copy pending (start field PXE)')
        } else {
            [void]$missing.Add('http/wimboot/wimboot - run scripts/fetch-wimboot.ps1 and rebuild')
        }
    }
    $wimFiles = @(Get-ChildItem -LiteralPath $paths.wimDir -Filter '*.wim' -File -ErrorAction SilentlyContinue)
    $isoFiles = @(Get-ChildItem -LiteralPath $paths.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue)
    $cfg = Read-AppPxeBootConfig
    if ($wimFiles.Count -eq 0) {
        [void]$warnings.Add('http/wim/*.wim - add a boot WIM below (import from a Windows ISO)')
    }
    if ($isoFiles.Count -gt 0) {
        foreach ($iso in $isoFiles) {
            # Mount-and-serve only: install.wim is exposed live from the mounted ISO
            # once imaging services run - warn only when services are up but the
            # mount failed. (Extraction removed 2026-08-18: duplicated multi-GB WIMs.)
            # Mounts are keyed by token, not by the bare stem (the stem lookup never
            # matched, so this warned for every ISO whenever HTTP was up). livePath is
            # install.wim for Windows media and the kernel for a Linux ISO.
            $token = Get-AppPxeBootIsoMountToken -IsoFileName $iso.Name
            $mount = if ($script:AppPxeBootState.IsoMounts.ContainsKey($token)) { $script:AppPxeBootState.IsoMounts[$token] } else { $null }
            $httpRunning = $script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited
            $mountLive = $false
            if ($mount) {
                $probe = [string]$mount.livePath
                $mountLive = [bool]($probe -and (Test-Path -LiteralPath $probe))
            }
            if ($httpRunning -and -not $mountLive) {
                [void]$warnings.Add(
                    "iso/$($iso.Name) - ISO not mounted (needs sources/install.wim, or a Linux installer layout such as install.amd/; Stop then Start Imaging Services)"
                )
            }
        }
    }
    foreach ($wim in $wimFiles) {
        if ($wim.Length -lt 1MB) {
            [void]$warnings.Add(
                "http/wim/$($wim.Name) - file is only $([math]::Round($wim.Length / 1KB, 1)) KB (corrupt or placeholder - re-import via Add boot WIM...)"
            )
        }
        $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $wim.Name
        if (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'bootAssetsMissing') {
            [void]$warnings.Add(
                "http/wim-boot/$([IO.Path]::GetFileNameWithoutExtension($wim.Name))/ - boot files missing (remove and re-add the WIM in Netboot)"
            )
        }
    }

    $drivers = Get-AppPxeBootDriversSummary
    if ([int]$drivers.modelCount -gt 0 -and [int]$drivers.readyCount -eq 0) {
        [void]$warnings.Add('Drivers/<model> - model folders exist but no driver packs yet (.cab/.exe/.7z - Open drivers folder or aria2 Tracker)')
    }

    @{
        ok                 = ($missing.Count -eq 0)
        storeRoot          = $paths.storeRoot
        tftpRoot           = $paths.tftpRoot
        httpRoot           = $paths.httpRoot
        snponlyEfi         = $paths.snponlyEfi
        wimbootPath        = $paths.wimboot
        wimFiles           = @($wimFiles | ForEach-Object { $_.Name })
        isoFiles           = @($isoFiles | ForEach-Object { $_.Name })
        defaultBootWim     = if ($cfg.defaultBootWim) { [string]$cfg.defaultBootWim } else { $null }
        wims               = @(Get-AppPxeBootWimInventory)
        isos               = @(Get-AppPxeBootIsoInventory)
        localHttpOnly      = -not (Test-AppPxeBootWanDeployMenuEnabled)
        wanIsoCatalogUrl   = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        driversSummary     = $drivers
        missing            = @($missing)
        warnings           = @($warnings)
    }
}

function Test-AppIsExcludedLocationIPv4 {
    <#
    .SYNOPSIS
        True when an IPv4 address cannot be the PXE host address.
    .DESCRIPTION
        PXE clients reach this machine by broadcasting on the local segment, so
        the host IP must be a real, routable-on-LAN address. Excluded:
          * loopback            127.0.0.0/8
          * link-local / APIPA  169.254.0.0/16  (DHCP never answered)
          * CGNAT               100.64.0.0/10   (carrier-grade NAT and overlay
                                                 networks - no broadcast domain
                                                 shared with the client)
          * unspecified         0.0.0.0/8
          * multicast/reserved  224.0.0.0/4 and above
        Everything else - RFC1918 LAN ranges and public addresses - is allowed.
    .NOTES
        Replaces the USM original, which filtered against an org site catalog.
    #>
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) { return $true }
    $parsed = [System.Net.IPAddress]::Any
    if (-not [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsed)) { return $true }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $true }

    $o = $parsed.GetAddressBytes()
    if ($o[0] -eq 127) { return $true }                        # loopback
    if ($o[0] -eq 0) { return $true }                          # unspecified
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return $true }     # link-local
    if ($o[0] -eq 100 -and $o[1] -ge 64 -and $o[1] -le 127) { return $true }  # CGNAT
    if ($o[0] -ge 224) { return $true }                        # multicast / reserved
    return $false
}

# --- Short-lived memos for the status build ---------------------------------
# Get-AppPxeBootStatus is polled every 8s by the Netboot panel and cost ~700ms per
# call, nearly all of it shelling out: the adapter list, the LAN IP, `sharing -l`,
# and a WIM-library file walk (measured 2026-08-22 - 190/151/113/64 ms). None of
# those change between two polls, so each gets a memo shorter than the poll. What is
# deliberately NOT memoised for long is process liveness: a stale "running" badge is
# worse than a slow one, so that memo is ~1.5s, just long enough to stop one status
# build probing the same port twice.
$script:AppPxeBootMemo = @{}

function Get-AppPxeBootMemo {
    <#
    .SYNOPSIS
        Run $Producer at most once per $Seconds for a given key. Failures are not
        cached - a transient shell-out error must not stick around.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Producer,
        [double]$Seconds = 10
    )
    $now = [DateTime]::UtcNow
    $hit = $script:AppPxeBootMemo[$Key]
    if ($hit -and ($now - $hit.at).TotalSeconds -lt $Seconds) { return $hit.value }
    $value = & $Producer
    $script:AppPxeBootMemo[$Key] = @{ at = $now; value = $value }
    return $value
}

function Clear-AppPxeBootMemo {
    # Anything that changes what these read - starting or stopping a service, importing
    # a WIM or ISO, publishing the share - must call this so the panel does not show a
    # stale answer for the next few seconds.
    param([string]$Key)
    if ($Key) { $script:AppPxeBootMemo.Remove($Key) } else { $script:AppPxeBootMemo.Clear() }
}

function Get-AppPxeBootNetworkAdaptersUncached {
    $cfg = Read-AppPxeBootConfig
    $defaultIfId = $null
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $ua.Address.ToString()
                $gw = Get-AppIpv4DefaultGatewayForAddress -Ip $ip
                if ($gw) {
                    $defaultIfId = $nic.Id
                    break
                }
            }
            if ($defaultIfId) { break }
        }
    } catch {
        # Was a bare catch {}. A fault in here leaves every adapter un-flagged and
        # surfaces as "No LAN IP" with no log line anywhere - the exact diagnosis
        # this cost during the port, and again in USM (b2fa883).
        Write-SidecarLogVerbose "PXE boot: default-gateway detection failed - $($_.Exception.Message)"
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $ips = [System.Collections.Generic.List[string]]::new()
            foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $ua.Address.ToString()
                if ($ip -eq '127.0.0.1' -or $ip.StartsWith('127.')) { continue }
                if (Test-AppIsExcludedLocationIPv4 $ip) { continue }
                [void]$ips.Add($ip)
            }
            if ($ips.Count -eq 0) { continue }
            $isDefault = ($nic.Id -eq $defaultIfId)
            if (-not $isDefault -and $cfg.interfaceId -and $nic.Id -eq $cfg.interfaceId) {
                $isDefault = $true
            }
            [void]$rows.Add([ordered]@{
                id          = $nic.Id
                name        = $nic.Name
                description = $nic.Description
                ipv4        = @($ips)
                isDefault   = $isDefault
            })
        }
    } catch {
        Write-SidecarLog "PXE boot: adapter enumeration failed - $($_.Exception.Message)"
    }

    if ($rows.Count -gt 0 -and -not ($rows | Where-Object { $_.isDefault })) {
        $rows[0].isDefault = $true
    }
    @($rows)
}

function Resolve-AppPxeBootSelectedAdapter {
    param([string]$InterfaceId)
    $adapters = @(Get-AppPxeBootNetworkAdapters)
    if ($InterfaceId) {
        $match = $adapters | Where-Object { $_.id -eq $InterfaceId } | Select-Object -First 1
        if ($match) { return $match }
    }
    $adapters | Where-Object { $_.isDefault } | Select-Object -First 1
}

function Get-AppPxeBootNetworkAdapters {
    # Interfaces do not change between two 8s polls; the enumeration walks every NIC.
    Get-AppPxeBootMemo -Key 'adapters' -Seconds 12 -Producer { @(Get-AppPxeBootNetworkAdaptersUncached) }
}

function Get-AppPxeBootLanIpUncached {
    param([string]$InterfaceId)
    $adapter = Resolve-AppPxeBootSelectedAdapter -InterfaceId $InterfaceId
    if (-not $adapter) { return $null }
    $ip = @($adapter.ipv4 | Where-Object { $_ -and -not (Test-AppIsExcludedLocationIPv4 $_) } | Select-Object -First 1)
    if ($ip) { return [string]$ip }
    return $null
}

function Get-AppPxeBootLanIp {
    # Still ~100ms with the adapter list cached (the exclusion checks per address), and
    # the host's LAN address does not change between two polls.
    param([string]$InterfaceId)
    Get-AppPxeBootMemo -Key "lan-ip-$InterfaceId" -Seconds 12 -Producer { Get-AppPxeBootLanIpUncached -InterfaceId $InterfaceId }
}

function Get-AppPxeBootLanIpHint {
    param([string]$InterfaceId)
    $adapters = @(Get-AppPxeBootNetworkAdapters)
    if ($adapters.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($InterfaceId)) {
            return 'Select the Ethernet adapter below - the default route is not a usable PXE address.'
        }
        return $null
    }

    $vpnOrLinkLocalOnly = $false
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $hasUsable = $false
            $hasExcluded = $false
            foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $ua.Address.ToString()
                if ($ip -eq '127.0.0.1' -or $ip.StartsWith('127.')) { continue }
                if (Test-AppIsExcludedLocationIPv4 $ip) {
                    $hasExcluded = $true
                } else {
                    $hasUsable = $true
                }
            }
            if ($hasUsable) { return 'Adapters are still refreshing - pick Ethernet below or wait a moment and refresh.' }
            if ($hasExcluded) { $vpnOrLinkLocalOnly = $true }
        }
    } catch { }

    if ($vpnOrLinkLocalOnly) {
        return 'No usable Ethernet IPv4 is up - PXE needs a real LAN address. Plug in the cable, wait for DHCP, then pick that adapter.'
    }
    return 'No usable IPv4 on any adapter. Plug in Ethernet and wait for an address (link-local and CGNAT are ignored).'
}

function Resolve-AppPxeBootDnsmasqPath {
    $bundled = Get-AppPxeBootBundledDnsmasqPath
    if ($bundled) { return $bundled }

    $cmd = Get-Command dnsmasq -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    # No Homebrew / MacPorts probe (Craig, 2026-08-29): the bundled dnsmasq is the only
    # supported macOS source.
    return $null
}

function Get-AppPxeBootBundledDnsmasqPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }

    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        foreach ($rel in @('binaries\dnsmasq.exe', 'sidecar\tools\dnsmasq.exe')) {
            $path = Join-Path $root $rel
            if (Test-Path -LiteralPath $path) {
                return (Resolve-Path -LiteralPath $path).Path
            }
        }
        $vendor = Join-Path $root 'vendor\binaries\pxe-windows\dnsmasq.exe'
        if (Test-Path -LiteralPath $vendor) {
            return (Resolve-Path -LiteralPath $vendor).Path
        }
        return $null
    }

    if ($IsMacOS) {
        $candidates = [System.Collections.Generic.List[string]]::new()
        [void]$candidates.Add((Join-Path $root 'binaries/dnsmasq-universal'))
        $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
        $suffix = if ($isArm) { 'aarch64-apple-darwin' } else { 'x86_64-apple-darwin' }
        [void]$candidates.Add((Join-Path $root "binaries/dnsmasq-$suffix"))
        [void]$candidates.Add((Join-Path $root 'binaries/dnsmasq'))
        [void]$candidates.Add((Join-Path $root 'vendor/binaries/pxe-macos/dnsmasq-universal'))
        [void]$candidates.Add((Join-Path $root "vendor/binaries/pxe-macos/dnsmasq-$suffix"))
        foreach ($path in $candidates) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            Set-AppPxeBootDnsmasqExecutable -Path $path
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Set-AppPxeBootDnsmasqExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not ($IsMacOS -or $IsDarwin)) { return }
    $null = & chmod '+x' $Path 2>$null
    $null = & xattr -d com.apple.quarantine $Path 2>$null
}

function Get-AppPxeBootMacOsTftpTraverseDirs {
    <#
    .SYNOPSIS
        Directories from ~/Library down to the pxe-boot store parent that elevated dnsmasq
        must traverse. TFTP assets stay in Application Support; macOS defaults ~/Library to
        700 so root cannot reach plugins/pxe-boot/tftp without a traverse grant.
    #>
    if (-not ($IsMacOS -or $IsDarwin)) { return @() }
    $tftpRoot = try { (Get-AppPxeBootLayoutPaths).tftpRoot } catch { $null }
    $userHome = $env:HOME
    if ([string]::IsNullOrWhiteSpace($tftpRoot) -or [string]::IsNullOrWhiteSpace($userHome)) { return @() }

    $libraryFull = try {
        [System.IO.Path]::GetFullPath((Join-Path $userHome 'Library'))
    } catch {
        Join-Path $userHome 'Library'
    }

    $chain = [System.Collections.Generic.List[string]]::new()
    $cursor = Split-Path -Parent $tftpRoot
    while ($cursor) {
        $cursorFull = try { [System.IO.Path]::GetFullPath($cursor) } catch { $cursor }
        if ($chain -notcontains $cursorFull) {
            [void]$chain.Insert(0, $cursorFull)
        }
        if ($cursorFull -eq $libraryFull) { break }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    @($chain)
}

function Get-AppPxeBootMacOsTftpRootTraverseShellMac {
    <#
    .SYNOPSIS
        Elevated shell prelude: grant traverse (search) on ~/Library -> .../pxe-boot so root dnsmasq
        can read the canonical TFTP tree under Application Support. No copy or /private/tmp mirror.
    #>
    if (-not (Test-AppSidecarCommand ConvertTo-AppUnixShellSingleQuotedString)) {
        return ''
    }
    $dirs = @(Get-AppPxeBootMacOsTftpTraverseDirs)
    if ($dirs.Count -eq 0) { return '' }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in $dirs) {
        $q = ConvertTo-AppUnixShellSingleQuotedString -Value $dir
        [void]$parts.Add("chmod +a 'everyone allow search' $q 2>/dev/null || chmod o+x $q 2>/dev/null || true")
    }
    return ($parts -join ' && ')
}

function Get-AppPxeBootInterfaceNameForDnsmasq {
    param([string]$InterfaceId)
    $adapter = Resolve-AppPxeBootSelectedAdapter -InterfaceId $InterfaceId
    if (-not $adapter) { return $null }
    if ($IsMacOS) { return [string]$adapter.name }
    return [string]$adapter.name
}

function New-AppPxeBootDnsmasqConfig {
    param(
        [Parameter(Mandatory)][string]$TftpRoot,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$InterfaceId,
        [ValidateSet('router', 'standalone', 'proxy')]
        [string]$Mode = 'router'
    )
    $iface = Get-AppPxeBootInterfaceNameForDnsmasq -InterfaceId $InterfaceId
    if (-not $iface) {
        throw 'PXE boot: no active network adapter with IPv4 - connect Ethernet and retry.'
    }
    $bootFile = Get-AppPxeBootConfiguredTftpBootFile
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $InterfaceId
    $tftpRootNorm = ($TftpRoot -replace '\\', '/')
    $logFile = Join-Path (Get-AppPxeBootStoreRoot) 'dnsmasq.log'
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("# Netboot PXE boot - generated $(Get-Date -Format 'o')")
    [void]$lines.Add("interface=$iface")
    [void]$lines.Add('bind-interfaces')
    switch ($Mode) {
        'router' {
            # TFTP only - no site DHCP/DNS (port=0). Matches ipxeboot dnsmasq-tftp-only.conf.
            [void]$lines.Add('port=0')
        }
        'standalone' {
            [void]$lines.Add('dhcp-range=192.168.99.50,192.168.99.200,255.255.255.0,12h')
            [void]$lines.Add('dhcp-option=3,192.168.99.1')
            [void]$lines.Add('log-dhcp')
        }
        'proxy' {
            [void]$lines.Add('dhcp-range=0.0.0.0,proxy,255.255.255.0')
            [void]$lines.Add('log-dhcp')
        }
    }
    if ($Mode -in @('proxy', 'standalone')) {
        if ($lanIp) {
            [void]$lines.Add("dhcp-boot=$bootFile,$lanIp,$lanIp")
        } else {
            [void]$lines.Add("dhcp-boot=$bootFile")
        }
    }
    [void]$lines.Add('enable-tftp')
    [void]$lines.Add("tftp-root=$tftpRootNorm")
    [void]$lines.Add("log-facility=$($logFile -replace '\\', '/')")
    ($lines -join "`n") | Set-Content -LiteralPath $OutPath -Encoding UTF8 -Force
    $OutPath
}

# Keep in sync with packaging/pxe-caddy.json (runtime install - not bundled in signed macOS pkg).
$script:AppPxeBootCaddyVersion = '2.11.4'

function Get-AppPxeBootCaddyManifestDefaultUrl {
    if ($env:APP_PXE_CADDY_MANIFEST_URL) {
        return [string]$env:APP_PXE_CADDY_MANIFEST_URL
    }
    return (Get-AppProductAssetFeedUrl -Name 'pxe-caddy.json')
}

function Get-AppPxeBootCaddyBundledManifestPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    $path = Join-Path $root 'packaging/pxe-caddy.json'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppPxeBootCaddyManifestProp {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-AppPxeBootCaddyPlatformKey {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
        if ($isArm) { return 'windows_arm64' }
        return 'windows_amd64'
    }
    if ($IsMacOS -or $IsDarwin) {
        $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
        if ($isArm) { return 'macos_arm64' }
        return 'macos_amd64'
    }
    throw 'PXE boot: Caddy install is supported on macOS and Windows only.'
}

function Get-AppPxeBootCaddyBinaryFileName {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) { return 'caddy.exe' }
    return 'caddy'
}

function Get-AppPxeBootCaddyMarkerPath {
    Join-Path (Get-AppPxeBootLayoutPaths).caddyBinaryDir '.caddy-version'
}

function Test-AppPxeBootCaddyInstalled {
    param([switch]$RequirePinnedVersion)
    $paths = Get-AppPxeBootLayoutPaths
    $bin = Join-Path $paths.caddyBinaryDir (Get-AppPxeBootCaddyBinaryFileName)
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { return $false }
    if ($RequirePinnedVersion) {
        $marker = Get-AppPxeBootCaddyMarkerPath
        if (-not (Test-Path -LiteralPath $marker)) { return $false }
        $installed = [string](Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
        $expected = if (Test-AppSidecarCommand Get-AppToolExpectedVersion) { Get-AppToolExpectedVersion -Id 'caddy' -Default $script:AppPxeBootCaddyVersion } else { $script:AppPxeBootCaddyVersion }
        if ($installed -ne $expected) { return $false }
    }
    return $true
}

function Get-AppPxeBootCaddyPath {
    if ($env:APP_PXE_CADDY -and (Test-Path -LiteralPath $env:APP_PXE_CADDY -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:APP_PXE_CADDY).Path
    }
    $paths = Get-AppPxeBootLayoutPaths
    $bin = Join-Path $paths.caddyBinaryDir (Get-AppPxeBootCaddyBinaryFileName)
    if (Test-Path -LiteralPath $bin -PathType Leaf) {
        return (Resolve-Path -LiteralPath $bin).Path
    }
    $cmd = Get-Command caddy -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
        return $cmd.Source
    }
    return $null
}

function Set-AppPxeBootCaddyExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-AppIsMacOSPlatform)) { return }
    $null = & chmod '+x' $Path 2>$null
    $null = & xattr -d com.apple.quarantine $Path 2>$null
}

function Read-AppPxeBootCaddyManifestObject {
    param([Parameter(Mandatory)]$Obj)
    $schemaVal = Get-AppPxeBootCaddyManifestProp -Item $Obj -Name 'schema'
    if ($schemaVal -and [int]$schemaVal -ne 1) { return $null }
    $version = [string](Get-AppPxeBootCaddyManifestProp -Item $Obj -Name 'version')
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    $platformsRaw = Get-AppPxeBootCaddyManifestProp -Item $Obj -Name 'platforms'
    if (-not $platformsRaw) { return $null }
    $platforms = @{}
    foreach ($prop in $platformsRaw.PSObject.Properties) {
        $entry = $prop.Value
        $archiveName = [string](Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'archiveName')
        $archiveKind = [string](Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'archiveKind')
        $binaryName = [string](Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'binaryName')
        $shaProp = Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'sha256'
        $urlProp = Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'downloadUrl'
        $githubProp = Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'githubUrl'
        $sizeProp = Get-AppPxeBootCaddyManifestProp -Item $entry -Name 'sizeBytes'
        if ([string]::IsNullOrWhiteSpace($archiveName) -or [string]::IsNullOrWhiteSpace($binaryName)) { continue }
        if ($archiveKind -notin @('zip', 'tar.gz')) { continue }
        $platforms[$prop.Name] = @{
            archiveName = $archiveName.Trim()
            archiveKind = $archiveKind
            binaryName  = $binaryName.Trim()
            sha256      = if ($shaProp) { [string]$shaProp } else { $null }
            downloadUrl = if ($urlProp) { [string]$urlProp } else { $null }
            githubUrl   = if ($githubProp) { [string]$githubProp } else { $null }
            sizeBytes   = if ($null -ne $sizeProp) { [long]$sizeProp } else { 0 }
        }
    }
    if ($platforms.Count -eq 0) { return $null }
    $updatedProp = Get-AppPxeBootCaddyManifestProp -Item $Obj -Name 'updated'
    @{
        schema      = 1
        version     = $version.Trim()
        updated     = if ($updatedProp) { [string]$updatedProp } else { $null }
        manifestUrl = Get-AppPxeBootCaddyManifestDefaultUrl
        platforms   = $platforms
        source      = 'unknown'
    }
}

function Get-AppPxeBootCaddyManifest {
    $manifestUrl = Get-AppPxeBootCaddyManifestDefaultUrl
    try {
        $remote = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $parsed = Read-AppPxeBootCaddyManifestObject -Obj $remote
        if ($parsed) {
            $parsed.source = 'remote'
            $parsed.manifestUrl = $manifestUrl
            return $parsed
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: Caddy manifest fetch failed ($manifestUrl): $($_.Exception.Message)"
    }
    $bundledPath = Get-AppPxeBootCaddyBundledManifestPath
    if ($bundledPath) {
        try {
            $local = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsed = Read-AppPxeBootCaddyManifestObject -Obj $local
            if ($parsed) {
                $parsed.source = 'bundled'
                $parsed.manifestUrl = $manifestUrl
                return $parsed
            }
        } catch {
            Write-SidecarLogVerbose "PXE boot: bundled Caddy manifest read failed: $($_.Exception.Message)"
        }
    }
    throw 'PXE boot: Caddy manifest unavailable (no asset feed configured and no bundled copy).'
}

function Get-AppPxeBootCaddyPlatformEntry {
    $manifest = Get-AppPxeBootCaddyManifest
    $key = Get-AppPxeBootCaddyPlatformKey
    if (-not $manifest.platforms.ContainsKey($key)) {
        throw "PXE boot: Caddy manifest has no entry for platform $key."
    }
    @{
        platformKey = $key
        manifest    = $manifest
        entry       = $manifest.platforms[$key]
    }
}

function Invoke-AppPxeBootCaddyArtifactDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing `
            -UserAgent (Get-AppUserAgent) -MaximumRedirection 5 -TimeoutSec 600 -ErrorAction Stop
    } catch {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 404) {
            throw "Caddy download failed (404): $Uri"
        }
        throw
    }
}

function Test-AppPxeBootCaddyArchiveFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256,
        [long]$ExpectedSizeBytes = 0
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ($ExpectedSizeBytes -gt 0) {
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -ne $ExpectedSizeBytes) { return $false }
    }
    if ($ExpectedSha256) {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $ExpectedSha256.ToLowerInvariant()) { return $false }
    }
    return $true
}

function Expand-AppPxeBootCaddyArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$ArchiveKind,
        [Parameter(Mandatory)][string]$ExtractDir,
        [Parameter(Mandatory)][string]$BinaryName
    )
    if (-not (Test-Path -LiteralPath $ExtractDir)) {
        $null = New-Item -Path $ExtractDir -ItemType Directory -Force
    }
    if ($ArchiveKind -eq 'zip') {
        Expand-Archive -LiteralPath $Archive -DestinationPath $ExtractDir -Force
    } elseif ($ArchiveKind -eq 'tar.gz') {
        & tar -xzf $Archive -C $ExtractDir
        if ($LASTEXITCODE -ne 0) {
            throw "PXE boot: tar extract failed for $(Split-Path -Leaf $Archive)"
        }
    } else {
        throw "PXE boot: unknown Caddy archive kind $ArchiveKind"
    }
    $bin = Join-Path $ExtractDir $BinaryName
    if (Test-Path -LiteralPath $bin) { return $bin }
    $found = Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $BinaryName } |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "PXE boot: $BinaryName missing after extracting $(Split-Path -Leaf $Archive)"
}

function Get-AppPxeBootCaddyDownloadStatus {
    $path = Get-AppPxeBootCaddyPath
    $marker = Get-AppPxeBootCaddyMarkerPath
    $installedVersion = $null
    if (Test-Path -LiteralPath $marker) {
        $installedVersion = [string](Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
    }
    @{
        ready            = [bool]$path
        path             = $path
        installedVersion = $installedVersion
        pinnedVersion    = $script:AppPxeBootCaddyVersion
        needsInstall     = -not (Test-AppPxeBootCaddyInstalled -RequirePinnedVersion)
    }
}

function Ensure-AppPxeBootCaddy {
    Ensure-AppPxeBootStoreLayout | Out-Null
    if (Test-AppPxeBootCaddyInstalled -RequirePinnedVersion) {
        return @{
            ok      = $true
            skipped = $true
            path    = (Get-AppPxeBootCaddyPath)
            version = $script:AppPxeBootCaddyVersion
        }
    }

    $resolved = Get-AppPxeBootCaddyPlatformEntry
    $entry = $resolved.entry
    $platformKey = $resolved.platformKey
    $manifest = $resolved.manifest
    $paths = Get-AppPxeBootLayoutPaths
    $destBin = Join-Path $paths.caddyBinaryDir (Get-AppPxeBootCaddyBinaryFileName)
    $sizeMb = if ($entry.sizeBytes -gt 0) { [math]::Round($entry.sizeBytes / 1MB, 0) } else { 17 }

    Write-SidecarLog "PXE boot: installing Caddy $($manifest.version) ($platformKey, ~${sizeMb} MB) to $($paths.caddyBinaryDir)"
    Write-SidecarEvent -EventName 'pxe-caddy' -Data @{
        phase   = 'installing'
        version = [string]$manifest.version
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sm-pxe-caddy-" + [guid]::NewGuid().ToString())
    $archivePath = Join-Path $tmpRoot $entry.archiveName
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    try {
        $downloadUrls = [System.Collections.Generic.List[string]]::new()
        if ($entry.downloadUrl) { [void]$downloadUrls.Add([string]$entry.downloadUrl) }
        if ($entry.githubUrl -and $entry.githubUrl -ne $entry.downloadUrl) {
            [void]$downloadUrls.Add([string]$entry.githubUrl)
        }
        if ($downloadUrls.Count -eq 0) {
            throw 'PXE boot: Caddy manifest entry has no download URL.'
        }

        $downloaded = $false
        $lastError = $null
        foreach ($url in @($downloadUrls)) {
            try {
                if (Test-Path -LiteralPath $archivePath) {
                    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                }
                Invoke-AppPxeBootCaddyArtifactDownload -Uri $url -OutFile $archivePath
                if (Test-AppPxeBootCaddyArchiveFile -Path $archivePath -ExpectedSha256 $entry.sha256 -ExpectedSizeBytes $entry.sizeBytes) {
                    $downloaded = $true
                    break
                }
                $lastError = 'SHA256 or size mismatch after download'
            } catch {
                $lastError = $_.Exception.Message
                Write-SidecarLogVerbose "PXE boot: Caddy download failed from $url - $lastError"
            }
        }
        if (-not $downloaded) {
            throw "PXE boot: Caddy download failed - $lastError"
        }

        $extractDir = Join-Path $tmpRoot 'extract'
        $extractedBin = Expand-AppPxeBootCaddyArchive `
            -Archive $archivePath `
            -ArchiveKind $entry.archiveKind `
            -ExtractDir $extractDir `
            -BinaryName $entry.binaryName
        Copy-Item -LiteralPath $extractedBin -Destination $destBin -Force
        Set-AppPxeBootCaddyExecutable -Path $destBin
        Set-Content -LiteralPath (Get-AppPxeBootCaddyMarkerPath) -Value $script:AppPxeBootCaddyVersion -Encoding ASCII -Force

        Write-SidecarLog "PXE boot: Caddy $($script:AppPxeBootCaddyVersion) installed at $destBin"
        Write-SidecarEvent -EventName 'pxe-caddy' -Data @{
            phase   = 'complete'
            version = $script:AppPxeBootCaddyVersion
            path    = $destBin
        }
        return @{
            ok      = $true
            skipped = $false
            path    = $destBin
            version = $script:AppPxeBootCaddyVersion
        }
    } catch {
        Write-SidecarEvent -EventName 'pxe-caddy' -Data @{
            phase   = 'failed'
            message = $_.Exception.Message
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AppPxeBootCaddyfile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HttpRoot,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$BindAddress,
        # When > 0, POST /imaging-log/* reverse-proxies to the sidecar's loopback ingest
        # listener (deploy client live-log push). 0 = route omitted; clients fail fast.
        [int]$ImagingLogIngestPort = 0
    )
    $rootNorm = ($HttpRoot -replace '\\', '/')
    $accessLogNorm = ((Join-Path (Get-AppPxeBootStoreRoot) 'http-access.log') -replace '\\', '/')
    $listenSite = if ($BindAddress -eq '0.0.0.0') { "http://:$Port" } else { "http://${BindAddress}:$Port" }

    # Image-library routes: ISOs, driver packs, and imageable WIMs live under the
    # user-chosen ISO & driver root (off the system drive), not the PXE store.
    # handle_path strips the leading prefix so e.g.
    #   GET /drivers/index.json -> <root>/Drivers/index.json
    #   GET /iso/foo.iso        -> <root>/iso/foo.iso
    #   GET /WIMs/soe.wim       -> <root>/WIMs/soe.wim
    # Only boot WIMs (http/wim), iso-wim extracts, and the iPXE/menu chain remain
    # served from $HttpRoot. URL paths are unchanged from the old in-store layout.
    $routeLines = @()
    try {
        $lib = Get-AppImageLibraryPaths
        foreach ($route in @(
                @{ prefix = 'iso';     dir = $lib.isoDir },
                @{ prefix = 'drivers'; dir = $lib.driversDir },
                @{ prefix = 'WIMs';    dir = $lib.wimsDir },
                # TaskSequences/ so an HTTP-only client (no Deploy$ mount) can read
                # index.json and the unattend it names. Same files the share serves.
                @{ prefix = 'TaskSequences'; dir = (Join-Path $lib.root 'TaskSequences') },
                # Scripts/ so a Linux install fetches its first-boot script from here and a
                # Windows first boot streams a .ps1 with irm | iex. Everything in it is a
                # text script: say so, or Go sniffs a type per file and irm may try to
                # parse the body as something else.
                @{ prefix = 'Scripts'; dir = (Join-Path $lib.root 'Scripts'); contentType = 'text/plain; charset=utf-8' }
            )) {
            $dirNorm = ([string]$route.dir -replace '\\', '/')
            $routeLines += @(
                "    handle_path /$($route.prefix)/* {"
                "        root * `"$dirNorm`""
            )
            if ($route.Contains('contentType')) { $routeLines += "        header Content-Type `"$($route.contentType)`"" }
            $routeLines += @(
                '        file_server'
                '    }'
            )
        }
    } catch {
        Write-SidecarLog "PXE boot: image library routes unavailable - $($_.Exception.Message)"
        $routeLines = @()
    }

    # Phase 4a: serve install.wim straight out of each mounted ISO (no extraction).
    #   GET /iso-wim/<base>/install.wim -> <mount>/sources/install.wim
    # These routes must precede the generic /iso-wim file_server (default handle root)
    # so a live mount wins over any stale extracted copy under http/iso-wim/.
    foreach ($mount in @($script:AppPxeBootState.IsoMounts.Values)) {
        if (-not $mount.sourcesDir -or -not (Test-Path -LiteralPath $mount.sourcesDir)) { continue }
        $srcNorm = ([string]$mount.sourcesDir -replace '\\', '/')
        $baseEsc = [string]$mount.base
        $routeLines += @(
            "    handle_path /iso-wim/$baseEsc/* {"
            "        root * `"$srcNorm`""
            '        file_server'
            '    }'
        )
    }

    # Every mount also serves its whole tree at /iso-mount/<token>/. A Linux ISO's kernel
    # and initrd boot straight from here (Get-AppPxeBootLinuxIpxeBlock), and a Debian
    # tree doubles as an apt mirror for the installer later. Read-only, same files the
    # Deploy$ share already exposes under .mounts/.
    foreach ($mount in @($script:AppPxeBootState.IsoMounts.Values)) {
        $mountRoot = [string]$mount.mountRoot
        if (-not $mountRoot -or -not (Test-Path -LiteralPath $mountRoot -PathType Container)) { continue }
        $mountNorm = ($mountRoot -replace '\\', '/')
        $baseEsc = [string]$mount.base
        $routeLines += @(
            "    handle_path /iso-mount/$baseEsc/* {"
            "        root * `"$mountNorm`""
            '        file_server'
            '    }'
        )
    }

    # Imaging-log ingest: must precede the catch-all file_server handle.
    if ($ImagingLogIngestPort -gt 0) {
        $routeLines += @(
            '    handle /imaging-log/* {'
            "        reverse_proxy 127.0.0.1:$ImagingLogIngestPort"
            '    }'
        )
    }

    $lines = @(
        "# Netboot - generated $(Get-Date -Format 'o')"
        '{'
        '    auto_https off'
        '}'
        ''
        "$listenSite {"
    ) + $routeLines + @(
        '    handle {'
        "        root * `"$rootNorm`""
        '        file_server'
        '    }'
        # Access log: one line per fetch, so "what did that client actually download"
        # is answerable from the server side - reading a WinPE console by eye was the
        # only record of a failed boot chain until 2026-08-24. The boot-chain VM test
        # asserts against this file too. Caddy rolls it at 10MB, keeps 2.
        '    log {'
        "        output file `"$accessLogNorm`" {"
        '            roll_size 10MiB'
        '            roll_keep 2'
        '        }'
        '        format console'
        '    }'
        '}'
        ''
    )
    ($lines -join "`n") | Set-Content -LiteralPath $Path -Encoding UTF8 -Force
}

function Clear-AppPxeBootLegacyHttpRunner {
    $paths = Get-AppPxeBootLayoutPaths
    $legacyScript = Join-Path $paths.storeRoot 'run-http.ps1'
    if (Test-Path -LiteralPath $legacyScript) {
        Remove-Item -LiteralPath $legacyScript -Force -ErrorAction SilentlyContinue
    }
    if (Get-Command pgrep -ErrorAction SilentlyContinue) {
        foreach ($candidate in @(& pgrep -f 'run-http\.ps1' 2>$null)) {
            $procId = 0
            if ([int]::TryParse([string]$candidate, [ref]$procId) -and $procId -gt 0) {
                Stop-AppPxeBootHttpProcessById -ProcessId $procId
            }
        }
    }
}

# Keep in sync with packaging/pxe-tftpd64.json (Windows TFTP - runtime install like Caddy).
$script:AppPxeBootTftpd64Version = '4.74'

function Get-AppPxeBootTftpd64ManifestDefaultUrl {
    if ($env:APP_PXE_TFTPD64_MANIFEST_URL) {
        return [string]$env:APP_PXE_TFTPD64_MANIFEST_URL
    }
    return (Get-AppProductAssetFeedUrl -Name 'pxe-tftpd64.json')
}

function Get-AppPxeBootTftpd64BundledManifestPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    $path = Join-Path $root 'packaging/pxe-tftpd64.json'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppPxeBootTftpd64PlatformKey {
    if (-not ($IsWindows -or ($env:OS -eq 'Windows_NT'))) {
        throw 'PXE boot: Tftpd64 install is Windows-only.'
    }
    $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
    if ($isArm) { return 'windows_arm64' }
    return 'windows_amd64'
}

function Get-AppPxeBootTftpd64BinaryFileName {
    'tftpd64.exe'
}

function Get-AppPxeBootTftpd64MarkerPath {
    Join-Path (Get-AppPxeBootLayoutPaths).tftpd64BinaryDir '.tftpd64-version'
}

function Test-AppPxeBootTftpd64Installed {
    param([switch]$RequirePinnedVersion)
    $paths = Get-AppPxeBootLayoutPaths
    $bin = Join-Path $paths.tftpd64BinaryDir (Get-AppPxeBootTftpd64BinaryFileName)
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { return $false }
    if ($RequirePinnedVersion) {
        $marker = Get-AppPxeBootTftpd64MarkerPath
        if (-not (Test-Path -LiteralPath $marker)) { return $false }
        $installed = [string](Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
        $expected = if (Test-AppSidecarCommand Get-AppToolExpectedVersion) { Get-AppToolExpectedVersion -Id 'tftpd64' -Default $script:AppPxeBootTftpd64Version } else { $script:AppPxeBootTftpd64Version }
        if ($installed -ne $expected) { return $false }
    }
    return $true
}

function Get-AppPxeBootTftpd64Path {
    if ($env:APP_PXE_TFTPD64 -and (Test-Path -LiteralPath $env:APP_PXE_TFTPD64 -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:APP_PXE_TFTPD64).Path
    }
    $paths = Get-AppPxeBootLayoutPaths
    $bin = Join-Path $paths.tftpd64BinaryDir (Get-AppPxeBootTftpd64BinaryFileName)
    if (Test-Path -LiteralPath $bin -PathType Leaf) {
        return (Resolve-Path -LiteralPath $bin).Path
    }
    return $null
}

function Get-AppPxeBootBundledTftpd64Path {
    foreach ($name in @('tftpd64.exe', 'Tftpd64.exe')) {
        if ($SidecarRoot) {
            $path = Join-Path $SidecarRoot "binaries/tftpd64/$name"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                return (Resolve-Path -LiteralPath $path).Path
            }
        }
    }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @(
            'vendor/binaries/pxe-windows/tftpd64/tftpd64.exe'
            'sidecar/binaries/tftpd64/tftpd64.exe'
        )) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Get-AppPxeBootTftpd64Manifest {
    $manifestUrl = Get-AppPxeBootTftpd64ManifestDefaultUrl
    try {
        $remote = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $parsed = Read-AppPxeBootCaddyManifestObject -Obj $remote
        if ($parsed) {
            $parsed.source = 'remote'
            $parsed.manifestUrl = $manifestUrl
            return $parsed
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: Tftpd64 manifest fetch failed ($manifestUrl): $($_.Exception.Message)"
    }
    $bundledPath = Get-AppPxeBootTftpd64BundledManifestPath
    if ($bundledPath) {
        try {
            $local = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsed = Read-AppPxeBootCaddyManifestObject -Obj $local
            if ($parsed) {
                $parsed.source = 'bundled'
                $parsed.manifestUrl = $manifestUrl
                return $parsed
            }
        } catch {
            Write-SidecarLogVerbose "PXE boot: bundled Tftpd64 manifest read failed: $($_.Exception.Message)"
        }
    }
    throw 'PXE boot: Tftpd64 manifest unavailable (no asset feed configured and no bundled copy).'
}

function Get-AppPxeBootTftpd64PlatformEntry {
    $manifest = Get-AppPxeBootTftpd64Manifest
    $key = Get-AppPxeBootTftpd64PlatformKey
    if (-not $manifest.platforms.ContainsKey($key)) {
        if ($key -eq 'windows_arm64' -and $manifest.platforms.ContainsKey('windows_amd64')) {
            $key = 'windows_amd64'
        } else {
            throw "PXE boot: Tftpd64 manifest has no entry for platform $key."
        }
    }
    @{
        platformKey = $key
        manifest    = $manifest
        entry       = $manifest.platforms[$key]
    }
}

function Copy-AppPxeBootBundledTftpd64Install {
    $bundled = Get-AppPxeBootBundledTftpd64Path
    if (-not $bundled) { return $false }

    $paths = Get-AppPxeBootLayoutPaths
    $destDir = $paths.tftpd64BinaryDir
    $destBin = Join-Path $destDir (Get-AppPxeBootTftpd64BinaryFileName)
    if (-not (Test-Path -LiteralPath $destDir)) {
        $null = New-Item -Path $destDir -ItemType Directory -Force
    }
    Copy-Item -LiteralPath $bundled -Destination $destBin -Force
    Set-Content -LiteralPath (Get-AppPxeBootTftpd64MarkerPath) -Value $script:AppPxeBootTftpd64Version -Encoding ASCII -Force
    Write-SidecarLog "PXE boot: Tftpd64 $($script:AppPxeBootTftpd64Version) copied from app bundle to $destBin"
    return $true
}

function Ensure-AppPxeBootTftpd64 {
    if (-not ($IsWindows -or ($env:OS -eq 'Windows_NT'))) {
        return @{ ok = $true; skipped = $true; reason = 'not-windows' }
    }

    Ensure-AppPxeBootStoreLayout | Out-Null
    if (Test-AppPxeBootTftpd64Installed -RequirePinnedVersion) {
        return @{
            ok      = $true
            skipped = $true
            path    = (Get-AppPxeBootTftpd64Path)
            version = $script:AppPxeBootTftpd64Version
        }
    }

    if (Copy-AppPxeBootBundledTftpd64Install) {
        return @{
            ok      = $true
            skipped = $false
            path    = (Get-AppPxeBootTftpd64Path)
            version = $script:AppPxeBootTftpd64Version
        }
    }

    $resolved = Get-AppPxeBootTftpd64PlatformEntry
    $entry = $resolved.entry
    $platformKey = $resolved.platformKey
    $manifest = $resolved.manifest
    $paths = Get-AppPxeBootLayoutPaths
    $destDir = $paths.tftpd64BinaryDir
    $destBin = Join-Path $destDir (Get-AppPxeBootTftpd64BinaryFileName)
    $sizeMb = if ($entry.sizeBytes -gt 0) { [math]::Round($entry.sizeBytes / 1MB, 1) } else { 0.6 }

    Write-SidecarLog "PXE boot: installing Tftpd64 $($manifest.version) ($platformKey, ~${sizeMb} MB) to $destDir"
    Write-SidecarEvent -EventName 'pxe-tftpd64' -Data @{
        phase   = 'installing'
        version = [string]$manifest.version
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sm-pxe-tftpd64-" + [guid]::NewGuid().ToString())
    $archivePath = Join-Path $tmpRoot $entry.archiveName
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    try {
        $downloadUrls = [System.Collections.Generic.List[string]]::new()
        if ($entry.githubUrl) { [void]$downloadUrls.Add([string]$entry.githubUrl) }
        if ($entry.downloadUrl -and $entry.downloadUrl -ne $entry.githubUrl) {
            [void]$downloadUrls.Add([string]$entry.downloadUrl)
        }
        if ($downloadUrls.Count -eq 0) {
            throw 'PXE boot: Tftpd64 manifest entry has no download URL.'
        }

        $downloaded = $false
        $lastError = $null
        foreach ($url in @($downloadUrls)) {
            try {
                if (Test-Path -LiteralPath $archivePath) {
                    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                }
                Invoke-AppPxeBootCaddyArtifactDownload -Uri $url -OutFile $archivePath
                if (Test-AppPxeBootCaddyArchiveFile -Path $archivePath -ExpectedSha256 $entry.sha256 -ExpectedSizeBytes $entry.sizeBytes) {
                    $downloaded = $true
                    break
                }
                $lastError = 'SHA256 or size mismatch after download'
            } catch {
                $lastError = $_.Exception.Message
                Write-SidecarLogVerbose "PXE boot: Tftpd64 download failed from $url - $lastError"
            }
        }
        if (-not $downloaded) {
            throw "PXE boot: Tftpd64 download failed - $lastError"
        }

        $extractDir = Join-Path $tmpRoot 'extract'
        $extractedBin = Expand-AppPxeBootCaddyArchive `
            -Archive $archivePath `
            -ArchiveKind $entry.archiveKind `
            -ExtractDir $extractDir `
            -BinaryName $entry.binaryName
        if (-not (Test-Path -LiteralPath $destDir)) {
            $null = New-Item -Path $destDir -ItemType Directory -Force
        }
        Copy-Item -LiteralPath $extractedBin -Destination $destBin -Force
        Set-Content -LiteralPath (Get-AppPxeBootTftpd64MarkerPath) -Value $script:AppPxeBootTftpd64Version -Encoding ASCII -Force

        Write-SidecarLog "PXE boot: Tftpd64 $($script:AppPxeBootTftpd64Version) installed at $destBin"
        Write-SidecarEvent -EventName 'pxe-tftpd64' -Data @{
            phase   = 'complete'
            version = $script:AppPxeBootTftpd64Version
            path    = $destBin
        }
        return @{
            ok      = $true
            skipped = $false
            path    = $destBin
            version = $script:AppPxeBootTftpd64Version
        }
    } catch {
        Write-SidecarEvent -EventName 'pxe-tftpd64' -Data @{
            phase   = 'failed'
            message = $_.Exception.Message
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-AppPxeBootWindowsFirewallRules {
    param(
        [int]$HttpPort = 8080,
        [string]$Tftpd64Exe
    )

    if (-not ($IsWindows -or ($env:OS -eq 'Windows_NT'))) {
        return @{ ok = $true; skipped = $true; reason = 'not-windows' }
    }

    $added = [System.Collections.Generic.List[string]]::new()

    $portRules = @(
        @{ DisplayName = "$(Get-AppProductDisplayName) Netboot TFTP (UDP 69)"; Protocol = 'UDP'; LocalPort = 69 }
        @{ DisplayName = "$(Get-AppProductDisplayName) Netboot HTTP (TCP $HttpPort)"; Protocol = 'TCP'; LocalPort = $HttpPort }
    )

    if (Get-Module -ListAvailable -Name NetSecurity) {
        Import-Module NetSecurity -ErrorAction SilentlyContinue | Out-Null
        foreach ($spec in $portRules) {
            $existing = Get-NetFirewallRule -DisplayName $spec.DisplayName -ErrorAction SilentlyContinue
            if ($existing) { continue }
            try {
                New-NetFirewallRule -DisplayName $spec.DisplayName -Direction Inbound -Action Allow `
                    -Protocol $spec.Protocol -LocalPort $spec.LocalPort -Profile Any -ErrorAction Stop | Out-Null
                [void]$added.Add($spec.DisplayName)
            } catch {
                Write-SidecarLogVerbose "PXE boot: New-NetFirewallRule failed ($($spec.DisplayName)) - $($_.Exception.Message)"
            }
        }
        if ($Tftpd64Exe -and (Test-Path -LiteralPath $Tftpd64Exe)) {
            $progName = "$(Get-AppProductDisplayName) Netboot Tftpd64"
            $existing = Get-NetFirewallRule -DisplayName $progName -ErrorAction SilentlyContinue
            if (-not $existing) {
                try {
                    New-NetFirewallRule -DisplayName $progName -Direction Inbound -Program $Tftpd64Exe `
                        -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                    [void]$added.Add($progName)
                } catch {
                    Write-SidecarLogVerbose "PXE boot: Tftpd64 program firewall rule failed - $($_.Exception.Message)"
                }
            }
        }
    }

    foreach ($spec in $portRules) {
        $ruleName = $spec.DisplayName
        $check = & netsh advfirewall firewall show rule name="$ruleName" 2>$null | Out-String
        if ($check -match 'No rules match') {
            $proto = $spec.Protocol.ToLowerInvariant()
            $port = $spec.LocalPort
            $null = & netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow `
                protocol=$proto localport=$port profile=any 2>$null
            if ($LASTEXITCODE -eq 0 -and -not ($added -contains $ruleName)) {
                [void]$added.Add("$ruleName (netsh)")
            }
        }
    }

    if ($added.Count -gt 0) {
        Write-SidecarLog "PXE boot: Windows Firewall - $($added -join ', ')"
    }

    @{ ok = $true; added = @($added) }
}

function Resolve-AppPxeBootTftpd64Path {
    param([string]$ConfiguredPath)
    if ($ConfiguredPath -and (Test-Path -LiteralPath $ConfiguredPath)) {
        return (Resolve-Path -LiteralPath $ConfiguredPath).Path
    }
    $store = Get-AppPxeBootTftpd64Path
    if ($store) { return $store }
    foreach ($candidate in @(
        "${env:ProgramFiles}\Tftpd64\Tftpd64.exe"
        "${env:ProgramFiles(x86)}\Tftpd64\Tftpd64.exe"
        "${env:ProgramFiles}\Tftpd64\tftpd64.exe"
        "${env:ProgramFiles(x86)}\Tftpd64\tftpd64.exe"
        "${env:ProgramFiles}\Tftpd32\Tftpd32.exe"
        "${env:ProgramFiles(x86)}\Tftpd32\Tftpd32.exe"
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Get-AppPxeBootDnsmasqPidPath {
    Join-Path (Get-AppPxeBootStoreRoot) 'dnsmasq.pid'
}

function Get-AppPxeBootPort69ProcessId {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        try {
            $conn = Get-NetUDPEndpoint -LocalPort 69 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($conn -and $conn.OwningProcess -gt 0) {
                return [int]$conn.OwningProcess
            }
        } catch { }
        return 0
    }
    if (-not ($IsMacOS -or $IsDarwin)) { return 0 }
    if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) { return 0 }
    try {
        foreach ($line in @(& lsof -n -P -iUDP:69 2>$null)) {
            if ($line -match '^\S+\s+(\d+)\s') {
                $procId = 0
                if ([int]::TryParse($matches[1], [ref]$procId) -and $procId -gt 0) {
                    return $procId
                }
            }
        }
    } catch { }
    return 0
}

function Test-AppPxeBootDnsmasqIsOurs {
    param(
        [int]$ProcessId,
        [string]$ConfPath
    )
    if ($ProcessId -le 0 -or -not $ConfPath) { return $false }
    if (Get-Command pgrep -ErrorAction SilentlyContinue) {
        $matches = @(& pgrep -f ([regex]::Escape($ConfPath)) 2>$null)
        if ($matches -contains [string]$ProcessId) { return $true }
    }
    try {
        $cmd = (& ps -p $ProcessId -o command= 2>$null | Out-String).Trim()
        if ($cmd -and $cmd.Contains($ConfPath)) { return $true }
    } catch { }
    return $false
}

function Test-AppPxeBootDnsmasqProcessIsAutoKillable {
    param(
        [int]$ProcessId,
        [string]$ConfPath,
        [string]$StoreRoot
    )
    if ($ProcessId -le 0) { return $false }
    if (Test-AppPxeBootDnsmasqIsOurs -ProcessId $ProcessId -ConfPath $ConfPath) { return $true }
    try {
        $cmd = (& ps -p $ProcessId -o command= 2>$null | Out-String).Trim()
        if (-not $cmd) { return $false }
        if ($ConfPath -and $cmd.Contains($ConfPath)) { return $true }
        if ($StoreRoot -and $cmd.Contains($StoreRoot) -and $cmd -match '(?i)dnsmasq') { return $true }
    } catch { }
    return $false
}

function Get-AppPxeBootDnsmasqProcessIds {
    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
    $storeRoot = Get-AppPxeBootStoreRoot
    $pidPath = Get-AppPxeBootDnsmasqPidPath
    $pids = [System.Collections.Generic.HashSet[int]]::new()

    if ($script:AppPxeBootState.TftpElevatedPid) {
        [void]$pids.Add([int]$script:AppPxeBootState.TftpElevatedPid)
    }
    $proc = $script:AppPxeBootState.TftpProcess
    if ($proc -and -not $proc.HasExited) {
        [void]$pids.Add($proc.Id)
    }

    $resolved = Resolve-AppPxeBootDnsmasqProcessId -PidPath $pidPath -ConfPath $confPath
    if ($resolved -gt 0) { [void]$pids.Add($resolved) }

    if (Get-Command pgrep -ErrorAction SilentlyContinue) {
        foreach ($candidate in @(& pgrep -f ([regex]::Escape($confPath)) 2>$null)) {
            $procId = 0
            if ([int]::TryParse([string]$candidate, [ref]$procId) -and $procId -gt 0) {
                [void]$pids.Add($procId)
            }
        }
    }

    if ($IsMacOS -or $IsDarwin) {
        $holder = Get-AppPxeBootPort69ProcessId
        if ($holder -gt 0 -and (Test-AppPxeBootDnsmasqProcessIsAutoKillable -ProcessId $holder -ConfPath $confPath -StoreRoot $storeRoot)) {
            [void]$pids.Add($holder)
        }
    }

    return @($pids)
}

function Get-AppPxeBootElevatedPort69ClearShellMac {
    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
    $storeRoot = Get-AppPxeBootStoreRoot
    $pidPath = Get-AppPxeBootDnsmasqPidPath
    if (-not (Test-AppSidecarCommand ConvertTo-AppUnixShellSingleQuotedString)) {
        return @()
    }

    $procIds = @(Get-AppPxeBootDnsmasqProcessIds | Sort-Object -Unique)
    $holder = Get-AppPxeBootPort69ProcessId
    if ($holder -gt 0 -and $procIds -notcontains $holder) {
        if (Test-AppPxeBootDnsmasqProcessIsAutoKillable -ProcessId $holder -ConfPath $confPath -StoreRoot $storeRoot) {
            $procIds = @($procIds + $holder | Sort-Object -Unique)
        }
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($procId in $procIds) {
        if ($procId -le 0) { continue }
        [void]$parts.Add("kill -9 $procId 2>/dev/null || true")
    }
    if ($parts.Count -gt 0 -or (Test-Path -LiteralPath $pidPath)) {
        $confShell = ConvertTo-AppUnixShellSingleQuotedString -Value $confPath
        [void]$parts.Add("pkill -9 -f $confShell 2>/dev/null || true")
        [void]$parts.Add("rm -f $(ConvertTo-AppUnixShellSingleQuotedString -Value $pidPath)")
    }
    return @($parts)
}

function Get-AppPxeBootElevatedDnsmasqStartShellMac {
    param(
        [Parameter(Mandatory)][string]$Dnsmasq,
        [Parameter(Mandatory)][string]$ConfPath
    )
    if (-not (Test-AppSidecarCommand ConvertTo-AppUnixShellSingleQuotedString)) {
        throw 'PXE boot: shell quoting helper not available.'
    }
    $pidPath = Get-AppPxeBootDnsmasqPidPath
    $logFile = Join-Path (Get-AppPxeBootStoreRoot) 'dnsmasq.log'
    $dnsmasqQ = ConvertTo-AppUnixShellSingleQuotedString -Value $Dnsmasq
    $confQ = ConvertTo-AppUnixShellSingleQuotedString -Value $ConfPath
    $pidQ = ConvertTo-AppUnixShellSingleQuotedString -Value $pidPath
    $logQ = ConvertTo-AppUnixShellSingleQuotedString -Value $logFile
    return @(
        "$dnsmasqQ -C $confQ --test"
        "rm -f $pidQ"
        "$dnsmasqQ -C $confQ --pid-file=$pidQ"
        'sleep 0.5'
        "if test -s $pidQ; then cat $pidQ; elif test -s $logQ; then tail -5 $logQ; exit 1; else exit 1; fi"
    )
}

function Get-AppPxeBootElevatedTftpStartShellMac {
    param(
        [Parameter(Mandatory)][string]$Dnsmasq,
        [Parameter(Mandatory)][string]$ConfPath,
        [switch]$IncludePortClear
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($IncludePortClear) {
        foreach ($line in @(Get-AppPxeBootElevatedPort69ClearShellMac)) {
            [void]$parts.Add($line)
        }
    }
    $traverse = Get-AppPxeBootMacOsTftpRootTraverseShellMac
    if ($traverse) {
        [void]$parts.Add($traverse)
    }
    foreach ($line in @(Get-AppPxeBootElevatedDnsmasqStartShellMac -Dnsmasq $Dnsmasq -ConfPath $ConfPath)) {
        [void]$parts.Add($line)
    }
    return ($parts -join ' && ')
}

function Clear-AppPxeBootPort69Mac {
    param([switch]$AllowForeignHolder)

    if (-not ($IsMacOS -or $IsDarwin)) { return $true }

    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
    $storeRoot = Get-AppPxeBootStoreRoot
    $pidPath = Get-AppPxeBootDnsmasqPidPath
    $procIds = @(Get-AppPxeBootDnsmasqProcessIds | Sort-Object -Unique)
    $holder = Get-AppPxeBootPort69ProcessId

    if ($holder -gt 0 -and $procIds -notcontains $holder) {
        if ($AllowForeignHolder -or (Test-AppPxeBootDnsmasqProcessIsAutoKillable -ProcessId $holder -ConfPath $confPath -StoreRoot $storeRoot)) {
            $procIds = @($procIds + $holder | Sort-Object -Unique)
        }
    }

    if ($procIds.Count -gt 0) {
        Write-SidecarLog "PXE boot: killing dnsmasq on port 69 (pids: $($procIds -join ', '))"
        $killShell = (Get-AppPxeBootElevatedPort69ClearShellMac) -join '; '
        if ($killShell -and (Test-AppSidecarCommand Invoke-AppMacOsAdminShellCommand)) {
            try {
                Invoke-AppMacOsAdminShellCommand -ShellCommand $killShell -AllowFailure | Out-Null
            } catch {
                Write-SidecarLog "PXE boot: elevated dnsmasq kill failed: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Milliseconds 400
        Clear-AppPxeBootTftpTracking
    } elseif (Test-Path -LiteralPath $pidPath) {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        Clear-AppPxeBootTftpTracking
    }

    return ((Get-AppPxeBootPort69ProcessId) -le 0)
}

function Stop-AppPxeBootDnsmasq {
    param([switch]$SkipAdminKill)

    if ($IsMacOS -or $IsDarwin) {
        if ($SkipAdminKill) {
            foreach ($procId in @(Get-AppPxeBootDnsmasqProcessIds)) {
                try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { }
            }
            Start-Sleep -Milliseconds 250
            $stillAlive = @((Get-AppPxeBootDnsmasqProcessIds) | Where-Object {
                    $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
                    $p -and -not $p.HasExited
                })
            if ($stillAlive.Count -eq 0) {
                $pidPath = Get-AppPxeBootDnsmasqPidPath
                if (Test-Path -LiteralPath $pidPath) {
                    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
                }
                Clear-AppPxeBootTftpTracking
            }
            return ($stillAlive.Count -eq 0)
        }

        $before = Get-AppPxeBootPort69ProcessId
        $cleared = Clear-AppPxeBootPort69Mac
        if ($before -gt 0 -and $cleared) {
            Write-SidecarLog "PXE boot: stopped Netboot dnsmasq (port 69 cleared, pid $before)"
            return $true
        }
        if ($before -gt 0) {
            Write-SidecarLog "PXE boot: Netboot dnsmasq still holding port 69 (pid $before)"
            return $false
        }
        return $false
    }

    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
    $pidPath = Get-AppPxeBootDnsmasqPidPath
    $procIds = @(Get-AppPxeBootDnsmasqProcessIds)
    if ($procIds.Count -eq 0) { return $false }

    foreach ($procId in $procIds) {
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
        } catch {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc -and -not $proc.HasExited) {
                try {
                    $proc.Kill($true)
                    [void](Wait-Process -Id $procId -Timeout 3 -ErrorAction SilentlyContinue)
                } catch { }
            }
        }
    }

    Start-Sleep -Milliseconds 250
    $stillAlive = @($procIds | Where-Object {
            $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
            $p -and -not $p.HasExited
        })
    if ($stillAlive.Count -eq 0) {
        if (Test-Path -LiteralPath $pidPath) {
            Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        }
        Clear-AppPxeBootTftpTracking
        if ($procIds.Count -gt 0) {
            Write-SidecarLog "PXE boot: stopped Netboot dnsmasq (pids: $($procIds -join ', '))"
        }
        return $procIds.Count -gt 0
    }

    Write-SidecarLog "PXE boot: Netboot dnsmasq still running (pids: $($stillAlive -join ', '))"
    return $false
}

function Get-AppPxeBootPort69KillShellCommand {
    if (-not ($IsMacOS -or $IsDarwin)) { return $null }
    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
    $pidPath = Get-AppPxeBootDnsmasqPidPath
    $lines = [System.Collections.Generic.List[string]]::new()

    $procIds = @(Get-AppPxeBootDnsmasqProcessIds | Sort-Object -Unique)
    if ($procIds.Count -eq 0) {
        $holder = Get-AppPxeBootPort69ProcessId
        if ($holder -gt 0) { $procIds = @($holder) }
    }

    foreach ($procId in $procIds) {
        [void]$lines.Add("sudo kill -9 $procId")
    }

    # Bundled dnsmasq ignores SIGTERM; pkill without -9 leaves port 69 blocked.
    [void]$lines.Add("sudo pkill -9 -f '$confPath'")
    [void]$lines.Add("sudo rm -f '$pidPath'")

    return ($lines -join "`n")
}

function Test-AppPxeBootPort69Blocked {
    if ($script:AppPxeBootState.TftpLastError -match 'already in use|Address already in use') {
        return $true
    }
    if (-not ($IsMacOS -or $IsDarwin)) { return $false }
    return ((Get-AppPxeBootPort69ProcessId) -gt 0)
}

function Get-AppPxeBootPort69ConflictMessage {
    if (-not ($IsMacOS -or $IsDarwin)) { return $null }
    try {
        $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
        $holder = Get-AppPxeBootPort69ProcessId
        if ($holder -le 0) {
            $lines = @(& netstat -an -p udp 2>$null)
            if (-not $lines) { $lines = @(& netstat -an 2>$null) }
            if (-not ($lines | Where-Object { $_ -match '\.69\s' })) { return $null }
            return @(
                'PXE boot: UDP port 69 is already in use on this workstation.'
                "Stop PXE services in $(Get-AppProductDisplayName), or stop the other dnsmasq / TFTP server, then retry."
            ) -join ' '
        }

        if (Test-AppPxeBootDnsmasqIsOurs -ProcessId $holder -ConfPath $confPath) {
            return @(
                "PXE boot: UDP port 69 is held by a previous Netboot dnsmasq (pid $holder)."
                'Netboot will try to clear this automatically when you start TFTP.'
            ) -join ' '
        }

        $procName = ''
        try { $procName = (Get-Process -Id $holder -ErrorAction SilentlyContinue).ProcessName } catch { }
        $nameHint = if ($procName) { " ($procName)" } else { '' }
        return @(
            "PXE boot: UDP port 69 is already in use (pid $holder$nameHint)."
            'Stop the other TFTP server (another dnsmasq, setup-laptop-macos.sh, etc.) and retry.'
        ) -join ' '
    } catch {
        return $null
    }
}

function Read-AppPxeBootDnsmasqLogTail {
    param([int]$MaxChars = 1200)
    $paths = @(
        (Join-Path (Get-AppPxeBootStoreRoot) 'dnsmasq.log')
        (Join-Path (Get-AppPxeBootStoreRoot) 'dnsmasq-stderr.log')
    )
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $text = (Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)
        if ($text) {
            $trim = $text.Trim()
            if ($trim.Length -gt $MaxChars) {
                return $trim.Substring($trim.Length - $MaxChars)
            }
            return $trim
        }
    }
    return ''
}

function Clear-AppPxeBootLogTail {
    <#
    .SYNOPSIS
        Truncate the PXE activity log (dnsmasq/TFTP) shown in the Netboot panel.
        Truncates in place rather than deleting so a running dnsmasq keeps its open
        handle and continues appending. On macOS dnsmasq runs as root and the log is
        usually root-owned, so a plain truncate fails with permission denied; then the
        same cached administrator credential that started TFTP truncates it via sudo.
    #>
    $storeRoot = Get-AppPxeBootStoreRoot
    $logPath = Join-Path $storeRoot 'dnsmasq.log'
    $result = [ordered]@{ cleared = $false; path = $logPath; error = $null }
    if (-not (Test-Path -LiteralPath $logPath)) { return $result }
    try {
        Set-Content -LiteralPath $logPath -Value '' -NoNewline -ErrorAction Stop
        $result.cleared = $true
    } catch {
        $direct = $_.Exception.Message
        if (($IsMacOS -or $IsDarwin) -and (Test-AppSidecarCommand Invoke-AppMacOsAdminShellCommand)) {
            try {
                $logQ = ConvertTo-AppUnixShellSingleQuotedString -Value $logPath
                $null = Invoke-AppMacOsAdminShellCommand -ShellCommand ": > $logQ" -PromptMessage 'Clearing the PXE activity log needs your macOS administrator password (the log is owned by root).'
                $result.cleared = $true
            } catch {
                $result.error = $_.Exception.Message
            }
        } else {
            $result.error = $direct
        }
    }
    if ($result.cleared) {
        Write-SidecarLog 'PXE boot: activity log cleared.'
    } else {
        Write-SidecarLog "PXE boot: could not clear activity log - $($result.error)"
    }
    return $result
}

function Get-AppPxeBootLogTail {
    # UI-facing PXE activity log: returns the most-recent dnsmasq/TFTP log lines so
    # the Netboot panel can show which client requested which boot file (e.g. the
    # snponly.efi loop). Read-only; never throws to the IPC layer.
    param([int]$MaxLines = 200)
    if ($MaxLines -le 0 -or $MaxLines -gt 1000) { $MaxLines = 200 }
    $storeRoot = Get-AppPxeBootStoreRoot
    $logPath = Join-Path $storeRoot 'dnsmasq.log'
    $result = [ordered]@{
        available = $false
        path      = $logPath
        lines     = @()
        truncated = $false
    }
    if (-not (Test-Path -LiteralPath $logPath)) { return $result }
    $result.available = $true
    $all = @()
    try {
        $all = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
    } catch {
        $all = @()
    }
    if ($all.Count -eq 0) { return $result }
    $tail = if ($all.Count -gt $MaxLines) {
        $result.truncated = $true
        $all[($all.Count - $MaxLines)..($all.Count - 1)]
    } else {
        $all
    }
    # Shorten the long absolute tftp-root prefix to just the boot-relative file name
    # so lines read as "sent snponly.efi to 10.150.198.81" rather than a full path.
    $tftpRoot = $null
    try { $tftpRoot = (Get-AppPxeBootLayoutPaths).tftpRoot } catch { $tftpRoot = $null }
    if ($tftpRoot) {
        $tftpRoot = ([string]$tftpRoot).TrimEnd('/', '\')
        $tail = foreach ($line in $tail) {
            ([string]$line).Replace("$tftpRoot/", '').Replace("$tftpRoot\", '').Replace($tftpRoot, '')
        }
    }
    $result.lines = @($tail)
    return $result
}

function Resolve-AppPxeBootDnsmasqProcessId {
    param(
        [string]$PidPath,
        [string]$ConfPath
    )
    if ($PidPath -and (Test-Path -LiteralPath $PidPath)) {
        $raw = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()
        $procId = 0
        if ([int]::TryParse($raw, [ref]$procId) -and $procId -gt 0) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc -and -not $proc.HasExited) { return $procId }
        }
    }
    if ($ConfPath -and (Get-Command pgrep -ErrorAction SilentlyContinue)) {
        $matches = @(& pgrep -f ([regex]::Escape($ConfPath)) 2>$null)
        foreach ($candidate in $matches) {
            $procId = 0
            if ([int]::TryParse([string]$candidate, [ref]$procId) -and $procId -gt 0) {
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.HasExited) { return $procId }
            }
        }
    }
    return 0
}

function Sync-AppPxeBootTftpProcessState {
    if (-not $script:AppPxeBootState.TftpElevatedPid) {
        # Adopt a daemon another process started. Since the service start moved to a
        # child pwsh (2026-08-24), the pid lives in THAT process's memory - this one
        # only sees the pid file. Without adoption the badge said "TFTP not running"
        # while dnsmasq was up and serving (Craig hit exactly that, same day).
        $adopted = Resolve-AppPxeBootDnsmasqProcessId `
            -PidPath (Get-AppPxeBootDnsmasqPidPath) `
            -ConfPath (Get-AppPxeBootLayoutPaths).dnsmasqConf
        if ($adopted -le 0) { return }
        $script:AppPxeBootState.TftpElevatedPid = $adopted
        $script:AppPxeBootState.TftpElevated = $true
        Write-SidecarLogVerbose "PXE boot: adopted running dnsmasq (pid $adopted) from the pid file"
    }
    $proc = Get-Process -Id $script:AppPxeBootState.TftpElevatedPid -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.HasExited) {
        $script:AppPxeBootState.TftpProcess = $proc
        return
    }
    $script:AppPxeBootState.TftpProcess = $null
    $script:AppPxeBootState.TftpElevated = $false
    $script:AppPxeBootState.TftpElevatedPid = $null
}

function Clear-AppPxeBootTftpTracking {
    $script:AppPxeBootState.TftpProcess = $null
    $script:AppPxeBootState.TftpElevated = $false
    $script:AppPxeBootState.TftpElevatedPid = $null
}

function Start-AppPxeBootTftpServerElevatedMac {
    param(
        [Parameter(Mandatory)][string]$Dnsmasq,
        [Parameter(Mandatory)][string]$ConfPath,
        [switch]$IncludePortClear
    )
    if (-not (Test-AppSidecarCommand Invoke-AppMacOsAdminShellCommand)) {
        throw 'PXE boot: administrator elevation helper not available.'
    }
    $pidPath = Get-AppPxeBootDnsmasqPidPath

    Write-SidecarLog 'PXE boot: starting TFTP (port 69) with administrator privileges'
    $traverseDirs = @(Get-AppPxeBootMacOsTftpTraverseDirs)
    if ($traverseDirs.Count -gt 0) {
        Write-SidecarLog "PXE boot: macOS TFTP traverse grant on $($traverseDirs.Count) Application Support parent dir(s) (canonical store unchanged)"
    }
    $shell = Get-AppPxeBootElevatedTftpStartShellMac -Dnsmasq $Dnsmasq -ConfPath $ConfPath -IncludePortClear:$IncludePortClear
    $out = Invoke-AppMacOsAdminShellCommand -ShellCommand $shell
    Start-Sleep -Milliseconds 400
    $procId = Resolve-AppPxeBootDnsmasqProcessId -PidPath $pidPath -ConfPath $ConfPath
    if ($procId -le 0) {
        $pidText = ($out -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        if ($pidText) { [void][int]::TryParse([string]$pidText, [ref]$procId) }
    }
    if ($procId -le 0) {
        $procId = Resolve-AppPxeBootDnsmasqProcessId -PidPath $pidPath -ConfPath $ConfPath
    }
    if ($procId -le 0) {
        $err = Read-AppPxeBootDnsmasqLogTail
        if ($err -match 'Address already in use') {
            throw @(
                'PXE boot: UDP port 69 is already in use.'
                'Stop any other TFTP server on this workstation and retry.'
                $err
            ) -join ' '
        }
        throw "PXE boot: elevated dnsmasq did not stay running. $err"
    }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) {
        $err = Read-AppPxeBootDnsmasqLogTail
        throw "PXE boot: elevated dnsmasq did not stay running. $err"
    }
    $script:AppPxeBootState.TftpProcess = $proc
    $script:AppPxeBootState.TftpElevated = $true
    $script:AppPxeBootState.TftpElevatedPid = $procId
    $script:AppPxeBootState.TftpLastError = $null
    $script:AppPxeBootState.TftpElevatedCommand = $null
    Write-SidecarLog "PXE boot: TFTP started via dnsmasq (elevated, pid $procId)"
    @{ ok = $true; backend = 'dnsmasq-elevated'; detail = $Dnsmasq; pid = $procId }
}

function Stop-AppPxeBootTftpServer {
    param([switch]$SkipAdminKill)

    Sync-AppPxeBootTftpProcessState
    $stopped = Stop-AppPxeBootDnsmasq -SkipAdminKill:$SkipAdminKill

    $proc = $script:AppPxeBootState.TftpProcess
    if ($proc -and -not $proc.HasExited) {
        try {
            $proc.Kill($true)
            [void](Wait-Process -Id $proc.Id -Timeout 3 -ErrorAction SilentlyContinue)
            $stopped = $true
        } catch { }
        Clear-AppPxeBootTftpTracking
    }

    return $stopped
}

function Get-AppPxeBootWindowsShortPath {
    param([Parameter(Mandatory)][string]$Path)

    $pathNorm = ([string]$Path).Trim().TrimEnd('\', '/')
    if (-not $pathNorm) { return $pathNorm }
    if ($pathNorm -notmatch '\s') { return $pathNorm }
    if (-not (Test-Path -LiteralPath $pathNorm)) { return $pathNorm }
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = [string]$fso.GetFolder($pathNorm).ShortPath
        if ($short) { return $short.TrimEnd('\', '/') }
    } catch { }
    return $pathNorm
}

function Write-AppPxeBootTftpd64Ini {
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$TftpRoot
    )

    $baseDir = Get-AppPxeBootWindowsShortPath -Path $TftpRoot
    $lines = @(
        '[TFTPD32]'
        "BaseDirectory=$baseDir"
        'UseTftp=1'
        'Services=1'
        'TftpPort=69'
        'VirtualRoot=1'
        'PXECompatibility=1'
        'Hide=1'
        'ShowProgressBar=0'
        'WinSize=0,0,0,0'
    )
    $content = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($IniPath, $content, [System.Text.Encoding]::ASCII)
}

function Test-AppPxeBootTftpd64ProcessIsOurs {
    param(
        [int]$ProcessId,
        [string]$Tftpd64Exe
    )
    if ($ProcessId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { return $false }
        $path = $null
        try { $path = $proc.Path } catch { $path = $null }
        if ($path -and $Tftpd64Exe) {
            try {
                $procPath = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
                $exePath = (Resolve-Path -LiteralPath $Tftpd64Exe -ErrorAction Stop).Path
                if ($procPath -ieq $exePath) { return $true }
            } catch { }
        }
        if ($proc.ProcessName -match '^(tftpd64|Tftpd64)$') {
            $ownPattern = 'pxe-boot|' + [regex]::Escape((Get-AppProductDisplayName)) + '|' + [regex]::Escape((Get-AppProductBinaryName))
            if ($path -and ($path -match $ownPattern)) { return $true }
        }
    } catch { }
    return $false
}

function Clear-AppPxeBootPort69Windows {
    param([string]$Tftpd64Exe)

    if (-not ($IsWindows -or ($env:OS -eq 'Windows_NT'))) { return $true }
    $holder = Get-AppPxeBootPort69ProcessId
    if ($holder -le 0) { return $true }
    if (-not (Test-AppPxeBootTftpd64ProcessIsOurs -ProcessId $holder -Tftpd64Exe $Tftpd64Exe)) {
        return $false
    }
    try {
        Stop-Process -Id $holder -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 300
    } catch { return $false }
    return ((Get-AppPxeBootPort69ProcessId) -le 0)
}

function Get-AppPxeBootTftpd64StartFailureDetail {
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$TftpRoot
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $TftpRoot)) {
        [void]$parts.Add("TFTP root missing: $TftpRoot")
    }
    if (Test-Path -LiteralPath $IniPath) {
        $iniText = (Get-Content -LiteralPath $IniPath -Raw -ErrorAction SilentlyContinue)
        if ($iniText -match '(?m)^BaseDirectory=\s*$') {
            [void]$parts.Add('Tftpd32.ini BaseDirectory is empty - check path with spaces')
        }
    } else {
        [void]$parts.Add("Tftpd32.ini missing: $IniPath")
    }
    $holder = Get-AppPxeBootPort69ProcessId
    if ($holder -gt 0) {
        [void]$parts.Add("UDP port 69 still held by pid $holder")
    }
    if ($parts.Count -eq 0) { return $null }
    return ($parts -join '; ')
}

function Start-AppPxeBootTftpServer {
    param(
        [Parameter(Mandatory)][string]$TftpRoot,
        [string]$InterfaceId,
        [string]$Tftpd64Path,
        [ValidateSet('router', 'standalone', 'proxy')]
        [string]$Mode = 'router'
    )

    if ($script:AppPxeBootState.TftpProcess -and -not $script:AppPxeBootState.TftpProcess.HasExited) {
        return @{ ok = $true; backend = 'existing'; detail = 'TFTP already running' }
    }
    Sync-AppPxeBootTftpProcessState
    if ($script:AppPxeBootState.TftpProcess -and -not $script:AppPxeBootState.TftpProcess.HasExited) {
        return @{ ok = $true; backend = 'existing'; detail = 'TFTP already running' }
    }
    Ensure-AppPxeBootAutoexecIfMissing | Out-Null
    Write-AppPxeBootTftpAutoexecScript | Out-Null

    $preferDnsmasq = ($Mode -in @('proxy', 'standalone'))
    if (($IsWindows -or ($env:OS -eq 'Windows_NT')) -and -not $preferDnsmasq) {
        Ensure-AppPxeBootTftpd64 | Out-Null
        $exe = Resolve-AppPxeBootTftpd64Path -ConfiguredPath $Tftpd64Path
        if ($exe) {
            $cfgPort = [int](Read-AppPxeBootConfig).httpPort
            Ensure-AppPxeBootWindowsFirewallRules -HttpPort $cfgPort -Tftpd64Exe $exe | Out-Null
            Sync-AppPxeBootBundledBootAssets | Out-Null
            if (-not (Test-Path -LiteralPath $TftpRoot)) {
                $null = New-Item -Path $TftpRoot -ItemType Directory -Force
            }
            $exeDir = Split-Path -Parent $exe
            $iniPath = Join-Path $exeDir 'Tftpd32.ini'
            Write-AppPxeBootTftpd64Ini -IniPath $iniPath -TftpRoot $TftpRoot
            $proc = $script:AppPxeBootState.TftpProcess
            if ($proc -and -not $proc.HasExited) {
                try { $proc.Kill($true) } catch { }
                Clear-AppPxeBootTftpTracking
            }
            if (-not (Clear-AppPxeBootPort69Windows -Tftpd64Exe $exe)) {
                $holder = Get-AppPxeBootPort69ProcessId
                throw "PXE boot: UDP port 69 is already in use (pid $holder). Stop the other TFTP server and retry."
            }
            # Tftpd64 is a Win32 GUI app - Start-Process -WindowStyle Hidden works; CreateNoWindow does not.
            $proc = Start-Process -FilePath $exe -ArgumentList @('-hide') -WorkingDirectory $exeDir -PassThru -WindowStyle Hidden
            Start-Sleep -Milliseconds 1200
            if ($proc -and -not $proc.HasExited) {
                $script:AppPxeBootState.TftpProcess = $proc
                $script:AppPxeBootState.TftpElevated = $false
                $script:AppPxeBootState.TftpElevatedPid = $null
                $script:AppPxeBootState.TftpLastError = $null
                $script:AppPxeBootState.TftpElevatedCommand = $null
                Write-SidecarLog "PXE boot: TFTP started via Tftpd64 ($exe)"
                return @{ ok = $true; backend = 'tftpd64'; detail = $exe }
            }
            $detail = Get-AppPxeBootTftpd64StartFailureDetail -IniPath $iniPath -TftpRoot $TftpRoot
            $hint = if ($detail) { $detail } else { "check Windows Firewall ($(Get-AppProductDisplayName) adds rules automatically when permitted)" }
            throw "PXE boot: Tftpd64 exited immediately - $hint"
        }
        throw 'PXE boot: Tftpd64 could not be installed - enable Netboot and retry, or set a custom path in Settings.'
    } elseif (($IsWindows -or ($env:OS -eq 'Windows_NT')) -and $preferDnsmasq) {
        Write-SidecarLog "PXE boot: TFTP mode $Mode uses dnsmasq (ProxyDHCP/standalone - not Tftpd64)"
    }

    $dnsmasq = Resolve-AppPxeBootDnsmasqPath
    if (-not $dnsmasq) {
        if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
            throw 'PXE boot: Tftpd64 could not be installed - enable Netboot and retry, or set a custom path in Settings.'
        }
        throw 'PXE boot: bundled dnsmasq not found - run ./scripts/build-dnsmasq-macos.sh and rebuild.'
    }

    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
    New-AppPxeBootDnsmasqConfig -TftpRoot $TftpRoot -OutPath $confPath -InterfaceId $InterfaceId -Mode $Mode | Out-Null

    if ($IsMacOS) {
        $holder = Get-AppPxeBootPort69ProcessId
        if ($holder -gt 0) {
            $confPathCheck = (Get-AppPxeBootLayoutPaths).dnsmasqConf
            $storeRootCheck = Get-AppPxeBootStoreRoot
            if (-not (Test-AppPxeBootDnsmasqProcessIsAutoKillable -ProcessId $holder -ConfPath $confPathCheck -StoreRoot $storeRootCheck)) {
                throw (Get-AppPxeBootPort69ConflictMessage)
            }
            Write-SidecarLog "PXE boot: port 69 blocked by pid $holder - will clear in single elevated TFTP start"
        }

        $includeClear = ($holder -gt 0) -or (@(Get-AppPxeBootDnsmasqProcessIds).Count -gt 0)
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                return Start-AppPxeBootTftpServerElevatedMac `
                    -Dnsmasq $dnsmasq `
                    -ConfPath $confPath `
                    -IncludePortClear:($includeClear -or $attempt -gt 1)
            } catch {
                $msg = $_.Exception.Message
                if ($attempt -lt 2 -and $msg -match 'already in use|Address already in use') {
                    Write-SidecarLog 'PXE boot: port 69 blocked during TFTP start - retrying with elevated clear'
                    $includeClear = $true
                    Start-Sleep -Milliseconds 400
                    continue
                }
                throw
            }
        }
    }

    $stderrFile = Join-Path (Get-AppPxeBootStoreRoot) 'dnsmasq-stderr.log'
    if (Test-Path -LiteralPath $stderrFile) { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue }

    $dnsmasqArgs = Format-AppProcessArgumentList -Arguments @('-C', $confPath, '--log-facility=-')
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $proc = Start-Process -FilePath $dnsmasq -ArgumentList $dnsmasqArgs `
            -PassThru -NoNewWindow -RedirectStandardError $stderrFile
    } else {
        $proc = Start-Process -FilePath $dnsmasq -ArgumentList $dnsmasqArgs `
            -PassThru -RedirectStandardError $stderrFile
    }
    Start-Sleep -Milliseconds 600
    if ($proc.HasExited) {
        $err = Read-AppPxeBootDnsmasqLogTail
        throw "PXE boot: dnsmasq failed to start. $err"
    }

    $pidPath = Get-AppPxeBootDnsmasqPidPath
    if ($proc.Id -gt 0) {
        try { [string]$proc.Id | Set-Content -LiteralPath $pidPath -Encoding ASCII -Force -NoNewline } catch { }
    }

    $script:AppPxeBootState.TftpProcess = $proc
    $script:AppPxeBootState.TftpElevated = $false
    $script:AppPxeBootState.TftpElevatedPid = $null
    $script:AppPxeBootState.TftpLastError = $null
    $script:AppPxeBootState.TftpElevatedCommand = $null
    Write-SidecarLog "PXE boot: TFTP started via dnsmasq ($dnsmasq)"
    @{ ok = $true; backend = 'dnsmasq'; detail = $dnsmasq }
}

function Get-AppPxeBootHttpPortProcessId {
    param([Parameter(Mandatory)][int]$Port)

    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        try {
            $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($conn -and $conn.OwningProcess -gt 0) {
                return [int]$conn.OwningProcess
            }
        } catch { }
        return 0
    }

    if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) { return 0 }
    try {
        foreach ($line in @(& lsof -n -P -iTCP:$Port -sTCP:LISTEN 2>$null)) {
            if ($line -match '^\S+\s+(\d+)\s') {
                $procId = 0
                if ([int]::TryParse($matches[1], [ref]$procId) -and $procId -gt 0) {
                    return $procId
                }
            }
        }
    } catch { }
    return 0
}

function Start-AppPxeBootBackgroundProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [switch]$Hidden
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    $psi.UseShellExecute = $false
    if ($Hidden) { $psi.CreateNoWindow = $true }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($arg in $ArgumentList) {
        [void]$psi.ArgumentList.Add([string]$arg)
    }
    return [System.Diagnostics.Process]::Start($psi)
}

function Get-AppPxeBootCaddyStartFailureDetail {
    param(
        [Parameter(Mandatory)][string]$CaddyExe,
        [Parameter(Mandatory)][string]$CaddyConfig,
        [Parameter(Mandatory)][string]$StoreRoot
    )
    $stderrPath = Join-Path $StoreRoot 'caddy-start-stderr.log'
    if (Test-Path -LiteralPath $stderrPath) {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($CaddyExe)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $StoreRoot
        $psi.RedirectStandardError = $true
        [void]$psi.ArgumentList.Add('run')
        [void]$psi.ArgumentList.Add('--config')
        [void]$psi.ArgumentList.Add($CaddyConfig)
        [void]$psi.ArgumentList.Add('--adapter')
        [void]$psi.ArgumentList.Add('caddyfile')
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { return $null }
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(5000)
        if ($err) { return ($err.Trim() -split "`n" | Select-Object -Last 3) -join ' | ' }
    } catch { }
    return $null
}

function Wait-AppPxeBootHttpListening {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Sync-AppPxeBootHttpProcessState -Port $Port
        if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
            return $true
        }
        $holder = Get-AppPxeBootHttpPortProcessId -Port $Port
        if ($holder -gt 0) {
            Sync-AppPxeBootHttpProcessState -Port $Port
            if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
                return $true
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Test-AppPxeBootHttpProcessIsOurs {
    param(
        [int]$ProcessId,
        [string]$CaddyConfigPath,
        [string]$StoreRoot
    )
    if ($ProcessId -le 0) { return $false }
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
            $cmd = if ($proc) { [string]$proc.CommandLine } else { $null }
            if ($cmd) {
                if ($CaddyConfigPath -and $cmd.Contains($CaddyConfigPath)) { return $true }
                if ($StoreRoot -and $cmd.Contains($StoreRoot) -and $cmd -match '(?i)\bcaddy(\.exe)?\b') { return $true }
            }
        } catch { }
        return $false
    }
    if ($CaddyConfigPath) {
        if (Get-Command pgrep -ErrorAction SilentlyContinue) {
            $matches = @(& pgrep -f ([regex]::Escape($CaddyConfigPath)) 2>$null)
            if ($matches -contains [string]$ProcessId) { return $true }
        }
    }
    try {
        $cmd = (& ps -p $ProcessId -o command= 2>$null | Out-String).Trim()
        if (-not $cmd) { return $false }
        if ($CaddyConfigPath -and $cmd.Contains($CaddyConfigPath)) { return $true }
        if ($StoreRoot -and $cmd.Contains($StoreRoot) -and $cmd -match '(?i)\bcaddy\b') { return $true }
        if ($StoreRoot -and $cmd.Contains($StoreRoot) -and $cmd -match '(?i)run-http\.ps1') { return $true }
    } catch { }
    return $false
}

function Get-AppPxeBootHttpServerProcessIdsUncached {
    param([int]$Port = 0)

    $caddyConfig = (Get-AppPxeBootLayoutPaths).caddyfile
    $storeRoot = Get-AppPxeBootStoreRoot
    $pids = [System.Collections.Generic.HashSet[int]]::new()

    $proc = $script:AppPxeBootState.HttpProcess
    if ($proc -and -not $proc.HasExited) {
        [void]$pids.Add($proc.Id)
    }

    if (Get-Command pgrep -ErrorAction SilentlyContinue) {
        if ($caddyConfig) {
            foreach ($candidate in @(& pgrep -f ([regex]::Escape($caddyConfig)) 2>$null)) {
                $procId = 0
                if ([int]::TryParse([string]$candidate, [ref]$procId) -and $procId -gt 0) {
                    [void]$pids.Add($procId)
                }
            }
        }
        foreach ($candidate in @(& pgrep -f 'run-http\.ps1' 2>$null)) {
            $procId = 0
            if ([int]::TryParse([string]$candidate, [ref]$procId) -and $procId -gt 0) {
                if (Test-AppPxeBootHttpProcessIsOurs -ProcessId $procId -CaddyConfigPath $caddyConfig -StoreRoot $storeRoot) {
                    [void]$pids.Add($procId)
                }
            }
        }
    }

    if ($Port -gt 0) {
        $holder = Get-AppPxeBootHttpPortProcessId -Port $Port
        if ($holder -gt 0 -and (Test-AppPxeBootHttpProcessIsOurs -ProcessId $holder -CaddyConfigPath $caddyConfig -StoreRoot $storeRoot)) {
            [void]$pids.Add($holder)
        }
    }

    return @($pids)
}

function Stop-AppPxeBootHttpProcessById {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) {
            $proc.Kill($true)
            [void](Wait-Process -Id $ProcessId -Timeout 3 -ErrorAction SilentlyContinue)
        }
    } catch { }
}

function Clear-AppPxeBootHttpTracking {
    $script:AppPxeBootState.HttpProcess = $null
}

function Get-AppPxeBootHttpServerProcessIds {
    # Liveness, so the memo is deliberately tiny - long enough to stop one status build
    # probing the same port twice, short enough that a service that just started or died
    # shows correctly on the next 8s poll. Start/stop clear it outright.
    param([int]$Port = 0)
    Get-AppPxeBootMemo -Key "http-pids-$Port" -Seconds 1.5 -Producer { @(Get-AppPxeBootHttpServerProcessIdsUncached -Port $Port) }
}

function Sync-AppPxeBootHttpProcessState {
    param([int]$Port = 0)

    if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
        return
    }

    $cfg = Read-AppPxeBootConfig
    $resolvedPort = if ($Port -gt 0) { $Port } else { [int]$cfg.httpPort }
    $ids = @(Get-AppPxeBootHttpServerProcessIds -Port $resolvedPort)
    if ($ids.Count -eq 1) {
        $proc = Get-Process -Id $ids[0] -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) {
            $script:AppPxeBootState.HttpProcess = $proc
            $script:AppPxeBootState.HttpLastError = $null
        }
    }
}

function Clear-AppPxeBootHttpPort {
    param([Parameter(Mandatory)][int]$Port)

    $caddyConfig = (Get-AppPxeBootLayoutPaths).caddyfile
    $storeRoot = Get-AppPxeBootStoreRoot
    $procIds = @(Get-AppPxeBootHttpServerProcessIds -Port $Port | Sort-Object -Unique)
    $holder = Get-AppPxeBootHttpPortProcessId -Port $Port

    if ($holder -gt 0 -and $procIds -notcontains $holder) {
        if (Test-AppPxeBootHttpProcessIsOurs -ProcessId $holder -CaddyConfigPath $caddyConfig -StoreRoot $storeRoot) {
            $procIds = @($procIds + $holder | Sort-Object -Unique)
        }
    }

    if ($procIds.Count -gt 0) {
        Write-SidecarLog "PXE boot: killing HTTP server on port $Port (pids: $($procIds -join ', '))"
        foreach ($procId in $procIds) {
            Stop-AppPxeBootHttpProcessById -ProcessId $procId
        }
        Start-Sleep -Milliseconds 300
        Clear-AppPxeBootHttpTracking
    }

    return ((Get-AppPxeBootHttpPortProcessId -Port $Port) -le 0)
}

function Get-AppPxeBootHttpPortKillShellCommand {
    param([Parameter(Mandatory)][int]$Port)

    $caddyConfig = (Get-AppPxeBootLayoutPaths).caddyfile
    $lines = [System.Collections.Generic.List[string]]::new()
    $procIds = @(Get-AppPxeBootHttpServerProcessIds -Port $Port | Sort-Object -Unique)
    if ($procIds.Count -eq 0) {
        $holder = Get-AppPxeBootHttpPortProcessId -Port $Port
        if ($holder -gt 0) { $procIds = @($holder) }
    }
    foreach ($procId in $procIds) {
        [void]$lines.Add("kill -9 $procId")
    }
    if ($caddyConfig) {
        [void]$lines.Add("pkill -9 -f '$caddyConfig'")
    }
    [void]$lines.Add("pkill -9 -f 'run-http.ps1'")
    return ($lines -join "`n")
}

function Test-AppPxeBootHttpPortBlocked {
    param([Parameter(Mandatory)][int]$Port)

    if ($script:AppPxeBootState.HttpLastError -match 'already in use|Address already in use') {
        return $true
    }
    return ((Get-AppPxeBootHttpPortProcessId -Port $Port) -gt 0)
}

function Get-AppPxeBootHttpPortConflictMessage {
    param([Parameter(Mandatory)][int]$Port)

    try {
        $caddyConfig = (Get-AppPxeBootLayoutPaths).caddyfile
        $holder = Get-AppPxeBootHttpPortProcessId -Port $Port
        if ($holder -le 0) { return $null }

        if (Test-AppPxeBootHttpProcessIsOurs -ProcessId $holder -CaddyConfigPath $caddyConfig -StoreRoot (Get-AppPxeBootStoreRoot)) {
            return @(
                "PXE boot: TCP port $Port is held by a previous Netboot HTTP server (pid $holder)."
                'Netboot will try to clear this automatically when you start HTTP.'
            ) -join ' '
        }

        $procName = ''
        try { $procName = (Get-Process -Id $holder -ErrorAction SilentlyContinue).ProcessName } catch { }
        $nameHint = if ($procName) { " ($procName)" } else { '' }
        return @(
            "PXE boot: TCP port $Port is already in use (pid $holder$nameHint)."
            'Stop the other process using that port and retry.'
        ) -join ' '
    } catch {
        return $null
    }
}

function Get-AppPxeBootImagingLogDir {
    # Per-client imaging logs pushed by a deploy client's log push over HTTP. Lives beside
    # (not under) http/ - the panel reads via IPC; Caddy never serves these files.
    $dir = Join-Path (Get-AppPxeBootStoreRoot) 'imaging-logs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Start-AppPxeBootImagingLogIngest {
    <#
    .SYNOPSIS
        Loopback ingest endpoint for deploy client imaging-log pushes. Caddy reverse-proxies
        POST /imaging-log/ingest here, so no new public port, no firewall prompt, and no
        http.sys URL-ACL headaches - a plain TcpListener on 127.0.0.1 with a minimal HTTP
        responder running in its own runspace. Returns the bound port, or 0 on failure
        (imaging must never depend on log ingest).
    #>
    if ($script:AppPxeBootState.LogIngest) {
        return [int]$script:AppPxeBootState.LogIngest.Port
    }
    try {
        $logDir = Get-AppPxeBootImagingLogDir
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

        $worker = [powershell]::Create()
        [void]$worker.AddScript({
            param($Listener, $LogDir)
            $errorLog = Join-Path $LogDir 'ingest-error.log'
            function Write-IngestError([string]$msg) {
                try {
                    "$([DateTime]::UtcNow.ToString('o')) $msg" | Out-File -Append -FilePath $errorLog -Encoding utf8
                } catch { }
            }
            function Get-IngestProp($Obj, [string]$Name) {
                if ($null -eq $Obj) { return $null }
                $p = $Obj.PSObject.Properties[$Name]
                if ($p) { return $p.Value }
                return $null
            }
            $encoding = [System.Text.Encoding]::UTF8
            while ($true) {
                try {
                    if (-not $Listener.Pending()) {
                        Start-Sleep -Milliseconds 200
                        continue
                    }
                    $client = $Listener.AcceptTcpClient()
                } catch {
                    break   # listener stopped - shut down
                }
                try {
                    $client.ReceiveTimeout = 3000
                    $client.SendTimeout = 3000
                    $stream = $client.GetStream()

                    # Read headers byte-wise until CRLFCRLF (bounded), then the JSON body.
                    $headerBytes = [System.IO.MemoryStream]::new()
                    $tail = 0   # rolling last-4-bytes window packed into an int
                    while ($headerBytes.Length -lt 16384) {
                        $b = $stream.ReadByte()
                        if ($b -lt 0) { break }
                        $headerBytes.WriteByte([byte]$b)
                        $tail = (($tail -shl 8) -bor $b) -band 0xFFFFFFFF
                        if ($tail -eq 0x0D0A0D0A) { break }   # \r\n\r\n
                    }
                    $headerText = $encoding.GetString($headerBytes.ToArray())
                    $lines = $headerText -split "`r`n"
                    $requestLine = if ($lines.Count -gt 0) { $lines[0] } else { '' }
                    $contentLength = 0
                    $clientIp = $null
                    foreach ($line in $lines) {
                        if ($line -match '^(?i)Content-Length:\s*(\d+)\s*$') {
                            $contentLength = [int]$matches[1]
                        } elseif ($line -match '^(?i)X-Forwarded-For:\s*(.+)$') {
                            # Caddy's reverse_proxy adds the real client address (first hop).
                            $clientIp = (([string]$matches[1]) -split ',')[0].Trim()
                        }
                    }

                    $status = $null
                    if ($requestLine -notmatch '^POST\s+/imaging-log/ingest(\?|\s)') {
                        $status = "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                    } elseif ($contentLength -le 0 -or $contentLength -gt 524288) {
                        $status = "HTTP/1.1 413 Payload Too Large`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                    }

                    if (-not $status) {
                        $body = [byte[]]::new($contentLength)
                        $read = 0
                        while ($read -lt $contentLength) {
                            $n = $stream.Read($body, $read, $contentLength - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        $payload = $null
                        try { $payload = $encoding.GetString($body, 0, $read) | ConvertFrom-Json } catch { $payload = $null }
                        # StrictMode: a bare $payload.lines THROWS when the client omits
                        # the key, and `-and $payload.lines` does NOT guard it - the
                        # property read happens before the comparison. Read every field
                        # through Get-IngestProp, defined INSIDE this scriptblock: the
                        # worker runs in a bare runspace where no sidecar function exists
                        # (Get-AppSidecarJsonProp here made every push fail - field bug
                        # found 2026-08-22 by a harness that starts the listener for real).
                        # A push carries log lines, or is a heartbeat (no lines) from a
                        # client parked at the deployment window - heartbeats keep the row
                        # live and let the driver pull-through start fetching early.
                        $payloadLines = @(Get-IngestProp $payload 'lines' | ForEach-Object { [string]$_ })
                        $isHeartbeat = ($payloadLines.Count -eq 0) -and [bool](Get-IngestProp $payload 'heartbeat')
                        if ($payload -and ($payloadLines.Count -gt 0 -or $isHeartbeat)) {
                            $serialRaw = [string](Get-IngestProp $payload 'serial')
                            if ([string]::IsNullOrWhiteSpace($serialRaw)) { $serialRaw = 'UNKNOWN' }
                            # Leading dots would make the file hidden on macOS (and invisible to
                            # the non -Force Get-ChildItem readers) - trim them off too.
                            $serial = ($serialRaw.Trim() -replace '[^A-Za-z0-9._-]', '-').TrimStart('.', '-')
                            if ([string]::IsNullOrWhiteSpace($serial)) { $serial = 'UNKNOWN' }
                            if ($serial.Length -gt 64) { $serial = $serial.Substring(0, 64) }
                            $logPath = Join-Path $LogDir "$serial.log"
                            $newLines = $payloadLines
                            if ($newLines.Count -gt 0) {
                                $newLines | Out-File -Append -FilePath $logPath -Encoding utf8
                            }
                            # Cap runaway logs: keep the newest 1500 lines past 4MB.
                            try {
                                $item = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
                                if ($item -and $item.Length -gt 4MB) {
                                    $tail = Get-Content -LiteralPath $logPath -Tail 1500 -ErrorAction SilentlyContinue
                                    Set-Content -LiteralPath $logPath -Value ($tail -join [Environment]::NewLine) -Encoding utf8
                                }
                            } catch { }
                            $statusPath = Join-Path $LogDir "$serial.json"
                            $previous = $null
                            try {
                                $previous = Get-Content -LiteralPath $statusPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                            } catch { $previous = $null }
                            if (-not $clientIp) {
                                # No X-Forwarded-For on this push - keep the last known IP.
                                $previousIp = [string](Get-IngestProp $previous 'ip')
                                if ($previousIp) { $clientIp = $previousIp }
                            }
                            # Imaging-session identity: newer deploy clients send one id per
                            # WinPE boot; for older clients the host derives one that rolls over
                            # when a serial reappears after 10 quiet minutes. The driver
                            # pull-through uses it to retry a failed pack fetch on the NEXT
                            # session of a model instead of looping on the same device.
                            $session = [string](Get-IngestProp $payload 'session')
                            if ([string]::IsNullOrWhiteSpace($session)) {
                                $previousSession = [string](Get-IngestProp $previous 'session')
                                $previousSeenRaw = Get-IngestProp $previous 'lastSeenUtc'
                                $previousSeen = [DateTime]::MinValue
                                if ($previousSeenRaw -is [DateTime]) {
                                    $previousSeen = [DateTime]$previousSeenRaw
                                } else {
                                    [void][DateTime]::TryParse([string]$previousSeenRaw, [ref]$previousSeen)
                                }
                                $quietMinutes = ([DateTime]::UtcNow - $previousSeen.ToUniversalTime()).TotalMinutes
                                if ($previousSession -and $quietMinutes -lt 10) {
                                    $session = $previousSession
                                } else {
                                    $session = 'host-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
                                }
                            }
                            $statusInfo = [ordered]@{
                                serial      = $serialRaw.Trim()
                                make        = [string](Get-IngestProp $payload 'make')
                                model       = [string](Get-IngestProp $payload 'model')
                                ip          = [string]$clientIp
                                session     = $session
                                lastSeenUtc = [DateTime]::UtcNow.ToString('o')
                                # A heartbeat carries no new line - keep the last one we saw.
                                lastLine    = if ($newLines.Count -gt 0) {
                                    [string]($newLines | Select-Object -Last 1)
                                } else {
                                    [string](Get-IngestProp $previous 'lastLine')
                                }
                            }
                            ($statusInfo | ConvertTo-Json -Compress) | Set-Content -LiteralPath $statusPath -Encoding utf8 -Force
                            $status = "HTTP/1.1 204 No Content`r`nConnection: close`r`n`r`n"
                        } else {
                            $status = "HTTP/1.1 400 Bad Request`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                        }
                    }

                    $reply = $encoding.GetBytes($status)
                    $stream.Write($reply, 0, $reply.Length)
                    $stream.Flush()
                } catch {
                    Write-IngestError "request error - $($_.Exception.Message)"
                } finally {
                    try { $client.Close() } catch { }
                }
            }
        }).AddArgument($listener).AddArgument($logDir)
        $async = $worker.BeginInvoke()

        $script:AppPxeBootState.LogIngest = @{
            Listener   = $listener
            PowerShell = $worker
            Async      = $async
            Port       = $port
        }
        Write-SidecarLog "PXE boot: imaging-log ingest listening on 127.0.0.1:$port"
        return $port
    } catch {
        Write-SidecarLog "PXE boot: imaging-log ingest failed to start - $($_.Exception.Message)"
        try { if ($listener) { $listener.Stop() } } catch { }
        $script:AppPxeBootState.LogIngest = $null
        return 0
    }
}

function Stop-AppPxeBootImagingLogIngest {
    $ingest = $script:AppPxeBootState.LogIngest
    if (-not $ingest) { return }
    $script:AppPxeBootState.LogIngest = $null
    try { $ingest.Listener.Stop() } catch { }
    try {
        $ingest.PowerShell.Stop()
        $ingest.PowerShell.Dispose()
    } catch { }
    Write-SidecarLogVerbose 'PXE boot: imaging-log ingest stopped'
}

function Get-AppPxeBootImagingClients {
    <#
    .SYNOPSIS
        Devices that have pushed imaging logs: one row per <serial>.json status snapshot,
        newest activity first. active = pushed within the last 3 minutes (the client
        pushes at most every 2 seconds while logging).
    #>
    $dir = Join-Path (Get-AppPxeBootStoreRoot) 'imaging-logs'
    $clients = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $dir)) { return @($clients) }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $info = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            continue
        }
        # Set-StrictMode: snapshots from older builds may lack fields (ip landed later) -
        # read every property tolerantly rather than by dot access.
        function Get-ImagingSnapshotProp {
            param($Info, [string]$Name)
            if ($Info -is [System.Collections.IDictionary]) {
                if ($Info.Contains($Name)) { return $Info[$Name] }
                return $null
            }
            $p = $Info.PSObject.Properties[$Name]
            if ($p) { return $p.Value }
            return $null
        }
        $lastSeenRaw = Get-ImagingSnapshotProp -Info $info -Name 'lastSeenUtc'
        # ConvertFrom-Json hydrates ISO strings straight into [DateTime]; tolerate both.
        $lastSeen = [DateTime]::MinValue
        if ($lastSeenRaw -is [DateTime]) {
            $lastSeen = [DateTime]$lastSeenRaw
        } else {
            [void][DateTime]::TryParse([string]$lastSeenRaw, [ref]$lastSeen)
        }
        $ageRaw = ([DateTime]::UtcNow - $lastSeen.ToUniversalTime()).TotalSeconds
        # No [Math]::Max/Min here: PS can bind the Int32 overload for (0, double) and
        # overflow on huge values (unparseable lastSeen -> age since year 1).
        $ageSeconds = if ($ageRaw -lt 0) { 0 } elseif ($ageRaw -gt 2000000000) { 2000000000 } else { [int]$ageRaw }
        $logPath = [IO.Path]::ChangeExtension($file.FullName, '.log')
        $logBytes = 0
        $logItem = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
        if ($logItem) { $logBytes = [long]$logItem.Length }
        [void]$clients.Add([ordered]@{
            serial     = [string](Get-ImagingSnapshotProp -Info $info -Name 'serial')
            make       = [string](Get-ImagingSnapshotProp -Info $info -Name 'make')
            model      = [string](Get-ImagingSnapshotProp -Info $info -Name 'model')
            ip         = [string](Get-ImagingSnapshotProp -Info $info -Name 'ip')
            session    = [string](Get-ImagingSnapshotProp -Info $info -Name 'session')
            lastSeen   = $lastSeen.ToUniversalTime().ToString('o')
            ageSeconds = $ageSeconds
            active     = ($ageSeconds -le 180)
            lastLine   = [string](Get-ImagingSnapshotProp -Info $info -Name 'lastLine')
            logBytes   = $logBytes
        })
    }
    return @($clients | Sort-Object -Property ageSeconds)
}

function Get-AppPxeBootImagingClientLog {
    param(
        [Parameter(Mandatory)][string]$Serial,
        [int]$MaxLines = 300
    )
    if ($MaxLines -le 0 -or $MaxLines -gt 2000) { $MaxLines = 300 }
    # Keep in lock-step with the ingest worker's sanitiser.
    $safe = (([string]$Serial).Trim() -replace '[^A-Za-z0-9._-]', '-').TrimStart('.', '-')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'UNKNOWN' }
    if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64) }
    $logPath = Join-Path (Join-Path (Get-AppPxeBootStoreRoot) 'imaging-logs') "$safe.log"
    $result = [ordered]@{
        serial    = [string]$Serial
        available = $false
        lines     = @()
    }
    if (-not (Test-Path -LiteralPath $logPath)) { return $result }
    $result.available = $true
    $result.lines = @(Get-Content -LiteralPath $logPath -Tail $MaxLines -ErrorAction SilentlyContinue)
    return $result
}

function Clear-AppPxeBootImagingLogs {
    $dir = Join-Path (Get-AppPxeBootStoreRoot) 'imaging-logs'
    $removed = 0
    if (Test-Path -LiteralPath $dir) {
        # -Force: also catch hidden files (dot-named strays, ingest-error.log rotations).
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    Write-SidecarLog "PXE boot: cleared imaging logs ($removed file(s))"
    return @{ removed = $removed }
}

function Stop-AppPxeBootHttpServer {
    $cfg = Read-AppPxeBootConfig
    $port = [int]$cfg.httpPort
    Sync-AppPxeBootHttpProcessState -Port $port

    $stopped = $false
    $proc = $script:AppPxeBootState.HttpProcess
    if ($proc -and -not $proc.HasExited) {
        try {
            $proc.Kill($true)
            [void](Wait-Process -Id $proc.Id -Timeout 3 -ErrorAction SilentlyContinue)
            $stopped = $true
        } catch { }
    }

    if (Clear-AppPxeBootHttpPort -Port $port) {
        $stopped = $true
    }

    Stop-AppPxeBootImagingLogIngest

    $script:AppPxeBootState.HttpLastError = $null
    Clear-AppPxeBootHttpTracking
    return $stopped
}

function Start-AppPxeBootHttpServer {
    param(
        [Parameter(Mandatory)][string]$HttpRoot,
        [Parameter(Mandatory)][int]$Port,
        [string]$InterfaceId,
        # The imaging-log ingest listener lives in a PROCESS, and since the service
        # start moved to a child pwsh (2026-08-24) that process must be the parent
        # sidecar - the child's listener died with it and every WinPE log push got a
        # 502 from Caddy. When the parent already owns a listener it passes the port
        # here; 0 = start one in this process (the inline path).
        [int]$IngestPort = 0
    )

    Clear-AppPxeBootLegacyHttpRunner

    Sync-AppPxeBootHttpProcessState -Port $Port
    if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
        # An adopted Caddy has its Caddyfile baked - if its imaging-log route points at
        # a dead listener (the one that started it exited; ports are per-process), every
        # WinPE log push 502s until Caddy is restarted with the live port. Verify before
        # accepting it (caught live 2026-08-24: client pushes bounced off port 54960).
        $desiredIngest = if ($IngestPort -gt 0) { $IngestPort } elseif ($script:AppPxeBootState.LogIngest) { [int]$script:AppPxeBootState.LogIngest.Port } else { 0 }
        $currentIngest = 0
        try {
            $cfText = Get-Content -LiteralPath (Get-AppPxeBootLayoutPaths).caddyfile -Raw -ErrorAction Stop
            if ($cfText -match 'reverse_proxy 127\.0\.0\.1:(\d+)') { $currentIngest = [int]$Matches[1] }
        } catch { }
        if ($desiredIngest -gt 0 -and $currentIngest -ne $desiredIngest) {
            Write-SidecarLog "PXE boot: restarting HTTP - Caddy proxies imaging logs to :$currentIngest but the live ingest listener is :$desiredIngest"
            Stop-AppPxeBootHttpServer | Out-Null
        } else {
            return @{ ok = $true; detail = 'HTTP already running'; backend = 'caddy' }
        }
    }

    $paths = Get-AppPxeBootLayoutPaths
    $caddyConfig = $paths.caddyfile
    $storeRoot = Get-AppPxeBootStoreRoot
    $holder = Get-AppPxeBootHttpPortProcessId -Port $Port
    $orphanIds = @(Get-AppPxeBootHttpServerProcessIds -Port $Port)

    if ($holder -gt 0) {
        if (Test-AppPxeBootHttpProcessIsOurs -ProcessId $holder -CaddyConfigPath $caddyConfig -StoreRoot $storeRoot) {
            Write-SidecarLog "PXE boot: port $Port blocked by previous Netboot Caddy (pid $holder) - clearing"
            Clear-AppPxeBootHttpPort -Port $Port | Out-Null
        } elseif ($orphanIds.Count -gt 0) {
            Write-SidecarLog "PXE boot: clearing orphan HTTP server process(es) on port $Port"
            Clear-AppPxeBootHttpPort -Port $Port | Out-Null
        } else {
            throw (Get-AppPxeBootHttpPortConflictMessage -Port $Port)
        }
    } elseif ($orphanIds.Count -gt 0) {
        Write-SidecarLog 'PXE boot: clearing orphan HTTP server process(es)'
        Clear-AppPxeBootHttpPort -Port $Port | Out-Null
    }

    $cfg = Read-AppPxeBootConfig
    $ifId = if ($InterfaceId) { $InterfaceId } else { $cfg.interfaceId }
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $ifId
    # Listen on all interfaces; selected adapter only drives menu/boot URLs (Get-AppPxeBootLanIp).
    $bindAddress = '0.0.0.0'

    Ensure-AppPxeBootCaddy | Out-Null
    $caddyExe = Get-AppPxeBootCaddyPath
    if (-not $caddyExe) {
        throw 'PXE boot: Caddy is not installed - enable Netboot and wait for the download to finish.'
    }

    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Ensure-AppPxeBootWindowsFirewallRules -HttpPort $Port | Out-Null
    }

    # Imaging-log ingest first so the Caddyfile can carry its reverse_proxy port. A failed
    # ingest start (port 0) just omits the route - imaging never depends on log push.
    $ingestPort = if ($IngestPort -gt 0) { $IngestPort } else { Start-AppPxeBootImagingLogIngest }

    Write-AppPxeBootCaddyfile -Path $caddyConfig -HttpRoot $HttpRoot -Port $Port -BindAddress $bindAddress -ImagingLogIngestPort $ingestPort

    $caddyArgs = @('run', '--config', $caddyConfig, '--adapter', 'caddyfile')
    $proc = Start-AppPxeBootBackgroundProcess -FilePath $caddyExe -ArgumentList $caddyArgs -WorkingDirectory $storeRoot -Hidden
    if (-not $proc) {
        throw 'PXE boot: failed to start Caddy process.'
    }
    $listening = Wait-AppPxeBootHttpListening -Port $Port
    if (-not $listening -and $proc.HasExited) {
        if (Clear-AppPxeBootHttpPort -Port $Port) {
            $proc = Start-AppPxeBootBackgroundProcess -FilePath $caddyExe -ArgumentList $caddyArgs -WorkingDirectory $storeRoot -Hidden
            if ($proc) {
                $listening = Wait-AppPxeBootHttpListening -Port $Port
            }
        }
    }
    if (-not $listening) {
        $detail = Get-AppPxeBootCaddyStartFailureDetail -CaddyExe $caddyExe -CaddyConfig $caddyConfig -StoreRoot $storeRoot
        $hint = 'check Caddyfile and port availability'
        if ($detail) { $hint = $detail }
        throw "PXE boot: Caddy exited immediately - $hint"
    }

    if (-not $script:AppPxeBootState.HttpProcess -or $script:AppPxeBootState.HttpProcess.HasExited) {
        $script:AppPxeBootState.HttpProcess = $proc
    }
    $script:AppPxeBootState.HttpLastError = $null
    $urlHint = if ($lanIp) { ", menu URLs use $lanIp" } else { '' }
    Write-SidecarLog "PXE boot: HTTP listening on :$Port (all interfaces$urlHint, Caddy)"
    @{ ok = $true; port = $Port; backend = 'caddy'; bindAddress = '0.0.0.0'; caddyPath = $caddyExe }
}

function Stop-AppPxeBootServices {
    param(
        [switch]$HttpOnly,
        [switch]$TftpOnly,
        [switch]$SkipAdminKill,
        # Stop the server processes only - leave ISO mounts and the Deploy$ share
        # untouched (see Start-AppPxeBootServices -Minimal).
        [switch]$Minimal
    )
    # Whatever the badges say next must reflect what we are about to do.
    Clear-AppPxeBootMemo
    $stopHttp = $HttpOnly -or (-not $HttpOnly -and -not $TftpOnly)
    $stopTftp = $TftpOnly -or (-not $HttpOnly -and -not $TftpOnly)
    $stopped = [System.Collections.Generic.List[string]]::new()

    if ($stopHttp) {
        if (Stop-AppPxeBootHttpServer) {
            [void]$stopped.Add('http')
        } elseif (@(Get-AppPxeBootHttpServerProcessIds -Port ([int](Read-AppPxeBootConfig).httpPort)).Count -gt 0) {
            Write-SidecarLog 'PXE boot: HTTP may still be running (orphan Caddy process)'
        }
        if ($Minimal) {
            # A non-Netboot caller (AP Converter) stopping "its" web server must not
            # dismount ISOs or unshare Deploy$ out from under an imaging session.
            Write-SidecarLogVerbose 'PXE boot: minimal stop - leaving ISO mounts and Deploy$ share alone.'
        } else {
            # Release in-place install.wim ISO mounts once HTTP is no longer serving them.
            try {
                Dismount-AppPxeBootInstallWimIsos
            } catch {
                Write-SidecarLog "PXE boot: ISO dismount-all error - $($_.Exception.Message)"
            }
            # Tear down the Deploy$ share too so its state follows imaging services (best
            # effort; macOS only unshares when admin is already cached - no fresh prompt).
            try {
                Remove-AppPxeBootImageLibraryShare
            } catch {
                Write-SidecarLog "PXE boot: SMB share teardown error - $($_.Exception.Message)"
            }
        }
    }

    if ($stopTftp) {
        if (Stop-AppPxeBootTftpServer -SkipAdminKill:$SkipAdminKill) {
            $script:AppPxeBootState.TftpLastError = $null
            $script:AppPxeBootState.TftpElevatedCommand = $null
            [void]$stopped.Add('tftp')
        } elseif (-not $SkipAdminKill) {
            $orphanIds = @(Get-AppPxeBootDnsmasqProcessIds)
            if ($orphanIds.Count -gt 0) {
                Write-SidecarLog "PXE boot: TFTP may still be running (pids: $($orphanIds -join ', '))"
            }
        }
    }

    $httpStillRunning = $script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited
    Sync-AppPxeBootTftpProcessState
    $tftpStillRunning = $script:AppPxeBootState.TftpProcess -and -not $script:AppPxeBootState.TftpProcess.HasExited
    if (-not $httpStillRunning -and -not $tftpStillRunning) {
        $script:AppPxeBootState.StartedAt = $null
    }

    Write-SidecarLog "PXE boot: stopped $($stopped -join ', ')"
    @{ stopped = @($stopped) }
}

function Get-AppPxeBootSafeTftpBootFileName {
    param([Parameter(Mandatory)][string]$FileName)
    $name = ($FileName -replace '\\', '/').Trim().TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'PXE boot: TFTP boot file name is required.'
    }
    if ($name -match '\.\.') {
        throw 'PXE boot: TFTP boot file path is invalid.'
    }
    if ($name -notmatch '(?i)^[\w./-]+\.efi$') {
        throw 'PXE boot: TFTP boot file must be a .efi path under tftp/.'
    }
    return $name
}

function Get-AppPxeBootTftpBootFileAbsolutePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $rel = Get-AppPxeBootSafeTftpBootFileName -FileName $RelativePath
    $tftpRoot = (Get-AppPxeBootLayoutPaths).tftpRoot
    Join-Path $tftpRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
}

function Test-AppPxeBootTftpBootFileExists {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Get-AppPxeBootTftpBootFileAbsolutePath -RelativePath $RelativePath
    Test-Path -LiteralPath $path -PathType Leaf
}

function Get-AppPxeBootConfiguredTftpBootFile {
    $cfg = Read-AppPxeBootConfig
    $name = if ($cfg.tftpBootFile) { [string]$cfg.tftpBootFile } else { $script:AppPxeBootDefaultTftpBootFile }
    try {
        return Get-AppPxeBootSafeTftpBootFileName -FileName $name
    } catch {
        return $script:AppPxeBootDefaultTftpBootFile
    }
}

function Test-AppPxeBootTftpBootFileIsSecureBootShimEntry {
    param([Parameter(Mandatory)][string]$RelativePath)
    $rel = ($RelativePath -replace '\\', '/').ToLowerInvariant()
    if ($rel -match '(^|/)shimx64\.efi$') { return $true }
    if ($rel -match '(^|/)shimaa64\.efi$') { return $true }
    if ($rel -match '(^|/)shimia32\.efi$') { return $true }
    if ($rel -match '-shim\.efi$') { return $true }
    return $false
}

function Test-AppPxeBootTftpBootFileSecureBoot {
    param([Parameter(Mandatory)][string]$RelativePath)
    $rel = ($RelativePath -replace '\\', '/').ToLowerInvariant()
    return ($rel -match '(^|/)(x86_64-sb|arm64-sb|i386-sb|sb)/') -or ($rel -match 'shim.*\.efi$')
}

function Get-AppPxeBootTftpBootFilePresets {
    @(
        @{
            fileName       = 'x86_64-sb/shimx64.efi'
            displayLabel   = '(default - secure boot on)'
            secureBoot     = $true
            secureBootShim = $true
            preset         = $true
        }
        @{
            fileName       = 'snponly.efi'
            displayLabel   = '(default - Secure boot off)'
            secureBoot     = $false
            secureBootShim = $false
            preset         = $true
        }
    )
}

function Get-AppPxeBootTftpBootFileRecommended {
    param([Parameter(Mandatory)][string]$RelativePath)
    $rel = ($RelativePath -replace '\\', '/').ToLowerInvariant()
    foreach ($preset in Get-AppPxeBootTftpBootFilePresets) {
        if ($rel -eq [string]$preset.fileName) {
            return [string]$preset.displayLabel
        }
    }
    return $null
}

function Get-AppPxeBootTftpBootFileInventory {
    $tftpRoot = (Get-AppPxeBootLayoutPaths).tftpRoot
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($preset in Get-AppPxeBootTftpBootFilePresets) {
        $rel = [string]$preset.fileName
        [void]$seen.Add($rel)
        $sizeBytes = 0L
        $missing = $true
        if ($tftpRoot -and (Test-Path -LiteralPath $tftpRoot)) {
            $abs = Get-AppPxeBootTftpBootFileAbsolutePath -RelativePath $rel
            if (Test-Path -LiteralPath $abs -PathType Leaf) {
                $sizeBytes = [long](Get-Item -LiteralPath $abs).Length
                $missing = $false
            }
        }
        [void]$rows.Add(@{
                fileName       = $rel
                displayLabel   = "$rel $([string]$preset.displayLabel)"
                sizeBytes      = $sizeBytes
                secureBoot     = [bool]$preset.secureBoot
                secureBootShim = [bool]$preset.secureBootShim
                recommended    = [string]$preset.displayLabel
                preset         = $true
                missing        = $missing
            })
    }
    if (-not (Test-Path -LiteralPath $tftpRoot)) { return @($rows) }
    foreach ($file in @(Get-ChildItem -LiteralPath $tftpRoot -Filter '*.efi' -File -Recurse -ErrorAction SilentlyContinue)) {
        $rel = $file.FullName.Substring($tftpRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, '/')
        $rel = $rel -replace '\\', '/'
        if ($seen.Contains($rel)) { continue }
        [void]$seen.Add($rel)
        $hint = Get-AppPxeBootTftpBootFileRecommended -RelativePath $rel
        [void]$rows.Add(@{
                fileName       = $rel
                sizeBytes      = [long]$file.Length
                secureBoot     = (Test-AppPxeBootTftpBootFileSecureBoot -RelativePath $rel)
                secureBootShim = (Test-AppPxeBootTftpBootFileIsSecureBootShimEntry -RelativePath $rel)
                recommended    = $hint
                preset         = $false
            })
    }
    $configured = Get-AppPxeBootConfiguredTftpBootFile
    if (-not $seen.Contains($configured)) {
        [void]$rows.Add(@{
                fileName       = $configured
                sizeBytes      = 0
                secureBoot     = (Test-AppPxeBootTftpBootFileSecureBoot -RelativePath $configured)
                secureBootShim = (Test-AppPxeBootTftpBootFileIsSecureBootShimEntry -RelativePath $configured)
                recommended    = $null
                preset         = $false
                missing        = $true
            })
    }
    @($rows | Sort-Object @{
            Expression = {
                if ($_.PSObject.Properties['preset'] -and [bool]$_.preset) {
                    if ($_.fileName -eq 'x86_64-sb/shimx64.efi') { 0 } else { 1 }
                }
                elseif ($_.fileName -eq 'x86_64-sb/shimx64.efi') { 2 }
                elseif ($_.fileName -eq 'snponly.efi') { 3 }
                elseif ($_.secureBoot) { 4 }
                else { 5 }
            }
        }, @{ Expression = 'fileName' })
}

function Get-AppPxeBootRouterInstructions {
    param(
        [string]$LanIp,
        [int]$HttpPort
    )
    $bootFile = Get-AppPxeBootConfiguredTftpBootFile
    $sb = Test-AppPxeBootTftpBootFileSecureBoot -RelativePath $bootFile
    @{
        option66      = if ($LanIp) { $LanIp } else { '<host IP>' }
        option67      = $bootFile
        option66Label = 'Next Server (boot server host name / IP)'
        option67Label = 'Bootfile Name'
        notes         = @(
            'On the site router or DHCP server - leave client leases unchanged; add PXE boot options only.'
            'Option 66 = this laptop IPv4 on the deployment LAN (same subnet as targets).'
            "Option 67 = $bootFile (path relative to tftp/ on this host)."
            if ($sb) {
                'Secure Boot: Option 67 must be shimx64.efi (shim loads ipxe/snponly from x86_64-sb/). Do not use x86_64-sb/ipxe.efi as Option 67.'
                'Hyper-V Gen2: Security -> Secure Boot template -> Microsoft UEFI Certificate Authority (not Windows-only).'
            } else {
                'Non-Secure Boot: snponly.efi chains to local boot.ipxe over HTTP.'
            }
            'Some routers accept only a flat filename - copy or symlink shimx64.efi to tftp/ root if needed.'
            'Turn on the TFTP server switch in Netboot before PXE booting a target.'
            'UEFI target -> TFTP boot file -> local boot.ipxe menu; WIM/ISO over HTTP from this workstation.'
        )
    }
}

function Get-AppPxeBootWimLibraryLayoutSnapshot {
    # A file walk over the WIM/ISO library. Importing or removing media clears the memo,
    # so the only staleness possible is a file dropped in by hand within 5 seconds.
    Get-AppPxeBootMemo -Key 'wim-layout' -Seconds 5 -Producer { Get-AppPxeBootWimLibraryLayoutSnapshotUncached }
}

function Get-AppPxeBootStatus {
    param(
        [switch]$SkipCatalogSync,
        [switch]$SkipLayoutProbe,
        [switch]$SkipHeavyChecks,
        $Layout
    )

    if (-not $SkipCatalogSync) {
    }
    $cfg = Read-AppPxeBootConfig
    if ($Layout) {
        $layout = $Layout
    } elseif ($SkipLayoutProbe) {
        $layout = Get-AppPxeBootWimLibraryLayoutSnapshot
    } else {
        $layout = Test-AppPxeBootLayout
    }
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId
    $adapters = @(Get-AppPxeBootNetworkAdapters)

    $httpRunning = $false
    $httpPid = $null
    Sync-AppPxeBootHttpProcessState -Port ([int]$cfg.httpPort)
    if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
        $httpRunning = $true
        $httpPid = $script:AppPxeBootState.HttpProcess.Id
    } else {
        $holder = Get-AppPxeBootHttpPortProcessId -Port ([int]$cfg.httpPort)
        if ($holder -gt 0 -and (Test-AppPxeBootHttpProcessIsOurs -ProcessId $holder -CaddyConfigPath (Get-AppPxeBootLayoutPaths).caddyfile -StoreRoot (Get-AppPxeBootStoreRoot))) {
            Sync-AppPxeBootHttpProcessState -Port ([int]$cfg.httpPort)
            if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
                $httpRunning = $true
                $httpPid = $script:AppPxeBootState.HttpProcess.Id
            }
        }
    }

    $tftpRunning = $false
    $tftpPid = $null
    $tftpBackend = $null
    Sync-AppPxeBootTftpProcessState
    if ($script:AppPxeBootState.TftpProcess -and -not $script:AppPxeBootState.TftpProcess.HasExited) {
        $tftpRunning = $true
        $tftpPid = $script:AppPxeBootState.TftpProcess.Id
        if ($script:AppPxeBootState.TftpElevated) {
            $tftpBackend = 'dnsmasq-elevated'
        } else {
            $tftpBackend = if ($IsWindows -or ($env:OS -eq 'Windows_NT')) { 'tftpd64/dnsmasq' } else { 'dnsmasq' }
        }
    }

    $router = Get-AppPxeBootRouterInstructions -LanIp $lanIp -HttpPort $cfg.httpPort
    $platform = if ($IsWindows -or ($env:OS -eq 'Windows_NT')) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'other' }
    $defaultWim = if ($cfg.defaultBootWim) { [string]$cfg.defaultBootWim } else { $null }
    $defaultBootWimUrl = $null
    if ($defaultWim -and $lanIp) {
        $defaultPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $defaultWim
        if (Test-Path -LiteralPath $defaultPath) {
            $defaultBootWimUrl = "http://${lanIp}:$($cfg.httpPort)/wim/$defaultWim"
        } else {
            $defaultWim = $null
        }
    }

    @{
        platform          = $platform
        storeRoot         = $layout.storeRoot
        layout            = $layout
        config            = $cfg
        adapters          = $adapters
        lanIp             = $lanIp
        lanIpHint         = if ($lanIp) { $null } else { Get-AppPxeBootLanIpHint -InterfaceId $cfg.interfaceId }
        httpRunning       = $httpRunning
        httpPid           = $httpPid
        httpBackend       = if ($httpRunning) { 'caddy' } else { $null }
        httpUrl           = if ($httpRunning -and $lanIp) { "http://${lanIp}:$($cfg.httpPort)/" } else { $null }
        httpPort          = [int]$cfg.httpPort
        tftpRunning       = $tftpRunning
        tftpPid           = $tftpPid
        tftpBackend       = $tftpBackend
        running           = ($httpRunning -or $tftpRunning)
        # Devices that pushed imaging logs in the last 3 minutes - drives the collapsed
        # "Imaging clients" badge off the panel's existing 8s status poll (cheap dir scan).
        imagingClientsActive = @(Get-AppPxeBootImagingClients | Where-Object { $_.active }).Count
        startedAt         = $script:AppPxeBootState.StartedAt
        deployMenuUrl        = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        localHttpOnly        = -not (Test-AppPxeBootWanDeployMenuEnabled)
        wanIsoCatalogUrl     = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        router               = $router
        bundledSnponly    = [bool](Get-AppPxeBootBundledSnponlyPath)
        bundledWimboot    = [bool](Get-AppPxeBootBundledWimbootPath)
        bundledSecureBoot = [bool](Get-AppPxeBootBundledSecureBootTftpRoot)
        dnsmasqPath       = Resolve-AppPxeBootDnsmasqPath
        tftpd64Path       = Resolve-AppPxeBootTftpd64Path -ConfiguredPath $cfg.tftpd64Path
        defaultBootWim    = $defaultWim
        defaultBootWimUrl = $defaultBootWimUrl
        bootChainMode     = Get-AppPxeBootBootChainMode
        defaultWimbootKernelOptions = if ($defaultWim) {
            Format-AppPxeBootWimbootKernelOptions -Recipe (Get-AppPxeBootWimbootRecipe -WimFileName $defaultWim)
        } else { $null }
        defaultWimbootUsesBootAssets = if ($defaultWim) {
            [bool](Get-AppPxeBootWimBootAssetsDir -WimFileName $defaultWim)
        } else { $false }
        wims              = @(Get-AppPxeBootWimInventory)
        isos              = @(Get-AppPxeBootIsoInventory)
        optionalAssets    = Get-AppPxeBootOptionalAssetsStatus -SkipHash:$SkipHeavyChecks
        caddy             = Get-AppPxeBootCaddyDownloadStatus
        httpLastError     = $script:AppPxeBootState.HttpLastError
        httpPortKillCommand = if (-not $httpRunning -and (Test-AppPxeBootHttpPortBlocked -Port ([int]$cfg.httpPort))) {
            Get-AppPxeBootHttpPortKillShellCommand -Port ([int]$cfg.httpPort)
        } else {
            $null
        }
        tftpLastError       = $script:AppPxeBootState.TftpLastError
        tftpElevatedCommand = $script:AppPxeBootState.TftpElevatedCommand
        tftpPort69KillCommand = if ($platform -eq 'macos' -and -not $tftpRunning -and (Test-AppPxeBootPort69Blocked)) {
            Get-AppPxeBootPort69KillShellCommand
        } else {
            $null
        }
        tftpElevated        = [bool]$script:AppPxeBootState.TftpElevated
        dnsmasqConfPath     = (Get-AppPxeBootLayoutPaths).dnsmasqConf
        macOsAdminCredentialCached = if ($platform -eq 'macos' -and (Test-AppSidecarCommand Get-AppMacOsAdminCredentialCacheStatus)) {
            [bool](Get-AppMacOsAdminCredentialCacheStatus).cached
        } else {
            $false
        }
        localMachineCredentialConfigured = if (Test-AppSidecarCommand Test-AppLocalMachineCredentialConfigured) {
            [bool](Test-AppLocalMachineCredentialConfigured)
        } else {
            $false
        }
        tftpBootFile      = Get-AppPxeBootConfiguredTftpBootFile
        tftpBootFiles     = @(Get-AppPxeBootTftpBootFileInventory)
    }
}

# Hidden, read-only SMB share exposing the image library root as a
# Deploy$-equivalent so the deploy client reads <root>\Drivers\<model> and <root>\WIMs
# the same way it reads the configured deploy share.
$script:AppPxeBootImageLibraryShareName = 'Deploy$'

# --- Throwaway SMB account ---
# One hidden local account used to authenticate the Deploy$ share. Its identity
# lives in a cred file in the store; created once, reused across restarts.
function Get-AppPxeBootSmbCredFilePath {
    # Renamed from fieldiso-smb-test.cred when FieldIso left the product (2026-08-24);
    # migrate the old file so the existing account (and the SMB fast-path marker built
    # on it) survives the rename.
    $new = Join-Path (Get-AppPxeBootStoreRoot) 'smb-throwaway.cred'
    $old = Join-Path (Get-AppPxeBootStoreRoot) 'fieldiso-smb-test.cred'
    if (-not (Test-Path -LiteralPath $new) -and (Test-Path -LiteralPath $old)) {
        Move-Item -LiteralPath $old -Destination $new -Force -ErrorAction SilentlyContinue
    }
    $new
}

function Read-AppPxeBootSmbThrowawayCred {
    $p = Get-AppPxeBootSmbCredFilePath
    if (Test-Path -LiteralPath $p) {
        $lines = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -ge 2) {
            return [pscustomobject]@{ User = ([string]$lines[0]).Trim(); Pass = ([string]$lines[1]).Trim() }
        }
    }
    $null
}

function Write-AppPxeBootSmbThrowawayCred {
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Pass)
    $p = Get-AppPxeBootSmbCredFilePath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Set-Content -LiteralPath $p -Value @($User, $Pass) -Encoding ASCII -Force
    if (($IsMacOS -or $IsDarwin) -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod -f 600 $p 2>$null
    }
}

function New-AppPxeBootSmbRandomHex {
    param([int]$Bytes = 12)
    $b = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
    ($b | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}

function Test-AppPxeBootMacOsUserExists {
    param([Parameter(Mandatory)][string]$Name)
    try { (& id $Name 2>$null) | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Test-AppPxeBootWindowsUserExists {
    param([Parameter(Mandatory)][string]$Name)
    if (-not ($IsWindows -or ($env:OS -eq 'Windows_NT'))) { return $false }
    if (Test-AppSidecarCommand Get-LocalUser) {
        try { return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) } catch { }
    }
    try {
        & net.exe user $Name >$null 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { }
    return $false
}

function Test-AppPxeBootSmbThrowawayUserExists {
    param([Parameter(Mandatory)][string]$Name)
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        return (Test-AppPxeBootWindowsUserExists -Name $Name)
    }
    if ($IsMacOS -or $IsDarwin) {
        return (Test-AppPxeBootMacOsUserExists -Name $Name)
    }
    return $false
}

function Get-AppPxeBootSmbThrowawayCredential {
    # Reuse the existing throwaway pair if its account still exists on this host; otherwise
    # mint a fresh random account name + password and persist it.
    $cred = Read-AppPxeBootSmbThrowawayCred
    if ($cred -and (Test-AppPxeBootSmbThrowawayUserExists -Name $cred.User)) {
        return $cred
    }
    $prefix = 'smimg'
    $user = $null
    do { $user = $prefix + (New-AppPxeBootSmbRandomHex -Bytes 3) } while (Test-AppPxeBootSmbThrowawayUserExists -Name $user)
    $pass = New-AppPxeBootSmbRandomHex -Bytes 12
    Write-AppPxeBootSmbThrowawayCred -User $user -Pass $pass
    [pscustomobject]@{ User = $user; Pass = $pass }
}

function New-AppPxeBootWindowsSmbPassword {
    # Keep <=14 chars so net.exe fallback stays non-interactive.
    'Sm1!' + (New-AppPxeBootSmbRandomHex -Bytes 4)
}

function Ensure-AppPxeBootWindowsSmbThrowawayCredential {
    param([Parameter(Mandatory)][string]$Root)

    if (-not ($IsWindows -or ($env:OS -eq 'Windows_NT'))) { return $null }

    $existing = Read-AppPxeBootSmbThrowawayCred
    $user = $null
    $pass = $null
    $persistCred = $false
    if ($existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.User) -and
        (Test-AppPxeBootWindowsUserExists -Name ([string]$existing.User).Trim())) {
        $user = ([string]$existing.User).Trim()
        $pass = if ($existing.Pass) { ([string]$existing.Pass).Trim() } else { $null }
    } else {
        do { $user = 'smimg' + (New-AppPxeBootSmbRandomHex -Bytes 3) } while (Test-AppPxeBootWindowsUserExists -Name $user)
        $pass = New-AppPxeBootWindowsSmbPassword
        $persistCred = $true
    }
    if ([string]::IsNullOrWhiteSpace($pass) -or $pass.Length -gt 14) {
        $pass = New-AppPxeBootWindowsSmbPassword
        $persistCred = $true
    }
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) { return $null }

    $userExists = Test-AppPxeBootWindowsUserExists -Name $user
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    if (-not $userExists -and -not $isAdmin) {
        Write-SidecarLog "PXE boot: throwaway SMB user '$user' is missing and this app is not elevated; cannot create local account. Run $(Get-AppProductDisplayName) as Administrator once or switch overlay credentials mode to blank."
        return $null
    }

    if (-not $userExists) {
        try {
            if (Test-AppSidecarCommand New-LocalUser) {
                $sec = ConvertTo-SecureString $pass -AsPlainText -Force
                New-LocalUser -Name $user -Password $sec `
                    -FullName "$(Get-AppProductDisplayName) imaging throwaway SMB" `
                    -Description 'Read-only Deploy$ SMB account for overlay' `
                    -AccountNeverExpires -PasswordNeverExpires | Out-Null
            } else {
                & net.exe user $user $pass /add /active:yes /expires:never /passwordchg:no >$null 2>$null
                if ($LASTEXITCODE -ne 0) {
                    throw "net user exited with code $LASTEXITCODE"
                }
            }
            Write-SidecarLog "PXE boot: created Windows throwaway SMB user $user"
        } catch {
            Write-SidecarLog "PXE boot: failed to create Windows throwaway SMB user - $($_.Exception.Message)"
            return $null
        }
        $persistCred = $true
    }

    $passwordSynced = $false
    try {
        if (Test-AppSidecarCommand Set-LocalUser) {
            $sec = ConvertTo-SecureString $pass -AsPlainText -Force
            Set-LocalUser -Name $user -Password $sec -ErrorAction Stop | Out-Null
            $passwordSynced = $true
        } else {
            & net.exe user $user $pass >$null 2>$null
            $passwordSynced = ($LASTEXITCODE -eq 0)
        }
    } catch {
        $passwordSynced = $false
    }
    if (-not $passwordSynced) {
        Write-SidecarLog "PXE boot: failed to sync password for Windows throwaway SMB user $user"
        return $null
    }
    if ($persistCred) {
        Write-AppPxeBootSmbThrowawayCred -User $user -Pass $pass
    }

    if (Test-AppSidecarCommand Enable-LocalUser) {
        try { Enable-LocalUser -Name $user -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    $needsAcl = -not (
        ($script:AppPxeBootWindowsSmbAclRoot -and ([string]$script:AppPxeBootWindowsSmbAclRoot -eq [string]$Root)) -and
        ($script:AppPxeBootWindowsSmbAclUser -and ([string]$script:AppPxeBootWindowsSmbAclUser -eq [string]$user))
    )
    if ($needsAcl) {
        $account = if ($env:COMPUTERNAME) { "$($env:COMPUTERNAME)\$user" } else { $user }
        try {
            & icacls.exe $Root /grant "$($account):(OI)(CI)(RX)" /T /C /Q >$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                $script:AppPxeBootWindowsSmbAclRoot = [string]$Root
                $script:AppPxeBootWindowsSmbAclUser = [string]$user
            } else {
                Write-SidecarLog "PXE boot: failed to grant NTFS read for $account on $Root (icacls exit $LASTEXITCODE)"
            }
        } catch {
            Write-SidecarLog "PXE boot: failed to grant NTFS read for $account on $Root - $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{ User = $user; Pass = $pass }
}

function Test-AppPxeBootMacOsShareActive {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $out = & /usr/sbin/sharing -l 2>$null
        if (-not $out) { return $false }
        return [bool](($out -join "`n") -match [regex]::Escape($Name))
    } catch { return $false }
}

function Ensure-AppPxeBootMacOsImageLibraryShare {
    <#
    .SYNOPSIS
        Create/repoint the hidden read-only Deploy$ SMB share on the image library
        root and (idempotently) provision the random hidden throwaway SMB-NT account
        WinPE authenticates with as WORKGROUP\<user>. One elevation.
    #>
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-AppSidecarCommand Invoke-AppMacOsAdminShellCommand)) {
        throw 'macOS admin elevation helper unavailable.'
    }
    # TCC guard: a share rooted under ~/Downloads, ~/Desktop or ~/Documents is
    # created but smbd is denied read access, so it never serves. Refuse loudly here
    # (the panel surfaces matching guidance via Get-AppPxeBootImageLibraryShareStatus).
    $tccBase = if (Test-AppSidecarCommand Get-AppMacOsTccProtectedBase) {
        Get-AppMacOsTccProtectedBase -Path $Root
    } else { $null }
    if ($tccBase) {
        Write-SidecarLog "PXE boot: refusing Deploy`$ share - '$Root' is under TCC-protected '$tccBase'; smbd cannot serve it. Move the ISO & driver root to e.g. ~/Public/$(Get-AppProductDisplayName)."
        return $false
    }
    $name = $script:AppPxeBootImageLibraryShareName
    $cred = Get-AppPxeBootSmbThrowawayCredential
    $u = $cred.User
    $p = $cred.Pass
    $rootEsc = $Root -replace "'", "'\''"

    # Fast path. The root script below re-mints the account, re-tests SMB auth and
    # removes/re-adds the share EVERY time - about 11 of the 17 seconds a Start took
    # (Craig, 2026-08-23: "IPC: StartPxeBootServices ok +17017ms SLOW", and because the
    # dispatcher is single-threaded every panel he clicked queued behind it). When the
    # share already points at this root and the account still exists, there is nothing
    # to do. Both checks are read-only and need no elevation, so a Start with
    # everything in place costs ~50 ms instead of ~11 s.
    # It is not skipped forever: the marker records when the heavy path last verified
    # this share+account, and it runs again if that is missing or older than 7 days, or
    # if either check fails.
    $markerPath = Join-Path (Get-AppPxeBootStoreRoot) 'smb-share-verified.json'
    $verifiedRecently = $false
    try {
        if (Test-Path -LiteralPath $markerPath) {
            $m = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sameShape = ([string]$m.root -eq [string]$Root) -and ([string]$m.user -eq [string]$u) -and ([string]$m.share -eq [string]$name)
            if ($sameShape -and $m.verifiedAt) {
                $verifiedRecently = ([DateTime]::UtcNow - [DateTime]::Parse([string]$m.verifiedAt).ToUniversalTime()).TotalDays -lt 7
            }
        }
    } catch { $verifiedRecently = $false }
    if ($verifiedRecently) {
        $shareOk = $false
        try {
            $listing = (& /usr/sbin/sharing -l 2>$null | Out-String)
            # sharing -l prints "name:<tab><share>" and "path:<tab><root>" per entry.
            if ($listing -match "(?m)^name:\s+$([regex]::Escape($name))\s*$") {
                foreach ($block in ($listing -split '(?m)^name:\s+')) {
                    if ($block -match "^$([regex]::Escape($name))\s") {
                        $shareOk = $block -match "(?m)^path:\s+$([regex]::Escape($Root))\s*$"
                        break
                    }
                }
            }
        } catch { $shareOk = $false }
        $userOk = $false
        try {
            $null = & dscl . -read "/Users/$u" RecordName 2>$null
            $userOk = ($LASTEXITCODE -eq 0)
        } catch { $userOk = $false }
        if ($shareOk -and $userOk) {
            Write-SidecarLogVerbose "PXE boot: Deploy`$ share and throwaway account already in place - skipping the elevated re-provision"
            return $true
        }
    }
    # PowerShell here-string: $u/$p/$name/$aa/$rootEsc interpolate; `$U etc are sh vars.
    # Verify-first, recreate-on-broken. The old re-run path (pwpolicy sethashtypes
    # + dscl -passwd on every start) was DESTRUCTIVE on macOS 26: pwpolicy silently
    # fails, the AuthenticationAuthority hash-list write does not persist, and the
    # unconditional password reset then regenerated ShadowHashData WITHOUT the
    # SMB-NT hash - killing WinPE logons that had worked since the account was
    # created (sysadminctl -addUser is the one path that reliably mints SMB-NT).
    # Field incident 2026-08-18; see AGENT_NOTES_WINPE_SMB_AUTH_MACOS.md.
    $script = @"
set -e
U='$u'
P='$p'
ROOT='$rootEsc'
SHARE='$name'
if ! id "`$U" >/dev/null 2>&1; then
  sysadminctl -addUser "`$U" -fullName "$(Get-AppProductDisplayName) imaging throwaway SMB" -password "`$P" -home /var/empty -shell /usr/bin/false
fi
dscl . -create "/Users/`$U" IsHidden 1
dscl . -create "/Users/`$U" NFSHomeDirectory /var/empty
dscl . -create "/Users/`$U" UserShell /usr/bin/false
[ -d "/Users/`$U" ] && rm -rf "/Users/`$U" || true
if ! smbutil view "//WORKGROUP;`$U:`$P@127.0.0.1" >/dev/null 2>&1; then
  # Field-proven remediation (2026-08-18, three stacked causes):
  # 1. SMB-NT hash: sysadminctl -addUser does NOT mint it on this macOS build;
  #    pwpolicy sethashtypes + a password (re)set is what lands it. No '|| true'
  #    on pwpolicy - a silent failure here was how the hash quietly vanished.
  # 2. Service ACL: when com.apple.access_smb exists, smbd rejects any account
  #    not in it ("account restrictions" in WinPE) - admit the throwaway.
  pwpolicy -u "`$U" -sethashtypes SMB-NT on
  dscl . -passwd "/Users/`$U" "`$P"
  if dscl . -read /Groups/com.apple.access_smb >/dev/null 2>&1; then
    dseditgroup -o edit -a "`$U" -t user com.apple.access_smb || true
    dsmemberutil flushcache || true
  fi
  launchctl kickstart -k system/com.apple.smbd || true
  sleep 2
  if smbutil view "//WORKGROUP;`$U:`$P@127.0.0.1" >/dev/null 2>&1; then
    echo SM_SMB_REMEDIATED
  else
    echo SM_SMB_AUTH_BROKEN
  fi
fi
launchctl kickstart -k system/com.apple.smbd || true
mkdir -p "`$ROOT"
# Always remove any existing share of this name first: /usr/sbin/sharing -e cannot
# repoint a share's path, so a stale Deploy`$ left over from an earlier (e.g.
# TCC-protected ~/Downloads) root would keep serving the wrong path and WinPE would
# fail with "network name not found". Remove + re-add guarantees the current ROOT.
/usr/sbin/sharing -r "`$SHARE" >/dev/null 2>&1 || true
/usr/sbin/sharing -a "`$ROOT" -n "`$SHARE" -S "`$SHARE" -s 001 -g 000 -R 1
echo SM_SMB_OK
"@
    # Runs as genuine root via sudo (Invoke-AppMacOsAdminShellCommand) - dscl /
    # sysadminctl / pwpolicy fail with eDSPermissionError under osascript's restricted
    # elevated context, so privileged execution must not go through AppleScript.
    $out = Invoke-AppMacOsAdminShellCommand -ShellCommand $script -AllowFailure
    if ($out -match 'SM_SMB_OK') {
        if ($out -match 'SM_SMB_REMEDIATED') {
            Write-SidecarLog "PXE boot: throwaway SMB account $u failed local auth - remediated (SMB-NT hash + service-ACL membership) and re-verified OK"
        } elseif ($out -match 'SM_SMB_AUTH_BROKEN') {
            Write-SidecarLog "PXE boot: WARNING - throwaway SMB account $u STILL fails local SMB auth after remediation; WinPE Deploy`$ mounts will fail (see AGENT_NOTES_WINPE_SMB_AUTH_MACOS.md)"
        }
        Write-SidecarLog "PXE boot: macOS SMB share $name -> $Root (read-only, guest off; auth WORKGROUP\$u)"
        try {
            (@{ root = $Root; user = $u; share = $name; verifiedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json) |
                Set-Content -LiteralPath $markerPath -Encoding UTF8
        } catch {
            Write-SidecarLogVerbose "PXE boot: could not record the SMB verification marker - $($_.Exception.Message)"
        }
        return $true
    }
    Write-SidecarLog "PXE boot: macOS SMB share provisioning did not confirm - $out"
    return $false
}

function Get-AppPxeBootImageLibraryShareUnc {
    $hostName = try { [System.Net.Dns]::GetHostName() } catch { $env:COMPUTERNAME }
    "\\$hostName\$($script:AppPxeBootImageLibraryShareName)"
}

function Get-AppPxeBootImageLibraryPlatform {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
}

function Get-AppPxeBootImageLibraryShareStatusUncached {
    $name = $script:AppPxeBootImageLibraryShareName
    $cfg = Read-AppPxeBootConfig
    $root = try { Get-AppImageLibraryRoot -NoCreate } catch { $null }
    $platform = Get-AppPxeBootImageLibraryPlatform
    $status = [ordered]@{
        enabled    = [bool]$cfg.smbShareEnabled
        shareName  = $name
        path       = $root
        unc        = Get-AppPxeBootImageLibraryShareUnc
        readOnly   = $true
        platform   = $platform
        active     = $false
        authUser   = $null
        authDomain = $null
        tccBlocked = $false
        guidance   = $null
        error      = $null
    }
    try {
        if ($platform -eq 'windows') {
            if (Test-AppSidecarCommand Get-SmbShare) {
                $share = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
                if ($share) { $status.active = $true; $status.path = [string]$share.Path }
            }
            $credsMode = Get-AppPxeBootDeployOverlayCredsMode -Cfg $cfg
            if ($credsMode -eq 'throwaway') {
                $cred = Read-AppPxeBootSmbThrowawayCred
                if ($cred -and (Test-AppPxeBootWindowsUserExists -Name $cred.User)) {
                    $status.authUser = [string]$cred.User
                    $status.authDomain = if ($env:COMPUTERNAME) { [string]$env:COMPUTERNAME } else { $null }
                }
            }
        } elseif ($platform -eq 'macos') {
            # ~/Downloads, ~/Desktop, ~/Documents are TCC-protected: smbd is denied
            # read access, so a share rooted there is created but never served. Surface
            # this loudly instead of letting WinPE fail with "network name not found".
            $tccBase = if (Test-AppSidecarCommand Get-AppMacOsTccProtectedBase) {
                Get-AppMacOsTccProtectedBase -Path $root
            } else { $null }
            # Auto-created on Start Imaging Services via /usr/sbin/sharing + a hidden
            # throwaway SMB-NT account mounted as WORKGROUP\<user>.
            $cred = Read-AppPxeBootSmbThrowawayCred
            if ($cred) { $status.authUser = $cred.User; $status.authDomain = 'WORKGROUP' }
            $status.active = Test-AppPxeBootMacOsShareActive -Name $name
            if ($tccBase) {
                $status.tccBlocked = $true
                $status.guidance = "macOS protects '$tccBase' (TCC) - smbd cannot serve $name from here, so WinPE will fail with 'network name not found'. Move the ISO & driver root out of Downloads/Desktop/Documents (e.g. ~/Public/$(Get-AppProductDisplayName)) in Settings -> Downloads, then Start Imaging Services again."
            } elseif (-not $status.active -and $status.enabled) {
                # Ticked but not published: the share was torn down (services stopped, or a
                # reboot) and nothing has re-created it. Say so - the old copy told the tech
                # to tick a box that is already ticked.
                $status.guidance = "$name is enabled but not published right now, so WinPE will fail with 'network path not found'. Start Imaging Services (or un-tick and re-tick this box) to re-create it - you will be asked for your administrator password."
            } elseif (-not $status.active) {
                $status.guidance = "Tick this box and Start Imaging Services to auto-create $name (read-only, hidden) and a throwaway SMB user. WinPE then mounts $($status.unc) as WORKGROUP\<user>."
            }
        } else {
            $status.guidance = 'Export the image library root via Samba as a read-only share.'
        }
    } catch { $status.error = $_.Exception.Message }
    $status
}

function Get-AppPxeBootImageLibraryShareStatus {
    # Shells out to `sharing -l`. Publishing or tearing down the share clears the memo.
    Get-AppPxeBootMemo -Key 'share-status' -Seconds 8 -Producer { Get-AppPxeBootImageLibraryShareStatusUncached }
}

function Ensure-AppPxeBootImageLibraryShare {
    Clear-AppPxeBootMemo -Key 'share-status'
    $name = $script:AppPxeBootImageLibraryShareName
    $root = Get-AppImageLibraryRoot
    $cfg = Read-AppPxeBootConfig
    try { New-AppImageLibraryLayout -Root $root | Out-Null } catch { }
    if ((Get-AppPxeBootImageLibraryPlatform) -eq 'windows') {
        try {
            if (-not (Get-Command New-SmbShare -ErrorAction SilentlyContinue)) {
                throw 'SMB cmdlets unavailable (Server service / LanmanServer required).'
            }
            $existing = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
            if ($existing -and ([string]$existing.Path -ne [string]$root)) {
                Remove-SmbShare -Name $name -Force -ErrorAction Stop
                $existing = $null
            }
            if (-not $existing) {
                New-SmbShare -Name $name -Path $root -ReadAccess 'Everyone' `
                    -Description "$(Get-AppProductDisplayName) imaging library (read-only)" -ErrorAction Stop | Out-Null
                Write-SidecarLog "PXE boot: SMB share $name -> $root"
            }
            $credsMode = Get-AppPxeBootDeployOverlayCredsMode -Cfg $cfg
            if ([bool]$cfg.smbOverlayEnabled -and $credsMode -eq 'throwaway') {
                $cred = Ensure-AppPxeBootWindowsSmbThrowawayCredential -Root $root
                if ($cred -and $cred.User) {
                    $account = if ($env:COMPUTERNAME) { "$($env:COMPUTERNAME)\$([string]$cred.User)" } else { [string]$cred.User }
                    Write-SidecarLog "PXE boot: Windows SMB throwaway user ready ($account)"
                }
            }
        } catch {
            Write-SidecarLog "PXE boot: SMB share ensure failed - $($_.Exception.Message)"
        }
    } elseif ((Get-AppPxeBootImageLibraryPlatform) -eq 'macos') {
        try {
            Ensure-AppPxeBootMacOsImageLibraryShare -Root $root | Out-Null
        } catch {
            Write-SidecarLog "PXE boot: macOS SMB share ensure failed - $($_.Exception.Message)"
        }
    } else {
        Write-SidecarLog "PXE boot: SMB share is manual on this OS - see Netboot panel guidance."
    }
    Get-AppPxeBootImageLibraryShareStatus
}

function Remove-AppPxeBootImageLibraryShare {
    Clear-AppPxeBootMemo -Key 'share-status'
    <#
    .SYNOPSIS
        Tear down the Deploy$ SMB share so its state follows imaging services / the SMB
        toggle (a share that lingers after Stop or after un-ticking SMB shows a stale
        "shared" badge). Best-effort and never prompts: on macOS it only acts when the
        admin password is already cached this session.
    #>
    $name = $script:AppPxeBootImageLibraryShareName
    $platform = Get-AppPxeBootImageLibraryPlatform
    try {
        if ($platform -eq 'windows') {
            if ((Test-AppSidecarCommand Get-SmbShare) -and
                (Get-SmbShare -Name $name -ErrorAction SilentlyContinue)) {
                Remove-SmbShare -Name $name -Force -ErrorAction Stop | Out-Null
                Write-SidecarLog "PXE boot: removed SMB share $name"
            }
        } elseif ($platform -eq 'macos') {
            if (-not (Test-AppPxeBootMacOsShareActive -Name $name)) { return }
            # Only act if admin creds are available WITHOUT prompting - either cached this
            # session or resolvable from the local-admin vault. We never pop a dialog just
            # to unshare; if neither source exists the share is left for the next Start /
            # explicit toggle to reconcile.
            $cached = if (Test-AppSidecarCommand Get-AppMacOsAdminCredentialCacheStatus) {
                [bool](Get-AppMacOsAdminCredentialCacheStatus).cached
            } else { $false }
            $vaultAvailable = $false
            if (-not $cached -and (Test-AppSidecarCommand Get-AppLocalMachineCredentialSecure)) {
                try { $vaultAvailable = [bool](Get-AppLocalMachineCredentialSecure) } catch { $vaultAvailable = $false }
            }
            if (-not $cached -and -not $vaultAvailable) {
                Write-SidecarLog "PXE boot: leaving $name shared (no cached/vault admin password - won't prompt just to unshare)"
                return
            }
            if (Test-AppSidecarCommand Invoke-AppMacOsAdminShellCommand) {
                $nameEsc = $name -replace "'", "'\''"
                $rm = "/usr/sbin/sharing -r '$nameEsc' >/dev/null 2>&1 || true; echo SM_SMB_REMOVED"
                $out = Invoke-AppMacOsAdminShellCommand -ShellCommand $rm -AllowFailure
                if ($out -match 'SM_SMB_REMOVED') {
                    Write-SidecarLog "PXE boot: removed macOS SMB share $name"
                }
            }
        }
    } catch {
        Write-SidecarLog "PXE boot: SMB share removal warning - $($_.Exception.Message)"
    }
}

function Test-AppPxeBootServiceStartNeedsPrompt {
    <#
    .SYNOPSIS
        $true when starting would have to put up the macOS admin password dialog.
    .NOTES
        The one reason a start cannot move to a child process: that dialog has to come
        from this process's own STA thread. Windows, Linux, and any macOS box whose
        admin credential is already in the vault or the session cache can all be
        backgrounded - which is every machine after the first successful start.
    #>
    param([switch]$HttpOnly, [switch]$Minimal)
    if (-not $IsMacOS) { return $false }
    $cfg = Read-AppPxeBootConfig
    $startTftp = -not $HttpOnly
    $needsAdmin = $startTftp -or ($cfg.smbShareEnabled -and -not $Minimal)
    if (-not $needsAdmin) { return $false }
    try {
        if ((Get-AppMacOsAdminCredentialCacheStatus).cached) { return $false }
    } catch { }
    try {
        if (Test-AppSidecarCommand Resolve-AppMacOsAdminCredentialFromVaultOrPrompt) {
            if (Resolve-AppMacOsAdminCredentialFromVaultOrPrompt) { return $false }
        }
    } catch { }
    return $true
}

function Start-AppPxeBootServices {
    param(
        [switch]$HttpOnly,
        [switch]$TftpOnly,
        # Serve files only - no Deploy$ SMB share, no ISO mounts, no menu regeneration.
        # For callers that just need the local web root (AP Converter), which must not
        # enable SMB on a machine whose owner never turned Netboot on.
        [switch]$Minimal,
        # See Start-AppPxeBootHttpServer: the parent sidecar's ingest listener port,
        # when this start runs in a child process.
        [int]$IngestPort = 0
    )
    # Whatever the badges say next must reflect what we are about to do.
    Clear-AppPxeBootMemo
    $cfg = Read-AppPxeBootConfig
    $startHttp = -not $TftpOnly
    $startTftp = -not $HttpOnly
    $errors = [System.Collections.Generic.List[string]]::new()

    $adminPrefetch = $null
    try {
        # Elevation is needed for macOS TFTP (dnsmasq) and for the macOS Deploy$ SMB
        # auto-create. Prefetch once up front so any prompt (vault-less session only)
        # happens at the start rather than mid-sequence at SMB-ensure time.
        $needsAdmin = $startTftp -or (($startHttp -or $startTftp) -and $cfg.smbShareEnabled -and -not $Minimal)
        if ($IsMacOS -and $needsAdmin -and (Test-AppSidecarCommand Start-AppMacOsAdminCredentialPrefetch)) {
            $adminPrefetch = Start-AppMacOsAdminCredentialPrefetch -Purpose 'pxe'
        }

        # The store tree may never have been provisioned (plug-in never enabled, or a
        # non-Netboot caller such as AP Converter). Sync-AppPxeBootBundledBootAssets copies
        # into <store>/tftp and <store>/http/wimboot without creating parents, so it
        # throws under $ErrorActionPreference='Stop' when those are missing.
        Ensure-AppPxeBootStoreLayoutLite | Out-Null

        Sync-AppPxeBootBundledBootAssets | Out-Null
        Sync-AppPxeBootWimBootAssets | Out-Null

        $layout = Test-AppPxeBootLayout -SkipStoreInit
        if (-not $layout.ok) {
            $layout = Test-AppPxeBootLayout
        }
        if (-not $layout.ok) {
            throw ('PXE boot: missing required files: ' + ($layout.missing -join ', '))
        }

    # Mount ISOs before the menu and before HTTP: the menu's Linux entries come from the
    # mount map, and Start-AppPxeBootHttpServer's Caddyfile picks up the per-mount
    # /iso-wim/<token> and /iso-mount/<token> routes that serve them in place (no extraction).
    if ($startHttp -and -not $Minimal) {
        try {
            Mount-AppPxeBootInstallWimIsos | Out-Null
        } catch {
            Write-SidecarLog "PXE boot: ISO mount-serve error - $($_.Exception.Message)"
        }
    }

    Write-AppPxeBootMenuFiles

    if ($startHttp) {
        try {
            Start-AppPxeBootHttpServer -HttpRoot $layout.httpRoot -Port ([int]$cfg.httpPort) -InterfaceId $cfg.interfaceId -IngestPort $IngestPort | Out-Null
        } catch {
            $msg = $_.Exception.Message
            $script:AppPxeBootState.HttpLastError = $msg
            [void]$errors.Add($msg)
        }
    }
    if ($startTftp) {
        try {
            if ($adminPrefetch -and (Test-AppSidecarCommand Complete-AppMacOsAdminCredentialPrefetch)) {
                Complete-AppMacOsAdminCredentialPrefetch -PrefetchState $adminPrefetch
                $adminPrefetch = $null
            }
            Start-AppPxeBootTftpServer `
                -TftpRoot $layout.tftpRoot `
                -InterfaceId $cfg.interfaceId `
                -Tftpd64Path $cfg.tftpd64Path `
                -Mode $cfg.tftpMode | Out-Null
        } catch {
            $msg = $_.Exception.Message
            $script:AppPxeBootState.TftpLastError = $msg
            if ($IsMacOS -and -not $script:AppPxeBootState.TftpElevatedCommand) {
                if ($msg -match 'already in use|Address already in use') {
                    $script:AppPxeBootState.TftpElevatedCommand = $null
                } else {
                    $confPath = (Get-AppPxeBootLayoutPaths).dnsmasqConf
                    $script:AppPxeBootState.TftpElevatedCommand = "sudo dnsmasq -C `"$confPath`""
                }
            }
            [void]$errors.Add($msg)
        }
    }

    # SMB comes up with imaging services for parity with HTTP/TFTP (techs shouldn't have
    # to remember a separate tick). The only hard blocker is a TCC-protected root on
    # macOS - smbd can't serve it - so skip + surface guidance there instead of creating
    # a dead share. Otherwise enable it (persist the tick) and ensure the share.
    #
    # Gated on ANY service start, not just HTTP: a full stop tears the share down, so a
    # later TFTP-only start (HTTP already serving from an earlier app session) used to
    # leave Deploy$ unpublished while the panel still showed it ticked - WinPE then fails
    # with "The network path was not found" (field, 2026-08-22).
    if ($startHttp -or $startTftp) {
        try {
            $shareStatus = Get-AppPxeBootImageLibraryShareStatus
            if ($Minimal) {
                Write-SidecarLogVerbose 'PXE boot: minimal start - skipping Deploy$ SMB share.'
            } elseif ($shareStatus.tccBlocked) {
                Write-SidecarLog "PXE boot: SMB not auto-enabled - $($shareStatus.guidance)"
            } else {
                if (-not $cfg.smbShareEnabled) {
                    $cfg = Write-AppPxeBootConfig -SmbShareEnabled $true
                }
                Ensure-AppPxeBootImageLibraryShare | Out-Null
                # First-ever start mints the throwaway cred *inside* the ensure above, after
                # boot.ipxe was already generated without the deploy overlay cred. Now
                # that the cred exists, regenerate the boot menu so the overlay initrds are
                # injected for this boot too (subsequent starts pick it up in one pass).
                Write-AppPxeBootMenuFiles
            }
        } catch {
            Write-SidecarLog "PXE boot: SMB ensure error - $($_.Exception.Message)"
        }
    }

    $status = Get-AppPxeBootStatus -SkipCatalogSync -SkipLayoutProbe -SkipHeavyChecks
    $anyRunning = [bool]$status.httpRunning -or [bool]$status.tftpRunning

    if ($startHttp -and $startTftp) {
        if (-not $anyRunning) {
            throw ($errors -join ' ')
        }
        if ($startHttp -and -not $status.httpRunning) {
            $httpHint = if (Test-AppPxeBootWanDeployMenuEnabled) {
                'snponly.efi falls back to deploy.example.com when boot.ipxe is unreachable. '
            } else {
                'Clients need HTTP for the local boot menu - enable HTTP in Netboot. '
            }
            throw ('PXE boot: HTTP did not start - ' + $httpHint + ($errors -join ' '))
        }
        if ($errors.Count -gt 0) {
            Write-SidecarLog "PXE boot: partial start - $($errors -join ' | ')"
        }
    } elseif ($errors.Count -gt 0) {
        throw $errors[0]
    }

    if ($anyRunning -and -not $script:AppPxeBootState.StartedAt) {
        $script:AppPxeBootState.StartedAt = (Get-Date).ToString('o')
    }
    $status
    } finally {
        if ($adminPrefetch -and (Test-AppSidecarCommand Stop-AppMacOsAdminCredentialPrefetch)) {
            Stop-AppMacOsAdminCredentialPrefetch -PrefetchState $adminPrefetch | Out-Null
        }
    }
}

function Open-AppPxeBootStoreFolder {
    $path = Get-AppPxeBootStoreRoot
    Initialize-AppPxeBootStore | Out-Null
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } elseif ($IsMacOS) {
        Start-Process -FilePath 'open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } else {
        Start-Process -FilePath 'xdg-open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path)) -ErrorAction SilentlyContinue
    }
    @{ opened = $true; path = $path }
}

function Reveal-AppPxeBootMacOsSmbd {
    # Open the Full Disk Access pane AND reveal /usr/sbin/smbd selected in Finder so a
    # user can drag it into the list when they insist on a TCC-protected share root
    # (Downloads/Desktop/Documents). smbd - not this app - is the process TCC blocks, so
    # this is the only way to let it serve those folders. Both opens run here in the
    # sidecar because Tauri's shell `open` scope rejects the x-apple.systempreferences:
    # URL scheme. macOS only.
    $smbd = '/usr/sbin/smbd'
    $fda = 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'
    if ($IsMacOS) {
        try {
            # Open Full Disk Access FIRST, then let System Settings settle before revealing
            # smbd - System Settings grabs focus asynchronously a beat after launch, so if
            # we reveal Finder first it gets shoved to the back. Reveal + raise Finder LAST
            # so it wins the foreground (this is what worked in early tests). Plain `open`,
            # no AppleScript needed.
            Start-Process -FilePath 'open' -ArgumentList @($fda)
            Start-Sleep -Milliseconds 700
            Start-Process -FilePath 'open' -ArgumentList @('-R', $smbd)
            Start-Process -FilePath 'open' -ArgumentList @('-a', 'Finder')
            return @{ opened = $true; path = $smbd; settings = $fda }
        } catch {
            return @{ opened = $false; path = $smbd; error = $_.Exception.Message }
        }
    }
    @{ opened = $false; path = $smbd; error = 'macOS only' }
}

function Get-AppPxeBootWimLibraryLayoutSnapshotUncached {
    $paths = Get-AppPxeBootLayoutPaths
    $cfg = Read-AppPxeBootConfig
    $wimFiles = @(Get-ChildItem -LiteralPath $paths.wimDir -Filter '*.wim' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $isoFiles = @(Get-ChildItem -LiteralPath $paths.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $defaultName = if ($cfg.defaultBootWim) { [string]$cfg.defaultBootWim } else { $null }
    @{
        ok                 = $true
        storeRoot          = $paths.storeRoot
        tftpRoot           = $paths.tftpRoot
        httpRoot           = $paths.httpRoot
        snponlyEfi         = $paths.snponlyEfi
        wimbootPath        = $paths.wimboot
        wimFiles           = @($wimFiles)
        isoFiles           = @($isoFiles)
        defaultBootWim     = $defaultName
        wims               = @(Get-AppPxeBootWimInventory)
        isos               = @(Get-AppPxeBootIsoInventory)
        localHttpOnly      = -not (Test-AppPxeBootWanDeployMenuEnabled)
        wanIsoCatalogUrl   = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        driversSummary     = $null
        missing            = @()
        warnings           = @()
    }
}

function Get-AppPxeBootWimLibraryResponse {
    param(
        [switch]$SkipStatusRefresh,
        [switch]$SkipLayoutProbe
    )

    $layout = if ($SkipLayoutProbe) { Get-AppPxeBootWimLibraryLayoutSnapshot } else { Test-AppPxeBootLayout }
    @{
        wims        = @(Get-AppPxeBootWimInventory)
        isos        = @(Get-AppPxeBootIsoInventory)
        config      = Read-AppPxeBootConfig
        layout      = $layout
        status      = if ($SkipStatusRefresh) { $null } else { Get-AppPxeBootStatus -SkipCatalogSync -Layout $layout }
    }
}

function Import-AppPxeBootWim {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetFileName,
        [switch]$ReplaceExisting
    )
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw 'PXE boot: source WIM file not found.'
    }
    $sourceItem = Get-Item -LiteralPath $SourcePath
    if ($sourceItem.Extension -notmatch '^\.wim$') {
        throw 'PXE boot: source file must be a .wim boot image.'
    }

    $paths = Initialize-AppPxeBootStore
    $targetName = if ($TargetFileName) {
        Get-AppPxeBootSafeWimFileName -FileName $TargetFileName
    } else {
        Get-AppPxeBootSafeWimFileName -FileName $sourceItem.Name
    }
    $dest = Join-Path $paths.wimDir $targetName
    if ((Test-Path -LiteralPath $dest) -and -not $ReplaceExisting) {
        throw "PXE boot: $targetName already exists."
    }

    $sizeMb = [math]::Round($sourceItem.Length / 1MB, 1)
    Write-SidecarLog "PXE boot: copying WIM $targetName (${sizeMb} MB) into store"
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force

    Complete-AppPxeBootWimImport -TargetName $targetName -Dest $dest -Paths $paths -ReplaceExisting:$ReplaceExisting
}

# Imageable / SOE WIMs (install.wim, custom SOE) - placed under the user-chosen
# ISO & driver root at <root>/WIMs/<name>.wim, served via Caddy /WIMs/* and read
# by the WinPE client from <DeployShare>\WIMs\. These are NOT boot WIMs:
# no boot-asset packaging, no default-WIM selection, no iPXE menu entry.
function Import-AppPxeBootImageableWim {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetFileName,
        [switch]$ReplaceExisting
    )
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw 'PXE boot: source WIM file not found.'
    }
    $sourceItem = Get-Item -LiteralPath $SourcePath
    if ($sourceItem.Extension -notmatch '^\.wim$') {
        throw 'PXE boot: source file must be a .wim image.'
    }

    $wimsDir = (Get-AppPxeBootLayoutPaths).imageWimsDir
    if (-not (Test-Path -LiteralPath $wimsDir)) {
        $null = New-Item -Path $wimsDir -ItemType Directory -Force
    }
    $targetName = if ($TargetFileName) {
        Get-AppPxeBootSafeWimFileName -FileName $TargetFileName
    } else {
        Get-AppPxeBootSafeWimFileName -FileName $sourceItem.Name
    }
    $dest = Join-Path $wimsDir $targetName
    if ((Test-Path -LiteralPath $dest) -and -not $ReplaceExisting) {
        throw "PXE boot: $targetName already exists in the WIMs library."
    }

    $sizeMb = [math]::Round($sourceItem.Length / 1MB, 1)
    Write-SidecarLog "PXE boot: copying imageable WIM $targetName (${sizeMb} MB) into WIMs library"
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    @{
        fileName  = $targetName
        sizeBytes = [long](Get-Item -LiteralPath $dest).Length
        path      = $dest
        httpPath  = "WIMs/$targetName"
    }
}

# Shared post-placement steps for any boot WIM landing in the store (direct import or ISO extract):
# prepare boot assets, set default when appropriate, regenerate menus, return the library response.
function Complete-AppPxeBootWimImport {
    param(
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)]$Paths,
        [switch]$ReplaceExisting
    )
    $bootAssets = $null
    try {
        $bootAssets = Ensure-AppPxeBootWimBootAssets -WimFileName $TargetName -SkipMenuRegen
    } catch {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        $stem = [IO.Path]::GetFileNameWithoutExtension($TargetName)
        $bootDir = Join-Path $Paths.httpRoot "wim-boot/$stem"
        if (Test-Path -LiteralPath $bootDir) {
            Remove-Item -LiteralPath $bootDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    $cfg = Read-AppPxeBootConfig
    $setDefault = $false
    if (-not $cfg.defaultBootWim) { $setDefault = $true }
    elseif ($ReplaceExisting -and $cfg.defaultBootWim -eq $TargetName) { $setDefault = $true }
    if ($setDefault) {
        $existing = Read-AppPxeBootConfig
        Write-AppPxeBootConfig `
            -HttpPort ([int]$existing.httpPort) `
            -InterfaceId $existing.interfaceId `
            -DeployMenuUrl $existing.deployMenuUrl `
            -Tftpd64Path $existing.tftpd64Path `
            -TftpMode $existing.tftpMode `
            -DefaultBootWim $TargetName | Out-Null
        Write-SidecarLog "PXE boot: default boot WIM set to $TargetName"
    }

    Write-AppPxeBootMenuFiles
    @{
        fileName            = $TargetName
        sizeBytes           = [long](Get-Item -LiteralPath $Dest).Length
        # Read defensively: Ensure-AppPxeBootWimBootAssets has early-return shapes without
        # these keys, and under StrictMode a bare read threw AFTER the WIM had been copied -
        # the import looked like it failed when the file was already in the library.
        bootAssetsReady     = [bool](Get-AppSidecarJsonProp -Item $bootAssets -Name 'complete')
        bootAssetsPackaged  = @(Get-AppSidecarJsonProp -Item $bootAssets -Name 'packaged')
        bootAssetsExtracted = @(Get-AppSidecarJsonProp -Item $bootAssets -Name 'extracted')
        library             = (Get-AppPxeBootWimLibraryResponse)
    }
}

function Remove-AppPxeBootWim {
    param([Parameter(Mandatory)][string]$FileName)
    $name = Get-AppPxeBootSafeWimFileName -FileName $FileName
    $paths = Get-AppPxeBootLayoutPaths
    $dest = Join-Path $paths.wimDir $name
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "PXE boot: boot WIM not found: $name"
    }
    Remove-Item -LiteralPath $dest -Force
    Write-SidecarLog "PXE boot: removed boot WIM $name"

    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $bootDir = Join-Path $paths.httpRoot "wim-boot/$stem"
    if (Test-Path -LiteralPath $bootDir) {
        Remove-Item -LiteralPath $bootDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cfg = Read-AppPxeBootConfig
    if ($cfg.defaultBootWim -eq $name) {
        $remaining = @(Get-AppPxeBootWimInventory)
        $newDefault = if ($remaining.Count -gt 0) { [string]$remaining[0].fileName } else { $null }
        $existing = Read-AppPxeBootConfig
        Write-AppPxeBootConfig `
            -HttpPort ([int]$existing.httpPort) `
            -InterfaceId $existing.interfaceId `
            -DeployMenuUrl $existing.deployMenuUrl `
            -Tftpd64Path $existing.tftpd64Path `
            -TftpMode $existing.tftpMode `
            -DefaultBootWim $newDefault | Out-Null
    }

    Write-AppPxeBootMenuFiles
    Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh -SkipLayoutProbe
}

function ConvertFrom-AppPxeBootHdiutilInfo {
    <#
    .SYNOPSIS
        `hdiutil info -plist` (as JSON) -> @( @{ imagePath; devEntry; mountPoint } ) per entity.
        Pure parse so the gate can feed it a canned record.
    #>
    param([AllowEmptyString()][string]$Json)
    # Self-contained property reads: Get-AppSidecarJsonProp lives in lib/Ipc.ps1, which
    # the sidecar loads but the gates do not - the first cut of this parser silently
    # returned nothing outside the app, so the detach it fed never happened (2026-08-23).
    $prop = {
        param($Item, [string]$Name)
        if ($null -eq $Item) { return $null }
        $p = $Item.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }
    $rows = @()
    if ([string]::IsNullOrWhiteSpace($Json)) { return $rows }
    try {
        $info = $Json | ConvertFrom-Json
        foreach ($image in @(& $prop $info 'images')) {
            $imagePath = [string](& $prop $image 'image-path')
            if (-not $imagePath) { continue }
            foreach ($entity in @(& $prop $image 'system-entities')) {
                if ($null -eq $entity) { continue }
                $rows += , @{
                    imagePath  = $imagePath
                    devEntry   = [string](& $prop $entity 'dev-entry')
                    mountPoint = [string](& $prop $entity 'mount-point')
                }
            }
        }
    } catch { }
    # Plain output: callers write @(ConvertFrom-AppPxeBootHdiutilInfo ...).
    $rows
}

function Get-AppPxeBootMacCd9660MountDevice {
    <#
    .SYNOPSIS
        The device a directory is mounted from when it is one of OUR cd9660 mounts, else $null.
    .NOTES
        `mount` prints "<dev> on <path> (cd9660, local, ...)". hdiutil reports the mount
        point too, but it never learns the filesystem, and only this path is safe to
        umount by hand.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not ($IsMacOS -or $IsDarwin)) { return $null }
    $norm = (($Path -replace '/+$', '') -replace '^/private', '')
    $lines = @()
    try { $lines = @(& mount 2>$null) } catch { $lines = @() }
    foreach ($line in $lines) {
        if ([string]$line -notmatch '^(\S+) on (.+) \((cd9660|udf)[,)]') { continue }
        $at = (($Matches[2] -replace '/+$', '') -replace '^/private', '')
        if ($at -eq $norm) { return [string]$Matches[1] }
    }
    return $null
}

function Dismount-AppPxeBootMacCd9660Path {
    <#
    .SYNOPSIS
        umount a cd9660 volume we mounted by hand, then detach its image device. $true
        when the path is no longer a cd9660 mount. No-op (and $true) for anything else.
    .NOTES
        `hdiutil detach -force` refuses ("Resource busy") while the volume is mounted -
        the kernel mount is ours, not hdiutil's. Verified 2026-09-04 on
        debian-13.6.0-amd64-netinst.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $dev = Get-AppPxeBootMacCd9660MountDevice -Path $Path
    if (-not $dev) { return $true }
    & umount $Path 2>&1 | Out-Null
    if (Get-AppPxeBootMacCd9660MountDevice -Path $Path) {
        & umount -f $Path 2>&1 | Out-Null
    }
    $gone = -not (Get-AppPxeBootMacCd9660MountDevice -Path $Path)
    if ($gone) { & hdiutil detach $dev -force 2>&1 | Out-Null }
    return $gone
}

function Mount-AppPxeBootIsoCd9660 {
    <#
    .SYNOPSIS
        Attach an ISO without letting hdiutil pick a filesystem, then mount its ISO 9660
        volume ourselves. Returns the /dev/diskN the image is attached as.
    .NOTES
        Debian's (and most distros') hybrid ISOs carry an Apple partition map for Mac
        EFI boot. hdiutil sees that map, finds a 4 MB HFS stub and nothing else it
        likes, and gives up with "no mountable file systems" - the ISO 9660 volume
        underneath is fine. -nomount attaches the raw image; mount -t cd9660 reads the
        volume the way a CD drive would. No elevation: the attach and the mount are
        both ours, and hdiutil info still reports the mount point, so the borrow logic
        (Get-AppPxeBootAttachedIsoMountPoint) sees it like any other. Verified
        2026-09-04, debian-13.6.0-amd64-netinst.
    #>
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$MountDir
    )
    $attachOut = [string](& hdiutil attach -nomount -readonly $IsoPath 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        $reason = [string](@($attachOut -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1)
        throw "PXE boot: failed to attach ISO (hdiutil -nomount: $($reason.Trim()))"
    }
    $device = $null
    foreach ($line in ($attachOut -split "`n")) {
        $first = [string](($line.Trim() -split '\s+')[0])
        if ($first -match '^/dev/disk\d+$') { $device = $first; break }
    }
    if (-not $device) { throw 'PXE boot: hdiutil attached the ISO but reported no whole-disk device.' }
    $mountOut = [string](& mount -t cd9660 -o rdonly $device $MountDir 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        & hdiutil detach $device -force 2>&1 | Out-Null
        # First use loads the cd9660 kext and says so on stderr; that line is not the error.
        $reason = [string](@($mountOut -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch 'kmutil' }) | Select-Object -Last 1)
        throw "PXE boot: failed to mount ISO 9660 volume (mount_cd9660: $($reason.Trim()))"
    }
    return $device
}

function Get-AppPxeBootAttachedIsoEntities {
    # Every hdiutil entity for this image (dev entry + mount point, either may be empty).
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not ($IsMacOS -or $IsDarwin)) { return @() }
    $full = try { (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path } catch { $IsoPath }
    $json = try { (& hdiutil info -plist 2>$null | & plutil -convert json -o - -- - 2>$null) -join '' } catch { '' }
    # -eq is case-insensitive: hdiutil reports the path as the caller typed it at attach
    # time (Public/WinDeployKit vs Public/windeploykit on this case-insensitive volume).
    @(ConvertFrom-AppPxeBootHdiutilInfo -Json $json | Where-Object { $_.imagePath -eq $full })
}

function Disconnect-AppPxeBootAttachedIso {
    <#
    .SYNOPSIS
        Detach every entity of an attached ISO and report whether it is really gone.
    .NOTES
        Detaching by mount point alone left an orphan on 2026-08-23: the detach
        failed quietly, the temp directory was removed anyway, and from then on every
        Start borrowed a mount that lived in /private/var/folders - served fine over
        HTTP, invisible on the SMB share, "Image not on the share" at the device.
        Detach by dev entry, then CHECK.
    #>
    param([Parameter(Mandatory)][string]$IsoPath)
    foreach ($e in @(Get-AppPxeBootAttachedIsoEntities -IsoPath $IsoPath)) {
        # A volume WE mounted (cd9660 path) is not hdiutil's to drop - detach fails
        # "Resource busy" until it is unmounted.
        if ($e.mountPoint) { Dismount-AppPxeBootMacCd9660Path -Path $e.mountPoint | Out-Null }
        $target = if ($e.devEntry) { $e.devEntry } else { $e.mountPoint }
        if (-not $target) { continue }
        & hdiutil detach $target -force 2>&1 | Out-Null
    }
    $left = @(Get-AppPxeBootAttachedIsoEntities -IsoPath $IsoPath)
    return ($left.Count -eq 0)
}

function Get-AppPxeBootAttachedIsoMountPoint {
    <#
    .SYNOPSIS
        Where an ISO is ALREADY attached, or $null.
    .NOTES
        Netboot attaches every ISO in the store so install.wim can be served over HTTP,
        and macOS refuses a second attach of the same image with "Resource busy". Any
        code that wants to read inside an ISO has to reuse the existing mount rather
        than assume it owns the image (field, 2026-08-22: extracting a boot WIM from an
        ISO failed with "failed to mount ISO (hdiutil)" purely because Netboot had it).
    #>
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not ($IsMacOS -or $IsDarwin)) { return $null }
    $full = try { (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path } catch { $IsoPath }
    try {
        # plutil converts the plist to JSON so this is a data read, not XML shape-guessing
        # (the first attempt walked $xml.plist.dict.array.dict and silently found nothing).
        $json = & hdiutil info -plist 2>$null | & plutil -convert json -o - -- - 2>$null
        if (-not $json) { return $null }
        $info = ($json -join '') | ConvertFrom-Json
        foreach ($image in @($info.images)) {
            $imagePath = [string]$image.'image-path'
            if (-not $imagePath -or $imagePath -ne $full) { continue }
            foreach ($entity in @($image.'system-entities')) {
                $mount = [string]$entity.'mount-point'
                if ($mount -and (Test-Path -LiteralPath $mount)) { return $mount }
            }
        }
    } catch { }
    return $null
}

function Mount-AppPxeBootIsoReadOnly {
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        # Optional explicit macOS mountpoint. Pass a path INSIDE the image-library tree
        # (.mounts/<base>) so install.wim is reachable on the Deploy$ share.
        [string]$MountPath
    )
    if ($IsMacOS -or $IsDarwin) {
        # Someone else (Netboot's mount-and-serve) may already have this image attached;
        # a second attach fails with "Resource busy". Borrow theirs, and remember not to
        # detach it when we are done.
        $existing = Get-AppPxeBootAttachedIsoMountPoint -IsoPath $IsoPath
        if ($existing) {
            $sameSpot = $MountPath -and ((($existing -replace '/+$', '') -eq ($MountPath -replace '/+$', '')) -or
                    (($existing -replace '^/private', '') -eq ($MountPath -replace '^/private', '')))
            if (-not $MountPath -or $sameSpot) {
                # Same keys as a fresh mount record: a borrowed hybrid ISO is still a cd9660
                # volume, and readers must not have to guess which shape they got.
                $borrowedDev = Get-AppPxeBootMacCd9660MountDevice -Path $existing
                return @{ platform = 'macos'; mountPath = $existing; borrowed = $true; isoPath = $IsoPath; cd9660 = [bool]$borrowedDev; device = $borrowedDev }
            }
            # A caller that needs the mount AT a specific path (mount-and-serve: inside
            # the Deploy$ share) cannot use one that lives elsewhere - SMB clients would
            # never see it. Re-home it: detach wherever it is and attach where asked.
            Write-SidecarLog "PXE boot: $([IO.Path]::GetFileName($IsoPath)) is attached at $existing, not in the share - re-homing to $MountPath"
            if (-not (Disconnect-AppPxeBootAttachedIso -IsoPath $IsoPath)) {
                throw "PXE boot: $([IO.Path]::GetFileName($IsoPath)) is attached at $existing and will not detach - close whatever is using it and Start again."
            }
        }
        $mountDir = if ($MountPath) {
            $MountPath
        } else {
            Join-Path ([IO.Path]::GetTempPath()) ("sm-pxe-iso-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        }
        if (Test-Path -LiteralPath $mountDir) {
            Dismount-AppPxeBootMacCd9660Path -Path $mountDir | Out-Null
            & hdiutil detach $mountDir -force 2>&1 | Out-Null
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -Path $mountDir -ItemType Directory -Force
        $attachOut = (& hdiutil attach -nobrowse -readonly -mountpoint $mountDir $IsoPath 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            if ($attachOut -match 'no mountable file systems') {
                # Hybrid Linux ISO (Debian and friends) - hdiutil trips over its Apple
                # partition map. Mount the ISO 9660 volume ourselves; see Mount-AppPxeBootIsoCd9660.
                try {
                    $device = Mount-AppPxeBootIsoCd9660 -IsoPath $IsoPath -MountDir $mountDir
                } catch {
                    Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
                    throw
                }
                return @{ platform = 'macos'; mountPath = $mountDir; isoPath = $IsoPath; borrowed = $false; cd9660 = $true; device = $device }
            }
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
            $reason = if ($attachOut) { ($attachOut -split "`n" | Select-Object -Last 1).Trim() } else { "exit $LASTEXITCODE" }
            throw "PXE boot: failed to mount ISO (hdiutil: $reason)"
        }
        return @{ platform = 'macos'; mountPath = $mountDir; isoPath = $IsoPath; borrowed = $false; cd9660 = $false; device = $null }
    }
    if (Get-Command -Name Mount-DiskImage -ErrorAction SilentlyContinue) {
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $letter = ($img | Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter | Select-Object -First 1
        if (-not $letter) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
            throw 'PXE boot: ISO mounted but no drive letter was assigned.'
        }
        return @{ platform = 'windows'; mountPath = "$($letter):\"; isoPath = $IsoPath; borrowed = $false; cd9660 = $false; device = $null }
    }
    throw 'PXE boot: cannot mount ISO on this platform without 7-Zip.'
}

function Dismount-AppPxeBootIso {
    param([Parameter(Mandatory)]$MountInfo)
    try {
        if ($MountInfo.platform -eq 'macos') {
            # Never tear down a mount we borrowed - Netboot is serving install.wim from it.
            if ($MountInfo.borrowed) { return }
            $gone = $false
            if ($MountInfo.isoPath) {
                $gone = Disconnect-AppPxeBootAttachedIso -IsoPath $MountInfo.isoPath
            } else {
                Dismount-AppPxeBootMacCd9660Path -Path $MountInfo.mountPath | Out-Null
                & hdiutil detach $MountInfo.mountPath -force 2>&1 | Out-Null
                $gone = -not (Test-Path -LiteralPath (Join-Path $MountInfo.mountPath 'sources'))
            }
            if ($gone) {
                Remove-Item -LiteralPath $MountInfo.mountPath -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                # Leave the directory: it is still the live mount point, and the next
                # attach will borrow it from here rather than orphan it.
                Write-SidecarLog "PXE boot: ISO still attached after detach ($($MountInfo.mountPath)) - left in place"
            }
        } elseif ($MountInfo.platform -eq 'windows') {
            # Remove the in-share junction first - Directory.Delete on a reparse point drops
            # the link only, never recursing into (and deleting) the mounted ISO contents.
            if ($MountInfo.shareMountPath -and (Test-Path -LiteralPath $MountInfo.shareMountPath)) {
                try { [System.IO.Directory]::Delete($MountInfo.shareMountPath, $false) }
                catch { Write-SidecarLog "PXE boot: junction cleanup warning - $($_.Exception.Message)" }
            }
            Dismount-DiskImage -ImagePath $MountInfo.isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-SidecarLog "PXE boot: ISO dismount warning - $($_.Exception.Message)"
    }
}

# --- Phase 4a: mount ISOs read-only and serve sources/install.wim (zero-copy) ----------
# Each library ISO is mounted read-only INSIDE the Deploy$ share at <root>/.mounts/<token>
# when imaging services start, so sources/install.wim is served two ways with no copy and
# no extraction:
#   - HTTP : Caddy handle_path /iso-wim/<token>/* -> <mount>/sources
#   - SMB  : an overlay-aware deploy client scans Z:\.mounts\*\sources\install.wim and
#            reads the REAL file straight across the sub-mount (verified working on macOS
#            smbd and Windows - DISM reads it directly).
# <token> is a deterministic, path-/Caddyfile-/URL-safe slug + 8-char hash of the ISO file
# name (Get-AppPxeBootIsoMountToken), so any number of ISOs - including ones with spaces or
# parentheses in their names - mount side by side without colliding or breaking the Caddyfile.
# The friendly ISO name is kept in a sibling <token>.name file so the WIM picker can show it.
# We previously tried symlinking a WIMs/<base>-install.wim entry to avoid putting the file
# at top level, but Apple's smbd does not emit a Windows-followable symlink (WinPE DISM
# fails error 58 even with every `fsutil SymlinkEvaluation` mode on). Mounting in-share +
# teaching the deploy client to scan the mount avoids both the symlink and any ~5 GB copy.
# Mounts are torn down on Stop.

function Resolve-AppPxeBootMountInstallWim {
    param([Parameter(Mandatory)][string]$MountPath)
    # Prefer the canonical sources/install.wim; fall back to the first install.wim found.
    $candidate = Join-Path $MountPath 'sources/install.wim'
    if (Test-Path -LiteralPath $candidate) {
        return [pscustomobject]@{ wim = $candidate; sourcesDir = (Split-Path -Parent $candidate) }
    }
    $found = Get-ChildItem -LiteralPath $MountPath -Recurse -Filter 'install.wim' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) {
        return [pscustomobject]@{ wim = $found.FullName; sourcesDir = $found.DirectoryName }
    }
    $null
}

# Linux ISOs we can boot straight off the mount. One row per layout; the first row whose
# kernel and initrd both exist wins, so the graphical Debian installer outranks the text
# one. Debian installer media are the tested rows (2026-09-04, debian-13.6.0-amd64-netinst
# in the QEMU boot test); the live row follows live-boot's documented fetch= contract but
# no live ISO has been through the VM yet. kernelArgs is emitted verbatim on the iPXE
# kernel line - ${http_base} is iPXE's variable, {token} is ours.
$script:AppPxeBootLinuxIsoLayouts = @(
    @{ id = 'debian-installer-amd64-gtk'; platform = 'debian'; arch = 'amd64'; kernel = 'install.amd/vmlinuz'; initrd = 'install.amd/gtk/initrd.gz'; suffix = 'amd64 installer';        kernelArgs = 'vga=788 --- quiet' }
    @{ id = 'debian-installer-amd64';     platform = 'debian'; arch = 'amd64'; kernel = 'install.amd/vmlinuz'; initrd = 'install.amd/initrd.gz';     suffix = 'amd64 installer (text)'; kernelArgs = 'vga=788 --- quiet' }
    @{ id = 'debian-installer-arm64-gtk'; platform = 'debian'; arch = 'arm64'; kernel = 'install.a64/vmlinuz'; initrd = 'install.a64/gtk/initrd.gz'; suffix = 'arm64 installer';        kernelArgs = '--- quiet' }
    @{ id = 'debian-installer-arm64';     platform = 'debian'; arch = 'arm64'; kernel = 'install.a64/vmlinuz'; initrd = 'install.a64/initrd.gz';     suffix = 'arm64 installer (text)'; kernelArgs = '--- quiet' }
    @{ id = 'debian-live';                platform = 'debian'; arch = '';      kernel = 'live/vmlinuz';        initrd = 'live/initrd.img';           suffix = 'live';                   kernelArgs = 'boot=live components fetch=${http_base}/iso-mount/{token}/live/filesystem.squashfs' }
    # Ubuntu 22.04+ (Subiquity): no d-i, no netboot. Canonical's PXE path is the live-server
    # ISO's own kernel + initrd with url= naming the ISO, which casper fetches whole over
    # HTTP and boots the installer from. The ISO is the install source; {isoUrl} is the
    # raw ISO Caddy already serves. Arch comes from .disk/info at resolve time.
    # cloud-config-url= is not optional: cloud-init ALSO reads a kernel `url=` as "fetch
    # this as my cloud-config", read the whole 3.4 GB ISO into memory and was OOM-killed
    # (2026-09-06). It prefers cloud-config-url= when both are present, so every Ubuntu
    # handler names one: an empty cloud-config for Interactive, the seed's user-data for
    # a task sequence (Add-AppPxeBootUbuntuAutoinstallKernelArgs replaces it).
    @{ id = 'ubuntu-live-server';         platform = 'ubuntu'; arch = '';      kernel = 'casper/vmlinuz';      initrd = 'casper/initrd';             suffix = 'installer';              kernelArgs = 'ip=dhcp url=${http_base}/{isoUrl} cloud-config-url=${http_base}/linux/ubuntu/cloud-config-none' }
)

function Get-AppPxeBootLinuxIsoLabel {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$IsoFileName,
        [string]$Suffix
    )
    # Debian media carry their own name in .disk/info, e.g.
    #   Debian GNU/Linux 13.6.0 "Trixie" - Official amd64 NETINST with firmware 20260711-09:42
    # Keep the part before ' - ' (the product), drop the quotes (iPXE's parser eats them)
    # and fall back to the file stem. Menu text is ASCII-only: iPXE draws it raw.
    $base = ''
    $infoPath = Join-Path $MountPath '.disk/info'
    if (Test-Path -LiteralPath $infoPath -PathType Leaf) {
        try {
            $info = [string](Get-Content -LiteralPath $infoPath -Raw -ErrorAction Stop)
            $firstLine = [string](@($info -split "`n") | Select-Object -First 1)
            $base = [string](@($firstLine.Trim() -split ' - ', 2) | Select-Object -First 1)
        } catch { $base = '' }
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = ([IO.Path]::GetFileNameWithoutExtension($IsoFileName) -replace '[_-]+', ' ')
    }
    $text = ("$base $Suffix" -replace '"', '')
    $text = [regex]::Replace($text, '[^\x20-\x7E]', '')
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 70) { $text = $text.Substring(0, 70).TrimEnd() }
    return $text
}

function Resolve-AppPxeBootMountLinuxBoot {
    <#
    .SYNOPSIS
        The kernel + initrd a mounted Linux ISO boots with, or $null when no layout matches.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$IsoFileName
    )
    foreach ($layout in $script:AppPxeBootLinuxIsoLayouts) {
        $kernel = Join-Path $MountPath ([string]$layout.kernel)
        $initrd = Join-Path $MountPath ([string]$layout.initrd)
        if (-not (Test-Path -LiteralPath $kernel -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath $initrd -PathType Leaf)) { continue }
        $token = Get-AppPxeBootIsoMountToken -IsoFileName $IsoFileName
        $arch = [string]$layout.arch
        $suffix = [string]$layout.suffix
        if (-not $arch) {
            # Rows that serve every arch read it off .disk/info ("... Release amd64 (...)").
            $arch = 'amd64'
            $infoPath = Join-Path $MountPath '.disk/info'
            try {
                if (Test-Path -LiteralPath $infoPath -PathType Leaf) {
                    $info = [string](Get-Content -LiteralPath $infoPath -Raw -ErrorAction Stop)
                    if ($info -match '\b(amd64|arm64)\b') { $arch = [string]$Matches[1] }
                }
            } catch { }
            $suffix = "$arch $suffix"
        }
        $isoUrl = 'iso/' + [Uri]::EscapeDataString($IsoFileName)
        return @{
            layoutId   = [string]$layout.id
            platform   = [string]$layout.platform
            arch       = $arch
            label      = (Get-AppPxeBootLinuxIsoLabel -MountPath $MountPath -IsoFileName $IsoFileName -Suffix $suffix)
            kernelRel  = [string]$layout.kernel
            initrdRel  = [string]$layout.initrd
            kernelPath = $kernel
            initrdPath = $initrd
            kernelArgs = ([string]$layout.kernelArgs).Replace('{token}', $token).Replace('{isoUrl}', $isoUrl)
            # Filled in by the mount pass: codename from the ISO's dists/ tree (Debian and
            # Ubuntu alike), netboot = the Debian companion initrd record. Same keys for
            # every layout.
            codename   = $null
            netboot    = $null
        }
    }
    return $null
}

# --- Debian installer media: the netboot initrd companion ----------------------------------
# A Debian CD/netinst initrd is the CD-ROM flavour (cdrom-detect, no net-retriever, no NIC
# modules): PXE-booted, it stops at "detect and mount installation media". Debian's answer
# is the netboot initrd from the mirror. The kernel shipped with a d-i build is the same
# file in the ISO (install.amd/vmlinuz) and on the mirror (netboot/.../linux), so hashing
# the ISO's kernel and matching it against the mirror's SHA256SUMS proves which d-i build
# the ISO came from - no version parsing, no cpio listing. Only that build's initrd.gz is
# downloaded (text ~40 MB, gtk ~85 MB), into http/linux/debian/<codename>-<arch>-<sha8>/.
# The kernel still boots off the mounted ISO and the ISO tree is the installer's mirror.

$script:AppPxeBootDebianMirrorBaseDefault = 'https://deb.debian.org/debian'

function Get-AppPxeBootDebianMirrorBase {
    if ($env:APP_DEBIAN_MIRROR -and -not [string]::IsNullOrWhiteSpace($env:APP_DEBIAN_MIRROR)) {
        return ([string]$env:APP_DEBIAN_MIRROR).Trim().TrimEnd('/')
    }
    return $script:AppPxeBootDebianMirrorBaseDefault
}

function Get-AppPxeBootDebianNetbootRoot {
    $paths = Get-AppPxeBootLayoutPaths
    return (Join-Path $paths.httpRoot 'linux/debian')
}

function Get-AppPxeBootDebianCodename {
    # dists/<codename>/Release carries "Codename: trixie". CD trees also have a
    # stable -> trixie symlink; the real directory is the one whose Release names itself.
    param([Parameter(Mandatory)][string]$MountPath)
    $dists = Join-Path $MountPath 'dists'
    if (-not (Test-Path -LiteralPath $dists -PathType Container)) { return $null }
    foreach ($dir in @(Get-ChildItem -LiteralPath $dists -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $release = Join-Path $dir.FullName 'Release'
        if (-not (Test-Path -LiteralPath $release -PathType Leaf)) { continue }
        try {
            foreach ($line in @(Get-Content -LiteralPath $release -ErrorAction Stop | Select-Object -First 20)) {
                if ([string]$line -match '^Codename:\s*(\S+)') {
                    $codename = [string]$Matches[1]
                    if ($codename -eq $dir.Name) { return $codename }
                }
            }
        } catch { }
    }
    return $null
}

function Get-AppPxeBootHttpTextContent {
    # Invoke-WebRequest hands back a byte[] for anything the server does not call text
    # (deb.debian.org serves SHA256SUMS as octet-stream) - [string] of that is "1 2 3",
    # not the file. Decode it ourselves.
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 30)
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    $content = $resp.Content
    if ($content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

function Get-AppPxeBootDebianInstallerBuildDirs {
    # The d-i builds a mirror keeps for a suite: the dated directories (20250803+deb13u6,
    # 20250803, ...) newest first, then current. An older ISO matches an older build.
    param([Parameter(Mandatory)][string]$IndexUrl)
    $dirs = [System.Collections.Generic.List[string]]::new()
    try {
        $html = Get-AppPxeBootHttpTextContent -Url $IndexUrl
        foreach ($m in [regex]::Matches($html, 'href="(\d{8}[^"/]*)/"')) {
            $name = [string]$m.Groups[1].Value
            if (-not $dirs.Contains($name)) { [void]$dirs.Add($name) }
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: d-i build index unavailable ($IndexUrl) - $($_.Exception.Message)"
    }
    # Dated builds first (newest first) so the manifest records a real build name;
    # 'current' last as the fallback when the index could not be read.
    $sorted = @($dirs | Sort-Object -Descending)
    return $sorted + @('current')
}

function Read-AppPxeBootDebianSha256Sums {
    # "<sha256>  ./netboot/gtk/debian-installer/amd64/initrd.gz" -> @{ './...' = sha }
    param([Parameter(Mandatory)][string]$Url)
    $map = @{}
    $text = Get-AppPxeBootHttpTextContent -Url $Url
    foreach ($line in ($text -split "`n")) {
        if ([string]$line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$') {
            $map[[string]$Matches[2]] = ([string]$Matches[1]).ToLowerInvariant()
        }
    }
    return $map
}

# --- ISO-less Debian: netboot pairs kept in the store --------------------------------------
# Craig, 2026-09-05: "drop the premise - the ISOs are freely available, I prefer that to
# having yet another ISO on the laptop, and it is always up to date." A Debian install
# then needs only the mirror's netboot kernel + initrd (~95 MB per release x arch); the
# mirror supplies drivers and packages at install time. http/linux/debian/<codename>-<arch>/
# holds {linux, initrd.gz, manifest.json}, and the menu offers one entry per pair - with
# the task-sequence submenu, exactly like an ISO-backed entry. Nothing here touches ISOs.

# kind 'netboot': Debian's kernel + initrd pair from the mirror (no ISO). kind 'iso': the
# distro's installer IS its ISO (Ubuntu 22.04+); Add downloads it from the release index
# into the library through Transfers, and it is then mounted and booted like any Linux ISO.
$script:AppPxeBootDebianNetbootCatalog = @(
    @{ platform = 'debian'; kind = 'netboot'; codename = 'trixie';   arch = 'amd64'; label = 'Debian 13 (trixie)' }
    @{ platform = 'debian'; kind = 'netboot'; codename = 'trixie';   arch = 'arm64'; label = 'Debian 13 (trixie)' }
    @{ platform = 'debian'; kind = 'netboot'; codename = 'bookworm'; arch = 'amd64'; label = 'Debian 12 (bookworm)' }
    @{ platform = 'debian'; kind = 'netboot'; codename = 'bookworm'; arch = 'arm64'; label = 'Debian 12 (bookworm)' }
    @{ platform = 'ubuntu'; kind = 'iso'; codename = 'noble'; arch = 'amd64'; label = 'Ubuntu 24.04 LTS Server';
       index = 'https://releases.ubuntu.com/24.04/'; isoPattern = 'ubuntu-24\.04(\.\d+)?-live-server-amd64\.iso' }
    @{ platform = 'ubuntu'; kind = 'iso'; codename = 'jammy'; arch = 'amd64'; label = 'Ubuntu 22.04 LTS Server';
       index = 'https://releases.ubuntu.com/22.04/'; isoPattern = 'ubuntu-22\.04(\.\d+)?-live-server-amd64\.iso' }
)

function Get-AppPxeBootLinuxCatalogRow {
    param([Parameter(Mandatory)][string]$Id)
    foreach ($row in $script:AppPxeBootDebianNetbootCatalog) {
        if ("$([string]$row.platform)-$([string]$row.codename)-$([string]$row.arch)" -eq $Id.Trim().ToLowerInvariant()) { return $row }
    }
    return $null
}

function Get-AppPxeBootLinuxCatalogIsoInLibrary {
    # The library ISO a kind='iso' catalog row is satisfied by, or $null.
    param([Parameter(Mandatory)]$Row)
    $paths = Get-AppPxeBootLayoutPaths
    if (-not (Test-Path -LiteralPath $paths.isoDir -PathType Container)) { return $null }
    $rx = '^' + [string]$Row.isoPattern + '$'
    foreach ($f in @(Get-ChildItem -LiteralPath $paths.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if ($f.Name -match $rx) { return $f }
    }
    return $null
}

function Start-AppPxeBootLinuxIsoDownload {
    <#
    .SYNOPSIS
        Queue a catalog row's current ISO (resolved from its release index, SHA256 from the
        index's SHA256SUMS) into the library over the aria2 direct rail - Transfers shows
        the progress, and the finished file is promoted into iso/ like any other ISO.
    #>
    param([Parameter(Mandatory)]$Row)
    if (-not (Test-AppSidecarCommand Add-AppAria2DirectHttpDownload)) {
        throw 'PXE boot: the download service (aria2 integration) is not loaded.'
    }
    $index = [string]$Row.index
    $html = Get-AppPxeBootHttpTextContent -Url $index
    $m = [regex]::Match($html, [string]$Row.isoPattern)
    if (-not $m.Success) { throw "PXE boot: no ISO matching $($Row.label) $($Row.arch) at $index" }
    $name = $m.Value
    $sha = ''
    try {
        $sums = Get-AppPxeBootHttpTextContent -Url ($index + 'SHA256SUMS')
        foreach ($line in ($sums -split "`n")) {
            if ($line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$' -and [string]$Matches[2] -eq $name) { $sha = ([string]$Matches[1]).ToLowerInvariant() }
        }
    } catch { $sha = '' }
    Write-SidecarLog "PXE boot: queueing $name from $index (sha256 $(if ($sha) { 'verified on arrival' } else { 'not published' }))"
    $args = @{
        Uris         = @($index + $name)
        AssetKind    = 'iso'
        FileNameHint = $name
        ProgressKey  = "linux|$([string]$Row.platform)-$([string]$Row.codename)-$([string]$Row.arch)"
        TimeoutSec   = 21600
    }
    if ($sha) { $args.ExpectedHash = $sha; $args.ExpectedHashAlgorithm = 'sha-256' }
    $queued = Add-AppAria2DirectHttpDownload @args
    return @{ fileName = $name; sha256 = $sha; download = $queued }
}

function Add-AppPxeBootLinuxInstaller {
    param([Parameter(Mandatory)][string]$Id)
    $row = Get-AppPxeBootLinuxCatalogRow -Id $Id
    if (-not $row) { throw "PXE boot: '$Id' is not a Linux installer this app offers." }
    if ([string]$row.kind -eq 'iso') {
        $have = Get-AppPxeBootLinuxCatalogIsoInLibrary -Row $row
        if ($have) { return @{ updated = $false; queued = $false; fileName = $have.Name } }
        $r = Start-AppPxeBootLinuxIsoDownload -Row $row
        return @{ updated = $false; queued = $true; fileName = [string]$r.fileName }
    }
    $r = Add-AppPxeBootDebianNetboot -Codename ([string]$row.codename) -Arch ([string]$row.arch)
    return @{ updated = [bool]$r.updated; queued = $false; fileName = '' }
}

function Remove-AppPxeBootLinuxInstaller {
    param([Parameter(Mandatory)][string]$Id)
    $row = Get-AppPxeBootLinuxCatalogRow -Id $Id
    if (-not $row) { throw "PXE boot: '$Id' is not a Linux installer this app offers." }
    if ([string]$row.kind -eq 'iso') {
        $have = Get-AppPxeBootLinuxCatalogIsoInLibrary -Row $row
        if ($have) { Remove-AppPxeBootIso -FileName $have.Name | Out-Null }
        return @{ removed = [bool]$have }
    }
    return (Remove-AppPxeBootDebianNetboot -Codename ([string]$row.codename) -Arch ([string]$row.arch))
}

function Get-AppPxeBootDebianReleaseLabel {
    param([Parameter(Mandatory)][string]$Codename)
    foreach ($row in $script:AppPxeBootDebianNetbootCatalog) {
        if ([string]$row.codename -eq $Codename) { return [string]$row.label }
    }
    return "Debian $Codename"
}

function Test-AppPxeBootDebianNetbootPairName {
    param([string]$Codename, [string]$Arch)
    return (([string]$Codename) -match '^[a-z]{3,20}$') -and (([string]$Arch) -in @('amd64', 'arm64'))
}

function Read-AppPxeBootDebianNetbootPair {
    <#
    .SYNOPSIS
        A store pair as a record, or $null when the directory is not a complete pair
        (both files and the manifest, or it is not offered).
    #>
    param([Parameter(Mandatory)][string]$DirName)
    if ($DirName -notmatch '^([a-z]{3,20})-(amd64|arm64)$') { return $null }
    $codename = [string]$Matches[1]
    $arch = [string]$Matches[2]
    $dir = Join-Path (Get-AppPxeBootDebianNetbootRoot) $DirName
    $linux = Join-Path $dir 'linux'
    $initrd = Join-Path $dir 'initrd.gz'
    $manifestPath = Join-Path $dir 'manifest.json'
    foreach ($f in @($linux, $initrd, $manifestPath)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    }
    $diVersion = ''
    $fetchedAt = ''
    $flavour = ''
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        if ($m.ContainsKey('diVersion')) { $diVersion = [string]$m['diVersion'] }
        if ($m.ContainsKey('fetchedAt')) { $fetchedAt = [string]$m['fetchedAt'] }
        if ($m.ContainsKey('flavour')) { $flavour = [string]$m['flavour'] }
    } catch { return $null }
    $size = [long](Get-Item -LiteralPath $linux).Length + [long](Get-Item -LiteralPath $initrd).Length
    @{
        dirName       = $DirName
        codename      = $codename
        arch          = $arch
        diVersion     = $diVersion
        flavour       = $flavour
        fetchedAt     = $fetchedAt
        sizeBytes     = $size
        linuxHttpRel  = "linux/debian/$DirName/linux"
        initrdHttpRel = "linux/debian/$DirName/initrd.gz"
    }
}

function Get-AppPxeBootDebianNetbootPairs {
    # Every complete pair in the store, in name order. Live state: the directory listing.
    $root = Get-AppPxeBootDebianNetbootRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $pair = Read-AppPxeBootDebianNetbootPair -DirName $dir.Name
        if ($pair) { $pairs.Add($pair) | Out-Null }
    }
    return $pairs.ToArray()
}

function Get-AppPxeBootDebianNetbootCatalogStatus {
    # The catalog joined with the store and the library: what the panel lists, with the
    # Add / Remove state. Debian rows are ready when their netboot pair is in the store,
    # Ubuntu rows when their ISO is in the library.
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($cat in $script:AppPxeBootDebianNetbootCatalog) {
        $platform = [string]$cat.platform
        $codename = [string]$cat.codename
        $arch = [string]$cat.arch
        $kind = [string]$cat.kind
        $row = @{
            id            = "$platform-$codename-$arch"
            platform      = $platform
            kind          = $kind
            codename      = $codename
            arch          = $arch
            label         = [string]$cat.label
            ready         = $false
            diVersion     = $null
            fetchedAt     = $null
            sizeBytes     = [long]0
            kernelHttpRel = $null
            initrdHttpRel = $null
            isoFileName   = $null
        }
        if ($kind -eq 'iso') {
            $iso = Get-AppPxeBootLinuxCatalogIsoInLibrary -Row $cat
            if ($iso) {
                $row.ready = $true
                $row.isoFileName = $iso.Name
                $row.sizeBytes = [long]$iso.Length
                $row.fetchedAt = $iso.LastWriteTimeUtc.ToString('o')
            }
        } else {
            $pair = Read-AppPxeBootDebianNetbootPair -DirName "$codename-$arch"
            if ($pair) {
                $row.ready = $true
                $row.diVersion = [string]$pair.diVersion
                $row.fetchedAt = [string]$pair.fetchedAt
                $row.sizeBytes = [long]$pair.sizeBytes
                $row.kernelHttpRel = [string]$pair.linuxHttpRel
                $row.initrdHttpRel = [string]$pair.initrdHttpRel
            }
        }
        $rows.Add($row) | Out-Null
    }
    return $rows.ToArray()
}

function Add-AppPxeBootDebianNetboot {
    <#
    .SYNOPSIS
        Fetch (or refresh) the current netboot kernel + initrd for one release x arch
        into the store, verified against the mirror's SHA256SUMS, then regenerate the
        menu. Already current = nothing downloaded.
    #>
    param(
        [Parameter(Mandatory)][string]$Codename,
        [Parameter(Mandatory)][string]$Arch,
        [ValidateSet('text', 'gtk')][string]$Flavour = 'gtk'
    )
    $Codename = $Codename.Trim().ToLowerInvariant()
    $Arch = $Arch.Trim().ToLowerInvariant()
    if (-not (Test-AppPxeBootDebianNetbootPairName -Codename $Codename -Arch $Arch)) {
        throw "PXE boot: '$Codename $Arch' is not a Debian release/arch this app offers."
    }
    $mirror = Get-AppPxeBootDebianMirrorBase
    $suiteBase = "$mirror/dists/$Codename/main/installer-$Arch"
    $rel = if ($Flavour -eq 'gtk') { "netboot/gtk/debian-installer/$Arch" } else { "netboot/debian-installer/$Arch" }
    $sums = Read-AppPxeBootDebianSha256Sums -Url "$suiteBase/current/images/SHA256SUMS"
    $linuxKey = "./$rel/linux"
    $initrdKey = "./$rel/initrd.gz"
    if (-not $sums.ContainsKey($linuxKey) -or -not $sums.ContainsKey($initrdKey)) {
        throw "PXE boot: the mirror has no $Flavour netboot images for $Codename $Arch."
    }
    $dirName = "$Codename-$Arch"
    $dir = Join-Path (Get-AppPxeBootDebianNetbootRoot) $dirName
    $manifestPath = Join-Path $dir 'manifest.json'
    $existing = Read-AppPxeBootDebianNetbootPair -DirName $dirName
    if ($existing) {
        $have = $null
        try { $have = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $have = $null }
        if ($have -and $have.ContainsKey('linuxSha256') -and $have.ContainsKey('initrdSha256') -and
            ([string]$have['linuxSha256'] -eq [string]$sums[$linuxKey]) -and ([string]$have['initrdSha256'] -eq [string]$sums[$initrdKey])) {
            Write-SidecarLog "PXE boot: Debian netboot $Codename $Arch is current (d-i $([string]$existing.diVersion))"
            return @{ updated = $false; pair = $existing }
        }
    }
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    # The dated build name, for the label: the newest dated directory whose linux hash
    # is the one current points at. Falls back to 'current' when the index is unreadable.
    $diVersion = 'current'
    foreach ($build in @(Get-AppPxeBootDebianInstallerBuildDirs -IndexUrl "$suiteBase/")) {
        if ($build -eq 'current') { continue }
        try {
            $s = Read-AppPxeBootDebianSha256Sums -Url "$suiteBase/$build/images/SHA256SUMS"
            if ($s.ContainsKey($linuxKey) -and ([string]$s[$linuxKey] -eq [string]$sums[$linuxKey])) { $diVersion = $build; break }
        } catch { }
    }
    $got = @{}
    foreach ($name in @('linux', 'initrd.gz')) {
        $key = if ($name -eq 'linux') { $linuxKey } else { $initrdKey }
        $url = "$suiteBase/current/images/$rel/$name"
        $tmp = Join-Path $dir "$name.part"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-SidecarLog "PXE boot: fetching Debian netboot $name ($Codename $Arch $Flavour, d-i $diVersion) from $url"
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne [string]$sums[$key]) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            throw "PXE boot: downloaded $name failed SHA256 verification ($Codename $Arch)."
        }
        $got[$name] = @{ tmp = $tmp; sha = $hash }
    }
    foreach ($name in @('linux', 'initrd.gz')) {
        Move-Item -LiteralPath $got[$name].tmp -Destination (Join-Path $dir $name) -Force
    }
    $manifest = @{
        codename     = $Codename
        arch         = $Arch
        flavour      = $Flavour
        diVersion    = $diVersion
        linuxSha256  = $got['linux'].sha
        initrdSha256 = $got['initrd.gz'].sha
        source       = "$suiteBase/current/images/$rel/"
        fetchedAt    = (Get-Date).ToUniversalTime().ToString('o')
    }
    ($manifest | ConvertTo-Json) | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Force
    $pair = Read-AppPxeBootDebianNetbootPair -DirName $dirName
    Write-SidecarLog "PXE boot: Debian netboot $Codename $Arch ready (d-i $diVersion, $([math]::Round($pair.sizeBytes / 1MB, 1)) MB)"
    Write-AppPxeBootMenuFiles
    return @{ updated = $true; pair = $pair }
}

function Remove-AppPxeBootDebianNetboot {
    param(
        [Parameter(Mandatory)][string]$Codename,
        [Parameter(Mandatory)][string]$Arch
    )
    $Codename = $Codename.Trim().ToLowerInvariant()
    $Arch = $Arch.Trim().ToLowerInvariant()
    if (-not (Test-AppPxeBootDebianNetbootPairName -Codename $Codename -Arch $Arch)) {
        throw "PXE boot: '$Codename $Arch' is not a Debian netboot pair name."
    }
    $dir = Join-Path (Get-AppPxeBootDebianNetbootRoot) "$Codename-$Arch"
    if (Test-Path -LiteralPath $dir -PathType Container) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-SidecarLog "PXE boot: removed Debian netboot $Codename $Arch"
    }
    Write-AppPxeBootMenuFiles
    return @{ removed = $true }
}

function Ensure-AppPxeBootDebianNetbootInitrd {
    <#
    .SYNOPSIS
        The netboot initrd record for a Debian installer ISO: @{ ready; httpRel; dirName;
        diVersion; reason }. Downloads it once per d-i build, verified against the mirror's
        SHA256SUMS. A failed attempt is remembered for 10 minutes so an offline laptop pays
        one DNS timeout per Start, not one per menu regen.
    #>
    param(
        [string]$Codename,
        [Parameter(Mandatory)][string]$Arch,
        [Parameter(Mandatory)][string]$KernelPath,
        [ValidateSet('text', 'gtk')][string]$Flavour = 'gtk'
    )
    $none = @{ ready = $false; httpRel = ''; dirName = ''; diVersion = ''; reason = '' }
    if ([string]::IsNullOrWhiteSpace($Codename)) { $none.reason = 'ISO has no dists/<codename>/Release'; return $none }
    if (-not (Test-Path -LiteralPath $KernelPath -PathType Leaf)) { $none.reason = 'kernel not readable on the mount'; return $none }
    $kernelSha = (Get-FileHash -LiteralPath $KernelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dirName = "$Codename-$Arch-$($kernelSha.Substring(0, 8))"
    $root = Get-AppPxeBootDebianNetbootRoot
    $dir = Join-Path $root $dirName
    $initrd = Join-Path $dir 'initrd.gz'
    $manifestPath = Join-Path $dir 'manifest.json'
    $httpRel = "linux/debian/$dirName/initrd.gz"

    if ((Test-Path -LiteralPath $initrd -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $diVersion = ''
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            if ($manifest.ContainsKey('diVersion')) { $diVersion = [string]$manifest['diVersion'] }
        } catch { }
        return @{ ready = $true; httpRel = $httpRel; dirName = $dirName; diVersion = $diVersion; reason = '' }
    }

    $memoKey = "debian-netboot:$dirName"
    $attempt = $script:AppPxeBootMemo[$memoKey]
    if ($attempt -and ([DateTime]::UtcNow - $attempt.at).TotalSeconds -lt 600) {
        $none.reason = [string]$attempt.value
        return $none
    }

    $reason = ''
    try {
        $mirror = Get-AppPxeBootDebianMirrorBase
        $suiteBase = "$mirror/dists/$Codename/main/installer-$Arch"
        $rel = if ($Flavour -eq 'gtk') { "netboot/gtk/debian-installer/$Arch" } else { "netboot/debian-installer/$Arch" }
        $tried = 0
        foreach ($build in @(Get-AppPxeBootDebianInstallerBuildDirs -IndexUrl "$suiteBase/")) {
            $sums = $null
            try { $sums = Read-AppPxeBootDebianSha256Sums -Url "$suiteBase/$build/images/SHA256SUMS" } catch {
                Write-SidecarLogVerbose "PXE boot: no SHA256SUMS for d-i build $build - $($_.Exception.Message)"
                continue
            }
            $tried++
            $linuxKey = "./$rel/linux"
            $initrdKey = "./$rel/initrd.gz"
            if (-not $sums.ContainsKey($linuxKey) -or -not $sums.ContainsKey($initrdKey)) { continue }
            if ([string]$sums[$linuxKey] -ne $kernelSha) { continue }

            $url = "$suiteBase/$build/images/$rel/initrd.gz"
            if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
            $tmp = Join-Path $dir 'initrd.gz.part'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Write-SidecarLog "PXE boot: fetching Debian netboot initrd ($Codename $Arch $Flavour, d-i build $build) from $url"
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
            $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($got -ne [string]$sums[$initrdKey]) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                throw "downloaded initrd.gz failed SHA256 verification (build $build)"
            }
            Move-Item -LiteralPath $tmp -Destination $initrd -Force
            $manifest = @{
                codename     = $Codename
                arch         = $Arch
                flavour      = $Flavour
                diVersion    = $build
                kernelSha256 = $kernelSha
                initrdSha256 = $got
                source       = $url
                fetchedAt    = (Get-Date).ToUniversalTime().ToString('o')
            }
            ($manifest | ConvertTo-Json) | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Force
            $sizeMb = [math]::Round((Get-Item -LiteralPath $initrd).Length / 1MB, 1)
            Write-SidecarLog "PXE boot: Debian netboot initrd ready - $httpRel ($sizeMb MB, d-i $build)"
            return @{ ready = $true; httpRel = $httpRel; dirName = $dirName; diVersion = $build; reason = '' }
        }
        $reason = if ($tried -eq 0) { "mirror unreachable ($mirror)" } else { "no d-i build on the mirror matches this ISO's kernel ($tried checked)" }
    } catch {
        $reason = $_.Exception.Message
    }
    $script:AppPxeBootMemo[$memoKey] = @{ at = [DateTime]::UtcNow; value = $reason }
    $none.reason = $reason
    return $none
}

function Clear-AppPxeBootStaleIsoMountDirs {
    param([Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$LiveTokens)
    # Migration + housekeeping sweep. The ONLY directories that belong under .mounts are the
    # current ISO tokens (<slug>-<hash>). Anything else is debris: a legacy pre-token mount
    # named after the raw ISO base (e.g. ".mounts/Windows 11"), an ISO that has since left the
    # library, or a crash leftover. Detach (macOS) / drop the junction (Windows) and delete the
    # now-empty dir so they neither accumulate nor get scanned by the deploy client. Runs on every
    # Start; the first run after upgrade clears the old base-named mounts, then it no-ops.
    $paths = Get-AppPxeBootLayoutPaths
    $mountsRoot = $paths.isoMountDir
    if (-not (Test-Path -LiteralPath $mountsRoot)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $mountsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($LiveTokens.Contains($dir.Name)) { continue }
        try {
            if ($IsMacOS -or $IsDarwin) {
                Dismount-AppPxeBootMacCd9660Path -Path $dir.FullName | Out-Null
                & hdiutil detach $dir.FullName -force 2>&1 | Out-Null
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                # Windows: a live mount is a junction (reparse point) - delete the link only so
                # we never recurse into and wipe the mounted ISO contents. Plain leftover dirs
                # (empty) are removed outright.
                $isReparse = $false
                try {
                    $attrs = (Get-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop).Attributes
                    $isReparse = [bool]($attrs -band [IO.FileAttributes]::ReparsePoint)
                } catch { }
                if ($isReparse) {
                    [System.IO.Directory]::Delete($dir.FullName, $false)
                } else {
                    Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-SidecarLog "PXE boot: cleaned stale .mounts entry '$($dir.Name)' (legacy/removed ISO)"
        } catch {
            Write-SidecarLog "PXE boot: could not clean stale .mounts entry '$($dir.Name)' - $($_.Exception.Message)"
        }
    }
}

function Mount-AppPxeBootInstallWimIsos {
    <#
    .SYNOPSIS
        Mount every library ISO read-only inside the Deploy$ share (.mounts/<token>) and
        register its sources/install.wim for in-place HTTP + SMB serving (zero-copy). The
        an overlay-aware deploy client scans Z:\.mounts\*\sources\install.wim. Idempotent.
    .NOTES
        Each ISO gets a deterministic, path-/Caddyfile-/URL-safe mount token
        (Get-AppPxeBootIsoMountToken) so multiple - and awkwardly named - ISOs never collide.
        The friendly ISO name is written alongside the mount as <token>.name so the WIM picker
        can show it instead of the slugged folder.
    #>
    $result = [System.Collections.Generic.List[object]]::new()
    $paths = Get-AppPxeBootLayoutPaths
    $isoDir = $paths.isoDir
    if (-not (Test-Path -LiteralPath $isoDir)) { return @() }

    $isoFiles = @(Get-ChildItem -LiteralPath $isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $live = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($iso in $isoFiles) {
        $displayName = [IO.Path]::GetFileNameWithoutExtension($iso.Name)
        $token = Get-AppPxeBootIsoMountToken -IsoFileName $iso.Name
        [void]$live.Add($token)
        $existing = $script:AppPxeBootState.IsoMounts[$token]
        if ($existing -and $existing.livePath -and (Test-Path -LiteralPath $existing.livePath)) {
            $result.Add($existing) | Out-Null
            continue
        }
        try {
            Write-SidecarLog "PXE boot: mounting ISO $($iso.Name) (read-only) to serve its boot files in place"
            # Expose the mount INSIDE the Deploy$ share at .mounts/<token> so SMB clients -
            # and an overlay-aware deploy client's scan of Z:\.mounts\*\sources\install.wim -
            # read the real file across the sub-mount.
            #   macOS  : hdiutil mounts directly at .mounts/<token>.
            #   Windows: Mount-DiskImage gives a drive letter, so we junction
            #            .mounts/<token> -> <letter>:\ (junctions are resolved server-side and
            #            served transparently over SMB, unlike symlinks).
            $mountArgs = @{ IsoPath = $iso.FullName }
            if ($IsMacOS -or $IsDarwin) {
                if (-not (Test-Path -LiteralPath $paths.isoMountDir)) {
                    $null = New-Item -Path $paths.isoMountDir -ItemType Directory -Force
                }
                $mountArgs.MountPath = Join-Path $paths.isoMountDir $token
            }
            $mountInfo = Mount-AppPxeBootIsoReadOnly @mountArgs
            if ($mountInfo.platform -eq 'windows') {
                try {
                    if (-not (Test-Path -LiteralPath $paths.isoMountDir)) {
                        $null = New-Item -Path $paths.isoMountDir -ItemType Directory -Force
                    }
                    $junction = Join-Path $paths.isoMountDir $token
                    if (Test-Path -LiteralPath $junction) {
                        [System.IO.Directory]::Delete($junction, $false)
                    }
                    $null = New-Item -ItemType Junction -Path $junction -Target $mountInfo.mountPath -ErrorAction Stop
                    $mountInfo.shareMountPath = $junction
                } catch {
                    Write-SidecarLog "PXE boot: could not junction $token into .mounts ($($_.Exception.Message)); SMB install.wim serving unavailable for this ISO"
                }
            }
            $resolved = Resolve-AppPxeBootMountInstallWim -MountPath $mountInfo.mountPath
            $linuxBoot = $null
            if (-not $resolved) {
                # Not Windows media. A Linux ISO earns its mount the same way: kernel and
                # initrd served in place, straight off the ISO 9660 volume.
                $linuxBoot = Resolve-AppPxeBootMountLinuxBoot -MountPath $mountInfo.mountPath -IsoFileName $iso.Name
                if ($linuxBoot) { $linuxBoot.codename = Get-AppPxeBootDebianCodename -MountPath $mountInfo.mountPath }
                if ($linuxBoot -and ([string]$linuxBoot.layoutId) -like 'debian-installer-*') {
                    # Installer media: make sure the matching netboot initrd is in the store
                    # (one download per Debian build; the ISO's own initrd cannot install).
                    $flavour = if (([string]$linuxBoot.layoutId) -like '*-gtk') { 'gtk' } else { 'text' }
                    try {
                        $linuxBoot.netboot = Ensure-AppPxeBootDebianNetbootInitrd -Codename ([string]$linuxBoot.codename) -Arch ([string]$linuxBoot.arch) -KernelPath ([string]$linuxBoot.kernelPath) -Flavour $flavour
                    } catch {
                        $linuxBoot.netboot = @{ ready = $false; httpRel = ''; dirName = ''; diVersion = ''; reason = $_.Exception.Message }
                    }
                    if ($linuxBoot.netboot.ready) {
                        Write-SidecarLog "PXE boot: $($iso.Name) installs from the mounted ISO via netboot initrd d-i $($linuxBoot.netboot.diVersion) ($($linuxBoot.netboot.httpRel))"
                    } else {
                        Write-SidecarLog "PXE boot: $($iso.Name) boots to the installer only - netboot initrd not available ($($linuxBoot.netboot.reason))"
                    }
                }
            }
            if (-not $resolved -and -not $linuxBoot) {
                Write-SidecarLog "PXE boot: $($iso.Name) has no install.wim and no recognised Linux boot layout - dismounting"
                Dismount-AppPxeBootIso -MountInfo $mountInfo
                continue
            }
            # Persist the friendly name next to the mount so an overlay-aware deploy client
            # WIM picker can label the install.wim with the real ISO name, not the slug token.
            try {
                $nameFile = (Join-Path $paths.isoMountDir $token) + '.name'
                Set-Content -LiteralPath $nameFile -Value $displayName -Encoding UTF8 -NoNewline -ErrorAction Stop
            } catch {
                Write-SidecarLog "PXE boot: could not write mount label for $token ($($_.Exception.Message))"
            }
            # One shape for both kinds - every consumer reads the same keys, and under
            # StrictMode a missing key is a throw, not a $null. livePath is the file whose
            # disappearance means the mount is gone (install.wim, or the Linux kernel).
            $entry = @{
                kind        = if ($resolved) { 'windows' } else { 'linux' }
                isoFileName = $iso.Name
                isoPath     = $iso.FullName
                base        = $token
                displayName = $displayName
                mountInfo   = $mountInfo
                mountRoot   = [string]$mountInfo.mountPath
                sourcesDir  = if ($resolved) { $resolved.sourcesDir } else { $null }
                installWim  = if ($resolved) { $resolved.wim } else { $null }
                livePath    = if ($resolved) { $resolved.wim } else { $linuxBoot.kernelPath }
                httpPath    = if ($resolved) { "iso-wim/$token/install.wim" } else { "iso-mount/$token/$($linuxBoot.kernelRel)" }
                linux       = $linuxBoot
            }
            $script:AppPxeBootState.IsoMounts[$token] = $entry
            $result.Add($entry) | Out-Null
            if ($resolved) {
                $sizeGb = [math]::Round((Get-Item -LiteralPath $resolved.wim).Length / 1GB, 2)
                Write-SidecarLog "PXE boot: serving install.wim for '$displayName' in place at .mounts/$token (${sizeGb} GB, no extract)"
            } else {
                Write-SidecarLog "PXE boot: serving Linux boot files for '$($linuxBoot.label)' in place at .mounts/$token ($($linuxBoot.kernelRel) + $($linuxBoot.initrdRel), no extract)"
            }
        } catch {
            Write-SidecarLog "PXE boot: failed to mount $($iso.Name) - $($_.Exception.Message)"
        }
    }

    # Dismount ISOs that are no longer in the library.
    foreach ($key in @($script:AppPxeBootState.IsoMounts.Keys)) {
        if (-not $live.Contains($key)) {
            Dismount-AppPxeBootInstallWimIso -Base $key
        }
    }
    # One-time migration + housekeeping: drop any on-disk .mounts dir that isn't a current
    # token (legacy base-named mounts from before the token scheme, or crash leftovers).
    Clear-AppPxeBootStaleIsoMountDirs -LiveTokens $live
    # Sweep orphaned <token>.name labels left behind by a crash / removed ISO.
    if (Test-Path -LiteralPath $paths.isoMountDir) {
        foreach ($nameFile in @(Get-ChildItem -LiteralPath $paths.isoMountDir -Filter '*.name' -File -ErrorAction SilentlyContinue)) {
            $tokenForName = [IO.Path]::GetFileNameWithoutExtension($nameFile.Name)
            if (-not $live.Contains($tokenForName)) {
                Remove-Item -LiteralPath $nameFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    @($result)
}

$script:AppPxeBootInstallWimMountsCheckedAt = $null

function Sync-AppPxeBootInstallWimMounts {
    <#
    .SYNOPSIS
        Housekeeping: while THIS sidecar is serving, make sure every ISO it mounted
        is still mounted, and re-mount what is not.
    .NOTES
        hdiutil detach is host-global. A second sidecar on the same Mac (a test
        harness, a dev shell, another copy of the app) calling Stop takes the mounts
        out from under the one that is live - which is exactly how a deployment on
        2026-08-23 reached "Image not on the share" with the share itself up.
        Mounting is idempotent and borrows an existing attach, so re-asserting is
        cheap; checked every 20s, and only when this process started HTTP.
    #>
    $state = $script:AppPxeBootState
    $serving = $state.HttpProcess -and -not $state.HttpProcess.HasExited
    if (-not $serving) { return }
    if ($state.IsoMounts.Count -eq 0) { return }
    $now = [DateTime]::UtcNow
    if ($script:AppPxeBootInstallWimMountsCheckedAt -and ($now - $script:AppPxeBootInstallWimMountsCheckedAt).TotalSeconds -lt 20) { return }
    $script:AppPxeBootInstallWimMountsCheckedAt = $now
    $lost = @($state.IsoMounts.Values | Where-Object {
            $probe = [string]$_.livePath
            $probe -and -not (Test-Path -LiteralPath $probe)
        })
    if ($lost.Count -eq 0) { return }
    Write-SidecarLog "PXE boot: $($lost.Count) ISO mount(s) went away while serving ($((@($lost | ForEach-Object { [string]$_.isoFileName })) -join ', ')) - re-mounting"
    foreach ($entry in $lost) { [void]$state.IsoMounts.Remove([string]$entry.base) }
    try {
        Mount-AppPxeBootInstallWimIsos | Out-Null
        Clear-AppPxeBootMemo
    } catch {
        Write-SidecarLog "PXE boot: re-mount failed - $($_.Exception.Message)"
    }
}

function Sync-AppPxeBootIngestRoute {
    <#
    .SYNOPSIS
        Housekeeping: if Caddy is serving but proxying imaging logs to a listener that
        is not this process's, own the route - start our listener and restart HTTP.
    .NOTES
        The Start handler already does this on a Start click, but a restarted sidecar
        ADOPTS running daemons without one: Craig's 21:25 session showed running badges,
        he booted a client, and every log push 502'd against the previous session's dead
        port until someone pressed Start (2026-08-24). Runs on the housekeeping tick;
        cheap no-op when HTTP is down or the route already points at our listener.
    #>
    Sync-AppPxeBootHttpProcessState
    if (-not ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited)) { return }
    $current = 0
    try {
        $cfText = Get-Content -LiteralPath (Get-AppPxeBootLayoutPaths).caddyfile -Raw -ErrorAction Stop
        if ($cfText -match 'reverse_proxy 127\.0\.0\.1:(\d+)') { $current = [int]$Matches[1] }
    } catch { return }
    if ($current -le 0) { return }
    $mine = if ($script:AppPxeBootState.LogIngest) { [int]$script:AppPxeBootState.LogIngest.Port } else { 0 }
    if ($current -eq $mine) { return }
    # Not ours. If whoever owns it is alive, leave it be; if it is dead, take over.
    $alive = $false
    try {
        $probe = [System.Net.Sockets.TcpClient]::new()
        $alive = $probe.ConnectAsync('127.0.0.1', $current).Wait(300) -and $probe.Connected
        $probe.Dispose()
    } catch { $alive = $false }
    if ($alive) { return }
    # Throttle: one attempt per 30s. The housekeeping tick fires every dispatch pass,
    # and an unthrottled attempt looped itself to death on 2026-08-24 - see below.
    $now = [DateTime]::UtcNow
    $last = if ($script:AppPxeBootState.ContainsKey('LastIngestRouteAdopt')) { $script:AppPxeBootState.LastIngestRouteAdopt } else { $null }
    if ($last -and ($now - $last).TotalSeconds -lt 30) { return }
    $script:AppPxeBootState.LastIngestRouteAdopt = $now
    Write-SidecarLog "PXE boot: adopting the imaging-log route - Caddy proxies to dead :$current"
    try {
        $cfg = Read-AppPxeBootConfig
        # Order matters: Stop-AppPxeBootHttpServer ALSO stops this process's ingest
        # listener (line ~6557), so the listener must be started AFTER the stop - the
        # first version started it first, the stop killed it, the next tick saw a dead
        # port again, and the loop restarted Caddy every two seconds until everything
        # fell over (2026-08-24).
        Stop-AppPxeBootHttpServer | Out-Null
        $port = Start-AppPxeBootImagingLogIngest
        if ($port -le 0) { return }
        Start-AppPxeBootHttpServer -HttpRoot (Get-AppPxeBootLayoutPaths).httpRoot -Port ([int]$cfg.httpPort) -InterfaceId $cfg.interfaceId -IngestPort $port | Out-Null
        Write-SidecarLog "PXE boot: imaging-log route restored onto live :$port"
    } catch {
        Write-SidecarLog "PXE boot: imaging-log route adoption failed - $($_.Exception.Message)"
    }
}

function Get-AppPxeBootHttpAccessTail {
    <#
    .SYNOPSIS
        The tail of Caddy's HTTP access log as rows for the Monitoring panel -
        the server-side record of what booting clients actually fetched
        (wimboot, boot.wim, overlay files, imaging-log POSTs). Sits under the
        Imaging clients section: device history first, plumbing second.
    #>
    param([int]$MaxRows = 150)
    $path = Join-Path (Split-Path -Parent (Get-AppPxeBootLayoutPaths).httpRoot) 'http-access.log'
    if (-not (Test-Path -LiteralPath $path)) { return @{ available = $false; rows = @() } }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $cap = 131072
            if ($fs.Length -gt $cap) { $null = $fs.Seek(-$cap, [System.IO.SeekOrigin]::End) }
            $reader = New-Object System.IO.StreamReader($fs)
            $text = $reader.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch {
        return @{ available = $false; rows = @() }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($text -split "`n")) {
        if (-not $line.Contains('handled request')) { continue }
        $i = $line.IndexOf('{')
        if ($i -lt 0) { continue }
        $j = $null
        try { $j = $line.Substring($i) | ConvertFrom-Json } catch { continue }
        if ($null -eq $j -or $null -eq $j.PSObject.Properties['request']) { continue }
        # The prefix timestamp is UTC ("2026/08/24 13:49:24.638\t...").
        $time = ''
        try {
            $stamp = $line.Substring(0, 23)
            $utc = [datetime]::ParseExact($stamp, 'yyyy/MM/dd HH:mm:ss.fff', $null,
                [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $time = $utc.ToLocalTime().ToString('HH:mm:ss')
        } catch { }
        $rows.Add(@{
            time   = $time
            ip     = [string]$j.request.remote_ip
            method = [string]$j.request.method
            uri    = [string]$j.request.uri
            status = [int]$j.status
            size   = [long]$j.size
        })
    }
    $all = @($rows.ToArray())
    $take = [Math]::Min($MaxRows, $all.Count)
    $slice = @()
    if ($take -gt 0) { $slice = @($all[($all.Count - $take)..($all.Count - 1)]) }
    [array]::Reverse($slice)
    @{ available = $true; rows = $slice }
}

function Sync-AppPxeBootDeployClientPublish {
    <#
    .SYNOPSIS
        Housekeeping: while serving, re-publish the deploy client when its source
        changed - so a fixed startnet.cmd reaches the next boot without Stop/Start.
    #>
    $state = $script:AppPxeBootState
    if (-not ($state.HttpProcess -and -not $state.HttpProcess.HasExited)) { return }
    $src = Get-AppPxeBootDeployClientStartnetSource
    if (-not $src) { return }
    $dir = Join-Path (Get-AppPxeBootLayoutPaths).httpRoot 'deploy'
    $dst = Join-Path $dir 'startnet.cmd'
    if (-not (Test-Path -LiteralPath $dst)) { return }
    $stale = (Get-Item -LiteralPath $src).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dst).LastWriteTimeUtc
    if (-not $stale) {
        # The published deploy.unc/loghost embed the LAN IP of publish time. A
        # laptop that moves networks (work <-> home, Craig 2026-08-25: booted
        # at home, client tried the work share) serves a working menu but a
        # dead share/loghost until these are rewritten - so an IP mismatch
        # republishes exactly like a newer source does.
        $uncFile = Join-Path $dir 'deploy.unc'
        if (Test-Path -LiteralPath $uncFile) {
            try {
                $ip = [string](Get-AppPxeBootLanIp)
                $unc = [string](Get-Content -LiteralPath $uncFile -TotalCount 1 -ErrorAction Stop)
                if ($ip -and $unc -and -not $unc.Contains($ip)) { $stale = $true }
            } catch { }
        }
    }
    if (-not $stale) { return }
    try {
        Write-AppPxeBootDeployOverlayFiles -Dir $dir -LanIp (Get-AppPxeBootLanIp)
    } catch {
        Write-SidecarLogVerbose "PXE boot: deploy client re-publish failed - $($_.Exception.Message)"
    }
}

function Get-AppPxeBootServiceRestartReasons {
    <#
    .SYNOPSIS
        What a file rewrite cannot fix: running daemons that still carry the old
        network. Empty means Update-AppPxeBootDeploymentShare was enough.
    .NOTES
        Caddy listens on 0.0.0.0 and its Caddyfile names no LAN IP, so HTTP never
        needs a restart for an address change. dnsmasq does: dhcp-boot=<file>,<ip>,<ip>
        is baked into its config at start and it does not re-read that on SIGHUP. The
        other case is an ISO mounted after HTTP came up - its /iso-wim/<token>/ route
        is written into the Caddyfile at HTTP start only.
    #>
    param(
        [string]$LanIp,
        [bool]$HttpRunning,
        [bool]$TftpRunning
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $paths = Get-AppPxeBootLayoutPaths
    $tftpName = ''
    try {
        if ($TftpRunning -and $script:AppPxeBootState.TftpProcess) {
            $tftpName = [string]$script:AppPxeBootState.TftpProcess.ProcessName
        }
    } catch { $tftpName = '' }
    # tftpd64 on Windows carries no address; only a dnsmasq config can go stale.
    if ($TftpRunning -and $tftpName -notmatch 'tftpd' -and -not [string]::IsNullOrWhiteSpace($LanIp)) {
        try {
            if (Test-Path -LiteralPath $paths.dnsmasqConf) {
                $conf = Get-Content -LiteralPath $paths.dnsmasqConf -Raw -ErrorAction Stop
                if ($conf -match '(?m)^dhcp-boot=[^,\r\n]+,(\d{1,3}(?:\.\d{1,3}){3})') {
                    $answers = $Matches[1]
                    if ($answers -ne $LanIp) {
                        [void]$reasons.Add("TFTP/proxyDHCP still names $answers as the boot server; this machine is now $LanIp.")
                    }
                }
            }
        } catch { }
    }
    if ($HttpRunning) {
        try {
            if (Test-Path -LiteralPath $paths.caddyfile) {
                $caddyText = Get-Content -LiteralPath $paths.caddyfile -Raw -ErrorAction Stop
                # Every kind of mount gets the /iso-mount/<token>/ route (Windows ones add
                # /iso-wim/ on top), so that is the one to look for.
                $unrouted = @($script:AppPxeBootState.IsoMounts.Values | Where-Object {
                        $base = [string]$_.base
                        $base -and -not $caddyText.Contains("/iso-mount/$base/")
                    })
                if ($unrouted.Count -gt 0) {
                    [void]$reasons.Add("$($unrouted.Count) mounted ISO(s) have no HTTP route yet (routes are written when HTTP starts).")
                }
            }
        } catch { }
    }
    return @($reasons)
}

function Update-AppPxeBootDeploymentShare {
    <#
    .SYNOPSIS
        MDT's "Update Deployment Share": regenerate everything the services serve,
        for the network this machine is on now - without touching a process.
    .DESCRIPTION
        Everything a Start does on the way up, minus the daemons: fresh LAN IP (memos
        cleared), store layout, bundled boot assets (snponly, wimboot, arch trees -
        hash-compared), per-WIM boot assets, the Deploy$ share re-ensured while a
        service is up (idempotent; a first-ever run mints the throwaway credential),
        task sequences to Z:\TaskSequences, boot.ipxe / menu.ipxe / the TFTP menu, the
        deploy overlay (deploy.unc, loghost, deploy.cred, startnet.cmd, tools), and ISO
        mounts re-asserted while HTTP serves.
        Nothing here kills, starts, dismounts or unshares, so a device mid-apply on Z:\
        keeps reading. The one thing files cannot do is move a running daemon to a new
        address - those come back as restartReasons for the panel to say "Restart
        Services". Craig, 2026-08-26: "everything minus the services".
    .OUTPUTS
        Summary hashtable - no status payload on purpose: Get-AppPxeBootStatus was 1.1 s
        of a 2.0 s call (measured 2026-08-26) and the panel refetches status right after
        anyway. Memos are cleared at the end so that refetch sees the new state.
    #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $warnings = [System.Collections.Generic.List[string]]::new()
    Clear-AppPxeBootMemo
    $cfg = Read-AppPxeBootConfig
    $lanIp = [string](Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId)
    if (-not $lanIp) {
        [void]$warnings.Add('No LAN IP: boot URLs and deploy.unc fall back to the host name, which WinPE resolves unreliably.')
    }

    Ensure-AppPxeBootStoreLayoutLite | Out-Null
    $assetsChanged = [bool](Sync-AppPxeBootBundledBootAssets)
    if (Sync-AppPxeBootWimBootAssets) { $assetsChanged = $true }
    $layout = Test-AppPxeBootLayout -SkipStoreInit
    if (-not $layout.ok) {
        [void]$warnings.Add('Missing boot files: ' + (@($layout.missing) -join ', '))
    }

    Sync-AppPxeBootHttpProcessState -Port ([int]$cfg.httpPort)
    Sync-AppPxeBootTftpProcessState
    $httpRunning = [bool]($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited)
    $tftpRunning = [bool]($script:AppPxeBootState.TftpProcess -and -not $script:AppPxeBootState.TftpProcess.HasExited)

    # Share before menu: a first-ever run mints the throwaway credential inside the
    # ensure, and the overlay the menu pass publishes must carry it (Start gets there
    # with two menu passes; one is enough when the order is right). Only while a
    # service is up - Stop tore the share down on purpose, and Start brings it back.
    $share = $null
    if (($httpRunning -or $tftpRunning) -and [bool]$cfg.smbShareEnabled) {
        $probe = Get-AppPxeBootImageLibraryShareStatus
        if ($probe.tccBlocked) {
            [void]$warnings.Add([string]$probe.guidance)
        } else {
            try {
                $share = @(Ensure-AppPxeBootImageLibraryShare) | Select-Object -Last 1
            } catch {
                [void]$warnings.Add("Deploy share not re-published - $($_.Exception.Message)")
            }
        }
    }
    if (-not $share) { $share = Get-AppPxeBootImageLibraryShareStatus }

    $tsPublished = 0
    if (Test-AppSidecarCommand Sync-AppPxeBootTaskSequenceStore) {
        try {
            $tsPublished = [int](Sync-AppPxeBootTaskSequenceStore).published
        } catch {
            [void]$warnings.Add("Task sequences not published - $($_.Exception.Message)")
        }
    }
    # Mounts first: the menu's Linux entries are read off the mount map.
    $isoMounts = 0
    if ($httpRunning) {
        try {
            $isoMounts = @(Mount-AppPxeBootInstallWimIsos).Count
        } catch {
            [void]$warnings.Add("ISO mounts - $($_.Exception.Message)")
        }
    }

    # boot.ipxe / menu.ipxe, the TFTP menu + autoexec, and the deploy overlay (published
    # inside the menu pass, before the initrd lines that depend on it are built).
    Write-AppPxeBootMenuFiles -SkipTaskSequenceSync

    $restartReasons = @(Get-AppPxeBootServiceRestartReasons -LanIp $lanIp -HttpRunning $httpRunning -TftpRunning $tftpRunning)
    $deployUnc = $null
    try {
        $uncFile = Join-Path (Join-Path (Get-AppPxeBootLayoutPaths).httpRoot 'deploy') 'deploy.unc'
        if (Test-Path -LiteralPath $uncFile) {
            $deployUnc = [string](Get-Content -LiteralPath $uncFile -TotalCount 1 -ErrorAction Stop)
        }
    } catch { $deployUnc = $null }
    Clear-AppPxeBootMemo
    $sw.Stop()

    $servicesText = if ($httpRunning -and $tftpRunning) { 'HTTP + TFTP up' } elseif ($httpRunning) { 'HTTP up' } elseif ($tftpRunning) { 'TFTP up' } else { 'stopped' }
    $shareText = if ([bool]$share.active) { 'shared' } elseif ([bool]$share.enabled) { 'enabled, not published' } else { 'off' }
    $lanText = if ($lanIp) { $lanIp } else { 'none' }
    $uncText = if ($deployUnc) { $deployUnc } else { 'not published' }
    Write-SidecarLog ("PXE boot: deployment share updated in {0} ms - LAN {1}; boot menu + {2} task sequence(s); overlay {3}; Deploy`$ {4}; {5} ISO mount(s); services {6}" -f `
            $sw.ElapsedMilliseconds, $lanText, $tsPublished, $uncText, $shareText, $isoMounts, $servicesText)
    foreach ($r in $restartReasons) { Write-SidecarLog "PXE boot: restart needed - $r" }
    foreach ($w in $warnings) { Write-SidecarLog "PXE boot: update warning - $w" }

    [ordered]@{
        ok                     = $true
        lanIp                  = $(if ($lanIp) { $lanIp } else { $null })
        httpRunning            = $httpRunning
        tftpRunning            = $tftpRunning
        servicesRunning        = ($httpRunning -or $tftpRunning)
        shareEnabled           = [bool]$share.enabled
        shareActive            = [bool]$share.active
        deployUnc              = $deployUnc
        taskSequencesPublished = $tsPublished
        isoMounts              = $isoMounts
        bootAssetsChanged      = $assetsChanged
        restartReasons         = @($restartReasons)
        warnings               = @($warnings)
        elapsedMs              = [int]$sw.ElapsedMilliseconds
    }
}

function Restart-AppPxeBootServices {
    <#
    .SYNOPSIS
        Bounce the daemons and bring them back bound to the network as it is now.
    .DESCRIPTION
        Minimal stop, full start: Caddy and dnsmasq/tftpd64 go down and come back with
        a freshly read LAN IP, and Start regenerates every served file on the way up
        (menus, task sequences, overlay, assets, share) - so this is
        Update-AppPxeBootDeploymentShare plus the bounce. The Deploy$ share and the ISO
        mounts stay up throughout: neither carries the LAN IP (host-named share,
        path-named mounts) and both are what a device mid-apply reads from, so an apply
        already copying from Z:\ survives, while a device still booting (menu, boot.wim
        download) fails and needs another PXE boot. The handler guards that case with
        the imaging-clients count.
    .PARAMETER IngestPort
        The parent sidecar's imaging-log listener when this runs in a child pwsh - see
        Start-AppPxeBootHttpServer.
    #>
    param([int]$IngestPort = 0)
    Stop-AppPxeBootServices -Minimal | Out-Null
    return (Start-AppPxeBootServices -IngestPort $IngestPort)
}

function Dismount-AppPxeBootInstallWimIso {
    param([Parameter(Mandatory)][string]$Base)
    $entry = $script:AppPxeBootState.IsoMounts[$Base]
    if (-not $entry) { return }
    # NB: an extracted WIMs/<base>-install.wim copy (if the operator made one) is a real
    # library asset and is intentionally NOT removed here - only when its ISO leaves the
    # library. Dismount just releases the read-only mount.
    if ($entry.mountInfo) {
        Dismount-AppPxeBootIso -MountInfo $entry.mountInfo
    }
    try {
        $paths = Get-AppPxeBootLayoutPaths
        $nameFile = (Join-Path $paths.isoMountDir $Base) + '.name'
        if (Test-Path -LiteralPath $nameFile) { Remove-Item -LiteralPath $nameFile -Force -ErrorAction SilentlyContinue }
    } catch { }
    $script:AppPxeBootState.IsoMounts.Remove($Base) | Out-Null
    Write-SidecarLog "PXE boot: dismounted ISO $Base"
}

function Dismount-AppPxeBootInstallWimIsos {
    foreach ($key in @($script:AppPxeBootState.IsoMounts.Keys)) {
        Dismount-AppPxeBootInstallWimIso -Base $key
    }
}

function Get-AppPxeBootIsoMountStatus {
    @{
        # Mount-and-serve is unconditional - extraction was removed 2026-08-18 and a
        # stale persisted isoMountServe=false must not make the UI claim it's off.
        enabled = $true
        mounts  = @($script:AppPxeBootState.IsoMounts.Values | ForEach-Object {
            @{
                isoFileName = [string]$_.isoFileName
                base        = [string]$_.base
                displayName = [string]$_.displayName
                kind        = [string]$_.kind
                installWim  = [string]$_.installWim
                httpPath    = [string]$_.httpPath
                bootLabel   = if ($_.linux) { [string]$_.linux.label } else { $null }
                bootNote    = if ($_.linux) { Get-AppPxeBootLinuxInstallNote -Linux $_.linux } else { $null }
            }
        })
    }
}

# Enumerate the *.wim files contained in an ISO (e.g. sources/boot.wim, sources/install.wim)
# so the operator can pick which one to import as a Netboot boot WIM.
function Get-AppPxeBootIsoWimList {
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw 'PXE boot: source ISO file not found.'
    }
    $item = Get-Item -LiteralPath $IsoPath
    if ($item.Extension -notmatch '^\.iso$') {
        throw 'PXE boot: source file must be a .iso image.'
    }

    $entries = New-Object System.Collections.Generic.List[object]

    if ($IsMacOS -or $IsDarwin) { Ensure-AppPxeBootP7zipTools | Out-Null }
    $sevenZ = Get-AppPxeBootHost7zPath

    if ($sevenZ) {
        $curPath = $null; $curSize = $null; $curDir = $false
        $flush = {
            if ($curPath -and -not $curDir -and $curPath -match '\.wim$') {
                $leaf = ($curPath -split '[\\/]')[-1]
                $entries.Add([ordered]@{
                    path        = $curPath
                    displayPath = ($curPath -replace '\\', '/')
                    name        = $leaf
                    sizeBytes   = [long]($curSize ?? 0)
                }) | Out-Null
            }
        }
        foreach ($line in (& $sevenZ l -slt $IsoPath 2>$null)) {
            if ($line -match '^Path = (.+)$') {
                & $flush
                $curPath = $Matches[1].Trim(); $curSize = $null; $curDir = $false
            } elseif ($line -match '^Size = (\d+)') {
                $curSize = $Matches[1]
            } elseif ($line -match '^Attributes = (.+)$') {
                if ($Matches[1] -match 'D') { $curDir = $true }
            }
        }
        & $flush
    } else {
        $mountInfo = Mount-AppPxeBootIsoReadOnly -IsoPath $IsoPath
        try {
            $base = $mountInfo.mountPath.TrimEnd('/', '\')
            Get-ChildItem -LiteralPath $mountInfo.mountPath -Recurse -Filter '*.wim' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Substring($base.Length).TrimStart('/', '\') -replace '\\', '/'
                $entries.Add([ordered]@{
                    path        = $rel
                    displayPath = $rel
                    name        = $_.Name
                    sizeBytes   = [long]$_.Length
                }) | Out-Null
            }
        } finally {
            Dismount-AppPxeBootIso -MountInfo $mountInfo
        }
    }

    @{
        isoFileName = $item.Name
        entries     = @($entries | Sort-Object { $_.name })
    }
}

# Extract a single chosen *.wim out of an ISO and register it as a Netboot boot WIM.
# Staging lives under the store root so the final placement is a same-volume move (no SSD double-fill).
function Import-AppPxeBootWimFromIso {
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$WimPath,
        [string]$TargetFileName,
        [switch]$ReplaceExisting
    )
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw 'PXE boot: source ISO file not found.'
    }
    $isoItem = Get-Item -LiteralPath $IsoPath
    if ($isoItem.Extension -notmatch '^\.iso$') {
        throw 'PXE boot: source file must be a .iso image.'
    }
    $wimLeaf = ($WimPath -split '[\\/]')[-1]
    if ($wimLeaf -notmatch '\.wim$') {
        throw 'PXE boot: selected entry is not a .wim file.'
    }

    $paths = Initialize-AppPxeBootStore
    $targetName = if ($TargetFileName) {
        Get-AppPxeBootSafeWimFileName -FileName $TargetFileName
    } else {
        Get-AppPxeBootSafeWimFileName -FileName $wimLeaf
    }
    $dest = Join-Path $paths.wimDir $targetName
    if ((Test-Path -LiteralPath $dest) -and -not $ReplaceExisting) {
        throw "PXE boot: $targetName already exists."
    }

    $stageDir = Join-Path (Join-Path $paths.storeRoot '.iso-extract') ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $null = New-Item -Path $stageDir -ItemType Directory -Force

    try {
        if ($IsMacOS -or $IsDarwin) { Ensure-AppPxeBootP7zipTools | Out-Null }
        $sevenZ = Get-AppPxeBootHost7zPath

        $staged = $null
        if ($sevenZ) {
            Write-SidecarLog "PXE boot: extracting $WimPath from $($isoItem.Name) (7z)..."
            $ok = Invoke-AppPxeBoot7zExtractMember -ArchivePath $IsoPath -MemberPath $WimPath -OutputDirectory $stageDir
            if (-not $ok) { throw "PXE boot: 7-Zip could not extract $WimPath from the ISO." }
            $candidate = Join-Path $stageDir ($WimPath -replace '\\', '/')
            if (-not (Test-Path -LiteralPath $candidate)) {
                $candidate = Get-ChildItem -LiteralPath $stageDir -Recurse -Filter $wimLeaf -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty FullName
            }
            $staged = $candidate
        } else {
            $mountInfo = Mount-AppPxeBootIsoReadOnly -IsoPath $IsoPath
            try {
                $src = Join-Path $mountInfo.mountPath ($WimPath -replace '/', [string][IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $src)) {
                    throw "PXE boot: $WimPath not found inside the ISO."
                }
                $staged = Join-Path $stageDir $wimLeaf
                Write-SidecarLog "PXE boot: copying $WimPath from $($isoItem.Name) (mount)..."
                Copy-Item -LiteralPath $src -Destination $staged -Force
            } finally {
                Dismount-AppPxeBootIso -MountInfo $mountInfo
            }
        }

        if (-not $staged -or -not (Test-Path -LiteralPath $staged)) {
            throw "PXE boot: failed to extract $wimLeaf from the ISO."
        }

        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Move-Item -LiteralPath $staged -Destination $dest -Force
    } finally {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Complete-AppPxeBootWimImport -TargetName $targetName -Dest $dest -Paths $paths -ReplaceExisting:$ReplaceExisting
}

function Import-AppPxeBootIso {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetFileName,
        [switch]$ReplaceExisting
    )
    # param() must be the FIRST statement in the body - anything above it turns it
    # into a plain call and the function dies with "called as if it were a method"
    # (broke ISO import in the field, 2026-08-24).
    Clear-AppPxeBootMemo -Key 'wim-layout'
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw 'PXE boot: source ISO file not found.'
    }
    $sourceItem = Get-Item -LiteralPath $SourcePath
    if ($sourceItem.Extension -notmatch '^\.iso$') {
        throw 'PXE boot: source file must be a .iso image.'
    }

    $paths = Initialize-AppPxeBootStore
    $targetName = if ($TargetFileName) {
        Get-AppPxeBootSafeIsoFileName -FileName $TargetFileName
    } else {
        Get-AppPxeBootSafeIsoFileName -FileName $sourceItem.Name
    }
    $dest = Join-Path $paths.isoDir $targetName
    if ((Test-Path -LiteralPath $dest) -and -not $ReplaceExisting) {
        throw "PXE boot: $targetName already exists."
    }

    $sizeMb = [math]::Round($sourceItem.Length / 1MB, 1)
    Write-SidecarLog "PXE boot: copying ISO $targetName (${sizeMb} MB) into store"
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force

    $cfg = Read-AppPxeBootConfig
    # Mount-and-serve is the ONLY path (no extraction, ever - duplicated multi-GB
    # WIMs on disk defeat the point of HTTP serving). If HTTP is already running,
    # mount now so the new ISO's install.wim serves immediately; else on next start.
    if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
        try {
            Mount-AppPxeBootInstallWimIsos | Out-Null
            # Caddy `run` doesn't hot-reload - restart so the new /iso-wim/<base> route applies.
            Stop-AppPxeBootHttpServer | Out-Null
            Start-AppPxeBootHttpServer -HttpRoot (Get-AppPxeBootLayoutPaths).httpRoot -Port ([int]$cfg.httpPort) -InterfaceId $cfg.interfaceId | Out-Null
        } catch {
            Write-SidecarLog "PXE boot: mount after ISO import failed - $($_.Exception.Message)"
        }
    }

    Write-AppPxeBootMenuFiles

    @{
        fileName = $targetName
        sizeBytes = [long](Get-Item -LiteralPath $dest).Length
        library  = (Get-AppPxeBootWimLibraryResponse)
    }
}

function Remove-AppPxeBootIso {
    param([Parameter(Mandatory)][string]$FileName)
    # param() must be the FIRST statement in the body - anything above it turns it
    # into a plain call and the function dies with "called as if it were a method"
    # (broke ISO import in the field, 2026-08-24).
    Clear-AppPxeBootMemo -Key 'wim-layout'
    $name = Get-AppPxeBootSafeIsoFileName -FileName $FileName
    $dest = Join-Path (Get-AppPxeBootLayoutPaths).isoDir $name
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "PXE boot: ISO not found: $name"
    }
    # Release any live mount first - the ISO file is locked while mounted. Mounts are
    # keyed by token (Get-AppPxeBootIsoMountToken), not the bare stem - the stem never
    # matched, so a removed ISO used to keep its mount until the next Start.
    $mountBase = Get-AppPxeBootIsoMountToken -IsoFileName $name
    if ($script:AppPxeBootState.IsoMounts.ContainsKey($mountBase)) {
        Dismount-AppPxeBootInstallWimIso -Base $mountBase
    }
    Remove-Item -LiteralPath $dest -Force
    Write-SidecarLog "PXE boot: removed ISO $name"

    Write-AppPxeBootMenuFiles
    Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh
}

function Open-AppPxeBootWimFolder {
    $paths = Initialize-AppPxeBootStore
    $path = $paths.wimDir
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } elseif ($IsMacOS) {
        Start-Process -FilePath 'open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } else {
        Start-Process -FilePath 'xdg-open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path)) -ErrorAction SilentlyContinue
    }
    @{ opened = $true; path = $path }
}

function Open-AppPxeBootIsoFolder {
    $paths = Initialize-AppPxeBootStore
    $path = $paths.isoDir
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } elseif ($IsMacOS) {
        Start-Process -FilePath 'open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } else {
        Start-Process -FilePath 'xdg-open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path)) -ErrorAction SilentlyContinue
    }
    @{ opened = $true; path = $path }
}

function Open-AppPxeBootDriversFolder {
    Initialize-AppPxeBootStore | Out-Null
    $path = Get-AppPxeBootDriversOsRoot
    if (-not (Test-Path -LiteralPath $path)) {
        $null = New-Item -Path $path -ItemType Directory -Force
    }
    Sync-AppPxeBootDriverStore | Out-Null
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } elseif ($IsMacOS) {
        Start-Process -FilePath 'open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } else {
        Start-Process -FilePath 'xdg-open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path)) -ErrorAction SilentlyContinue
    }
    @{ opened = $true; path = $path }
}

function Set-AppPxeBootDefaultWim {
    param(
        [string]$FileName,
        [switch]$Clear
    )
    $existing = Read-AppPxeBootConfig
    if ($Clear -or [string]::IsNullOrWhiteSpace($FileName)) {
        Write-AppPxeBootConfig `
            -HttpPort ([int]$existing.httpPort) `
            -InterfaceId $existing.interfaceId `
            -DeployMenuUrl $existing.deployMenuUrl `
            -Tftpd64Path $existing.tftpd64Path `
            -TftpMode $existing.tftpMode `
            -DefaultBootWim '' | Out-Null
        Write-AppPxeBootMenuFiles
        Write-SidecarLog 'PXE boot: default boot WIM cleared - clients choose from PXE menu'
        return (Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh)
    }
    $name = Get-AppPxeBootSafeWimFileName -FileName $FileName
    $dest = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $name
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "PXE boot: boot WIM not found: $name"
    }
    Ensure-AppPxeBootWimBootAssets -WimFileName $name -SkipMenuRegen | Out-Null
    $existing = Read-AppPxeBootConfig
    Write-AppPxeBootConfig `
        -HttpPort ([int]$existing.httpPort) `
        -InterfaceId $existing.interfaceId `
        -DeployMenuUrl $existing.deployMenuUrl `
        -Tftpd64Path $existing.tftpd64Path `
        -TftpMode $existing.tftpMode `
        -DefaultBootWim $name | Out-Null
    Write-AppPxeBootMenuFiles
    Write-SidecarLog "PXE boot: default boot WIM set to $name"
    Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh
}

function Get-AppPxeBootPluginConfig {
    if (Test-AppPxeBootPluginEnabled) {
        Ensure-AppPxeBootStoreLayoutLite | Out-Null
    }
    $cfg = Read-AppPxeBootConfig
    $layout = Get-AppPxeBootWimLibraryLayoutSnapshot
    @{
        config   = $cfg
        layout   = $layout
        status   = Get-AppPxeBootStatus -SkipCatalogSync -SkipLayoutProbe -SkipHeavyChecks -Layout $layout
        smbShare = Get-AppPxeBootImageLibraryShareStatus
        isoMount = Get-AppPxeBootIsoMountStatus
    }
}

function Set-AppPxeBootPluginConfig {
    param(
        [int]$HttpPort,
        [string]$InterfaceId,
        [string]$DeployMenuUrl,
        [string]$Tftpd64Path,
        [string]$TftpMode,
        [string]$TftpBootFile,
        [bool]$AutoBootDefault,
        [bool]$SmbShareEnabled,
        [bool]$SmbOverlayEnabled,
        [string]$DeployOverlayCreds,
        [string]$DeployOverlayShare,
        [bool]$DeployClientInject,
        [bool]$IsoMountServe,
        [switch]$SkipMenuRegen
    )
    $port = if ($HttpPort -ge 1 -and $HttpPort -le 65535) { $HttpPort } else { 8080 }
    $writeParams = @{
        HttpPort         = $port
        InterfaceId      = $InterfaceId
        DeployMenuUrl    = $DeployMenuUrl
        Tftpd64Path      = $Tftpd64Path
        TftpMode         = $(if ($TftpMode) { $TftpMode } else { 'router' })
    }
    if ($PSBoundParameters.ContainsKey('TftpBootFile')) {
        $writeParams['TftpBootFile'] = $TftpBootFile
    }
    if ($PSBoundParameters.ContainsKey('AutoBootDefault')) {
        $writeParams['AutoBootDefault'] = [bool]$AutoBootDefault
    }
    if ($PSBoundParameters.ContainsKey('SmbShareEnabled')) {
        $writeParams['SmbShareEnabled'] = [bool]$SmbShareEnabled
    }
    if ($PSBoundParameters.ContainsKey('SmbOverlayEnabled')) {
        $writeParams['SmbOverlayEnabled'] = [bool]$SmbOverlayEnabled
    }
    if ($PSBoundParameters.ContainsKey('DeployOverlayCreds')) {
        $writeParams['DeployOverlayCreds'] = [string]$DeployOverlayCreds
    }
    if ($PSBoundParameters.ContainsKey('DeployOverlayShare')) {
        $writeParams['DeployOverlayShare'] = [string]$DeployOverlayShare
    }
    if ($PSBoundParameters.ContainsKey('DeployClientInject')) {
        $writeParams['DeployClientInject'] = [bool]$DeployClientInject
    }
    if ($PSBoundParameters.ContainsKey('IsoMountServe')) {
        $writeParams['IsoMountServe'] = [bool]$IsoMountServe
    }
    $cfg = Write-AppPxeBootConfig @writeParams
    if (-not $SkipMenuRegen) {
        Write-AppPxeBootMenuFiles
    }
    # If SMB sharing was just turned on while HTTP is already serving, provision now
    # so the user doesn't have to restart imaging services.
    if ($PSBoundParameters.ContainsKey('SmbShareEnabled')) {
        try {
            if ([bool]$SmbShareEnabled -and [bool](Get-AppPxeBootStatus).httpRunning) {
                Ensure-AppPxeBootImageLibraryShare | Out-Null
            } elseif (-not [bool]$SmbShareEnabled) {
                # Un-ticking SMB tears the share down live so the badge reflects this
                # specific share's real state (best effort; macOS only when admin cached).
                Remove-AppPxeBootImageLibraryShare
            }
        } catch {
            Write-SidecarLog "PXE boot: SMB ensure (config change) error - $($_.Exception.Message)"
        }
    }
    # Apply an ISO mount-serve toggle live: (re)mount or dismount and restart HTTP so
    # Caddy picks up / drops the /iso-wim/<base> routes without a full service cycle.
    if ($PSBoundParameters.ContainsKey('IsoMountServe')) {
        try {
            $httpRunning = $script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited
            if ($httpRunning) {
                if ([bool]$IsoMountServe) {
                    Mount-AppPxeBootInstallWimIsos | Out-Null
                } else {
                    Dismount-AppPxeBootInstallWimIsos
                }
                Stop-AppPxeBootHttpServer | Out-Null
                Start-AppPxeBootHttpServer -HttpRoot (Get-AppPxeBootLayoutPaths).httpRoot -Port ([int]$cfg.httpPort) -InterfaceId $cfg.interfaceId | Out-Null
            }
        } catch {
            Write-SidecarLog "PXE boot: ISO mount toggle error - $($_.Exception.Message)"
        }
    }
    # Apply an overlay toggle live: publish/remove the runtime cred/UNC files, then refresh boot.ipxe so the iPXE initrd lines match -
    # no full service restart needed. All idempotent and gated on the config flags.
    if ($PSBoundParameters.ContainsKey('SmbOverlayEnabled') -or
        $PSBoundParameters.ContainsKey('DeployOverlayCreds') -or
        $PSBoundParameters.ContainsKey('DeployOverlayShare')) {
        try {
            Sync-AppPxeBootWimBootAssets | Out-Null
            if (-not $SkipMenuRegen) { Write-AppPxeBootMenuFiles }
        } catch {
            Write-SidecarLog "PXE boot: overlay toggle apply error - $($_.Exception.Message)"
        }
    }
    if ($SkipMenuRegen) {
        $layout = Get-AppPxeBootWimLibraryLayoutSnapshot
        $status = Get-AppPxeBootStatus -SkipCatalogSync -SkipLayoutProbe -Layout $layout
    } else {
        $layout = Test-AppPxeBootLayout
        $status = Get-AppPxeBootStatus
    }
    @{
        config   = $cfg
        layout   = $layout
        status   = $status
        smbShare = Get-AppPxeBootImageLibraryShareStatus
        isoMount = Get-AppPxeBootIsoMountStatus
    }
}
