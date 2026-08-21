# Field PXE boot helper - local HTTP (WIM/wimboot) + TFTP (snponly.efi).
# Optional WAN menu/catalog: deploy.example.com (hidden when local-HTTP-only). See docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md.

# Laptop/workstation field PXE only - no deploy.example.com chains in menus or snponly fallback.
# Set $false to re-enable WAN catalog items and deploy_base fallbacks.
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
$script:AppPxeBootP7zipPinnedVersion = '17.06'
$script:AppPxeBootP7zipInstallInProgress = $false
$script:AppPxeBootFieldIsoManifestCache = $null
$script:AppPxeBootFieldIsoManifestCacheAt = $null
$script:AppPxeBootOptionalAssetsManifestCache = $null
$script:AppPxeBootOptionalAssetsManifestCacheAt = $null
$script:AppPxeBootWindowsSmbAclRoot = $null
$script:AppPxeBootWindowsSmbAclUser = $null

function Get-AppPxeBootStoreRoot {
    if (-not (Get-Command Get-AppPluginDir -ErrorAction SilentlyContinue)) {
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
        isoCatalogSource  = 'local'
        tftpd64Path       = $null
        tftpMode          = 'router'
        tftpBootFile      = $script:AppPxeBootDefaultTftpBootFile
        defaultBootWim       = $null
        defaultBootIso       = $null
        autoBootDefault      = $false
        smbShareEnabled      = $false
        smbOverlayEnabled    = $false
        imageDeployerOverlayCreds = 'throwaway'
        imageDeployerOverlayShare = 'Deploy$'
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
        # ISO mount + in-place install.wim serving is now default behavior (the toggle
        # was removed from the UI). Ignore any stale persisted false so the mounter and
        # the WIMs/ install.wim symlinks always run when HTTP starts.
        $defaults.isoMountServe = $true
        if (-not (Test-AppPxeBootWanDeployMenuEnabled) -and [string]$defaults.isoCatalogSource -eq 'wan') {
            $defaults.isoCatalogSource = 'local'
        }
        # ImageDeployer overlay creds: blank | throwaway | dept | vault:<id>
        if (-not (Test-AppPxeBootImageDeployerOverlayCredsModeValue -Value ([string]$defaults.imageDeployerOverlayCreds))) {
            $defaults.imageDeployerOverlayCreds = 'throwaway'
        }
        if ([string]::IsNullOrWhiteSpace([string]$defaults.imageDeployerOverlayShare)) {
            $defaults.imageDeployerOverlayShare = 'Deploy$'
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
        [string]$IsoCatalogSource,
        [string]$Tftpd64Path,
        [string]$TftpMode = 'router',
        [string]$TftpBootFile,
        [string]$DefaultBootWim,
        [string]$DefaultBootIso,
        [bool]$AutoBootDefault,
        [bool]$SmbShareEnabled,
        [bool]$SmbOverlayEnabled,
        [string]$ImageDeployerOverlayCreds,
        [string]$ImageDeployerOverlayShare,
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
    $defaultIso = $existing.defaultBootIso
    if ($PSBoundParameters.ContainsKey('DefaultBootIso')) {
        if ([string]::IsNullOrWhiteSpace($DefaultBootIso)) {
            $defaultIso = $null
        } else {
            $defaultIso = Get-AppPxeBootSafeIsoFileName -FileName $DefaultBootIso
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
        isoCatalogSource = if (-not (Test-AppPxeBootWanDeployMenuEnabled)) {
            'local'
        } elseif ($PSBoundParameters.ContainsKey('IsoCatalogSource')) {
            $src = [string]$IsoCatalogSource
            if ($src -eq 'wan') { 'wan' } else { 'local' }
        } elseif ($existing.isoCatalogSource -eq 'wan') {
            'wan'
        } else {
            'local'
        }
        tftpd64Path    = if ([string]::IsNullOrWhiteSpace($Tftpd64Path)) { $null } else { $Tftpd64Path.Trim() }
        tftpMode       = if ($TftpMode -in @('router', 'standalone', 'proxy')) { $TftpMode } else { 'router' }
        tftpBootFile   = $storedTftpBootFile
        defaultBootWim     = $defaultWim
        defaultBootIso     = $defaultIso
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
        imageDeployerOverlayCreds = if ($PSBoundParameters.ContainsKey('ImageDeployerOverlayCreds')) {
            $next = ([string]$ImageDeployerOverlayCreds).Trim()
            if (Test-AppPxeBootImageDeployerOverlayCredsModeValue -Value $next) { $next } else { 'throwaway' }
        } elseif (Test-AppPxeBootImageDeployerOverlayCredsModeValue -Value ([string]$existing.imageDeployerOverlayCreds)) {
            ([string]$existing.imageDeployerOverlayCreds).Trim()
        } else {
            'throwaway'
        }
        imageDeployerOverlayShare = if ($PSBoundParameters.ContainsKey('ImageDeployerOverlayShare')) {
            if ([string]::IsNullOrWhiteSpace($ImageDeployerOverlayShare)) { 'Deploy$' } else { ([string]$ImageDeployerOverlayShare).Trim() }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$existing.imageDeployerOverlayShare)) {
            ([string]$existing.imageDeployerOverlayShare).Trim()
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
        isoCatalogDir   = Join-Path $root 'http/ISOs'
        isoUrlDir       = Join-Path $root 'http/ISOs/urls'
        caddyBinaryDir  = Join-Path $root 'binaries/caddy'
        tftpd64BinaryDir = Join-Path $root 'binaries/tftpd64'
        caddyfile       = Join-Path $root 'Caddyfile'
        bootChain       = Join-Path $root 'http/boot.ipxe'
        menuIpxe        = Join-Path $root 'http/menu.ipxe'
        isoCatalogMenu  = Join-Path $root 'http/ISOs/menu.ipxe'
        isoCatalogJson  = Join-Path $root 'http/ISOs/catalog.json'
        brandingDir     = Join-Path $root 'http/branding'
        fieldisoDir         = Join-Path $root 'http/fieldiso'
        fieldisoDriversDir  = Join-Path $root 'http/fieldiso/drivers'
        fieldisoDriversIndex = Join-Path $root 'http/fieldiso/drivers/index.json'
        fieldisoBootstrapUrl = Join-Path $root 'http/fieldiso/bootstrap.url'
        fieldisoRunScript     = Join-Path $root 'http/fieldiso/run.ps1'
        fieldisoToolsDir      = Join-Path $root 'http/fieldiso/tools'
        imagedeployerDir      = Join-Path $root 'http/imagedeployer'
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
                Write-SidecarLog 'Netboot: pxe-boot store ready (http/iso, ISOs, branding, fieldiso/drivers, share/)'
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
    Write-SidecarLog 'Netboot: pxe-boot store ready (http/iso, ISOs, branding, fieldiso/drivers, share/)'
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

function Test-AppPxeBootFieldIsoDriverSyncDue {
    param([int]$MinIntervalSeconds = 300)

    if (-not (Test-Path -LiteralPath (Get-AppPxeBootFieldIsoDriversIndexPath))) {
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
            $paths.isoCatalogDir
            $paths.isoUrlDir
            $paths.brandingDir
            $paths.fieldisoDir
            $paths.fieldisoDriversDir
            $paths.fieldisoToolsDir
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
    Write-AppPxeBootStoreReadmeIfMissing -Path (Join-Path $paths.isoCatalogDir 'README.txt') -ReadmeLines @(
        'Generated FieldIso ISO catalog - do not drop ISO files here.'
        'Source ISOs live in the image library iso/ folder (Settings > Downloads location).'
        'urls/*.install.wim.url points at /iso-wim/<name>/install.wim - served live'
        'from the read-only ISO mount, never extracted.'
    )
    Write-AppPxeBootStoreReadmeIfMissing -Path (Join-Path $paths.brandingDir 'README.txt') -ReadmeLines @(
        'PXE menu background PNGs for boot.ipxe and ISOs/menu.ipxe.'
        'Preferred: det-branding-1920x1080.png (also 1024x768 supported).'
    )
    Write-AppPxeBootStoreReadmeIfMissing -Path (Join-Path $paths.shareDir 'README.md') -ReadmeLines @(
        '# Share (reserved)'
        ' '
        'Future: peer/torrent plug-in to seed OOBD driver archives and DE official ISOs to other'
        'WinDeployKit laptops on the LAN. Not active yet - folder created when Netboot is enabled.'
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

    if (Test-AppPxeBootFieldIsoDriverSyncDue) {
        Sync-AppPxeBootFieldIsoDriverStore | Out-Null
        $script:AppPxeBootState.LastDriverSyncUtc = (Get-Date).ToUniversalTime()
    }
    Sync-AppPxeBootFieldIsoHttpAssets | Out-Null

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
        accepting a root - sidecar/pxe/ also holds fieldiso/, wimboot and snponly.efi.
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

function Test-AppPxeBootWimIsFieldIso {
    param([Parameter(Mandatory)][string]$FileName)
    return [string]$FileName -match '(?i)^FieldIso\.wim$'
}

function Test-AppPxeBootWimIsImageDeployer {
    # ImageDeployer.wim and creds-baked variants (e.g. ImageDeployerCH.wim) all run
    # ImageDeployer.ps1, which can consume the Deploy$ overlay we inject at boot.
    param([Parameter(Mandatory)][string]$FileName)
    return [string]$FileName -match '(?i)^ImageDeployer.*\.wim$'
}

function Test-AppPxeBootWimIsImageDeployerStock {
    # Bake target is *ImageDeployer*.wim (Craig, 2026-08-18) - any ImageDeployer-named
    # WIM gets the project's credential-free, overlay-aware ImageDeployer.ps1, including
    # numbered download copies kept side by side and legacy creds-baked variants. The
    # real guard is the bake entry's RequiresWimPaths XAML probe: pre-1.10 WIMs (inline
    # XAML - including old creds-baked variants like ImageDeployerCH.wim) are skipped,
    # so a bake can only land where the 1.10 layout exists, and runtime overlay
    # credentials supersede baked ones anyway.
    param([Parameter(Mandatory)][string]$FileName)
    return [string]$FileName -imatch '(?i)imagedeployer.*\.wim$'
}

function Get-AppPxeBootDirectBootWimName {
    $cfg = Read-AppPxeBootConfig
    if (-not $cfg.defaultBootWim) { return $null }
    $defaultPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $cfg.defaultBootWim
    if (-not (Test-Path -LiteralPath $defaultPath)) { return $null }
    $name = [string]$cfg.defaultBootWim
    if (Test-AppPxeBootWimIsFieldIso -FileName $name) { return $null }
    return $name
}

function Test-AppPxeBootFieldIsoIsDefaultBoot {
    $cfg = Read-AppPxeBootConfig
    if (-not $cfg.defaultBootWim) { return $false }
    if (-not (Test-AppPxeBootWimIsFieldIso -FileName $cfg.defaultBootWim)) { return $false }
    $defaultPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $cfg.defaultBootWim
    return (Test-Path -LiteralPath $defaultPath)
}

function Get-AppPxeBootBootChainMode {
    $direct = Get-AppPxeBootDirectBootWimName
    if ($direct) { return "wimboot:$direct" }
    if (Test-AppPxeBootFieldIsoIsDefaultBoot) {
        $defaultIso = Get-AppPxeBootDefaultIsoName
        if ($defaultIso) { return "fieldiso-iso:$defaultIso" }
        return 'fieldiso-catalog'
    }
    return 'deploy-iso'
}

function Get-AppPxeBootDefaultIsoName {
    $cfg = Read-AppPxeBootConfig
    if ([string]::IsNullOrWhiteSpace($cfg.defaultBootIso)) { return $null }
    try {
        $name = Get-AppPxeBootSafeIsoFileName -FileName ([string]$cfg.defaultBootIso)
    } catch {
        return $null
    }
    $dest = Join-Path (Get-AppPxeBootLayoutPaths).isoDir $name
    if (Test-Path -LiteralPath $dest) { return $name }
    return $null
}

function Get-AppPxeBootIsoCatalogMenuId {
    param([Parameter(Mandatory)][string]$FileName)
    (Get-AppPxeBootIsoMenuItemId -FileName $FileName) -replace '^iso_', ''
}

function Get-AppPxeBootIsoDisplayLabel {
    param([Parameter(Mandatory)][string]$FileName)
    ([IO.Path]::GetFileNameWithoutExtension($FileName) -replace '_', ' ')
}

function Get-AppPxeBootMenuDefaultChooseTarget {
    param(
        [string]$DirectBootWim,
        [array]$BootableWims,
        [string]$DefaultIsoMenuId
    )
    if ($DirectBootWim) { return 'boot_default' }
    if ($DefaultIsoMenuId) { return $DefaultIsoMenuId }
    if (Test-AppPxeBootFieldIsoIsDefaultBoot) { return 'iso_catalog' }
    $first = @($BootableWims | Where-Object { -not (Test-AppPxeBootWimIsFieldIso -FileName $_.fileName) } | Select-Object -First 1)
    if ($first.Count -gt 0) {
        return Get-AppPxeBootMenuItemId -FileName ([string]$first[0].fileName)
    }
    return 'iso_catalog'
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
    return $WimFileName -match '(?i)imagedeployer'
}

function Get-AppPxeBootWimBootmgrAssetCandidates {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [hashtable]$Recipe = $null
    )
    if (Test-AppPxeBootWimExtractBootmgrFromWim -WimFileName $WimFileName -Recipe $Recipe) {
        return @()
    }
    if ($WimFileName -match '(?i)imagedeployer') {
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
    } elseif ($WimFileName -match '(?i)techtools|imagedeployer') {
        $recipe['useBootAssets'] = $true
        $recipe['index'] = 1
        $recipe['gui'] = $true
        if ($WimFileName -match '(?i)imagedeployer') {
            $recipe['extractBootmgrFromWim'] = $true
        }
    } elseif (Test-AppPxeBootWimIsFieldIso -FileName $WimFileName) {
        $recipe['useBootAssets'] = $true
        $recipe['gui'] = $true
        $recipe['extractBootmgrFromWim'] = $true
        if (-not $recipe.ContainsKey('index')) { $recipe['index'] = 1 }
    }

    if (Test-AppPxeBootWimIsFieldIso -FileName $WimFileName) {
        if (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'extractBootmgrFromWim') {
            if (-not $recipe.ContainsKey('index')) { $recipe['index'] = 1 }
        } elseif ($recipe.ContainsKey('index')) {
            $recipe.Remove('index')
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
    # "wim/ImageDeployer (1).wim" truncated at the space and 404'd at boot.
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
            Id            = 'imagedeployer-deploy'
            ServedSubdir  = 'imagedeployer'
            # Runtime injection applies to all ImageDeployer-family WIMs...
            AppliesTo     = { param($Name) Test-AppPxeBootWimIsImageDeployer -FileName $Name }
            # ...but baking the credential-free script only targets the stock WIM, never
            # private creds-baked variants (e.g. ImageDeployerCH.wim).
            BakeAppliesTo = { param($Name) Test-AppPxeBootWimIsImageDeployerStock -FileName $Name }
            # Deploy source (smbOverlayEnabled) picks the UNC target; credentials are
            # independent. This machine needs the local Deploy$ share; on-site WDS only
            # needs the overlay-aware script + runtime UNC/cred injection.
            IsEnabled     = { Test-AppPxeBootImageDeployerOverlayEnabled }
            Bakes         = @(
                # RequiresWimPaths: the project script is rebased on vendor 1.10, which loads
                # its XAML from /Deploy/ImageDeployer.xaml. Baking it into a pre-1.10 stock WIM
                # (inline XAML, no Tools) would crash WinPE at startup, so the engine skips the
                # bake unless the WIM already carries the external XAML.
                @{
                    MarkerName       = '.imagedeployer-script'
                    WimPath          = '/Deploy/ImageDeployer.ps1'
                    Source           = { Get-AppPxeBootImageDeployerScriptSource }
                    RequiresWimPaths = @('/Deploy/ImageDeployer.xaml')
                    RequiresHint     = 'stock WIM is pre-1.10 (no external XAML) - re-download ImageDeployer.wim from the Netboot panel'
                }
                # Task Sequence picker row (script references cmbTaskSequence, so the
                # XAML must ship with the same bake generation).
                @{
                    MarkerName       = '.imagedeployer-xaml'
                    WimPath          = '/Deploy/ImageDeployer.xaml'
                    Source           = { Get-AppPxeBootImageDeployerXamlSource }
                    RequiresWimPaths = @('/Deploy/ImageDeployer.xaml')
                    RequiresHint     = 'stock WIM is pre-1.10 (no external XAML) - re-download ImageDeployer.wim from the Netboot panel'
                }
            )
            Runtime       = @(
                @{ ServedName = 'deploy.unc';  WinPeName = 'imagedeployer.deploy.unc';  Required = $true }
                @{ ServedName = 'deploy.cred'; WinPeName = 'imagedeployer.deploy.cred'; Required = $false }
                @{ ServedName = 'loghost';     WinPeName = 'imagedeployer.loghost';     Required = $false }
            )
            PublishRuntime = { param($Dir, $LanIp) Write-AppPxeBootImageDeployerDeployOverlayFiles -Dir $Dir -LanIp $LanIp }
        }
        # Example (future): bake a static unattend.xml into a custom install WIM -
        # @{
        #     Id = 'soe-unattend'
        #     AppliesTo = { param($Name) $Name -ieq 'Install.wim' }
        #     Bakes = @(@{ MarkerName = '.soe-unattend'; WimPath = '/Windows/Panther/unattend.xml'; Source = { Get-AppPxeBootUnattendXmlSource } })
        # }
    )
}

function Get-AppPxeBootWimOverlayProfileEnabled {
    param([Parameter(Mandatory)][hashtable]$OverlayProfile)
    if (-not $OverlayProfile.IsEnabled) { return $true }
    return [bool](& $OverlayProfile.IsEnabled)
}

function Get-AppPxeBootWimOverlayServedDir {
    param([Parameter(Mandatory)][hashtable]$OverlayProfile)
    if ([string]::IsNullOrWhiteSpace($OverlayProfile.ServedSubdir)) { return $null }
    Join-Path (Get-AppPxeBootLayoutPaths).httpRoot $OverlayProfile.ServedSubdir
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
        if (-not $overlayProfile.Runtime) { continue }
        if (-not (& $overlayProfile.AppliesTo $WimFileName)) { continue }
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $overlayProfile)) { continue }
        $dir = Get-AppPxeBootWimOverlayServedDir -OverlayProfile $overlayProfile
        if (-not $dir) { continue }
        $profileLines = @()
        $ok = $true
        foreach ($entry in $overlayProfile.Runtime) {
            $served = Join-Path $dir $entry.ServedName
            if (Test-Path -LiteralPath $served) {
                $profileLines += ('initrd -n {0} ${{http_base}}/{1}/{2} {0}' -f $entry.WinPeName, $overlayProfile.ServedSubdir, $entry.ServedName)
            } elseif ($entry.Required) {
                $ok = $false
                break
            }
        }
        if ($ok) { $lines += $profileLines }
    }
    return $lines
}

$script:AppPxeBootFieldIsoIpxeCatalogRevision = 4

function Test-AppPxeBootIsoCatalogIpxeTemplateOutdated {
    $paths = Get-AppPxeBootLayoutPaths
    if (-not (Test-Path -LiteralPath $paths.isoCatalogMenu)) { return [bool](Get-AppPxeBootFieldIsoWimName) }
    try {
        $text = [string](Get-Content -LiteralPath $paths.isoCatalogMenu -Raw -Encoding UTF8)
    } catch {
        return $true
    }
    if ($text -match '(?i)\bbootsdi\b') { return $true }
    if ($text -match '(?m)^item \S+`t') { return $true }
    $rev = [string]$script:AppPxeBootFieldIsoIpxeCatalogRevision
    if ($text -notmatch "(?m)^#\s*fieldiso-ipxe-rev:\s*$([regex]::Escape($rev))\s*$") { return $true }
    if ((Get-AppPxeBootFieldIsoWimName) -and $text -notmatch '(?m)^:fieldiso_smb_test\s*$') { return $true }
    return $false
}

function Get-AppPxeBootFieldIsoWimbootCoreLines {
    param(
        [Parameter(Mandatory)][string]$FieldIsoWim,
        [string]$EchoLabel
    )
    $block = [System.Collections.Generic.List[string]]::new()
    $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $FieldIsoWim
    if ($EchoLabel) {
        [void]$block.Add("echo $EchoLabel")
    }
    if (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'bootAssetsMissing') {
        [void]$block.Add('echo WARN: FieldIso boot files missing - re-download FieldIso in Netboot')
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
    return @($block)
}

function Get-AppPxeBootFieldIsoBootIpxeBlock {
    param(
        [Parameter(Mandatory)][string]$EntryLabel,
        [Parameter(Mandatory)][string]$UrlRel,
        [Parameter(Mandatory)][string]$FieldIsoWim
    )
    $block = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-AppPxeBootFieldIsoWimbootCoreLines -FieldIsoWim $FieldIsoWim -EchoLabel "Booting $EntryLabel - FieldIso curl install.wim + DISM (no httpdisk)")) {
        [void]$block.Add($line)
    }
    [void]$block.Add("initrd -n fieldiso.url `${http_base}/fieldiso/bootstrap.url fieldiso.url")
    [void]$block.Add("initrd -n iso.url `${catalog_base}/$UrlRel iso.url")
    $installWimUrlRel = $UrlRel -replace '\.iso\.url$','.install.wim.url'
    [void]$block.Add("initrd -n install.wim.url `${catalog_base}/$installWimUrlRel install.wim.url")
    [void]$block.Add('echo Loading FieldIso WinPE (~330 MB) - run.ps1 served over HTTP')
    [void]$block.Add("initrd -n boot.wim `${http_base}/wim/$FieldIsoWim boot.wim")
    [void]$block.Add('boot')
    [void]$block.Add('imgfree')
    [void]$block.Add('echo')
    [void]$block.Add("echo Boot of $EntryLabel failed - check Caddy HTTP, install.wim under http/iso-wim/, FieldIso overlay v$($script:AppPxeBootFieldIsoOverlayVersion).")
    [void]$block.Add('goto start')
    [void]$block.Add('')
    return @($block)
}

function Get-AppPxeBootFieldIsoSmbTestIpxeBlock {
    param(
        [Parameter(Mandatory)][string]$FieldIsoWim
    )
    $block = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-AppPxeBootFieldIsoWimbootCoreLines -FieldIsoWim $FieldIsoWim -EchoLabel 'Booting FieldIso SMB lab test - macOS share net use (no imaging)')) {
        [void]$block.Add($line)
    }
    [void]$block.Add("initrd -n fieldiso.url `${http_base}/fieldiso/bootstrap.url fieldiso.url")
    [void]$block.Add("initrd -n fieldiso.mode `${http_base}/fieldiso/mode/smb-test fieldiso.mode")
    [void]$block.Add("initrd -n smb-test.unc `${http_base}/fieldiso/smb-test.unc smb-test.unc")
    # Optional throwaway SMB credential (lab only). Only chained when the operator
    # has placed <storeRoot>/fieldiso-smb-test.cred - a missing initrd would fail boot.
    $smbCredSource = Join-Path (Get-AppPxeBootStoreRoot) 'fieldiso-smb-test.cred'
    if (Test-Path -LiteralPath $smbCredSource) {
        [void]$block.Add("initrd -n smb-test.cred `${http_base}/fieldiso/smb-test.cred smb-test.cred")
    }
    [void]$block.Add('echo Loading FieldIso WinPE - run-smb-test.ps1 over HTTP')
    [void]$block.Add("initrd -n boot.wim `${http_base}/wim/$FieldIsoWim boot.wim")
    [void]$block.Add('boot')
    [void]$block.Add('imgfree')
    [void]$block.Add('echo')
    [void]$block.Add("echo FieldIso SMB test boot failed - check run-smb-test.ps1, smb-test.unc, overlay v$($script:AppPxeBootFieldIsoOverlayVersion).")
    [void]$block.Add('goto start')
    [void]$block.Add('')
    return @($block)
}

function Get-AppPxeBootWimlibImagexPath {
    $bundled = Get-AppPxeBootBundledWimlibImagexPath
    if ($bundled) { return $bundled }
    foreach ($name in @('wimlib-imagex', 'wimlib-imagex.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    if ($IsMacOS) {
        foreach ($candidate in @(
            '/opt/homebrew/bin/wimlib-imagex'
            '/usr/local/bin/wimlib-imagex'
        )) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
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
        throw 'PXE boot: WIM tools are missing from this app install - reinstall WinDeployKit or contact support.'
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

$script:AppPxeBootFieldIsoOverlayVersion = 12

function Get-AppPxeBootFieldIsoOverlayFiles {
    $overlayRoot = Get-AppPxeBootFieldIsoOverlayRoot
    if (-not $overlayRoot) { return @() }
    @(
        @{ Source = Join-Path $overlayRoot 'Windows/System32/Mount-IsoFromUrl.cmd'; WimPath = '/Windows/System32/Mount-IsoFromUrl.cmd' }
        @{ Source = Join-Path $overlayRoot 'Windows/System32/winpeshl.ini'; WimPath = '/Windows/System32/winpeshl.ini' }
    ) | Where-Object { Test-Path -LiteralPath $_.Source }
}

function Get-AppPxeBootFieldIsoWimInjectRoot {
    $bundled = Get-AppPxeBootFieldIsoBundledRoot
    if (-not $bundled) { return $null }
    $path = Join-Path $bundled 'wim-inject'
    if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    return $null
}

function Get-AppPxeBootFieldIsoWimInjectEntries {
    <#
    .SYNOPSIS
        Local files to merge into FieldIso.wim via wimlib update (curl, WinPE-PowerShell tree, etc.).
    #>
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $seen = @{}

    $bundled = Get-AppPxeBootFieldIsoBundledRoot
    if ($bundled) {
        foreach ($toolName in @('curl.exe', '7z.exe', '7za.dll', '7zxa.dll')) {
            $toolSrc = Join-Path $bundled "tools\$toolName"
            if (-not (Test-Path -LiteralPath $toolSrc)) { continue }
            $key = "/Windows/System32/$toolName"
            if (-not $seen.ContainsKey($key)) {
                [void]$entries.Add(@{ Source = $toolSrc; WimPath = $key })
                $seen[$key] = $true
            }
        }
    }

    $injectRoot = Get-AppPxeBootFieldIsoWimInjectRoot
    if ($injectRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $injectRoot -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -ieq 'README.txt') { continue }
            $rel = $file.FullName.Substring($injectRoot.Length).TrimStart('\', '/')
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $wimPath = '/' + ($rel -replace '\\', '/')
            if ($seen.ContainsKey($wimPath)) { continue }
            [void]$entries.Add(@{ Source = $file.FullName; WimPath = $wimPath })
            $seen[$wimPath] = $true
        }
    }

    return @($entries)
}

function Test-AppPxeBootFieldIsoWinPePowerShellInjectAvailable {
    $injectRoot = Get-AppPxeBootFieldIsoWimInjectRoot
    if (-not $injectRoot) { return $false }
    $ps = Join-Path $injectRoot 'Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
    return (Test-Path -LiteralPath $ps)
}

function Get-AppPxeBootFieldIsoOverlayRoot {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/fieldiso-overlay', 'pxe/fieldiso-overlay')) {
        $path = Join-Path $root $rel
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootFieldIsoOverlayMarkerPath {
    param([Parameter(Mandatory)][string]$WimDir)
    Join-Path $WimDir ".fieldiso-overlay-v$($script:AppPxeBootFieldIsoOverlayVersion)"
}

function Sync-AppPxeBootFieldIsoWinPeOverlay {
    <#
    .SYNOPSIS
        Patch Mount-IsoFromUrl.cmd (+ optional wim-inject files) into FieldIso.wim.
    #>
    param([Parameter(Mandatory)][string]$WimPath)

    $overlayRoot = Get-AppPxeBootFieldIsoOverlayRoot
    if (-not $overlayRoot) { return @{ skipped = $true; reason = 'no-overlay' } }

    $cmdSrc = Join-Path $overlayRoot 'Windows/System32/Mount-IsoFromUrl.cmd'
    if (-not (Test-Path -LiteralPath $cmdSrc)) {
        return @{ skipped = $true; reason = 'no-cmd' }
    }

    $overlayFiles = @(Get-AppPxeBootFieldIsoOverlayFiles)
    if ($overlayFiles.Count -eq 0) {
        return @{ skipped = $true; reason = 'no-overlay-files' }
    }

    $wimDir = Split-Path -Parent $WimPath
    $marker = Get-AppPxeBootFieldIsoOverlayMarkerPath -WimDir $wimDir
    $markerItem = Get-Item -LiteralPath $marker -ErrorAction SilentlyContinue
    if ($markerItem) {
        $wimItem = Get-Item -LiteralPath $WimPath -ErrorAction Stop
        if ($markerItem.LastWriteTime -ge $wimItem.LastWriteTime) {
            return @{ skipped = $true; reason = 'current' }
        }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Write-SidecarLog 'PXE boot: FieldIso WIM newer than overlay marker - re-patching WinPE startup script'
    }

    $wimlib = Get-AppPxeBootWimlibImagexPath
    if (-not $wimlib) {
        Write-SidecarLog 'PXE boot: FieldIso WinPE overlay patch skipped - wimlib missing'
        return @{ skipped = $true; reason = 'no-wimlib' }
    }

    $cmdFile = Join-Path ([IO.Path]::GetTempPath()) ("sm-pxe-fieldiso-cmd-$([Guid]::NewGuid().ToString('N')).cmd")
    $updateFile = Join-Path ([IO.Path]::GetTempPath()) ("sm-pxe-fieldiso-update-$([Guid]::NewGuid().ToString('N')).txt")
    $tempFiles = [System.Collections.Generic.List[string]]::new()
    try {
        $updateLines = [System.Collections.Generic.List[string]]::new()
        foreach ($of in $overlayFiles) {
            if ($of.Source -match '\.cmd$') {
                Copy-Item -LiteralPath $of.Source -Destination $cmdFile -Force
                [void]$tempFiles.Add($cmdFile)
                [void]$updateLines.Add("add `"$cmdFile`" $($of.WimPath) --no-acls")
            } else {
                [void]$updateLines.Add("add `"$($of.Source)`" $($of.WimPath) --no-acls")
            }
        }
        foreach ($inject in Get-AppPxeBootFieldIsoWimInjectEntries) {
            [void]$updateLines.Add("add `"$($inject.Source)`" $($inject.WimPath) --no-acls")
        }
        Set-Content -LiteralPath $updateFile -Value ($updateLines -join "`n") -Encoding ASCII -Force
        $injectCount = [Math]::Max(0, $updateLines.Count - $overlayFiles.Count)
        $runtimeDir = Get-AppPxeBootWimlibRuntimeDirectory -ImagexPath $wimlib
        Push-Location -LiteralPath $runtimeDir
        try {
            Get-Content -LiteralPath $updateFile -Raw | & $wimlib update $WimPath 1 2>&1 | Out-String | ForEach-Object {
                if ($_ -match '\[ERROR\]|ERROR:') {
                    Write-SidecarLog "PXE boot: FieldIso overlay wimlib $_".Trim()
                }
            }
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            throw "wimlib update failed (exit $LASTEXITCODE)"
        }
        Set-Content -LiteralPath $marker -Value ([string]$script:AppPxeBootFieldIsoOverlayVersion) -Encoding ASCII -Force
        $markerLeaf = Split-Path -Leaf $marker
        Get-ChildItem -LiteralPath $wimDir -Filter '.fieldiso-overlay-v*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $markerLeaf } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-SidecarLog "PXE boot: patched FieldIso WinPE overlay (v$($script:AppPxeBootFieldIsoOverlayVersion))$(
            if ($injectCount -gt 0) { ", +$injectCount inject file(s)" } else { '' }
        )"
        return @{ patched = $true }
    } catch {
        Write-SidecarLog "PXE boot: FieldIso WinPE overlay patch failed - $($_.Exception.Message)"
        return @{ patched = $false; error = $_.Exception.Message }
    } finally {
        foreach ($tf in @($tempFiles)) {
            Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $updateFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-AppPxeBootImageDeployerScriptSource {
    <#
    .SYNOPSIS
        Project copy of the overlay-aware, credential-free ImageDeployer.ps1 that gets
        baked into ImageDeployer.wim. Source of truth is sidecar/pxe/imagedeployer/.
    #>
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/imagedeployer/ImageDeployer.ps1', 'pxe/imagedeployer/ImageDeployer.ps1')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootImageDeployerXamlSource {
    <#
    .SYNOPSIS
        Project copy of ImageDeployer.xaml (vendor 1.10 + the Task Sequence picker
        row) baked alongside the script. Source of truth is sidecar/pxe/imagedeployer/.
    #>
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/imagedeployer/ImageDeployer.xaml', 'pxe/imagedeployer/ImageDeployer.xaml')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
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
        if (-not $overlayProfile.Bakes) { continue }
        $bakePredicate = if ($overlayProfile.BakeAppliesTo) { $overlayProfile.BakeAppliesTo } else { $overlayProfile.AppliesTo }
        if (-not (& $bakePredicate $wimName)) { continue }
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $overlayProfile)) { continue }
        foreach ($bake in $overlayProfile.Bakes) {
            [void]$results.Add((Invoke-AppPxeBootWimOverlayBake -WimPath $WimPath -ProfileId $overlayProfile.Id -Bake $bake))
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

$script:AppPxeBootFieldIsoDriversOs = 'Win11x64'
$script:AppPxeBootFieldIsoDriverPackExtensions = @('.7z', '.cab', '.exe', '.zip')

function Get-AppPxeBootFieldIsoDriversBundledSeedPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/fieldiso-drivers/models.seed.json', 'pxe/fieldiso-drivers/models.seed.json')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Get-AppPxeBootFieldIsoDriversBundledReadmePath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/fieldiso-drivers/README.md', 'pxe/fieldiso-drivers/README.md')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Read-AppPxeBootFieldIsoDriversSeed {
    $path = Get-AppPxeBootFieldIsoDriversBundledSeedPath
    if (-not $path) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-SidecarLog "PXE boot: FieldIso driver seed read failed - $($_.Exception.Message)"
        return $null
    }
}

function Get-AppPxeBootFieldIsoDriversOsRoot {
    # User-relocatable driver root: <image library>/Drivers/<Make>/<Model>/ -
    # ImageDeployer 1.10's publish/search convention (Win32_ComputerSystem
    # Manufacturer + Model; its cache-hit search is -Recurse -Depth 1 under
    # Deploy$\Drivers). Vendor folder names come from models.seed.json keys,
    # which are Manufacturer-style (Acer, LENOVO).
    (Get-AppImageLibraryPaths).driversDir
}

function Get-AppPxeBootFieldIsoDriversIndexPath {
    Join-Path (Get-AppPxeBootFieldIsoDriversOsRoot) 'index.json'
}

function Test-AppPxeBootFieldIsoDriverPackExtension {
    param([Parameter(Mandatory)][string]$Extension)
    $script:AppPxeBootFieldIsoDriverPackExtensions -contains $Extension.ToLowerInvariant()
}

function Get-AppPxeBootFieldIsoDriverPackInFolder {
    param([Parameter(Mandatory)][string]$FolderPath)
    $packs = @(Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue |
        Where-Object { Test-AppPxeBootFieldIsoDriverPackExtension -Extension $_.Extension } |
        Sort-Object Length -Descending)
    if ($packs.Count -gt 0) {
        return [string]$packs[0].Name
    }
    return $null
}

function Get-AppPxeBootFieldIsoDriverSeedStringProp {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Name
    )
    $prop = $Model.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return $null }
    [string]$prop.Value
}

function Get-AppPxeBootFieldIsoDriverSeedArrayProp {
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

function Get-AppPxeBootFieldIsoDriverNsspCatalogLabels {
    param([Parameter(Mandatory)]$Model)
    $labels = @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $Model -Name 'nsspCatalogLabels')
    if ($labels.Count -gt 0) { return $labels }
    @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $Model -Name 'nsspModelNames')
}

function Sync-AppPxeBootFieldIsoDriverStore {
    <#
    .SYNOPSIS
        Ensure OOBD driver folders exist (seed layout) and regenerate index.json.
    #>
    $osRoot = Get-AppPxeBootFieldIsoDriversOsRoot
    foreach ($dir in @($osRoot, (Join-Path $osRoot '_default'))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }

    $readmeSrc = Get-AppPxeBootFieldIsoDriversBundledReadmePath
    $readmeDest = Join-Path $osRoot 'README.md'
    if ($readmeSrc -and (-not (Test-Path -LiteralPath $readmeDest))) {
        Copy-Item -LiteralPath $readmeSrc -Destination $readmeDest -Force
    }

    $seed = Read-AppPxeBootFieldIsoDriversSeed

    # Layout is <Drivers>/<Make>/<Model>/ - ImageDeployer 1.10's publish/search
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
            # model SUBDIRS is a Make container - ImageDeployer 1.10 publishes under raw
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
                        "FieldIso WinPE extracts with 7z at boot - no repack needed."
                        "Or use aria2 Tracker -> OOBD drivers (Acer/Lenovo SCCM catalogs)."
                    ) | Set-Content -LiteralPath $hintPath -Encoding UTF8
                }
                $folderCount++
            }
        }
    }

    $index = Write-AppPxeBootFieldIsoDriversIndex
    # aliases.json for the baked ImageDeployer (model names / machine types / seed
    # wmiPatterns -> installed pack folders); no-ops unless the installed set changed.
    if (Get-Command Write-AppPxeBootDriverAliasMap -ErrorAction SilentlyContinue) {
        try { Write-AppPxeBootDriverAliasMap } catch {
            Write-SidecarLogVerbose "PXE boot: alias map write failed - $($_.Exception.Message)"
        }
    }
    @{
        osRoot       = $osRoot
        modelFolders = $folderCount
        indexPath    = Get-AppPxeBootFieldIsoDriversIndexPath
        readyCount   = if ($index) { [int]$index.readyCount } else { 0 }
        modelCount   = if ($index) { [int]$index.modelCount } else { 0 }
    }
}

function Write-AppPxeBootFieldIsoDriversIndex {
    $osRoot = Get-AppPxeBootFieldIsoDriversOsRoot
    $seed = Read-AppPxeBootFieldIsoDriversSeed
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
                $archive = Get-AppPxeBootFieldIsoDriverPackInFolder -FolderPath $modelDir
                $ready = -not [string]::IsNullOrWhiteSpace($archive)
                if ($ready) { $readyCount++ }
                [void]$entries.Add(@{
                        folder            = $folderName
                        vendor            = $vendorName
                        relPath           = "drivers/$vendorName/$folderName"
                        archive           = $archive
                        archiveReady      = $ready
                        nsspCatalogLabels = @(Get-AppPxeBootFieldIsoDriverNsspCatalogLabels -Model $model)
                        wmiPatterns       = @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')
                    })
            }
            $vendorsOut[$vendorName] = @($entries)
        }
    }

    $defaultDir = Join-Path $osRoot '_default'
    $defaultArchive = Get-AppPxeBootFieldIsoDriverPackInFolder -FolderPath $defaultDir
    $defaultReady = -not [string]::IsNullOrWhiteSpace($defaultArchive)

    $doc = [ordered]@{
        schema       = 1
        generated    = $generated
        os           = $script:AppPxeBootFieldIsoDriversOs
        modelCount   = $modelCount
        readyCount   = $readyCount
        default      = @{
            relPath      = 'drivers/_default'
            archive      = $defaultArchive
            archiveReady = $defaultReady
        }
        vendors      = $vendorsOut
    }

    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Get-AppPxeBootFieldIsoDriversIndexPath) -Encoding UTF8 -Force
    $doc
}

function Get-AppPxeBootFieldIsoDriversSummary {
    Sync-AppPxeBootFieldIsoDriverStore | Out-Null
    $indexPath = Get-AppPxeBootFieldIsoDriversIndexPath
    if (-not (Test-Path -LiteralPath $indexPath)) {
        return @{
            osRoot     = Get-AppPxeBootFieldIsoDriversOsRoot
            indexPath  = $indexPath
            modelCount = 0
            readyCount = 0
            httpPath   = 'drivers/index.json'
        }
    }
    try {
        $idx = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @{
            osRoot       = Get-AppPxeBootFieldIsoDriversOsRoot
            indexPath    = $indexPath
            modelCount   = [int](Get-AppSidecarJsonProp -Item $idx -Name 'modelCount')
            readyCount   = [int](Get-AppSidecarJsonProp -Item $idx -Name 'readyCount')
            defaultReady = [bool](Get-AppSidecarJsonProp -Item (Get-AppSidecarJsonProp -Item $idx -Name 'default') -Name 'archiveReady')
            generated    = [string](Get-AppSidecarJsonProp -Item $idx -Name 'generated')
            httpPath     = 'drivers/index.json'
        }
    } catch {
        @{
            osRoot     = Get-AppPxeBootFieldIsoDriversOsRoot
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
    return $WimFileName -match '(?i)imagedeployer'
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
            return 'PXE boot: this app install is missing ImageDeployer boot files. Reinstall WinDeployKit or contact support.'
        }
        return "PXE boot: could not install ImageDeployer boot files for $WimFileName."
    }
    if (-not (Get-AppPxeBootWimlibImagexPath)) {
        return 'PXE boot: this app install is missing WIM tools needed to prepare boot files. Reinstall WinDeployKit or contact support.'
    }
    return "PXE boot: could not prepare boot files (BCD, boot.sdi, boot manager) from $WimFileName. The WIM may be corrupt or unsupported."
}

function Ensure-AppPxeBootWimBootAssets {
    param(
        [Parameter(Mandatory)][string]$WimFileName,
        [switch]$SkipMenuRegen
    )
    try {
        if (Test-AppPxeBootWimIsFieldIso -FileName $WimFileName) {
            if (Test-AppPxeBootWimBootAssetsComplete -WimFileName $WimFileName) {
                return @{ complete = $true; skipped = $true }
            }
        }
        $recipe = Get-AppPxeBootWimbootRecipe -WimFileName $WimFileName
        if (-not (Test-AppPxeBootRecipeFlag -Recipe $recipe -Key 'useBootAssets')) {
            return @{ complete = $true; skipped = $true }
        }
        if (Test-AppPxeBootWimUsesBundledMdtBootAssets -WimFileName $WimFileName) {
            # Always refresh ImageDeployer from bundled MDT (cheap; keeps stack coherent).
        } elseif (Test-AppPxeBootWimBootAssetsComplete -WimFileName $WimFileName) {
            return @{ complete = $true; skipped = $true }
        }
        $export = Export-AppPxeBootWimBootAssets -WimFileName $WimFileName -SkipMenuRegen:$SkipMenuRegen
        if (-not $export.complete) {
            throw (Get-AppPxeBootWimBootAssetsFailureMessage -WimFileName $WimFileName -ExportResult $export)
        }
        return $export
    } finally {
        # Apply any enabled WIM overlays (e.g. bake the credential-free ImageDeployer.ps1)
        # on import too (idempotent), so they are ready before first boot. The registry
        # decides which WIMs each overlay targets.
        $overlayWim = Join-Path (Get-AppPxeBootLayoutPaths).wimDir (Get-AppPxeBootSafeWimFileName -FileName $WimFileName)
        if (Test-Path -LiteralPath $overlayWim) {
            Sync-AppPxeBootWimOverlays -WimPath $overlayWim | Out-Null
        }
    }
}

function Ensure-AppPxeBootFieldIsoBootAssets {
    <#
    .SYNOPSIS
        UEFI FieldIso ISO boot needs wim-boot/FieldIso (BCD, boot.sdi, bootmgfw) on every catalog entry.
        Called before ISO catalog / menu regen so adding a Windows ISO never emits a broken iPXE chain.
    #>
    param([switch]$SkipMenuRegen)

    $fieldIsoWim = Get-AppPxeBootFieldIsoWimName
    if (-not $fieldIsoWim) {
        return @{ complete = $false; missingWim = $true }
    }
    if (Test-AppPxeBootWimBootAssetsComplete -WimFileName $fieldIsoWim) {
        $wimPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $fieldIsoWim
        if (Test-Path -LiteralPath $wimPath) {
            Sync-AppPxeBootFieldIsoWinPeOverlay -WimPath $wimPath | Out-Null
        }
        return @{ complete = $true; skipped = $true }
    }

    Write-SidecarLog "PXE boot: preparing FieldIso UEFI boot files (wim-boot/FieldIso) for ISO catalog"
    try {
        return Ensure-AppPxeBootWimBootAssets -WimFileName $fieldIsoWim -SkipMenuRegen:$SkipMenuRegen
    } catch {
        $msg = $_.Exception.Message
        Write-SidecarLog "PXE boot: FieldIso boot asset export failed - $msg"
        throw
    } finally {
        $wimPath = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $fieldIsoWim
        if (Test-Path -LiteralPath $wimPath) {
            Sync-AppPxeBootFieldIsoWinPeOverlay -WimPath $wimPath | Out-Null
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
        # BCD/boot.sdi must match bootmgfw - mixing ImageDeployer bootmgr with TechTools BCD causes 0xc000000f.
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
        # Apply any enabled WIM overlays (e.g. bake the credential-free ImageDeployer.ps1
        # into the stock ImageDeployer.wim) so Deploy$ auto-mounts without a tech hand-
        # running wimlib. The registry decides which WIMs each overlay targets.
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

function Write-AppPxeBootMenuFiles {
    <#
    .SYNOPSIS
        Write http/boot.ipxe (+ menu.ipxe) for field PXE.
        - defaultBootWim = local WIM (not FieldIso) -> auto-boot that WIM (WDS-style); :start menu if boot returns
        - defaultBootWim = FieldIso + defaultBootIso -> auto-boot that ISO via FieldIso WinPE
        - defaultBootWim = FieldIso (no defaultBootIso) -> chain straight to ISO catalog (WinDeployKit local or WAN)
        - defaultBootWim unset -> choose menu; first non-FieldIso WIM or ISO catalog when only FieldIso + ISOs
    #>
    param(
        [switch]$SkipFieldIsoPrepare,
        [switch]$SkipIsoCatalogRegen,
        [switch]$BootMenuOnly
    )

    # Task-sequence unattends ride the same regen cadence (save / start / import) so
    # Z:\TaskSequences always matches the panel. Guarded: lib loads after this one.
    if (Get-Command Sync-AppPxeBootTaskSequenceStore -ErrorAction SilentlyContinue) {
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
    if (-not $BootMenuOnly) {
        Sync-AppPxeBootFieldIsoHttpAssets | Out-Null
    }
    $cfg = Read-AppPxeBootConfig
    $port = [int]$cfg.httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $deployBase = Get-AppPxeBootWanIsoCatalogUrl
    $wanDeployEnabled = Test-AppPxeBootWanDeployMenuEnabled
    $generated = (Get-Date).ToString('o')

    $directBootWim = Get-AppPxeBootDirectBootWimName
    $wims = @(Get-AppPxeBootWimInventory)
    $fieldIsoWim = Get-AppPxeBootFieldIsoWimName

    $bootMenuLines = [System.Collections.Generic.List[string]]::new()
    # Default WIM/ISO toggles only change boot.ipxe - not ISOs/menu.ipxe or urls/*.iso.url.
    # REVERT: remove -SkipIsoCatalogRegen from Set-AppPxeBootDefault* if catalog must always regen with defaults.
    $catalogStale = Test-AppPxeBootIsoCatalogStale
    $ipxeTemplateOutdated = Test-AppPxeBootIsoCatalogIpxeTemplateOutdated
    $regenCatalog = -not $BootMenuOnly
    if ($regenCatalog -and $SkipIsoCatalogRegen -and -not $catalogStale -and -not $ipxeTemplateOutdated) {
        $regenCatalog = $false
    }
    if ($regenCatalog) {
        if ($ipxeTemplateOutdated) {
            Write-SidecarLog "PXE boot: ISO catalog iPXE template outdated (rev $($script:AppPxeBootFieldIsoIpxeCatalogRevision)) - regenerating menu"
        }
        Write-AppPxeBootLocalIsoCatalog -SkipFieldIsoPrepare:$SkipFieldIsoPrepare | Out-Null
    } elseif ($BootMenuOnly) {
        Write-SidecarLog 'PXE boot: boot menu only (WIM library change - ISO catalog unchanged)'
    } elseif ($SkipIsoCatalogRegen -and $catalogStale) {
        Write-SidecarLog 'PXE boot: boot menu only (default change - ISO catalog regen deferred; catalog stale until Start field PXE or ISO change)'
    } elseif ($SkipIsoCatalogRegen) {
        Write-SidecarLog 'PXE boot: boot menu only (skipped ISO catalog regen - catalog still fresh)'
    }
    $httpBaseLiteral = Get-AppPxeBootLocalHttpBaseUrl
    $catalogBaseLiteral = Get-AppPxeBootLocalIsoCatalogUrl
    [void]$bootMenuLines.Add('#!ipxe')
    [void]$bootMenuLines.Add("set http_port $port")
    if ($wanDeployEnabled) {
        [void]$bootMenuLines.Add("set deploy_base $deployBase")
    }
    [void]$bootMenuLines.Add("set http_base $httpBaseLiteral")
    [void]$bootMenuLines.Add("set catalog_base $catalogBaseLiteral")
    $autoBoot = Test-AppPxeBootAutoBootDefaultOnPxe -Config $cfg

    if ($directBootWim) {
        $defaultMenuId = 'boot_default'
        [void]$bootMenuLines.Add("# WinDeployKit field PXE - auto-boot $directBootWim - generated $generated")
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
        if ($wanDeployEnabled) {
            [void]$bootMenuLines.Add('echo Pick Default (local) to retry, open the ISO catalog, or use WAN backup.')
        } else {
            [void]$bootMenuLines.Add('echo Pick Default (local) to retry or open the local ISO catalog.')
        }
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
            if (Test-AppPxeBootWimIsFieldIso -FileName $name) { continue }
            $id = Get-AppPxeBootMenuItemId -FileName $name
            [void]$bootMenuLines.Add("item $id`t$name")
        }
        [void]$bootMenuLines.Add('item --gap -- ------------------------------')
        foreach ($line in (Get-AppPxeBootIsoCatalogMenuIpxeLines -Config $cfg)) {
            [void]$bootMenuLines.Add($line)
        }
        foreach ($line in @(Get-AppPxeBootIpxeMenuUtilityItemLines)) { [void]$bootMenuLines.Add([string]$line) }
        $defaultTarget = Get-AppPxeBootMenuDefaultChooseTarget -DirectBootWim $directBootWim -BootableWims $wims
        [void]$bootMenuLines.Add("choose --default $defaultTarget target || goto start")
        [void]$bootMenuLines.Add('goto ${target}')
        [void]$bootMenuLines.Add('')
        foreach ($wim in $wims) {
            $name = [string]$wim.fileName
            if ($name -eq $directBootWim) { continue }
            if (Test-AppPxeBootWimIsFieldIso -FileName $name) { continue }
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
        foreach ($line in (Get-AppPxeBootIsoCatalogBootIpxeBlock -Config $cfg -HttpPort $port)) {
            [void]$bootMenuLines.Add($line)
        }
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
    } else {
        $localIsos = @(Get-AppPxeBootIsoInventory)
        $bootableWims = @($wims | Where-Object { -not (Test-AppPxeBootWimIsFieldIso -FileName $_.fileName) })
        $hasLocalMenu = ($bootableWims.Count -gt 0) -or ($localIsos.Count -gt 0 -and $fieldIsoWim)

        if ($hasLocalMenu) {
            $autoIsoCatalog = Test-AppPxeBootFieldIsoIsDefaultBoot
            $defaultIso = if ($autoIsoCatalog) { Get-AppPxeBootDefaultIsoName } else { $null }
            $defaultIsoMenuId = if ($defaultIso) { Get-AppPxeBootIsoCatalogMenuId -FileName $defaultIso } else { $null }
            $defaultIsoLabel = if ($defaultIso) { Get-AppPxeBootIsoDisplayLabel -FileName $defaultIso } else { $null }
            if ($autoIsoCatalog -and $defaultIso -and $fieldIsoWim) {
                [void]$bootMenuLines.Add("# WinDeployKit field PXE - default FieldIso -> auto-boot $defaultIso - generated $generated")
            } elseif ($autoIsoCatalog) {
                [void]$bootMenuLines.Add("# WinDeployKit field PXE - default FieldIso -> ISO catalog - generated $generated")
            } else {
                [void]$bootMenuLines.Add("# WinDeployKit field PXE - local menu - generated $generated")
            }
            if ($autoBoot -and $autoIsoCatalog -and $defaultIso -and $fieldIsoWim) {
                [void]$bootMenuLines.Add("goto $($defaultIsoMenuId)_run")
            } elseif ($autoBoot -and $autoIsoCatalog) {
                [void]$bootMenuLines.Add('goto iso_catalog')
            } else {
                [void]$bootMenuLines.Add('goto start')
            }
            [void]$bootMenuLines.Add('')
            if ($defaultIsoMenuId -and $fieldIsoWim) {
                [void]$bootMenuLines.Add(":${defaultIsoMenuId}")
                [void]$bootMenuLines.Add("chain `${http_base}/boot.ipxe?t=`${buildsign} || goto $($defaultIsoMenuId)_run")
                [void]$bootMenuLines.Add('')
                [void]$bootMenuLines.Add(":$($defaultIsoMenuId)_run")
                $urlRel = "urls/$defaultIsoMenuId.iso.url"
                foreach ($line in (Get-AppPxeBootFieldIsoBootIpxeBlock -EntryLabel $defaultIsoLabel -UrlRel $urlRel -FieldIsoWim $fieldIsoWim)) {
                    [void]$bootMenuLines.Add($line)
                }
                [void]$bootMenuLines.Add('echo')
                [void]$bootMenuLines.Add("echo Auto-boot of $defaultIso failed - opening local menu.")
                if ($wanDeployEnabled) {
                    [void]$bootMenuLines.Add('echo Pick Default ISO to retry, open the ISO catalog, or use WAN backup.')
                } else {
                    [void]$bootMenuLines.Add('echo Pick Default ISO to retry or open the local ISO catalog.')
                }
                [void]$bootMenuLines.Add('goto start')
                [void]$bootMenuLines.Add('')
            }
            [void]$bootMenuLines.Add(':start')
            foreach ($line in @(Get-AppPxeBootMenuBrandingConsoleIpxeLines)) { [void]$bootMenuLines.Add([string]$line) }
            [void]$bootMenuLines.Add('menu Field PXE - choose boot image')
            foreach ($line in @(Get-AppPxeBootMenuBrandingSubtitleIpxeLines)) { [void]$bootMenuLines.Add([string]$line) }
            [void]$bootMenuLines.Add('item --gap -- ------------------------------')
            foreach ($wim in $bootableWims) {
                $name = [string]$wim.fileName
                $id = Get-AppPxeBootMenuItemId -FileName $name
                [void]$bootMenuLines.Add("item $id`t$name")
            }
            if ($defaultIsoMenuId -and $fieldIsoWim) {
                if ($bootableWims.Count -gt 0) {
                    [void]$bootMenuLines.Add('item --gap -- ------------------------------')
                }
                [void]$bootMenuLines.Add("item ${defaultIsoMenuId}`tDefault (local): $defaultIsoLabel")
            }
            [void]$bootMenuLines.Add('item --gap -- ------------------------------')
            foreach ($line in (Get-AppPxeBootIsoCatalogMenuIpxeLines -Config $cfg)) {
                [void]$bootMenuLines.Add($line)
            }
            foreach ($line in @(Get-AppPxeBootIpxeMenuUtilityItemLines)) { [void]$bootMenuLines.Add([string]$line) }
            $defaultTarget = Get-AppPxeBootMenuDefaultChooseTarget -DirectBootWim $null -BootableWims $bootableWims `
                -DefaultIsoMenuId $defaultIsoMenuId
            [void]$bootMenuLines.Add("choose --default $defaultTarget target || goto start")
            [void]$bootMenuLines.Add('goto ${target}')
            [void]$bootMenuLines.Add('')
            foreach ($wim in $bootableWims) {
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
            if ($defaultIsoMenuId -and $fieldIsoWim) {
                [void]$bootMenuLines.Add(":${defaultIsoMenuId}")
                foreach ($line in (Get-AppPxeBootFieldIsoBootIpxeBlock -EntryLabel $defaultIsoLabel -UrlRel "urls/$defaultIsoMenuId.iso.url" -FieldIsoWim $fieldIsoWim)) {
                    [void]$bootMenuLines.Add($line)
                }
                [void]$bootMenuLines.Add('echo')
                [void]$bootMenuLines.Add("echo Boot of $defaultIso failed.")
                [void]$bootMenuLines.Add('goto start')
                [void]$bootMenuLines.Add('')
            }
            foreach ($line in (Get-AppPxeBootIsoCatalogBootIpxeBlock -Config $cfg -HttpPort $port)) {
                [void]$bootMenuLines.Add($line)
            }
            foreach ($line in @(Get-AppPxeBootIpxeLocalDiskHandlerLines)) { [void]$bootMenuLines.Add([string]$line) }
            [void]$bootMenuLines.Add(':retry')
            [void]$bootMenuLines.Add('chain ${http_base}/boot.ipxe?t=${buildsign} || chain ${http_base}/boot.ipxe || goto start')
            [void]$bootMenuLines.Add('')
            [void]$bootMenuLines.Add(':shell')
            [void]$bootMenuLines.Add('shell')
            [void]$bootMenuLines.Add('goto start')
            if ($autoBoot -and $autoIsoCatalog -and $defaultIso) {
                if ($wanDeployEnabled) {
                    Write-SidecarLog "PXE boot: boot.ipxe auto-boots ISO $defaultIso (FieldIso default); catalog fallback; WAN backup $deployBase"
                } else {
                    Write-SidecarLog "PXE boot: boot.ipxe auto-boots ISO $defaultIso (FieldIso default); local catalog only"
                }
            } elseif ($autoIsoCatalog) {
                if ($wanDeployEnabled) {
                    Write-SidecarLog "PXE boot: boot.ipxe opens ISO catalog (FieldIso default); $($localIsos.Count) ISO(s); WAN backup $deployBase"
                } else {
                    Write-SidecarLog "PXE boot: boot.ipxe opens local ISO catalog (FieldIso default); $($localIsos.Count) ISO(s)"
                }
            } elseif (-not $autoBoot) {
                Write-SidecarLog 'PXE boot: boot.ipxe menu-first (autoBootDefault off - client must pick boot target)'
            } else {
                if ($wanDeployEnabled) {
                    Write-SidecarLog "PXE boot: boot.ipxe local menu ($($bootableWims.Count) WIM(s), $($localIsos.Count) ISO(s)); WAN backup $deployBase"
                } else {
                    Write-SidecarLog "PXE boot: boot.ipxe local menu ($($bootableWims.Count) WIM(s), $($localIsos.Count) ISO(s))"
                }
            }
        } else {
            if ($wanDeployEnabled) {
                [void]$bootMenuLines.Add("# WinDeployKit field PXE - deploy ISO catalog - generated $generated")
                [void]$bootMenuLines.Add('echo Loading deploy ISO menu...')
                [void]$bootMenuLines.Add('chain ${deploy_base}/menu.ipxe?t=${buildsign} || chain ${deploy_base}/menu.ipxe || goto failed')
                [void]$bootMenuLines.Add(':failed')
                [void]$bootMenuLines.Add('echo Could not load PXE menu from deploy server.')
                [void]$bootMenuLines.Add('shell')
                Write-SidecarLog "PXE boot: boot.ipxe chains deploy ISO catalog ($deployBase)"
            } else {
                [void]$bootMenuLines.Add("# WinDeployKit field PXE - no local boot assets - generated $generated")
                [void]$bootMenuLines.Add('echo No local boot WIM or ISO on this workstation.')
                [void]$bootMenuLines.Add('echo Open Netboot in WinDeployKit - add FieldIso.wim plus ISOs or a boot WIM.')
                [void]$bootMenuLines.Add('echo Enable HTTP + TFTP, then reboot the client.')
                [void]$bootMenuLines.Add('shell')
                Write-SidecarLog 'PXE boot: boot.ipxe has no local menu assets (local HTTP only - add WIM/ISO in Netboot)'
            }
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
    [void]$lines.Add('# WinDeployKit - TFTP/HTTP autoexec (regenerated on menu sync)')
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
        '# WinDeployKit - placeholder autoexec (full script written on menu sync / Start PXE)'
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
    $sevenZa = Join-Path $dir '7za'
    $sevenSo = Join-Path $dir '7z.so'
    if (-not ((Test-Path -LiteralPath $sevenZa) -and (Test-Path -LiteralPath $sevenSo))) {
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
    return 'https://artifacts.example.com/api/v4/projects/MacsInSpace%2Fwindeploykit/packages/generic/windeploykit/latest/p7zip-tools.json'
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
        if ($members.Count -eq 0) { $members = @('7za', '7z.so') }
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
    try {
        $remote = Invoke-RestMethod -Uri $manifestUrl -Method Get -UseBasicParsing -TimeoutSec 45
        $parsed = Read-AppPxeBootP7zipManifestObject -Obj $remote
        if ($parsed) { return $parsed }
    } catch {
        Write-SidecarLogVerbose "PXE boot: p7zip manifest fetch failed ($manifestUrl): $($_.Exception.Message)"
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
    throw 'PXE boot: p7zip manifest unavailable (GitLab + bundled copy both failed).'
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
        -UserAgent 'WinDeployKit' -MaximumRedirection 5
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
    if (-not ($IsMacOS -or $IsDarwin)) {
        return @{ ok = $true; skipped = $true; reason = 'not_macos' }
    }
    if ($script:AppPxeBootP7zipInstallInProgress) {
        return @{ ok = $false; installing = $true; skipped = $true; reason = 'install_in_progress' }
    }
    if (Test-AppPxeBootP7zipInstalled -RequirePinnedVersion) {
        return @{
            ok      = $true
            skipped = $true
            dir     = (Get-AppPxeBootP7zipToolsDir)
            version = $script:AppPxeBootP7zipPinnedVersion
        }
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
        return @{ ok = $false; message = 'p7zip manifest entry has no downloadUrl (publish archives to GitLab first).' }
    }

    $toolsDir = Get-AppPxeBootP7zipToolsDir
    $sizeMb = if ($entry.sizeBytes -gt 0) { [math]::Round($entry.sizeBytes / 1MB, 1) } else { 6 }
    Write-SidecarLog "PXE boot: installing p7zip $($manifest.version) ($platformKey, ~${sizeMb} MB) to $toolsDir (GitLab HTTPS once per Mac)"

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
        Set-AppPxeBootWimlibExecutable -Path (Join-Path $toolsDir '7za')
        Set-Content -LiteralPath (Get-AppPxeBootP7zipMarkerPath) -Value $script:AppPxeBootP7zipPinnedVersion -Encoding ASCII -Force
        Write-SidecarLog "PXE boot: p7zip $($script:AppPxeBootP7zipPinnedVersion) ready at $toolsDir"
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

function Get-AppPxeBootWindowsFieldIso7zToolsDir {
    $bundled = Get-AppPxeBootFieldIsoBundledRoot
    if ($bundled) {
        $toolsDir = Join-Path $bundled 'tools'
        $sevenZ = Join-Path $toolsDir '7z.exe'
        if (Test-Path -LiteralPath $sevenZ) {
            return (Resolve-Path -LiteralPath $toolsDir).Path
        }
    }
    return $null
}

function Get-AppPxeBootHost7zPath {
    if ($IsMacOS -or $IsDarwin) {
        if (Test-AppPxeBootP7zipInstalled) {
            return (Join-Path (Get-AppPxeBootP7zipToolsDir) '7za')
        }
        return $null
    }

    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $toolsDir = Get-AppPxeBootWindowsFieldIso7zToolsDir
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
        $toolsDir = Get-AppPxeBootWindowsFieldIso7zToolsDir
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

function Write-AppPxeBootFieldIsoBootstrapUrlFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HttpBaseUrl
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $HttpBaseUrl.Trim().TrimEnd('/') + "`n", $utf8NoBom)
}

function Get-AppPxeBootFieldIsoBundledRoot {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    foreach ($rel in @('sidecar/pxe/fieldiso', 'pxe/fieldiso')) {
        $path = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Write-AppPxeBootFieldIsoSmbTestHttpAssets {
    param(
        [Parameter(Mandatory)][hashtable]$Paths,
        [string]$LanIp
    )
    $modeDir = Join-Path $Paths.fieldisoDir 'mode'
    if (-not (Test-Path -LiteralPath $modeDir)) {
        $null = New-Item -Path $modeDir -ItemType Directory -Force
    }
    Set-Content -LiteralPath (Join-Path $modeDir 'smb-test') -Value 'smb-test' -Encoding ASCII -NoNewline -Force

    $hostPart = if ([string]::IsNullOrWhiteSpace($LanIp)) {
        try { [System.Net.Dns]::GetHostName() } catch { 'localhost' }
    } else {
        [string]$LanIp
    }
    # Trailing '$' = hidden share: macOS smbd (like Windows) does not advertise it
    # in browse/enumeration, but WinPE mounts it by explicit UNC so hiding is free.
    $shareName = 'SM_SMB_SPIKE$'
    $unc = "\\$hostPart\$shareName"
    Set-Content -LiteralPath (Join-Path $Paths.fieldisoDir 'smb-test.unc') -Value $unc -Encoding ASCII -NoNewline -Force

    # Optional throwaway SMB credential for the authenticated lab mount test.
    # Operator creates <storeRoot>/fieldiso-smb-test.cred (line 1 = user, line 2 = password,
    # a low-value read-only-share local account - NEVER a sudo/admin account). It is then
    # served at http/fieldiso/smb-test.cred and chained as an initrd in smb-test mode.
    # ASCII, no BOM - WinPE 'set /p' breaks on a UTF-8 BOM (same reason as iso.url files).
    $credSource = Join-Path $Paths.storeRoot 'fieldiso-smb-test.cred'
    $credDest = Join-Path $Paths.fieldisoDir 'smb-test.cred'
    if (Test-Path -LiteralPath $credSource) {
        $credLines = @(Get-Content -LiteralPath $credSource -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($credLines.Count -ge 2) {
            # CRLF, not LF: WinPE's `set /p` (in Mount-IsoFromUrl.cmd) needs CRLF to
            # split the two lines - an LF-only file makes it read BOTH lines into the
            # username. Write the bytes explicitly so the macOS/pwsh default LF does
            # not leak through. (run-smb-test.ps1 also reads this file directly.)
            $credText = ('{0}{2}{1}{2}' -f ([string]$credLines[0]).Trim(), ([string]$credLines[1]).Trim(), "`r`n")
            Set-Content -LiteralPath $credDest -Value $credText -Encoding ASCII -NoNewline -Force
        } else {
            Write-SidecarLog 'PXE SMB lab: fieldiso-smb-test.cred needs two lines (user, password) - credential not served.'
            if (Test-Path -LiteralPath $credDest) { Remove-Item -LiteralPath $credDest -Force -ErrorAction SilentlyContinue }
        }
    } elseif (Test-Path -LiteralPath $credDest) {
        Remove-Item -LiteralPath $credDest -Force -ErrorAction SilentlyContinue
    }
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
        if (-not $overlayProfile.Runtime) { continue }
        $dir = Get-AppPxeBootWimOverlayServedDir -OverlayProfile $overlayProfile
        if (-not $dir) { continue }
        if (-not (Get-AppPxeBootWimOverlayProfileEnabled -OverlayProfile $overlayProfile)) {
            foreach ($entry in $overlayProfile.Runtime) {
                $f = Join-Path $dir $entry.ServedName
                if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
        if ($overlayProfile.PublishRuntime) { & $overlayProfile.PublishRuntime $dir $LanIp }
    }
}

function Test-AppPxeBootImageDeployerOverlayCredsModeValue {
    param([string]$Value)
    $v = ([string]$Value).Trim()
    if ($v -in @('throwaway', 'blank', 'dept')) { return $true }
    if ($v -match '^vault:[A-Za-z0-9_-]+$') { return $true }
    return $false
}

function Get-AppPxeBootImageDeployerOverlayCredsMode {
    param($Cfg = $(Read-AppPxeBootConfig))
    $v = if ($Cfg) { [string]$Cfg.imageDeployerOverlayCreds } else { '' }
    if (Test-AppPxeBootImageDeployerOverlayCredsModeValue -Value $v) { return $v.Trim() }
    return 'throwaway'
}

function Test-AppPxeBootImageDeployerOverlayEnabled {
    param($Cfg = $(Read-AppPxeBootConfig))
    if ([bool]$Cfg.smbOverlayEnabled) {
        return [bool]$Cfg.smbShareEnabled
    }
    return $true
}

function Get-AppPxeBootImageDeployerDeployUnc {
    param(
        [Parameter(Mandatory)]$Cfg,
        [string]$LanIp
    )
    $shareName = if (-not [string]::IsNullOrWhiteSpace([string]$Cfg.imageDeployerOverlayShare)) {
        ([string]$Cfg.imageDeployerOverlayShare).Trim()
    } else {
        [string]$script:AppPxeBootImageLibraryShareName
    }
    if ([bool]$Cfg.smbOverlayEnabled) {
        $hostPart = if ([string]::IsNullOrWhiteSpace($LanIp)) {
            try { [System.Net.Dns]::GetHostName() } catch { 'localhost' }
        } else {
            [string]$LanIp
        }
        return "\\$hostPart\$shareName"
    }
    # TODO(Site Profile): the deploy-share host will come from the Site Profile.
    # Until then default to this machine's own share, same as the overlay branch.
    $hostPart = try { [System.Net.Dns]::GetHostName() } catch { 'localhost' }
    return "\\$hostPart\$shareName"
}

function Get-AppPxeBootImageDeployerOverlayCredentialPair {
    <#
    .SYNOPSIS
        Resolve overlay credential user + password for the configured creds mode.
        Returns @{ User; Pass } or $null when blank / unavailable.
    #>
    param([string]$CredsMode)
    $mode = if (Test-AppPxeBootImageDeployerOverlayCredsModeValue -Value $CredsMode) {
        ([string]$CredsMode).Trim()
    } else {
        'throwaway'
    }
    if ($mode -eq 'blank') { return $null }

    if ($mode -eq 'throwaway') {
        $cred = $null
        if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
            try {
                $root = if (Get-Command Get-AppImageLibraryRoot -ErrorAction SilentlyContinue) {
                    Get-AppImageLibraryRoot -NoCreate
                } else { $null }
                if (-not $root -and (Get-Command Get-AppImageLibraryRoot -ErrorAction SilentlyContinue)) {
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
            if (-not (Get-Command Test-AppInfraSshCredentialExists -ErrorAction SilentlyContinue)) { return $null }
            if (-not (Test-AppInfraSshCredentialExists -Id $id)) {
                Write-SidecarLog "PXE boot: vault credential '$id' not configured for ImageDeployer overlay"
                return $null
            }
            if (-not (Get-Command Get-AppInfraSshCredentialLoginNameById -ErrorAction SilentlyContinue)) { return $null }
            if (-not (Get-Command Get-AppInfraSshPlainPassword -ErrorAction SilentlyContinue)) { return $null }
            $user = Get-AppInfraSshCredentialLoginNameById -Id $id
            $pass = Get-AppInfraSshPlainPassword -Id $id
            if (-not [string]::IsNullOrWhiteSpace($user) -and -not [string]::IsNullOrWhiteSpace($pass)) {
                return @{ User = $user.Trim(); Pass = ([string]$pass).Trim() }
            }
        } catch {
            Write-SidecarLog "PXE boot: vault credential '$id' for ImageDeployer overlay unavailable - $($_.Exception.Message)"
        }
        return $null
    }

    return $null
}

function Write-AppPxeBootImageDeployerDeployOverlayFiles {
    <#
    .SYNOPSIS
        ImageDeployer Deploy$ overlay content writer (the 'imagedeployer-deploy' profile's
        PublishRuntime). Writes deploy.unc (local Deploy$ or on-site WDS) and deploy.cred
        (throwaway, DE, or vault credential) so ImageDeployer.ps1 auto-maps Z: when both
        user and password are present. The engine only calls this when the profile is enabled.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$LanIp
    )
    $uncFile = Join-Path $Dir 'deploy.unc'
    $credFile = Join-Path $Dir 'deploy.cred'
    $logHostFile = Join-Path $Dir 'loghost'
    $cfg = Read-AppPxeBootConfig

    $unc = Get-AppPxeBootImageDeployerDeployUnc -Cfg $cfg -LanIp $LanIp
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

    $credsMode = Get-AppPxeBootImageDeployerOverlayCredsMode -Cfg $cfg
    $pair = Get-AppPxeBootImageDeployerOverlayCredentialPair -CredsMode $credsMode
    if ($pair -and -not [string]::IsNullOrWhiteSpace($pair.User) -and -not [string]::IsNullOrWhiteSpace($pair.Pass)) {
        $credText = ('{0}{2}{1}{2}' -f $pair.User, $pair.Pass, "`r`n")
        Set-Content -LiteralPath $credFile -Value $credText -Encoding ASCII -NoNewline -Force
        # Runs on every menu/overlay regen - log at info only when the identity changes,
        # verbose otherwise (this line was drowning the sidecar log).
        $publishKey = "$($pair.User)|$credsMode"
        if ($script:AppPxeBootState.LastOverlayCredPublishKey -ne $publishKey) {
            $script:AppPxeBootState.LastOverlayCredPublishKey = $publishKey
            Write-SidecarLog "PXE boot: published ImageDeployer overlay credential ($($pair.User), mode=$credsMode)"
        } else {
            Write-SidecarLogVerbose "PXE boot: refreshed ImageDeployer overlay credential ($($pair.User), mode=$credsMode)"
        }
    } elseif (Test-Path -LiteralPath $credFile) {
        Remove-Item -LiteralPath $credFile -Force -ErrorAction SilentlyContinue
        $script:AppPxeBootState.LastOverlayCredPublishKey = $null
        Write-SidecarLog "PXE boot: ImageDeployer overlay credential not published (mode=$credsMode)"
    }
}

function Sync-AppPxeBootFieldIsoHttpAssets {
    <#
    .SYNOPSIS
        Copy HTTP-served FieldIso bootstrap (run.ps1, tools README) into the PXE store for Caddy.
    #>
    $paths = Get-AppPxeBootLayoutPaths
    foreach ($dir in @($paths.fieldisoDir, $paths.fieldisoToolsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }

    $bundled = Get-AppPxeBootFieldIsoBundledRoot
    if ($bundled) {
        $runSrc = Join-Path $bundled 'run.ps1'
        if (Test-Path -LiteralPath $runSrc) {
            Copy-Item -LiteralPath $runSrc -Destination $paths.fieldisoRunScript -Force
        }
        $smbTestSrc = Join-Path $bundled 'run-smb-test.ps1'
        if (Test-Path -LiteralPath $smbTestSrc) {
            Copy-Item -LiteralPath $smbTestSrc -Destination (Join-Path $paths.fieldisoDir 'run-smb-test.ps1') -Force
        }
        $toolsReadme = Join-Path $bundled 'tools\README.txt'
        if (Test-Path -LiteralPath $toolsReadme) {
            Copy-Item -LiteralPath $toolsReadme -Destination (Join-Path $paths.fieldisoToolsDir 'README.txt') -Force
        }
        foreach ($toolName in @('curl.exe', '7z.exe', '7za.dll', '7zxa.dll')) {
            $toolSrc = Join-Path $bundled "tools\$toolName"
            if (Test-Path -LiteralPath $toolSrc) {
                Copy-Item -LiteralPath $toolSrc -Destination (Join-Path $paths.fieldisoToolsDir $toolName) -Force
            }
        }
    }

    $cfg = Read-AppPxeBootConfig
    $port = [int]$cfg.httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $httpBase = Get-AppPxeBootLocalHttpBaseUrl
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId
    if ($lanIp) {
        Write-AppPxeBootFieldIsoBootstrapUrlFile -Path $paths.fieldisoBootstrapUrl -HttpBaseUrl $httpBase
    } elseif (Test-Path -LiteralPath $paths.fieldisoBootstrapUrl) {
        Remove-Item -LiteralPath $paths.fieldisoBootstrapUrl -Force -ErrorAction SilentlyContinue
    }
    Write-AppPxeBootFieldIsoSmbTestHttpAssets -Paths $paths -LanIp $lanIp
    Write-AppPxeBootWimOverlayRuntimeAssets -LanIp $lanIp

    @{
        runScript   = $paths.fieldisoRunScript
        bootstrapUrl = $paths.fieldisoBootstrapUrl
        toolsDir    = $paths.fieldisoToolsDir
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

function Get-AppPxeBootSiteIsoCatalogMenuLabel {
    'WinDeployKit boot ISO catalog'
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
    $fileName = Get-AppPxeBootBrandingPictureFileName
    if (-not $fileName) { return @() }
    @(
        "console --picture `${http_base}/branding/$fileName --left 110 --top 90 --right 90 --bottom 70"
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

function Get-AppPxeBootLocalIsoCatalogUrl {
    param([switch]$ForIpxe)
    return "$(Get-AppPxeBootLocalHttpBaseUrl -ForIpxe:$ForIpxe)/ISOs"
}

function Test-AppPxeBootLocalIsoCatalogReady {
    $fieldIsoWim = Get-AppPxeBootFieldIsoWimName
    if (-not $fieldIsoWim) { return $false }
    if (@(Get-AppPxeBootIsoInventory).Count -eq 0) { return $false }
    $menuPath = (Get-AppPxeBootLayoutPaths).isoCatalogMenu
    return (Test-Path -LiteralPath $menuPath)
}

function Test-AppPxeBootIsoCatalogStale {
    $paths = Get-AppPxeBootLayoutPaths
    $isos = @(Get-AppPxeBootIsoInventory)
    $fieldIsoWim = Get-AppPxeBootFieldIsoWimName
    $shouldHaveCatalog = ($isos.Count -gt 0) -and [bool]$fieldIsoWim

    if (-not $shouldHaveCatalog) {
        return (Test-Path -LiteralPath $paths.isoCatalogMenu) -or (Test-Path -LiteralPath $paths.isoCatalogJson)
    }
    # ISOs + FieldIso on disk but menu.ipxe / urls not built yet (typical after manual copy).
    if (-not (Test-AppPxeBootLocalIsoCatalogReady)) { return $true }
    if (-not (Test-Path -LiteralPath $paths.isoCatalogJson)) { return $true }

    try {
        $catalog = Get-Content -LiteralPath $paths.isoCatalogJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $catalogFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($catalog.entries)) {
            $path = [string](Get-AppSidecarJsonProp -Item $entry -Name 'path')
            if ($path -match '(?i)^iso/(.+)$') {
                [void]$catalogFiles.Add($Matches[1])
            }
        }
        $diskFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($iso in $isos) {
            [void]$diskFiles.Add([string]$iso.fileName)
        }
        if ($catalogFiles.Count -ne $diskFiles.Count) { return $true }
        foreach ($name in $diskFiles) {
            if (-not $catalogFiles.Contains($name)) { return $true }
        }
        return $false
    } catch {
        return $true
    }
}

function Sync-AppPxeBootIsoCatalogIfStale {
    if (-not (Test-AppPxeBootIsoCatalogStale)) { return $false }
    Write-AppPxeBootMenuFiles
    $isoCount = @(Get-AppPxeBootIsoInventory).Count
    Write-SidecarLog "PXE boot: regenerated ISO catalog and boot menu ($isoCount ISO(s) on disk)"
    return $true
}

function Write-AppPxeBootLocalIsoCatalog {
    param([switch]$SkipFieldIsoPrepare)

    $paths = Get-AppPxeBootLayoutPaths
    Initialize-AppPxeBootStore | Out-Null
    foreach ($dir in @($paths.isoCatalogDir, $paths.isoUrlDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }

    $cfg = Read-AppPxeBootConfig
    $port = [int]$cfg.httpPort
    if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
    $lanIp = Get-AppPxeBootLanIp -InterfaceId $cfg.interfaceId
    $fieldIsoWim = Get-AppPxeBootFieldIsoWimName
    $isos = @(Get-AppPxeBootIsoInventory)
    if ($isos.Count -gt 0 -and $fieldIsoWim -and -not $SkipFieldIsoPrepare) {
        try {
            Ensure-AppPxeBootFieldIsoBootAssets -SkipMenuRegen | Out-Null
        } catch {
            Write-SidecarLog "PXE boot: ISO catalog regen without FieldIso boot files - $($_.Exception.Message)"
        }
    }
    $wanBase = Get-AppPxeBootWanIsoCatalogUrl
    $wanDeployEnabled = Test-AppPxeBootWanDeployMenuEnabled
    $httpBaseLiteral = Get-AppPxeBootLocalHttpBaseUrl
    $catalogBaseLiteral = Get-AppPxeBootLocalIsoCatalogUrl
    $generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $expectedUrls = [System.Collections.Generic.HashSet[string]]::new()
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($iso in $isos) {
        $fileName = [string]$iso.fileName
        $slug = (Get-AppPxeBootIsoMenuItemId -FileName $fileName) -replace '^iso_', ''
        $urlFileName = "$slug.iso.url"
        $installWimUrlFileName = "$slug.install.wim.url"
        $urlPath = Join-Path $paths.isoUrlDir $urlFileName
        $installWimUrlPath = Join-Path $paths.isoUrlDir $installWimUrlFileName
        $isoHttpUrl = Get-AppPxeBootIsoHttpUrl -FileName $fileName -Port $port -LanIp $lanIp
        $installWimHttpUrl = Get-AppPxeBootInstallWimHttpUrl -FileName $fileName -Port $port -LanIp $lanIp
        Write-AppPxeBootIsoUrlFile -Path $urlPath -IsoHttpUrl $isoHttpUrl
        Write-AppPxeBootIsoUrlFile -Path $installWimUrlPath -IsoHttpUrl $installWimHttpUrl
        [void]$expectedUrls.Add($urlFileName)
        [void]$expectedUrls.Add($installWimUrlFileName)
        [void]$entries.Add(@{
                id      = $slug
                label   = if ($iso.label) { [string]$iso.label } else { ([IO.Path]::GetFileNameWithoutExtension($fileName) -replace '_', ' ') }
                type    = 'fieldiso-http'
                path    = "iso/$fileName"
                isoUrl  = "urls/$urlFileName"
                installWimUrl = "urls/$installWimUrlFileName"
                httpPort = $port
            })
    }

    foreach ($existing in @(Get-ChildItem -LiteralPath $paths.isoUrlDir -Filter '*.url' -File -ErrorAction SilentlyContinue)) {
        if (-not $expectedUrls.Contains($existing.Name)) {
            Remove-Item -LiteralPath $existing.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($entries.Count -eq 0 -or -not $fieldIsoWim) {
        foreach ($artifact in @($paths.isoCatalogMenu, $paths.isoCatalogJson)) {
            if (Test-Path -LiteralPath $artifact) {
                Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
            }
        }
        return @{
            entryCount = 0
            menuPath   = $paths.isoCatalogMenu
            catalogUrl = $catalogBaseLiteral
        }
    }

    $catalog = @{
        generated  = $generated
        baseUrl    = $catalogBaseLiteral
        entryCount = $entries.Count
        entries    = @($entries)
    }
    ($catalog | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $paths.isoCatalogJson -Encoding UTF8 -Force

    $catalogIpxeAcc = [System.Collections.Generic.List[string]]::new()
    [void]$catalogIpxeAcc.Add('#!ipxe')
    [void]$catalogIpxeAcc.Add("# fieldiso-ipxe-rev: $($script:AppPxeBootFieldIsoIpxeCatalogRevision)")
    [void]$catalogIpxeAcc.Add('# Generated by WinDeployKit - WinDeployKit boot ISO catalog')
    [void]$catalogIpxeAcc.Add("# $generated")
    [void]$catalogIpxeAcc.Add("set http_port $port")
    if ($wanDeployEnabled) {
        [void]$catalogIpxeAcc.Add("set deploy_base $wanBase")
    }
    [void]$catalogIpxeAcc.Add("set http_base $httpBaseLiteral")
    [void]$catalogIpxeAcc.Add("set catalog_base $catalogBaseLiteral")
    [void]$catalogIpxeAcc.Add('')
    [void]$catalogIpxeAcc.Add(':start')
    foreach ($line in @(Get-AppPxeBootMenuBrandingConsoleIpxeLines)) { [void]$catalogIpxeAcc.Add([string]$line) }
    [void]$catalogIpxeAcc.Add('menu WinDeployKit boot ISO catalog')
    foreach ($line in @(Get-AppPxeBootMenuBrandingSubtitleIpxeLines)) { [void]$catalogIpxeAcc.Add([string]$line) }
    [void]$catalogIpxeAcc.Add('item --gap -- ----- WinDeployKit (HTTP) -----')
    if ($fieldIsoWim) {
        [void]$catalogIpxeAcc.Add('item --gap -- ----- Lab -----')
        [void]$catalogIpxeAcc.Add((Format-AppPxeBootIpxeMenuItemLine -Id 'fieldiso_smb_test' -Label 'FieldIso SMB test (macOS share)'))
    }
    foreach ($entry in @($entries)) {
        [void]$catalogIpxeAcc.Add("item $($entry.id)`t$($entry.label)")
    }
    if ($wanDeployEnabled) {
        [void]$catalogIpxeAcc.Add('item --gap -- ----- Backup -----')
        [void]$catalogIpxeAcc.Add((Format-AppPxeBootIpxeMenuItemLine -Id 'wan_catalog' -Label 'Deploy server catalog (WAN)'))
    }
    foreach ($line in @(Get-AppPxeBootIpxeMenuUtilityItemLines)) { [void]$catalogIpxeAcc.Add([string]$line) }
    [void]$catalogIpxeAcc.Add('choose target || goto start')
    [void]$catalogIpxeAcc.Add('goto ${target}')
    [void]$catalogIpxeAcc.Add('')

    if ($fieldIsoWim) {
        [void]$catalogIpxeAcc.Add(':fieldiso_smb_test')
        foreach ($line in (Get-AppPxeBootFieldIsoSmbTestIpxeBlock -FieldIsoWim $fieldIsoWim)) {
            [void]$catalogIpxeAcc.Add($line)
        }
    }

    [void]$catalogIpxeAcc.Add(':retry')
    [void]$catalogIpxeAcc.Add('chain ${catalog_base}/menu.ipxe?t=${buildsign} || chain ${catalog_base}/menu.ipxe || goto start')
    [void]$catalogIpxeAcc.Add('')
    foreach ($line in @(Get-AppPxeBootIpxeLocalDiskHandlerLines)) { [void]$catalogIpxeAcc.Add([string]$line) }
    [void]$catalogIpxeAcc.Add(':shell')
    [void]$catalogIpxeAcc.Add('shell')
    [void]$catalogIpxeAcc.Add('goto start')
    if ($wanDeployEnabled) {
        [void]$catalogIpxeAcc.Add('')
        [void]$catalogIpxeAcc.Add(':wan_catalog')
        [void]$catalogIpxeAcc.Add('echo Loading deploy ISO catalog (WAN)...')
        [void]$catalogIpxeAcc.Add('chain ${deploy_base}/menu.ipxe?t=${buildsign} || chain ${deploy_base}/menu.ipxe || goto start')
        [void]$catalogIpxeAcc.Add('')
    }

    foreach ($entry in @($entries)) {
        $eid = [string]$entry.id
        $urlRel = [string]$entry.isoUrl
        [void]$catalogIpxeAcc.Add(":$eid")
        foreach ($line in (Get-AppPxeBootFieldIsoBootIpxeBlock -EntryLabel ([string]$entry.label) -UrlRel $urlRel -FieldIsoWim $fieldIsoWim)) {
            [void]$catalogIpxeAcc.Add($line)
        }
    }

    ($catalogIpxeAcc -join "`n").TrimEnd() + "`n" | Set-Content -LiteralPath $paths.isoCatalogMenu -Encoding UTF8 -Force
    Write-SidecarLog "PXE boot: wrote local ISO catalog ($($entries.Count) ISO(s)) at ISOs/menu.ipxe"
    @{
        entryCount = $entries.Count
        menuPath   = $paths.isoCatalogMenu
        catalogUrl = $catalogBaseLiteral
    }
}

function Get-AppPxeBootIsoCatalogMenuIpxeLines {
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-AppPxeBootWanDeployMenuEnabled)) {
        if (-not (Test-AppPxeBootLocalIsoCatalogReady)) {
            return @()
        }
        $siteCatalog = Get-AppPxeBootSiteIsoCatalogMenuLabel
        return @("item iso_catalog`t$siteCatalog")
    }
    $siteCatalog = Get-AppPxeBootSiteIsoCatalogMenuLabel
    $useLocalPrimary = ([string]$Config.isoCatalogSource -ne 'wan') -and (Test-AppPxeBootLocalIsoCatalogReady)
    if ($useLocalPrimary) {
        return @("item iso_catalog`t$siteCatalog")
    }
    return @((Format-AppPxeBootIpxeMenuItemLine -Id 'iso_catalog' -Label 'Deploy server ISO catalog (WAN)'))
}

function Get-AppPxeBootIsoCatalogBootIpxeBlock {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$HttpPort
    )
    $block = [System.Collections.Generic.List[string]]::new()
    $wanDeployEnabled = Test-AppPxeBootWanDeployMenuEnabled
    $useLocalPrimary = ([string]$Config.isoCatalogSource -ne 'wan') -and (Test-AppPxeBootLocalIsoCatalogReady)
    $siteCatalog = Get-AppPxeBootSiteIsoCatalogMenuLabel
    [void]$block.Add(':iso_catalog')
    if ($useLocalPrimary -or -not $wanDeployEnabled) {
        if (Test-AppPxeBootLocalIsoCatalogReady) {
            [void]$block.Add("echo Loading $siteCatalog...")
            if ($wanDeployEnabled) {
                [void]$block.Add('chain ${catalog_base}/menu.ipxe?t=${buildsign} || chain ${catalog_base}/menu.ipxe || goto iso_catalog_wan')
                [void]$block.Add(':iso_catalog_wan')
                [void]$block.Add('echo Loading deploy ISO catalog (WAN backup)...')
                [void]$block.Add('chain ${deploy_base}/menu.ipxe?t=${buildsign} || chain ${deploy_base}/menu.ipxe || goto start')
            } else {
                [void]$block.Add('chain ${catalog_base}/menu.ipxe?t=${buildsign} || chain ${catalog_base}/menu.ipxe || goto iso_catalog_failed')
                [void]$block.Add(':iso_catalog_failed')
                [void]$block.Add('echo Local ISO catalog failed - check HTTP and ISOs/FieldIso.wim in Netboot.')
                [void]$block.Add('goto start')
            }
        } else {
            [void]$block.Add('echo Local ISO catalog not ready - add FieldIso.wim and ISOs in Netboot.')
            [void]$block.Add('goto start')
        }
    } else {
        [void]$block.Add('echo Loading deploy ISO catalog...')
        [void]$block.Add('chain ${deploy_base}/menu.ipxe?t=${buildsign} || chain ${deploy_base}/menu.ipxe || goto start')
    }
    [void]$block.Add('')
    return @($block)
}

function Get-AppPxeBootFieldIsoWimName {
    $paths = Get-AppPxeBootLayoutPaths
    foreach ($candidate in @('FieldIso.wim', 'FieldISO.wim')) {
        if (Test-Path -LiteralPath (Join-Path $paths.wimDir $candidate)) {
            return $candidate
        }
    }
    foreach ($wim in @(Get-AppPxeBootWimInventory)) {
        if (Test-AppPxeBootWimIsFieldIso -FileName $wim.fileName) {
            return [string]$wim.fileName
        }
    }
    return $null
}

function Get-AppPxeBootFieldIsoManifestDefaultUrls {
    $base = 'https://artifacts.example.com/api/v4/projects/MacsInSpace%2Fwindeploykit/packages/generic/windeploykit/latest'
    @{
        Manifest = if ($env:APP_PXE_FIELDISO_MANIFEST_URL) {
            [string]$env:APP_PXE_FIELDISO_MANIFEST_URL
        } else {
            "$base/pxe-fieldiso.json"
        }
        Wim = if ($env:APP_PXE_FIELDISO_WIM_URL) {
            [string]$env:APP_PXE_FIELDISO_WIM_URL
        } else {
            "$base/FieldIso.wim"
        }
    }
}

function Get-AppPxeBootFieldIsoBundledManifestPath {
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if (-not $root) { return $null }
    $path = Join-Path $root 'packaging/pxe-fieldiso.json'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppPxeBootFieldIsoManifestProp {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name
    )
    # Sidecar runs under Set-StrictMode (NpsLogViewer.ps1); optional JSON keys must not be accessed directly.
    if (-not $Item) { return $null }
    if (-not ($Item.PSObject.Properties.Name -contains $Name)) { return $null }
    return $Item.$Name
}

function Read-AppPxeBootFieldIsoManifestObject {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    $schemaVal = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'schema'
    $schema = if ($null -ne $schemaVal) { [int]$schemaVal } else { 0 }
    if ($schema -ne 1) { return $null }
    $defaultUrls = Get-AppPxeBootFieldIsoManifestDefaultUrls
    $fileNameProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'fileName'
    $fileName = if ($fileNameProp) { [string]$fileNameProp } else { 'FieldIso.wim' }
    $wimUrlProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'wimUrl'
    $wimUrl = if ($wimUrlProp) { [string]$wimUrlProp.Trim() } else { $defaultUrls.Wim }
    $labelProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'label'
    $sizeProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'sizeBytes'
    $shaProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'sha256'
    $manifestUrlProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'manifestUrl'
    $updatedProp = Get-AppPxeBootFieldIsoManifestProp -Item $Obj -Name 'updated'
    @{
        schema      = 1
        fileName    = $fileName
        label       = if ($labelProp) { [string]$labelProp } else { 'FieldIso.wim' }
        sizeBytes   = if ($null -ne $sizeProp) { [long]$sizeProp } else { 0 }
        sha256      = if ($shaProp) { [string]$shaProp.Trim().ToLower() } else { $null }
        wimUrl      = $wimUrl
        manifestUrl = if ($manifestUrlProp) { [string]$manifestUrlProp.Trim() } else { $defaultUrls.Manifest }
        updated     = if ($updatedProp) { [string]$updatedProp } else { $null }
        source      = 'unknown'
    }
}

function Get-AppPxeBootFieldIsoManifest {
    param([switch]$UseCache)

    if ($UseCache -and $null -ne $script:AppPxeBootFieldIsoManifestCache -and $script:AppPxeBootFieldIsoManifestCacheAt) {
        $age = ((Get-Date) - $script:AppPxeBootFieldIsoManifestCacheAt).TotalSeconds
        if ($age -lt 300) {
            return $script:AppPxeBootFieldIsoManifestCache
        }
    }

    $urls = Get-AppPxeBootFieldIsoManifestDefaultUrls
    $result = $null
    if ($env:APP_SKIP_REMOTE_PXE_FIELDISO_MANIFEST -ne '1') {
        try {
            $remote = Invoke-RestMethod -Uri $urls.Manifest -Method Get -TimeoutSec 15 -Headers @{ Accept = 'application/json' } -ErrorAction Stop
            $parsed = Read-AppPxeBootFieldIsoManifestObject -Obj $remote
            if ($parsed) {
                $parsed['source'] = 'remote'
                $result = $parsed
            }
        } catch {
            Write-SidecarLogVerbose "PXE boot: FieldIso manifest fetch failed ($($urls.Manifest)): $($_.Exception.Message)"
        }
    }
    if (-not $result) {
        $bundledPath = Get-AppPxeBootFieldIsoBundledManifestPath
        if ($bundledPath) {
            try {
                $local = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $parsed = Read-AppPxeBootFieldIsoManifestObject -Obj $local
                if ($parsed) {
                    $parsed['source'] = 'bundled'
                    $result = $parsed
                }
            } catch {
                Write-SidecarLogVerbose "PXE boot: bundled FieldIso manifest read failed: $($_.Exception.Message)"
            }
        }
    }
    if (-not $result) {
        $result = @{
            schema      = 1
            fileName    = 'FieldIso.wim'
            label       = 'FieldIso.wim'
            sizeBytes   = 335544320
            sha256      = $null
            wimUrl      = $urls.Wim
            manifestUrl = $urls.Manifest
            updated     = $null
            source      = 'default'
        }
    }
    $script:AppPxeBootFieldIsoManifestCache = $result
    $script:AppPxeBootFieldIsoManifestCacheAt = Get-Date
    return $result
}

function Test-AppPxeBootFieldIsoWimFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256,
        [long]$MinSizeBytes = 104857600
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt $MinSizeBytes) { return $false }
    if ($ExpectedSha256) {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $ExpectedSha256.ToLower()) { return $false }
    }
    return $true
}

function Get-AppPxeBootFieldIsoDownloadStatus {
    param([switch]$SkipHash)
    $manifest = Get-AppPxeBootFieldIsoManifest -UseCache:$SkipHash
    $fileName = Get-AppPxeBootFieldIsoWimName
    $paths = Get-AppPxeBootLayoutPaths
    $dest = Join-Path $paths.wimDir 'FieldIso.wim'
    $sizeBytes = $null
    $sha256 = $null
    if ($fileName -and (Test-Path -LiteralPath $dest)) {
        $item = Get-Item -LiteralPath $dest
        $sizeBytes = [long]$item.Length
        if ($manifest.sha256 -and -not $SkipHash) {
            $sha256 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
        }
    }
    @{
        present      = [bool]$fileName
        fileName     = $fileName
        sizeBytes    = $sizeBytes
        sha256       = $sha256
        expectedSize = [long]$manifest.sizeBytes
        expectedSha256 = $manifest.sha256
        wimUrl       = [string]$manifest.wimUrl
        manifestUrl  = [string]$manifest.manifestUrl
        manifestSource = [string]$manifest.source
        label        = [string]$manifest.label
    }
}

function Download-AppPxeBootFieldIsoWim {
    param([switch]$ReplaceExisting)
    $manifest = Get-AppPxeBootFieldIsoManifest
    $targetName = Get-AppPxeBootSafeWimFileName -FileName ([string]$manifest.fileName)
    $paths = Initialize-AppPxeBootStore
    $dest = Join-Path $paths.wimDir $targetName
    if ((Test-Path -LiteralPath $dest) -and -not $ReplaceExisting) {
        if (Test-AppPxeBootFieldIsoWimFile -Path $dest -ExpectedSha256 $manifest.sha256) {
            try { Ensure-AppPxeBootFieldIsoBootAssets -SkipMenuRegen | Out-Null } catch { }
            return @{
                fileName  = $targetName
                sizeBytes = [long](Get-Item -LiteralPath $dest).Length
                skipped   = $true
                library   = (Get-AppPxeBootWimLibraryResponse)
            }
        }
        throw "PXE boot: $targetName already exists - use replace to re-download."
    }

    $wimUrl = [string]$manifest.wimUrl
    if ([string]::IsNullOrWhiteSpace($wimUrl)) {
        throw 'PXE boot: FieldIso download URL not configured.'
    }

    $tmp = Join-Path $paths.storeRoot ("download-$targetName.part")
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $sizeMb = if ($manifest.sizeBytes -gt 0) { [math]::Round($manifest.sizeBytes / 1MB, 0) } else { 320 }
    Write-SidecarLog "PXE boot: downloading $targetName (~${sizeMb} MB)..."
    try {
        Invoke-WebRequest -Uri $wimUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 3600 -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw "PXE boot: FieldIso download failed - $($_.Exception.Message)"
    }

    if (-not (Test-AppPxeBootFieldIsoWimFile -Path $tmp -ExpectedSha256 $manifest.sha256)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw 'PXE boot: downloaded FieldIso.wim failed validation (size or SHA256).'
    }

    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-SidecarLog "PXE boot: installed $targetName ($([math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1)) MB)"
    Sync-AppPxeBootFieldIsoWinPeOverlay -WimPath $dest | Out-Null
    Ensure-AppPxeBootFieldIsoBootAssets -SkipMenuRegen | Out-Null
    Write-AppPxeBootMenuFiles
    @{
        fileName  = $targetName
        sizeBytes = [long](Get-Item -LiteralPath $dest).Length
        skipped   = $false
        library   = (Get-AppPxeBootWimLibraryResponse)
    }
}

function Get-AppPxeBootOptionalAssetsManifestDefaultUrl {
    $base = 'https://artifacts.example.com/api/v4/projects/MacsInSpace%2Fwindeploykit/packages/generic/windeploykit/latest'
    if ($env:APP_PXE_OPTIONAL_ASSETS_MANIFEST_URL) {
        return [string]$env:APP_PXE_OPTIONAL_ASSETS_MANIFEST_URL
    }
    return "$base/pxe-optional-assets.json"
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

    if ($kind -eq 'wim' -and -not (Test-AppPxeBootWimIsFieldIso -FileName $targetName)) {
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
    $cfg = Read-AppPxeBootConfig
    $defaultName = if ($cfg.defaultBootIso) { [string]$cfg.defaultBootIso } else { $null }
    $files = @(Get-ChildItem -LiteralPath $paths.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    @($files | ForEach-Object {
        $name = $_.Name
        @{
            fileName   = $name
            sizeBytes  = [long]$_.Length
            modifiedAt = $_.LastWriteTimeUtc.ToString('o')
            httpPath   = "iso/$name"
            isoUrlRel  = Get-AppPxeBootIsoUrlRel -FileName $name
            label      = ([IO.Path]::GetFileNameWithoutExtension($name) -replace '_', ' ')
            isDefault  = ($defaultName -and ($name -eq $defaultName))
        }
    })
}

function Test-AppPxeBootLayout {
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
    if (Get-AppPxeBootFieldIsoWimName) {
        if (-not (Test-AppPxeBootFieldIsoWinPePowerShellInjectAvailable)) {
            [void]$warnings.Add(
                'FieldIso.wim - WinPE-PowerShell not built in (wim-inject/ empty). On Windows: scripts/prepare-fieldiso-wim-inject.ps1, then Mac: inject-fieldiso-winpe-tools.sh or rebuild FieldIso.wim'
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
        [void]$warnings.Add('http/wim/*.wim - add a boot WIM below (ImageDeployer.wim / TechTools)')
    }
    if ($isoFiles.Count -gt 0) {
        $fieldIso = Get-AppPxeBootFieldIsoWimName
        if (-not $fieldIso) {
            [void]$warnings.Add('http/iso/*.iso - local ISO boot needs FieldIso.wim in Boot WIM library')
        } elseif (-not (Test-AppPxeBootWimBootAssetsComplete -WimFileName $fieldIso)) {
            [void]$warnings.Add(
                "http/wim-boot/FieldIso/ - BCD/boot.sdi/bootmgfw missing (save settings or add an ISO to regen; ISO catalog boot will fail UEFI until fixed)"
            )
        } elseif (Test-AppPxeBootIsoCatalogStale) {
            [void]$warnings.Add('http/ISOs/menu.ipxe - catalog stale; save settings, start field PXE, or wait for status refresh')
        }
        foreach ($iso in $isoFiles) {
            # Mount-and-serve only: install.wim is exposed live from the mounted ISO
            # once imaging services run - warn only when services are up but the
            # mount failed. (Extraction removed 2026-08-18: duplicated multi-GB WIMs.)
            $isoBase = [IO.Path]::GetFileNameWithoutExtension((Get-AppPxeBootSafeIsoFileName -FileName $iso.Name))
            $mount = $script:AppPxeBootState.IsoMounts[$isoBase]
            $httpRunning = $script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited
            if ($httpRunning -and (-not $mount -or -not (Test-Path -LiteralPath $mount.installWim))) {
                [void]$warnings.Add(
                    "iso-wim/$isoBase/install.wim - ISO not mounted (check the ISO contains sources/install.wim; Stop then Start Imaging Services)"
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

    $drivers = Get-AppPxeBootFieldIsoDriversSummary
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
        defaultBootIso     = if ($cfg.defaultBootIso) { [string]$cfg.defaultBootIso } else { $null }
        wims               = @(Get-AppPxeBootWimInventory)
        isos               = @(Get-AppPxeBootIsoInventory)
        fieldIsoWim        = Get-AppPxeBootFieldIsoWimName
        isoCatalogSource   = if ($cfg.isoCatalogSource -eq 'wan') { 'wan' } else { 'local' }
        localHttpOnly      = -not (Test-AppPxeBootWanDeployMenuEnabled)
        localIsoCatalogUrl = Get-AppPxeBootLocalIsoCatalogUrl
        wanIsoCatalogUrl   = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        isoCatalogReady    = (Test-AppPxeBootLocalIsoCatalogReady)
        fieldIsoDrivers    = $drivers
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

function Get-AppPxeBootNetworkAdapters {
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

function Get-AppPxeBootLanIp {
    param([string]$InterfaceId)
    $adapter = Resolve-AppPxeBootSelectedAdapter -InterfaceId $InterfaceId
    if (-not $adapter) { return $null }
    $ip = @($adapter.ipv4 | Where-Object { $_ -and -not (Test-AppIsExcludedLocationIPv4 $_) } | Select-Object -First 1)
    if ($ip) { return [string]$ip }
    return $null
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
    if ($IsMacOS) {
        foreach ($candidate in @(
            '/opt/homebrew/opt/dnsmasq/sbin/dnsmasq'
            '/usr/local/opt/dnsmasq/sbin/dnsmasq'
        )) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
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
    if (-not (Get-Command ConvertTo-AppUnixShellSingleQuotedString -ErrorAction SilentlyContinue)) {
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
    [void]$lines.Add("# WinDeployKit PXE boot - generated $(Get-Date -Format 'o')")
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
    $base = 'https://artifacts.example.com/api/v4/projects/MacsInSpace%2Fwindeploykit/packages/generic/windeploykit/latest'
    if ($env:APP_PXE_CADDY_MANIFEST_URL) {
        return [string]$env:APP_PXE_CADDY_MANIFEST_URL
    }
    return "$base/pxe-caddy.json"
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
        if ($installed -ne $script:AppPxeBootCaddyVersion) { return $false }
    }
    return $true
}

function Get-AppPxeBootCaddyPath {
    if ($env:WINDEPLOYKIT_PXE_CADDY -and (Test-Path -LiteralPath $env:WINDEPLOYKIT_PXE_CADDY -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:WINDEPLOYKIT_PXE_CADDY).Path
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
    throw 'PXE boot: Caddy manifest unavailable (GitLab + bundled copy both failed).'
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
            -UserAgent 'WinDeployKit' -MaximumRedirection 5 -TimeoutSec 600 -ErrorAction Stop
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
        # listener (ImageDeployer live-log push). 0 = route omitted; clients fail fast.
        [int]$ImagingLogIngestPort = 0
    )
    $rootNorm = ($HttpRoot -replace '\\', '/')
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
                @{ prefix = 'WIMs';    dir = $lib.wimsDir }
            )) {
            $dirNorm = ([string]$route.dir -replace '\\', '/')
            $routeLines += @(
                "    handle_path /$($route.prefix)/* {"
                "        root * `"$dirNorm`""
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

    # Imaging-log ingest: must precede the catch-all file_server handle.
    if ($ImagingLogIngestPort -gt 0) {
        $routeLines += @(
            '    handle /imaging-log/* {'
            "        reverse_proxy 127.0.0.1:$ImagingLogIngestPort"
            '    }'
        )
    }

    $lines = @(
        "# WinDeployKit Netboot - generated $(Get-Date -Format 'o')"
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
    $base = 'https://artifacts.example.com/api/v4/projects/MacsInSpace%2Fwindeploykit/packages/generic/windeploykit/latest'
    if ($env:APP_PXE_TFTPD64_MANIFEST_URL) {
        return [string]$env:APP_PXE_TFTPD64_MANIFEST_URL
    }
    return "$base/pxe-tftpd64.json"
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
        if ($installed -ne $script:AppPxeBootTftpd64Version) { return $false }
    }
    return $true
}

function Get-AppPxeBootTftpd64Path {
    if ($env:WINDEPLOYKIT_PXE_TFTPD64 -and (Test-Path -LiteralPath $env:WINDEPLOYKIT_PXE_TFTPD64 -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:WINDEPLOYKIT_PXE_TFTPD64).Path
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
    throw 'PXE boot: Tftpd64 manifest unavailable (GitLab + bundled copy both failed).'
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
        @{ DisplayName = 'WinDeployKit Netboot TFTP (UDP 69)'; Protocol = 'UDP'; LocalPort = 69 }
        @{ DisplayName = "WinDeployKit Netboot HTTP (TCP $HttpPort)"; Protocol = 'TCP'; LocalPort = $HttpPort }
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
            $progName = 'WinDeployKit Netboot Tftpd64'
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
    if (-not (Get-Command ConvertTo-AppUnixShellSingleQuotedString -ErrorAction SilentlyContinue)) {
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
    if (-not (Get-Command ConvertTo-AppUnixShellSingleQuotedString -ErrorAction SilentlyContinue)) {
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
    [void]$parts.Add('brew services stop dnsmasq 2>/dev/null || true')
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
        if ($killShell -and (Get-Command Invoke-AppMacOsAdminShellCommand -ErrorAction SilentlyContinue)) {
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
            Write-SidecarLog "PXE boot: stopped WinDeployKit dnsmasq (port 69 cleared, pid $before)"
            return $true
        }
        if ($before -gt 0) {
            Write-SidecarLog "PXE boot: WinDeployKit dnsmasq still holding port 69 (pid $before)"
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
            Write-SidecarLog "PXE boot: stopped WinDeployKit dnsmasq (pids: $($procIds -join ', '))"
        }
        return $procIds.Count -gt 0
    }

    Write-SidecarLog "PXE boot: WinDeployKit dnsmasq still running (pids: $($stillAlive -join ', '))"
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
                'Stop PXE services in WinDeployKit, or stop brew dnsmasq / another TFTP server, then retry.'
            ) -join ' '
        }

        if (Test-AppPxeBootDnsmasqIsOurs -ProcessId $holder -ConfPath $confPath) {
            return @(
                "PXE boot: UDP port 69 is held by a previous WinDeployKit dnsmasq (pid $holder)."
                'WinDeployKit will try to clear this automatically when you start TFTP.'
            ) -join ' '
        }

        $procName = ''
        try { $procName = (Get-Process -Id $holder -ErrorAction SilentlyContinue).ProcessName } catch { }
        $nameHint = if ($procName) { " ($procName)" } else { '' }
        return @(
            "PXE boot: UDP port 69 is already in use (pid $holder$nameHint)."
            'Stop the other TFTP server (brew dnsmasq, setup-laptop-macos.sh, etc.) and retry.'
        ) -join ' '
    } catch {
        return $null
    }
}

function Stop-AppPxeBootBrewDnsmasqIfRunning {
    if (-not ($IsMacOS -or $IsDarwin)) { return }
    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) { return }
    try {
        $list = (& brew services list 2>$null | Out-String)
        if ($list -notmatch 'dnsmasq\s+started') { return }
        Write-SidecarLog 'PXE boot: stopping brew dnsmasq background service'
        if (Get-Command Invoke-AppMacOsAdminShellCommand -ErrorAction SilentlyContinue) {
            Invoke-AppMacOsAdminShellCommand -ShellCommand 'brew services stop dnsmasq 2>/dev/null || true' -AllowFailure | Out-Null
        }
    } catch { }
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
        Truncate the PXE activity log (dnsmasq/TFTP) shown in Monitoring.
        Truncates in place rather than deleting so a running dnsmasq keeps its
        open handle and continues appending.
    #>
    $storeRoot = Get-AppPxeBootStoreRoot
    $logPath = Join-Path $storeRoot 'dnsmasq.log'
    $result = [ordered]@{ cleared = $false; path = $logPath }
    if (-not (Test-Path -LiteralPath $logPath)) { return $result }
    try {
        Set-Content -LiteralPath $logPath -Value '' -NoNewline -ErrorAction Stop
        $result.cleared = $true
        Write-SidecarLog 'PXE boot: activity log cleared.'
    } catch {
        Write-SidecarLog "PXE boot: could not clear activity log - $($_.Exception.Message)"
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
    if (-not $script:AppPxeBootState.TftpElevatedPid) { return }
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
    if (-not (Get-Command Invoke-AppMacOsAdminShellCommand -ErrorAction SilentlyContinue)) {
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
            if ($path -and ($path -match 'pxe-boot|WinDeployKit|windeploykit')) { return $true }
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
            $hint = if ($detail) { $detail } else { 'check Windows Firewall (WinDeployKit adds rules automatically when permitted)' }
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
        throw 'PXE boot: bundled dnsmasq not found - run ./scripts/build-dnsmasq-macos.sh and rebuild, or brew install dnsmasq.'
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

function Get-AppPxeBootHttpServerProcessIds {
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
                "PXE boot: TCP port $Port is held by a previous WinDeployKit HTTP server (pid $holder)."
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
    # Per-client imaging logs pushed by ImageDeployer's Write-Log over HTTP. Lives beside
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
        Loopback ingest endpoint for ImageDeployer imaging-log pushes. Caddy reverse-proxies
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
                        # property read happens before the comparison. The agent contract
                        # is still in flux, so read every field defensively.
                        $payloadLines = @(Get-AppSidecarJsonProp -Item $payload -Name 'lines')
                        if ($payload -and $payloadLines.Count -gt 0 -and $null -ne $payloadLines[0]) {
                            $serialRaw = [string](Get-AppSidecarJsonProp -Item $payload -Name 'serial')
                            if ([string]::IsNullOrWhiteSpace($serialRaw)) { $serialRaw = 'UNKNOWN' }
                            # Leading dots would make the file hidden on macOS (and invisible to
                            # the non -Force Get-ChildItem readers) - trim them off too.
                            $serial = ($serialRaw.Trim() -replace '[^A-Za-z0-9._-]', '-').TrimStart('.', '-')
                            if ([string]::IsNullOrWhiteSpace($serial)) { $serial = 'UNKNOWN' }
                            if ($serial.Length -gt 64) { $serial = $serial.Substring(0, 64) }
                            $logPath = Join-Path $LogDir "$serial.log"
                            $newLines = @($payloadLines | ForEach-Object { [string]$_ })
                            $newLines | Out-File -Append -FilePath $logPath -Encoding utf8
                            # Cap runaway logs: keep the newest 1500 lines past 4MB.
                            try {
                                $item = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
                                if ($item -and $item.Length -gt 4MB) {
                                    $tail = Get-Content -LiteralPath $logPath -Tail 1500 -ErrorAction SilentlyContinue
                                    Set-Content -LiteralPath $logPath -Value ($tail -join [Environment]::NewLine) -Encoding utf8
                                }
                            } catch { }
                            $statusPath = Join-Path $LogDir "$serial.json"
                            if (-not $clientIp) {
                                # No X-Forwarded-For on this push - keep the last known IP.
                                try {
                                    $previous = Get-Content -LiteralPath $statusPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                                    $prevIp = Get-AppSidecarJsonProp -Item $previous -Name 'ip'
                                    if ($prevIp) { $clientIp = [string]$prevIp }
                                } catch { }
                            }
                            $statusInfo = [ordered]@{
                                serial      = $serialRaw.Trim()
                                make        = [string](Get-AppSidecarJsonProp -Item $payload -Name 'make')
                                model       = [string](Get-AppSidecarJsonProp -Item $payload -Name 'model')
                                ip          = [string]$clientIp
                                lastSeenUtc = [DateTime]::UtcNow.ToString('o')
                                lastLine    = [string]($newLines | Select-Object -Last 1)
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
        newest activity first. active = pushed within the last 3 minutes (ImageDeployer
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
        [string]$InterfaceId
    )

    Clear-AppPxeBootLegacyHttpRunner

    Sync-AppPxeBootHttpProcessState -Port $Port
    if ($script:AppPxeBootState.HttpProcess -and -not $script:AppPxeBootState.HttpProcess.HasExited) {
        return @{ ok = $true; detail = 'HTTP already running'; backend = 'caddy' }
    }

    $paths = Get-AppPxeBootLayoutPaths
    $caddyConfig = $paths.caddyfile
    $storeRoot = Get-AppPxeBootStoreRoot
    $holder = Get-AppPxeBootHttpPortProcessId -Port $Port
    $orphanIds = @(Get-AppPxeBootHttpServerProcessIds -Port $Port)

    if ($holder -gt 0) {
        if (Test-AppPxeBootHttpProcessIsOurs -ProcessId $holder -CaddyConfigPath $caddyConfig -StoreRoot $storeRoot) {
            Write-SidecarLog "PXE boot: port $Port blocked by previous WinDeployKit Caddy (pid $holder) - clearing"
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
    $ingestPort = Start-AppPxeBootImagingLogIngest

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

function Get-AppPxeBootStatus {
    param(
        [switch]$SkipCatalogSync,
        [switch]$SkipLayoutProbe,
        [switch]$SkipHeavyChecks,
        $Layout
    )

    if (-not $SkipCatalogSync) {
        Sync-AppPxeBootIsoCatalogIfStale | Out-Null
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
        isoCatalogSource     = if ($cfg.isoCatalogSource -eq 'wan') { 'wan' } else { 'local' }
        localHttpOnly        = -not (Test-AppPxeBootWanDeployMenuEnabled)
        localIsoCatalogUrl   = Get-AppPxeBootLocalIsoCatalogUrl
        wanIsoCatalogUrl     = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        localIsoCatalogReady = (Test-AppPxeBootLocalIsoCatalogReady)
        router               = $router
        bundledSnponly    = [bool](Get-AppPxeBootBundledSnponlyPath)
        bundledWimboot    = [bool](Get-AppPxeBootBundledWimbootPath)
        bundledSecureBoot = [bool](Get-AppPxeBootBundledSecureBootTftpRoot)
        dnsmasqPath       = Resolve-AppPxeBootDnsmasqPath
        tftpd64Path       = Resolve-AppPxeBootTftpd64Path -ConfiguredPath $cfg.tftpd64Path
        defaultBootWim    = $defaultWim
        defaultBootWimUrl = $defaultBootWimUrl
        defaultBootIso    = Get-AppPxeBootDefaultIsoName
        bootChainMode     = Get-AppPxeBootBootChainMode
        defaultWimbootKernelOptions = if ($defaultWim) {
            Format-AppPxeBootWimbootKernelOptions -Recipe (Get-AppPxeBootWimbootRecipe -WimFileName $defaultWim)
        } else { $null }
        defaultWimbootUsesBootAssets = if ($defaultWim) {
            [bool](Get-AppPxeBootWimBootAssetsDir -WimFileName $defaultWim)
        } else { $false }
        wims              = @(Get-AppPxeBootWimInventory)
        isos              = @(Get-AppPxeBootIsoInventory)
        fieldIsoWim       = Get-AppPxeBootFieldIsoWimName
        fieldIso          = Get-AppPxeBootFieldIsoDownloadStatus -SkipHash:$SkipHeavyChecks
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
        macOsAdminCredentialCached = if ($platform -eq 'macos' -and (Get-Command Get-AppMacOsAdminCredentialCacheStatus -ErrorAction SilentlyContinue)) {
            [bool](Get-AppMacOsAdminCredentialCacheStatus).cached
        } else {
            $false
        }
        localMachineCredentialConfigured = if (Get-Command Test-AppLocalMachineCredentialConfigured -ErrorAction SilentlyContinue) {
            [bool](Test-AppLocalMachineCredentialConfigured)
        } else {
            $false
        }
        tftpBootFile      = Get-AppPxeBootConfiguredTftpBootFile
        tftpBootFiles     = @(Get-AppPxeBootTftpBootFileInventory)
    }
}

# Hidden, read-only SMB share exposing the image library root as a
# Deploy$-equivalent so ImageDeployer reads <root>\Drivers\<model> and <root>\WIMs
# the same way it reads the configured deploy share.
$script:AppPxeBootImageLibraryShareName = 'Deploy$'

# --- Throwaway SMB account (reused from the FieldIso authenticated-SMB spike) ---
# WinPE/ImageDeployer can consume a low-value local WORKGROUP account for Deploy$
# auto-connect (credentials carried in the overlay's deploy.cred). Same cred file the
# FieldIso smb-test serves, so the two share one throwaway account.
function Get-AppPxeBootSmbCredFilePath {
    Join-Path (Get-AppPxeBootStoreRoot) 'fieldiso-smb-test.cred'
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
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
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
        Write-SidecarLog "PXE boot: throwaway SMB user '$user' is missing and this app is not elevated; cannot create local account. Run WinDeployKit as Administrator once or switch overlay credentials mode to blank."
        return $null
    }

    if (-not $userExists) {
        try {
            if (Get-Command New-LocalUser -ErrorAction SilentlyContinue) {
                $sec = ConvertTo-SecureString $pass -AsPlainText -Force
                New-LocalUser -Name $user -Password $sec `
                    -FullName 'WinDeployKit imaging throwaway SMB' `
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
        if (Get-Command Set-LocalUser -ErrorAction SilentlyContinue) {
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

    if (Get-Command Enable-LocalUser -ErrorAction SilentlyContinue) {
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
        WinPE/ImageDeployer authenticate with as WORKGROUP\<user>. One elevation.
    #>
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Get-Command Invoke-AppMacOsAdminShellCommand -ErrorAction SilentlyContinue)) {
        throw 'macOS admin elevation helper unavailable.'
    }
    # TCC guard: a share rooted under ~/Downloads, ~/Desktop or ~/Documents is
    # created but smbd is denied read access, so it never serves. Refuse loudly here
    # (the panel surfaces matching guidance via Get-AppPxeBootImageLibraryShareStatus).
    $tccBase = if (Get-Command Get-AppMacOsTccProtectedBase -ErrorAction SilentlyContinue) {
        Get-AppMacOsTccProtectedBase -Path $Root
    } else { $null }
    if ($tccBase) {
        Write-SidecarLog "PXE boot: refusing Deploy`$ share - '$Root' is under TCC-protected '$tccBase'; smbd cannot serve it. Move the ISO & driver root to e.g. ~/Public/WinDeployKit."
        return $false
    }
    $name = $script:AppPxeBootImageLibraryShareName
    $cred = Get-AppPxeBootSmbThrowawayCredential
    $u = $cred.User
    $p = $cred.Pass
    $rootEsc = $Root -replace "'", "'\''"
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
  sysadminctl -addUser "`$U" -fullName "WinDeployKit imaging throwaway SMB" -password "`$P" -home /var/empty -shell /usr/bin/false
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

function Get-AppPxeBootImageLibraryShareStatus {
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
            if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
                $share = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
                if ($share) { $status.active = $true; $status.path = [string]$share.Path }
            }
            $credsMode = Get-AppPxeBootImageDeployerOverlayCredsMode -Cfg $cfg
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
            $tccBase = if (Get-Command Get-AppMacOsTccProtectedBase -ErrorAction SilentlyContinue) {
                Get-AppMacOsTccProtectedBase -Path $root
            } else { $null }
            # Auto-created on Start Imaging Services via /usr/sbin/sharing + a hidden
            # throwaway SMB-NT account mounted as WORKGROUP\<user>.
            $cred = Read-AppPxeBootSmbThrowawayCred
            if ($cred) { $status.authUser = $cred.User; $status.authDomain = 'WORKGROUP' }
            $status.active = Test-AppPxeBootMacOsShareActive -Name $name
            if ($tccBase) {
                $status.tccBlocked = $true
                $status.guidance = "macOS protects '$tccBase' (TCC) - smbd cannot serve $name from here, so WinPE will fail with 'network name not found'. Move the ISO & driver root out of Downloads/Desktop/Documents (e.g. ~/Public/WinDeployKit) in Settings -> Downloads, then Start Imaging Services again."
            } elseif (-not $status.active) {
                $status.guidance = "Tick this box and Start Imaging Services to auto-create $name (read-only, hidden) and a throwaway SMB user. ImageDeployer/WinPE then mounts $($status.unc) as WORKGROUP\<user>."
            }
        } else {
            $status.guidance = 'Export the image library root via Samba as a read-only share.'
        }
    } catch { $status.error = $_.Exception.Message }
    $status
}

function Ensure-AppPxeBootImageLibraryShare {
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
                    -Description 'WinDeployKit imaging library (read-only)' -ErrorAction Stop | Out-Null
                Write-SidecarLog "PXE boot: SMB share $name -> $root"
            }
            $credsMode = Get-AppPxeBootImageDeployerOverlayCredsMode -Cfg $cfg
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
            if ((Get-Command Get-SmbShare -ErrorAction SilentlyContinue) -and
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
            $cached = if (Get-Command Get-AppMacOsAdminCredentialCacheStatus -ErrorAction SilentlyContinue) {
                [bool](Get-AppMacOsAdminCredentialCacheStatus).cached
            } else { $false }
            $vaultAvailable = $false
            if (-not $cached -and (Get-Command Get-AppLocalMachineCredentialSecure -ErrorAction SilentlyContinue)) {
                try { $vaultAvailable = [bool](Get-AppLocalMachineCredentialSecure) } catch { $vaultAvailable = $false }
            }
            if (-not $cached -and -not $vaultAvailable) {
                Write-SidecarLog "PXE boot: leaving $name shared (no cached/vault admin password - won't prompt just to unshare)"
                return
            }
            if (Get-Command Invoke-AppMacOsAdminShellCommand -ErrorAction SilentlyContinue) {
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

function Start-AppPxeBootServices {
    param(
        [switch]$HttpOnly,
        [switch]$TftpOnly,
        # Serve files only - no Deploy$ SMB share, no ISO mounts, no menu regeneration.
        # For callers that just need the local web root (AP Converter), which must not
        # enable SMB on a machine whose owner never turned Netboot on.
        [switch]$Minimal
    )
    $cfg = Read-AppPxeBootConfig
    $startHttp = -not $TftpOnly
    $startTftp = -not $HttpOnly
    $errors = [System.Collections.Generic.List[string]]::new()

    $adminPrefetch = $null
    try {
        # Elevation is needed for macOS TFTP (dnsmasq) and for the macOS Deploy$ SMB
        # auto-create. Prefetch once up front so any prompt (vault-less session only)
        # happens at the start rather than mid-sequence at SMB-ensure time.
        $needsAdmin = $startTftp -or ($startHttp -and $cfg.smbShareEnabled -and -not $Minimal)
        if ($IsMacOS -and $needsAdmin -and (Get-Command Start-AppMacOsAdminCredentialPrefetch -ErrorAction SilentlyContinue)) {
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

    Write-AppPxeBootMenuFiles

    # Mount ISOs before HTTP so Start-AppPxeBootHttpServer's Caddyfile picks up the
    # per-mount /iso-wim/<base> routes that serve install.wim in place (no extraction).
    if ($startHttp -and -not $Minimal) {
        try {
            Mount-AppPxeBootInstallWimIsos | Out-Null
        } catch {
            Write-SidecarLog "PXE boot: ISO mount-serve error - $($_.Exception.Message)"
        }
    }

    if ($startHttp) {
        try {
            Start-AppPxeBootHttpServer -HttpRoot $layout.httpRoot -Port ([int]$cfg.httpPort) -InterfaceId $cfg.interfaceId | Out-Null
        } catch {
            $msg = $_.Exception.Message
            $script:AppPxeBootState.HttpLastError = $msg
            [void]$errors.Add($msg)
        }
    }
    if ($startTftp) {
        try {
            if ($adminPrefetch -and (Get-Command Complete-AppMacOsAdminCredentialPrefetch -ErrorAction SilentlyContinue)) {
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
    if ($startHttp) {
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
                # boot.ipxe was already generated without the ImageDeployer overlay cred. Now
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
        if ($adminPrefetch -and (Get-Command Stop-AppMacOsAdminCredentialPrefetch -ErrorAction SilentlyContinue)) {
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

function Get-AppPxeBootWimLibraryLayoutSnapshot {
    $paths = Get-AppPxeBootLayoutPaths
    $cfg = Read-AppPxeBootConfig
    $wimFiles = @(Get-ChildItem -LiteralPath $paths.wimDir -Filter '*.wim' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $isoFiles = @(Get-ChildItem -LiteralPath $paths.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $defaultName = if ($cfg.defaultBootWim) { [string]$cfg.defaultBootWim } else { $null }
    $defaultIsoName = if ($cfg.defaultBootIso) { [string]$cfg.defaultBootIso } else { $null }
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
        defaultBootIso     = $defaultIsoName
        wims               = @(Get-AppPxeBootWimInventory)
        isos               = @(Get-AppPxeBootIsoInventory)
        fieldIsoWim        = Get-AppPxeBootFieldIsoWimName
        isoCatalogSource   = if ($cfg.isoCatalogSource -eq 'wan') { 'wan' } else { 'local' }
        localHttpOnly      = -not (Test-AppPxeBootWanDeployMenuEnabled)
        localIsoCatalogUrl = Get-AppPxeBootLocalIsoCatalogUrl
        wanIsoCatalogUrl   = if (Test-AppPxeBootWanDeployMenuEnabled) { Get-AppPxeBootWanIsoCatalogUrl } else { $null }
        isoCatalogReady    = (Test-AppPxeBootLocalIsoCatalogReady)
        fieldIsoDrivers    = $null
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
        fieldIsoWim = Get-AppPxeBootFieldIsoWimName
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
        bootAssetsReady     = [bool]$bootAssets.complete
        bootAssetsPackaged  = @($bootAssets.packaged)
        bootAssetsExtracted = @($bootAssets.extracted)
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

    $removedFieldIso = ($name -match '^FieldIso\.wim$')
    if ($removedFieldIso) {
        Get-ChildItem -LiteralPath $paths.wimDir -Filter '.fieldiso-overlay-v*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

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

    # Boot menu always; ISO catalog only when FieldIso removed (catalog entries need FieldIso.wim).
    # SkipFieldIsoPrepare - no wimlib overlay / boot-asset export on delete.
    if ($removedFieldIso) {
        Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare
    } else {
        Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare -BootMenuOnly
    }
    Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh -SkipLayoutProbe
}

function Mount-AppPxeBootIsoReadOnly {
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        # Optional explicit macOS mountpoint. Pass a path INSIDE the image-library tree
        # (.mounts/<base>) so install.wim is reachable on the Deploy$ share.
        [string]$MountPath
    )
    if ($IsMacOS -or $IsDarwin) {
        $mountDir = if ($MountPath) {
            $MountPath
        } else {
            Join-Path ([IO.Path]::GetTempPath()) ("sm-pxe-iso-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        }
        if (Test-Path -LiteralPath $mountDir) {
            & hdiutil detach $mountDir -force 2>&1 | Out-Null
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -Path $mountDir -ItemType Directory -Force
        & hdiutil attach -nobrowse -readonly -mountpoint $mountDir $IsoPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
            throw 'PXE boot: failed to mount ISO (hdiutil).'
        }
        return @{ platform = 'macos'; mountPath = $mountDir }
    }
    if (Get-Command -Name Mount-DiskImage -ErrorAction SilentlyContinue) {
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $letter = ($img | Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter | Select-Object -First 1
        if (-not $letter) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
            throw 'PXE boot: ISO mounted but no drive letter was assigned.'
        }
        return @{ platform = 'windows'; mountPath = "$($letter):\"; isoPath = $IsoPath }
    }
    throw 'PXE boot: cannot mount ISO on this platform without 7-Zip.'
}

function Dismount-AppPxeBootIso {
    param([Parameter(Mandatory)]$MountInfo)
    try {
        if ($MountInfo.platform -eq 'macos') {
            & hdiutil detach $MountInfo.mountPath -force 2>&1 | Out-Null
            Remove-Item -LiteralPath $MountInfo.mountPath -Recurse -Force -ErrorAction SilentlyContinue
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
#   - SMB  : the overlay-aware ImageDeployer.ps1 scans Z:\.mounts\*\sources\install.wim and
#            reads the REAL file straight across the sub-mount (verified working on macOS
#            smbd and Windows - DISM reads it directly).
# <token> is a deterministic, path-/Caddyfile-/URL-safe slug + 8-char hash of the ISO file
# name (Get-AppPxeBootIsoMountToken), so any number of ISOs - including ones with spaces or
# parentheses in their names - mount side by side without colliding or breaking the Caddyfile.
# The friendly ISO name is kept in a sibling <token>.name file so the WIM picker can show it.
# We previously tried symlinking a WIMs/<base>-install.wim entry to avoid putting the file
# at top level, but Apple's smbd does not emit a Windows-followable symlink (WinPE DISM
# fails error 58 even with every `fsutil SymlinkEvaluation` mode on). Mounting in-share +
# teaching ImageDeployer to scan the mount avoids both the symlink and any ~5 GB copy.
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

function Clear-AppPxeBootStaleIsoMountDirs {
    param([Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$LiveTokens)
    # Migration + housekeeping sweep. The ONLY directories that belong under .mounts are the
    # current ISO tokens (<slug>-<hash>). Anything else is debris: a legacy pre-token mount
    # named after the raw ISO base (e.g. ".mounts/Windows 11"), an ISO that has since left the
    # library, or a crash leftover. Detach (macOS) / drop the junction (Windows) and delete the
    # now-empty dir so they neither accumulate nor get scanned by ImageDeployer. Runs on every
    # Start; the first run after upgrade clears the old base-named mounts, then it no-ops.
    $paths = Get-AppPxeBootLayoutPaths
    $mountsRoot = $paths.isoMountDir
    if (-not (Test-Path -LiteralPath $mountsRoot)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $mountsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($LiveTokens.Contains($dir.Name)) { continue }
        try {
            if ($IsMacOS -or $IsDarwin) {
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
        overlay-aware ImageDeployer.ps1 scans Z:\.mounts\*\sources\install.wim. Idempotent.
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
        if ($existing -and $existing.installWim -and (Test-Path -LiteralPath $existing.installWim)) {
            $result.Add($existing) | Out-Null
            continue
        }
        try {
            Write-SidecarLog "PXE boot: mounting ISO $($iso.Name) (read-only) to serve install.wim in place"
            # Expose the mount INSIDE the Deploy$ share at .mounts/<token> so SMB clients -
            # and the overlay-aware ImageDeployer scan of Z:\.mounts\*\sources\install.wim -
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
            if (-not $resolved) {
                Write-SidecarLog "PXE boot: $($iso.Name) has no install.wim - dismounting"
                Dismount-AppPxeBootIso -MountInfo $mountInfo
                continue
            }
            # Persist the friendly name next to the mount so the overlay-aware ImageDeployer
            # WIM picker can label the install.wim with the real ISO name, not the slug token.
            try {
                $nameFile = (Join-Path $paths.isoMountDir $token) + '.name'
                Set-Content -LiteralPath $nameFile -Value $displayName -Encoding UTF8 -NoNewline -ErrorAction Stop
            } catch {
                Write-SidecarLog "PXE boot: could not write mount label for $token ($($_.Exception.Message))"
            }
            $entry = @{
                isoFileName = $iso.Name
                isoPath     = $iso.FullName
                base        = $token
                displayName = $displayName
                mountInfo   = $mountInfo
                sourcesDir  = $resolved.sourcesDir
                installWim  = $resolved.wim
                httpPath    = "iso-wim/$token/install.wim"
            }
            $script:AppPxeBootState.IsoMounts[$token] = $entry
            $result.Add($entry) | Out-Null
            $sizeGb = [math]::Round((Get-Item -LiteralPath $resolved.wim).Length / 1GB, 2)
            Write-SidecarLog "PXE boot: serving install.wim for '$displayName' in place at .mounts/$token (${sizeGb} GB, no extract)"
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
                installWim  = [string]$_.installWim
                httpPath    = [string]$_.httpPath
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
    $name = Get-AppPxeBootSafeIsoFileName -FileName $FileName
    $dest = Join-Path (Get-AppPxeBootLayoutPaths).isoDir $name
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "PXE boot: ISO not found: $name"
    }
    # Release any live mount first - the ISO file is locked while mounted.
    $mountBase = [IO.Path]::GetFileNameWithoutExtension($name)
    if ($script:AppPxeBootState.IsoMounts.ContainsKey($mountBase)) {
        Dismount-AppPxeBootInstallWimIso -Base $mountBase
    }
    Remove-Item -LiteralPath $dest -Force
    Write-SidecarLog "PXE boot: removed ISO $name"

    $cfg = Read-AppPxeBootConfig
    if ($cfg.defaultBootIso -eq $name) {
        $existing = Read-AppPxeBootConfig
        Write-AppPxeBootConfig `
            -HttpPort ([int]$existing.httpPort) `
            -InterfaceId $existing.interfaceId `
            -DeployMenuUrl $existing.deployMenuUrl `
            -IsoCatalogSource $existing.isoCatalogSource `
            -Tftpd64Path $existing.tftpd64Path `
            -TftpMode $existing.tftpMode `
            -DefaultBootIso '' | Out-Null
        Write-SidecarLog 'PXE boot: default boot ISO cleared (removed from library)'
    }

    Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare
    Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh
}

function Set-AppPxeBootDefaultIso {
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
            -IsoCatalogSource $existing.isoCatalogSource `
            -Tftpd64Path $existing.tftpd64Path `
            -TftpMode $existing.tftpMode `
            -DefaultBootIso '' | Out-Null
        Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare -SkipIsoCatalogRegen
        Write-SidecarLog 'PXE boot: default boot ISO cleared - FieldIso default opens ISO catalog menu'
        return (Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh)
    }
    $name = Get-AppPxeBootSafeIsoFileName -FileName $FileName
    $dest = Join-Path (Get-AppPxeBootLayoutPaths).isoDir $name
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "PXE boot: ISO not found: $name"
    }
    if (-not (Get-AppPxeBootFieldIsoWimName)) {
        throw 'PXE boot: default ISO requires FieldIso.wim in the boot WIM library.'
    }
    if (-not (Test-AppPxeBootFieldIsoIsDefaultBoot)) {
        Write-SidecarLog "PXE boot: default ISO set to $name (applies when FieldIso.wim is the default boot WIM)"
    }
    $existing = Read-AppPxeBootConfig
    Write-AppPxeBootConfig `
        -HttpPort ([int]$existing.httpPort) `
        -InterfaceId $existing.interfaceId `
        -DeployMenuUrl $existing.deployMenuUrl `
        -IsoCatalogSource $existing.isoCatalogSource `
        -Tftpd64Path $existing.tftpd64Path `
        -TftpMode $existing.tftpMode `
        -DefaultBootIso $name | Out-Null
    Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare -SkipIsoCatalogRegen
    Write-SidecarLog "PXE boot: default boot ISO set to $name"
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

function Open-AppPxeBootFieldIsoDriversFolder {
    Initialize-AppPxeBootStore | Out-Null
    $path = Get-AppPxeBootFieldIsoDriversOsRoot
    if (-not (Test-Path -LiteralPath $path)) {
        $null = New-Item -Path $path -ItemType Directory -Force
    }
    Sync-AppPxeBootFieldIsoDriverStore | Out-Null
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
        Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare -SkipIsoCatalogRegen
        Write-SidecarLog 'PXE boot: default boot WIM cleared - clients choose from PXE menu'
        return (Get-AppPxeBootWimLibraryResponse -SkipStatusRefresh)
    }
    $name = Get-AppPxeBootSafeWimFileName -FileName $FileName
    $dest = Join-Path (Get-AppPxeBootLayoutPaths).wimDir $name
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "PXE boot: boot WIM not found: $name"
    }
    if (-not (Test-AppPxeBootWimIsFieldIso -FileName $name)) {
        Ensure-AppPxeBootWimBootAssets -WimFileName $name -SkipMenuRegen | Out-Null
    }
    if (Test-AppPxeBootWimIsFieldIso -FileName $name) {
        Write-SidecarLog "PXE boot: default boot WIM set to $name (deploy ISO catalog chain - not local wimboot auto-boot)"
    }
    $existing = Read-AppPxeBootConfig
    Write-AppPxeBootConfig `
        -HttpPort ([int]$existing.httpPort) `
        -InterfaceId $existing.interfaceId `
        -DeployMenuUrl $existing.deployMenuUrl `
        -Tftpd64Path $existing.tftpd64Path `
        -TftpMode $existing.tftpMode `
        -DefaultBootWim $name | Out-Null
    Write-AppPxeBootMenuFiles -SkipFieldIsoPrepare -SkipIsoCatalogRegen
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
        [string]$IsoCatalogSource,
        [string]$Tftpd64Path,
        [string]$TftpMode,
        [string]$TftpBootFile,
        [bool]$AutoBootDefault,
        [bool]$SmbShareEnabled,
        [bool]$SmbOverlayEnabled,
        [string]$ImageDeployerOverlayCreds,
        [string]$ImageDeployerOverlayShare,
        [bool]$IsoMountServe,
        [switch]$SkipMenuRegen
    )
    $port = if ($HttpPort -ge 1 -and $HttpPort -le 65535) { $HttpPort } else { 8080 }
    $writeParams = @{
        HttpPort         = $port
        InterfaceId      = $InterfaceId
        DeployMenuUrl    = $DeployMenuUrl
        IsoCatalogSource = $IsoCatalogSource
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
    if ($PSBoundParameters.ContainsKey('ImageDeployerOverlayCreds')) {
        $writeParams['ImageDeployerOverlayCreds'] = [string]$ImageDeployerOverlayCreds
    }
    if ($PSBoundParameters.ContainsKey('ImageDeployerOverlayShare')) {
        $writeParams['ImageDeployerOverlayShare'] = [string]$ImageDeployerOverlayShare
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
    # Apply an overlay toggle live: (re)bake the ImageDeployer script and publish/remove
    # the runtime cred/UNC files, then refresh boot.ipxe so the iPXE initrd lines match -
    # no full service restart needed. All idempotent and gated on the config flags.
    if ($PSBoundParameters.ContainsKey('SmbOverlayEnabled') -or
        $PSBoundParameters.ContainsKey('ImageDeployerOverlayCreds') -or
        $PSBoundParameters.ContainsKey('ImageDeployerOverlayShare')) {
        try {
            Sync-AppPxeBootWimBootAssets | Out-Null
            Sync-AppPxeBootFieldIsoHttpAssets | Out-Null
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
