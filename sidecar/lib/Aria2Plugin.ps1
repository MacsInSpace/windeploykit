# aria2 plug-in - runtime binary install + local RPC daemon (Plug-ins panel).
# Agent notes: docs/plugins/aria2/AGENT_NOTES_ARIA2.md

# Canonical data-root resolvers (no-op when the sidecar already dot-sourced AppPaths.ps1;
# needed when dev/test scripts dot-source this lib standalone).
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

if (-not (Get-Command Get-AppDataRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppPaths.ps1')
}

# Keep in sync with packaging/aria2-tools.json (runtime install - not bundled in signed macOS pkg).
$script:AppAria2PinnedVersion = '1.37.0'
$script:AppAria2DefaultRpcPort = 16800
$script:AppAria2InstallInProgress = $false
$script:AppAria2StoreInitDeferred = $false
# Keep in sync with packaging/aria2-tracker.json announceUrl.
$script:AppAria2DefaultBtTracker = 'http://tracker.example.com/announce.php'

function Get-AppAria2JsonProp {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name
    )
    # Sidecar runs under Set-StrictMode (NpsLogViewer.ps1); optional JSON / config keys must not be accessed directly.
    if (-not $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    if (-not ($Item.PSObject.Properties.Name -contains $Name)) { return $null }
    return $Item.$Name
}

function ConvertTo-AppAria2ExtensionRouteHashtable {
    param($Route)
    if (-not $Route) {
        return @{ ext = '*'; assetKind = 'other'; usePxeStaging = $false; dir = $null }
    }
    $extVal = Get-AppAria2JsonProp -Item $Route -Name 'ext'
    $kindVal = Get-AppAria2JsonProp -Item $Route -Name 'assetKind'
    $stagingVal = Get-AppAria2JsonProp -Item $Route -Name 'usePxeStaging'
    $dirVal = Get-AppAria2JsonProp -Item $Route -Name 'dir'
    $kind = if ($kindVal) { [string]$kindVal } else { 'other' }
    $useStaging = if ($kind -in @('iso', 'wim', 'driver')) {
        $true
    } elseif ($null -ne $stagingVal) {
        [bool]$stagingVal
    } else {
        $false
    }
    @{
        ext           = if ($extVal) { [string]$extVal } else { '*' }
        assetKind     = $kind
        usePxeStaging = $useStaging
        dir           = if ($dirVal) { [string]$dirVal } else { $null }
    }
}

function Expand-AppAria2BtTrackerUrl {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    @($Raw -split '[,\s;]+' | ForEach-Object { [string]$_.Trim() } | Where-Object { $_ })
}

function Get-AppAria2BtTrackerList {
    $trackerAcc = [System.Collections.Generic.List[string]]::new()
    if ($env:APP_ARIA2_BT_TRACKER) {
        foreach ($url in @(Expand-AppAria2BtTrackerUrl ([string]$env:APP_ARIA2_BT_TRACKER))) {
            [void]$trackerAcc.Add($url)
        }
        return @($trackerAcc.ToArray())
    }
    $cfg = Read-AppAria2Config
    $fromCfg = Get-AppAria2JsonProp -Item $cfg -Name 'btTrackers'
    if ($fromCfg) {
        foreach ($t in @($fromCfg)) {
            foreach ($url in @(Expand-AppAria2BtTrackerUrl ([string]$t))) {
                [void]$trackerAcc.Add($url)
            }
        }
    }
    if ($trackerAcc.Count -eq 0 -and (Test-AppSidecarCommand Read-AppAria2TrackerManifest)) {
        $manifest = Read-AppAria2TrackerManifest
        $urls = Get-AppAria2JsonProp -Item $manifest -Name 'announceUrls'
        if ($urls) {
            foreach ($t in @($urls)) {
                foreach ($url in @(Expand-AppAria2BtTrackerUrl ([string]$t))) {
                    [void]$trackerAcc.Add($url)
                }
            }
        }
        if ($trackerAcc.Count -eq 0) {
            $url = Get-AppAria2JsonProp -Item $manifest -Name 'announceUrl'
            foreach ($entry in @(Expand-AppAria2BtTrackerUrl ([string]$url))) {
                [void]$trackerAcc.Add($entry)
            }
        }
    }
    if ($trackerAcc.Count -eq 0) {
        [void]$trackerAcc.Add($script:AppAria2DefaultBtTracker)
    }
    return @($trackerAcc.ToArray())
}

function Get-AppAria2BtTrackerArg {
    $trackers = @(Get-AppAria2BtTrackerList)
    if (@($trackers).Count -eq 0) { return $null }
    ($trackers | ForEach-Object { [string]$_ } | Where-Object { $_ }) -join ','
}

function Merge-AppAria2DownloadOptions {
    param([hashtable]$Options)
    $out = @{}
    if ($Options) {
        foreach ($k in $Options.Keys) { $out[$k] = $Options[$k] }
    }
    $trackerArg = Get-AppAria2BtTrackerArg
    if ($trackerArg -and -not $out.ContainsKey('bt-tracker')) {
        $out['bt-tracker'] = $trackerArg
    }
    return $out
}

function Get-AppAria2StoreRoot {
    Get-AppPluginDir -Plugin 'aria2'
}

function Get-AppAria2LayoutPaths {
    $root = Get-AppAria2StoreRoot
    @{
        root        = $root
        binaryDir   = Join-Path $root 'binaries'
        configPath  = Join-Path $root 'config.json'
        sessionPath = Join-Path $root 'aria2.session'
        downloadDir = Join-Path $root 'downloads'
        pidPath     = Join-Path $root 'aria2.pid'
        logPath     = Join-Path $root 'aria2.log'
    }
}

function Set-AppAria2RuntimeDownloadDir {
    param([string]$DownloadDir)
    if ([string]::IsNullOrWhiteSpace($DownloadDir)) { return }
    if (-not $script:AppState['RuntimeConfig']) {
        $script:AppState['RuntimeConfig'] = @{}
    }
    $script:AppState['RuntimeConfig']['aria2DownloadDir'] = [string]$DownloadDir.Trim()
}

function Get-AppAria2EffectiveDownloadDir {
    Ensure-AppAria2StoreLayout | Out-Null
    $rc = $script:AppState['RuntimeConfig']
    if ($rc -and $rc.Contains('aria2DownloadDir')) {
        $dir = [string]$rc['aria2DownloadDir']
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            if (-not (Test-Path -LiteralPath $dir)) {
                $null = New-Item -Path $dir -ItemType Directory -Force
            }
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }
    $cfg = Read-AppAria2Config
    $legacy = [string](Get-AppAria2JsonProp -Item $cfg -Name 'downloadDir')
    if (-not [string]::IsNullOrWhiteSpace($legacy)) {
        if (-not (Test-Path -LiteralPath $legacy)) {
            $null = New-Item -Path $legacy -ItemType Directory -Force
        }
        return (Resolve-Path -LiteralPath $legacy).Path
    }
    # STORAGE POLICY (see AGENT_NOTES.md section 'Where data lives'): downloads are
    # multi-GB ISOs and driver packs, so they default to the user-chosen image library
    # root (the Deploy$ base), NEVER the app-data store. The plugin store lives under
    # %LOCALAPPDATA% / ~/Library/Application Support - i.e. the SYSTEM DRIVE - and USM
    # filled an SSD exactly this way by writing a ~60 GB WIM to %LOCALAPPDATA% with no
    # choice of location. Do not reintroduce a fallback to $paths.downloadDir.
    $libDownloads = $null
    try {
        $libDownloads = (Get-AppImageLibraryPaths).incomingDir
    } catch {
        Write-SidecarLog "Aria2: image library unavailable for download dir - $($_.Exception.Message)"
    }
    if (-not $libDownloads) {
        # Still not the app-data store: the image library DEFAULT root is off the
        # app-data tree by design (~/Public on macOS, ~/Downloads on Windows).
        $libDownloads = Join-Path (Get-AppImageLibraryDefaultRoot) '.incoming'
    }
    if (-not (Test-Path -LiteralPath $libDownloads)) {
        $null = New-Item -Path $libDownloads -ItemType Directory -Force
    }
    (Resolve-Path -LiteralPath $libDownloads).Path
}

function Test-AppAria2PluginEnabled {
    $rc = $script:AppState['RuntimeConfig']
    if ($rc -and $rc.Contains('aria2PluginEnabled')) {
        return [bool]$rc['aria2PluginEnabled']
    }
    return $false
}

function Set-AppAria2PluginRuntimeEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    if (-not $script:AppState['RuntimeConfig']) {
        $script:AppState['RuntimeConfig'] = @{}
    }
    $prev = $null
    if ($script:AppState['RuntimeConfig'].ContainsKey('aria2PluginEnabled')) {
        $prev = [bool]$script:AppState['RuntimeConfig']['aria2PluginEnabled']
    }
    $script:AppState['RuntimeConfig']['aria2PluginEnabled'] = $Enabled
    if ($Enabled) {
        if ($script:AppState -and -not [bool]$script:AppState['IsReady']) {
            # Pre-login ApplyRuntimeConfig (bootstrap) - store init runs from
            # Invoke-AppPostBootstrapPluginInit; every use path self-ensures anyway.
            $script:AppAria2StoreInitDeferred = $true
            Write-SidecarLogVerbose 'aria2: plug-in enabled - store init deferred until after bootstrap.'
        } else {
            $script:AppAria2StoreInitDeferred = $false
            Ensure-AppAria2StoreLayout | Out-Null
        }
    } elseif ($null -ne $prev -and $prev -and -not $Enabled) {
        $script:AppAria2StoreInitDeferred = $false
        try {
            Stop-AppAria2Daemon | Out-Null
        } catch {
            Write-SidecarLog "aria2: stop on plug-in disable - $($_.Exception.Message)"
        }
    }
}

function Complete-AppAria2DeferredStoreInit {
    if (-not $script:AppAria2StoreInitDeferred) { return }
    $script:AppAria2StoreInitDeferred = $false
    $rc = $script:AppState['RuntimeConfig']
    if (-not ($rc -and $rc.ContainsKey('aria2PluginEnabled') -and [bool]$rc['aria2PluginEnabled'])) { return }
    Ensure-AppAria2StoreLayout | Out-Null
}

function Ensure-AppAria2StoreLayout {
    $paths = Get-AppAria2LayoutPaths
    foreach ($dir in @($paths.binaryDir, $paths.downloadDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
        }
    }
    if (-not (Test-Path -LiteralPath $paths.configPath)) {
        $secret = [guid]::NewGuid().ToString('N')
        @{
            rpcPort         = $script:AppAria2DefaultRpcPort
            rpcSecret       = $secret
            pxeIntegration  = @{ enabled = $true }
            btTrackers      = @($script:AppAria2DefaultBtTracker)
            extensionRoutes = @(
                @{ ext = '.iso'; assetKind = 'iso'; usePxeStaging = $true }
                @{ ext = '.wim'; assetKind = 'wim'; usePxeStaging = $true }
                @{ ext = '.7z';  assetKind = 'driver'; usePxeStaging = $true }
                @{ ext = '.cab'; assetKind = 'driver'; usePxeStaging = $true }
                @{ ext = '.zip'; assetKind = 'driver'; usePxeStaging = $true }
                @{ ext = '.exe'; assetKind = 'driver'; usePxeStaging = $true }
                @{ ext = '*';   assetKind = 'other'; usePxeStaging = $false }
            )
        } | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $paths.configPath -Encoding UTF8 -Force
    }
    if (Test-Path -LiteralPath $paths.sessionPath) {
        if ((Get-Item -LiteralPath $paths.sessionPath).PSIsContainer) {
            Remove-Item -LiteralPath $paths.sessionPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $paths.sessionPath)) {
        $null = New-Item -Path $paths.sessionPath -ItemType File -Force
    }
    $paths
}

function Repair-AppAria2ExtensionRoutes {
    param($Routes)
    $list = [System.Collections.Generic.List[object]]::new()
    if ($Routes) { foreach ($r in @($Routes)) { [void]$list.Add($r) } }
    $have = @{}
    foreach ($r in @($list)) {
        $ext = [string](Get-AppAria2JsonProp -Item $r -Name 'ext')
        if ($ext) { $have[$ext.ToLowerInvariant()] = $true }
    }
    foreach ($missing in @(
            @{ ext = '.cab'; assetKind = 'driver'; usePxeStaging = $true }
            @{ ext = '.zip'; assetKind = 'driver'; usePxeStaging = $true }
            @{ ext = '.exe'; assetKind = 'driver'; usePxeStaging = $true }
        )) {
        if (-not $have[[string]$missing.ext]) { [void]$list.Add($missing) }
    }
    $star = @($list | Where-Object { [string](Get-AppAria2JsonProp -Item $_ -Name 'ext') -eq '*' })
    $nonStar = @($list | Where-Object { [string](Get-AppAria2JsonProp -Item $_ -Name 'ext') -ne '*' })
    @($nonStar + $star)
}

function Read-AppAria2Config {
    $paths = Get-AppAria2LayoutPaths
    Ensure-AppAria2StoreLayout | Out-Null
    try {
        $raw = Get-Content -LiteralPath $paths.configPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = $prop.Value
        }
        if ($map.ContainsKey('extensionRoutes')) {
            $repaired = @(Repair-AppAria2ExtensionRoutes -Routes $map['extensionRoutes'])
            if ($repaired.Count -ne @($map['extensionRoutes']).Count) {
                $map['extensionRoutes'] = $repaired
                Write-AppAria2Config -Config $map
            }
        }
        return $map
    } catch {
        Write-SidecarLog "aria2: config read failed - $($_.Exception.Message)"
        return @{}
    }
}

function Write-AppAria2Config {
    param([Parameter(Mandatory)]$Config)
    $paths = Get-AppAria2LayoutPaths
    # -Depth matters: pxeIntegration / extensionRoutes[] nest to depth 3; the default
    # -Depth 2 silently truncates them to type-name strings (see APP_DATA_LAYOUT.md section 10).
    # Keep in step with the init write above, which already uses -Depth 6.
    ($Config | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $paths.configPath -Encoding UTF8 -Force
}

function Get-AppAria2ManifestDefaultUrl {
    if ($env:APP_ARIA2_MANIFEST_URL) {
        return [string]$env:APP_ARIA2_MANIFEST_URL
    }
    return (Get-AppProductAssetFeedUrl -Name 'aria2-tools.json')
}

function Get-AppAria2BundledManifestPath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($script:SidecarRoot) {
        [void]$candidates.Add((Join-Path $script:SidecarRoot 'packaging/aria2-tools.json'))
    }
    $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
    if ($root) {
        [void]$candidates.Add((Join-Path $root 'packaging/aria2-tools.json'))
        [void]$candidates.Add((Join-Path $root 'sidecar/packaging/aria2-tools.json'))
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

function Get-AppAria2ManifestProp {
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

function Get-AppAria2PlatformKey {
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
    throw 'aria2: binary install is supported on macOS and Windows only.'
}

function Get-AppAria2BinaryFileName {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) { return 'aria2c.exe' }
    return 'aria2c'
}

function Get-AppAria2MarkerPath {
    Join-Path (Get-AppAria2LayoutPaths).binaryDir '.aria2-version'
}

function Test-AppAria2BinaryInstalled {
    param([switch]$RequirePinnedVersion)
    $paths = Get-AppAria2LayoutPaths
    $bin = Join-Path $paths.binaryDir (Get-AppAria2BinaryFileName)
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) { return $false }
    if ($RequirePinnedVersion) {
        $marker = Get-AppAria2MarkerPath
        if (-not (Test-Path -LiteralPath $marker)) { return $false }
        $installed = [string](Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
        if ($installed -ne $script:AppAria2PinnedVersion) { return $false }
    }
    return $true
}

function Get-AppAria2BinaryPath {
    if ($env:APP_ARIA2 -and (Test-Path -LiteralPath $env:APP_ARIA2 -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:APP_ARIA2).Path
    }
    $paths = Get-AppAria2LayoutPaths
    $bin = Join-Path $paths.binaryDir (Get-AppAria2BinaryFileName)
    if (Test-Path -LiteralPath $bin -PathType Leaf) {
        return (Resolve-Path -LiteralPath $bin).Path
    }
    $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
        return $cmd.Source
    }
    return $null
}

function Set-AppAria2BinaryExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-AppSidecarCommand Test-AppIsMacOSPlatform) {
        if (-not (Test-AppIsMacOSPlatform)) { return }
    } elseif (-not ($IsMacOS -or ((Get-Variable -Name IsDarwin -Scope Global -ErrorAction SilentlyContinue) -and $IsDarwin))) {
        return
    }
    $null = & chmod '+x' $Path 2>$null
    $null = & xattr -d com.apple.quarantine $Path 2>$null
}

function Read-AppAria2ManifestObject {
    param([Parameter(Mandatory)]$Obj)
    $schemaVal = Get-AppAria2ManifestProp -Item $Obj -Name 'schema'
    if ($schemaVal -and [int]$schemaVal -ne 1) { return $null }
    $version = [string](Get-AppAria2ManifestProp -Item $Obj -Name 'version')
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    $platformsRaw = Get-AppAria2ManifestProp -Item $Obj -Name 'platforms'
    if (-not $platformsRaw) { return $null }
    $platforms = @{}
    foreach ($prop in $platformsRaw.PSObject.Properties) {
        $entry = $prop.Value
        $archiveName = [string](Get-AppAria2ManifestProp -Item $entry -Name 'archiveName')
        $archiveKind = [string](Get-AppAria2ManifestProp -Item $entry -Name 'archiveKind')
        $binaryName = [string](Get-AppAria2ManifestProp -Item $entry -Name 'binaryName')
        $shaProp = Get-AppAria2ManifestProp -Item $entry -Name 'sha256'
        $urlProp = Get-AppAria2ManifestProp -Item $entry -Name 'downloadUrl'
        $githubProp = Get-AppAria2ManifestProp -Item $entry -Name 'githubUrl'
        $sizeProp = Get-AppAria2ManifestProp -Item $entry -Name 'sizeBytes'
        if ([string]::IsNullOrWhiteSpace($archiveName) -or [string]::IsNullOrWhiteSpace($binaryName)) { continue }
        $platforms[$prop.Name] = @{
            archiveName = $archiveName
            archiveKind = if ($archiveKind) { $archiveKind } else { 'zip' }
            binaryName  = $binaryName
            sha256      = if ($shaProp) { [string]$shaProp } else { '' }
            downloadUrl = if ($urlProp) { [string]$urlProp } else { '' }
            githubUrl   = if ($githubProp) { [string]$githubProp } else { '' }
            sizeBytes   = if ($null -ne $sizeProp) { [long]$sizeProp } else { 0 }
        }
    }
    if ($platforms.Count -eq 0) { return $null }
    @{
        version     = $version
        platforms   = $platforms
        manifestUrl = Get-AppAria2ManifestDefaultUrl
    }
}

function Get-AppAria2Manifest {
    $manifestUrl = Get-AppAria2ManifestDefaultUrl
    try {
        $remote = Invoke-RestMethod -Uri $manifestUrl -Method Get -UseBasicParsing -TimeoutSec 45
        $parsed = Read-AppAria2ManifestObject -Obj $remote
        if ($parsed) { return $parsed }
    } catch {
        Write-SidecarLogVerbose "aria2: manifest fetch failed ($manifestUrl): $($_.Exception.Message)"
    }
    $bundledPath = Get-AppAria2BundledManifestPath
    if ($bundledPath) {
        try {
            $local = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsed = Read-AppAria2ManifestObject -Obj $local
            if ($parsed) { return $parsed }
        } catch {
            Write-SidecarLogVerbose "aria2: bundled manifest read failed: $($_.Exception.Message)"
        }
    }
    throw 'aria2: manifest unavailable (no asset feed configured and no bundled copy).'
}

function Get-AppAria2PlatformEntry {
    $manifest = Get-AppAria2Manifest
    $key = Get-AppAria2PlatformKey
    if (-not $manifest.platforms.ContainsKey($key)) {
        throw "aria2: manifest has no entry for platform $key."
    }
    @{
        manifest    = $manifest
        platformKey = $key
        entry       = $manifest.platforms[$key]
    }
}

function Invoke-AppAria2ArtifactDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing `
        -UserAgent (Get-AppUserAgent) -MaximumRedirection 5
}

function Test-AppAria2ArchiveFile {
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

function Expand-AppAria2Archive {
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
            throw "aria2: tar extract failed for $(Split-Path -Leaf $Archive)"
        }
    } else {
        throw "aria2: unknown archive kind $ArchiveKind"
    }
    $bin = Join-Path $ExtractDir $BinaryName
    if (Test-Path -LiteralPath $bin) { return $bin }
    $found = Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $BinaryName } |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "aria2: $BinaryName missing after extracting $(Split-Path -Leaf $Archive)"
}

function Sync-AppAria2InstallJob {
    # Legacy no-op - packaged sidecar installs synchronously via Ensure-AppAria2Binary.
    return $null
}

function Start-AppAria2BinaryInstallJob {
    # Back-compat alias - synchronous install (Start-Job failed silently in packaged builds).
    Ensure-AppAria2Binary
}

function Ensure-AppAria2Binary {
    if ($script:AppAria2InstallInProgress) {
        return @{ ok = $false; installing = $true; skipped = $true; reason = 'install_in_progress' }
    }
    Ensure-AppAria2StoreLayout | Out-Null
    if (Test-AppAria2BinaryInstalled -RequirePinnedVersion) {
        return @{
            ok      = $true
            skipped = $true
            path    = (Get-AppAria2BinaryPath)
            version = $script:AppAria2PinnedVersion
        }
    }

    $resolved = Get-AppAria2PlatformEntry
    $entry = $resolved.entry
    $platformKey = $resolved.platformKey
    $manifest = $resolved.manifest
    $paths = Get-AppAria2LayoutPaths
    $destBin = Join-Path $paths.binaryDir (Get-AppAria2BinaryFileName)
    $sizeMb = if ($entry.sizeBytes -gt 0) { [math]::Round($entry.sizeBytes / 1MB, 1) } else { 2.5 }

    Write-SidecarLog "aria2: installing $($manifest.version) ($platformKey, ~${sizeMb} MB) to $($paths.binaryDir)"
    Write-SidecarEvent -EventName 'aria2-tools' -Data @{
        phase   = 'installing'
        version = [string]$manifest.version
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("$(Get-AppProductSlug)-aria2-" + [guid]::NewGuid().ToString())
    $archivePath = Join-Path $tmpRoot $entry.archiveName
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    $script:AppAria2InstallInProgress = $true
    try {
        $downloadUrls = [System.Collections.Generic.List[string]]::new()
        if ($entry.downloadUrl) { [void]$downloadUrls.Add([string]$entry.downloadUrl) }
        if ($entry.githubUrl -and $entry.githubUrl -ne $entry.downloadUrl) {
            [void]$downloadUrls.Add([string]$entry.githubUrl)
        }
        $downloaded = $false
        $lastError = $null
        # Bundled archive first - vendor/aria2-tools/<archiveName>, the same shape as
        # p7zip's vendor/p7zip-tools fallback. macOS has no download URL at all (the
        # manifest entry is a Homebrew bottle repack), so before this the packaged app
        # could never install aria2 there (found by the 2026-08-26 bundle audit).
        $root = if ($script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } else { $null }
        if ($root) {
            $localArchive = Join-Path $root ("vendor/aria2-tools/$($entry.archiveName)" -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $localArchive) {
                Copy-Item -LiteralPath $localArchive -Destination $archivePath -Force
                if (Test-AppAria2ArchiveFile -Path $archivePath -ExpectedSha256 $entry.sha256 -ExpectedSizeBytes $entry.sizeBytes) {
                    $downloaded = $true
                    Write-SidecarLog "aria2: using the bundled archive $($entry.archiveName)"
                } else {
                    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                    $lastError = 'bundled archive failed its SHA256/size check'
                }
            }
        }
        if (-not $downloaded -and $downloadUrls.Count -eq 0) {
            throw 'aria2: manifest entry has no download URL and no bundled archive (vendor/aria2-tools) for this platform.'
        }
        foreach ($url in @($downloadUrls)) {
            if ($downloaded) { break }
            try {
                if (Test-Path -LiteralPath $archivePath) {
                    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                }
                Invoke-AppAria2ArtifactDownload -Uri $url -OutFile $archivePath
                if (Test-AppAria2ArchiveFile -Path $archivePath -ExpectedSha256 $entry.sha256 -ExpectedSizeBytes $entry.sizeBytes) {
                    $downloaded = $true
                    break
                }
                $lastError = 'SHA256 or size mismatch after download'
            } catch {
                $lastError = $_.Exception.Message
                Write-SidecarLogVerbose "aria2: download failed from $url - $lastError"
            }
        }
        if (-not $downloaded) {
            throw "aria2: download failed - $lastError"
        }

        $extractDir = Join-Path $tmpRoot 'extract'
        $extractedBin = Expand-AppAria2Archive `
            -Archive $archivePath `
            -ArchiveKind $entry.archiveKind `
            -ExtractDir $extractDir `
            -BinaryName $entry.binaryName
        Copy-Item -LiteralPath $extractedBin -Destination $destBin -Force
        Set-AppAria2BinaryExecutable -Path $destBin
        Set-Content -LiteralPath (Get-AppAria2MarkerPath) -Value $script:AppAria2PinnedVersion -Encoding ASCII -Force

        Write-SidecarLog "aria2: $($script:AppAria2PinnedVersion) installed at $destBin"
        Write-SidecarEvent -EventName 'aria2-tools' -Data @{
            phase   = 'complete'
            version = $script:AppAria2PinnedVersion
            path    = $destBin
        }
        return @{
            ok      = $true
            skipped = $false
            path    = $destBin
            version = $script:AppAria2PinnedVersion
        }
    } catch {
        Write-SidecarEvent -EventName 'aria2-tools' -Data @{
            phase   = 'failed'
            message = $_.Exception.Message
        }
        throw
    } finally {
        $script:AppAria2InstallInProgress = $false
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AppAria2BinaryStatus {
    Sync-AppAria2InstallJob | Out-Null
    $path = Get-AppAria2BinaryPath
    @{
        ready            = [bool]$path
        path             = $path
        pinnedVersion    = $script:AppAria2PinnedVersion
        installedVersion = if (Test-Path -LiteralPath (Get-AppAria2MarkerPath)) {
            [string](Get-Content -LiteralPath (Get-AppAria2MarkerPath) -Raw -ErrorAction SilentlyContinue).Trim()
        } else { $null }
        needsInstall     = -not (Test-AppAria2BinaryInstalled -RequirePinnedVersion)
        installing       = [bool]$script:AppAria2InstallInProgress
    }
}

function Get-AppAria2DaemonPid {
    $paths = Get-AppAria2LayoutPaths
    if (-not (Test-Path -LiteralPath $paths.pidPath)) { return $null }
    $raw = [string](Get-Content -LiteralPath $paths.pidPath -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $raw -match '^\d+$') { return $null }
    return [int]$raw
}

function Test-AppAria2DaemonRunning {
    $pidVal = Get-AppAria2DaemonPid
    if (-not $pidVal) { return $false }
    try {
        $proc = Get-Process -Id $pidVal -ErrorAction Stop
        return $null -ne $proc -and -not $proc.HasExited
    } catch {
        return $false
    }
}

function Stop-AppAria2Daemon {
    $paths = Get-AppAria2LayoutPaths
    $stopped = $false
    $pidVal = Get-AppAria2DaemonPid
    if ($pidVal) {
        try {
            Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
            $stopped = $true
        } catch { }
    }
    if (Test-Path -LiteralPath $paths.pidPath) {
        Remove-Item -LiteralPath $paths.pidPath -Force -ErrorAction SilentlyContinue
    }
    return @{ stopped = $stopped }
}

function Start-AppAria2Daemon {
    if (-not (Test-AppAria2PluginEnabled)) {
        throw 'aria2: plug-in is disabled in Settings.'
    }
    $binStatus = Get-AppAria2BinaryStatus
    if (-not $binStatus.ready) {
        Ensure-AppAria2Binary | Out-Null
        $binStatus = Get-AppAria2BinaryStatus
        if (-not $binStatus.ready) {
            throw 'aria2: binary install failed or is still in progress - try again in a moment.'
        }
    }
    if (Test-AppAria2DaemonRunning) {
        return @{ ok = $true; skipped = $true; pid = (Get-AppAria2DaemonPid) }
    }

    $bin = Get-AppAria2BinaryPath
    if (-not $bin) { throw 'aria2: aria2c not found.' }

    $cfg = Read-AppAria2Config
    $paths = Get-AppAria2LayoutPaths
    $rpcPortRaw = Get-AppAria2JsonProp -Item $cfg -Name 'rpcPort'
    $rpcPort = if ($rpcPortRaw) { [int]$rpcPortRaw } else { $script:AppAria2DefaultRpcPort }
    $rpcSecret = [string](Get-AppAria2JsonProp -Item $cfg -Name 'rpcSecret')
    if ([string]::IsNullOrWhiteSpace($rpcSecret)) {
        $rpcSecret = [guid]::NewGuid().ToString('N')
        $cfg['rpcSecret'] = $rpcSecret
        Write-AppAria2Config -Config $cfg
    }
    $downloadDir = Get-AppAria2EffectiveDownloadDir

    $aria2Args = @(
        '--enable-rpc=true'
        '--rpc-listen-all=false'
        "--rpc-listen-port=$rpcPort"
        "--rpc-secret=$rpcSecret"
        "--dir=$downloadDir"
        "--input-file=$($paths.sessionPath)"
        '--save-session-interval=30'
        '--continue=true'
        '--max-concurrent-downloads=5'
        '--file-allocation=none'
        '--console-log-level=warn'
        "--log=$($paths.logPath)"
        '--log-level=warn'
    )
    $btTracker = Get-AppAria2BtTrackerArg
    if ($btTracker) {
        $aria2Args += "--bt-tracker=$btTracker"
    }

    $argLine = Format-AppProcessArgumentList -Arguments $aria2Args
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $proc = Start-Process -FilePath $bin -ArgumentList $argLine -PassThru -WindowStyle Hidden
    } else {
        $proc = Start-Process -FilePath $bin -ArgumentList $argLine -PassThru
    }
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) {
        throw 'aria2: daemon exited immediately after start - check Sidecar Log and aria2.log in the plug-in store.'
    }
    Set-Content -LiteralPath $paths.pidPath -Value ([string]$proc.Id) -Encoding ASCII -Force
    Write-SidecarLog "aria2: daemon started (pid $($proc.Id), rpc port $rpcPort)"
    return @{ ok = $true; pid = $proc.Id; rpcPort = $rpcPort }
}

function Get-AppAria2RpcErrorMessage {
    param($Response)
    $err = Get-AppAria2JsonProp -Item $Response -Name 'error'
    if (-not $err) { return $null }
    $msg = Get-AppAria2JsonProp -Item $err -Name 'message'
    if ($msg) { return [string]$msg }
    return [string]$err
}

function Test-AppAria2RpcHasResult {
    param($Response)
    if (-not $Response) { return $false }
    if ($Response -is [System.Collections.IDictionary]) {
        return $Response.Contains('result')
    }
    return ($Response.PSObject.Properties.Name -contains 'result')
}

function Get-AppAria2RpcResult {
    param(
        [Parameter(Mandatory)][object]$Response,
        [string]$Method = 'aria2'
    )
    $errMsg = Get-AppAria2RpcErrorMessage -Response $Response
    if ($errMsg) {
        throw "aria2 RPC $Method failed: $errMsg"
    }
    if (-not (Test-AppAria2RpcHasResult -Response $Response)) {
        throw "aria2 RPC $Method returned no result."
    }
    return Get-AppAria2JsonProp -Item $Response -Name 'result'
}

function Invoke-AppAria2Rpc {
    param(
        [Parameter(Mandatory)][string]$Method,
        [object[]]$Params = @()
    )
    if (-not (Test-AppAria2DaemonRunning)) {
        throw 'aria2: daemon is not running - click Start daemon.'
    }
    $cfg = Read-AppAria2Config
    $rpcPortRaw = Get-AppAria2JsonProp -Item $cfg -Name 'rpcPort'
    $rpcPort = if ($rpcPortRaw) { [int]$rpcPortRaw } else { $script:AppAria2DefaultRpcPort }
    $secret = [string](Get-AppAria2JsonProp -Item $cfg -Name 'rpcSecret')
    $rpcParams = [System.Collections.Generic.List[object]]::new()
    if ($secret) { [void]$rpcParams.Add("token:$secret") }
    foreach ($p in $Params) { [void]$rpcParams.Add($p) }
    $body = @{
        jsonrpc = '2.0'
        id      = (Get-AppProductSlug)
        method  = $Method
        params  = @($rpcParams.ToArray())
    } | ConvertTo-Json -Depth 12 -Compress

    $uri = "http://127.0.0.1:$rpcPort/jsonrpc"
    try {
        return Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30
    } catch {
        throw "aria2 RPC $Method failed: $($_.Exception.Message)"
    }
}

function ConvertTo-AppAria2DownloadRow {
    param([Parameter(Mandatory)]$Status)
    if (-not $Status) { return $null }
    $totalRaw = Get-AppAria2JsonProp -Item $Status -Name 'totalLength'
    $completedRaw = Get-AppAria2JsonProp -Item $Status -Name 'completedLength'
    $speedRaw = Get-AppAria2JsonProp -Item $Status -Name 'downloadSpeed'
    $total = if ($totalRaw) { [long]$totalRaw } else { 0L }
    $completed = if ($completedRaw) { [long]$completedRaw } else { 0L }
    $speed = if ($speedRaw) { [long]$speedRaw } else { 0L }
    $pct = if ($total -gt 0) { [math]::Round(100.0 * $completed / $total, 1) } else { 0 }
    $name = $null
    $files = Get-AppAria2JsonProp -Item $Status -Name 'files'
    if ($files -and @($files).Count -gt 0) {
        $f0 = $files[0]
        $pathVal = Get-AppAria2JsonProp -Item $f0 -Name 'path'
        $urnVal = Get-AppAria2JsonProp -Item $f0 -Name 'urn'
        if ($pathVal) { $name = [string]$pathVal }
        elseif ($urnVal) { $name = [string]$urnVal }
    }
    if (-not $name) {
        $bt = Get-AppAria2JsonProp -Item $Status -Name 'bittorrent'
        $info = Get-AppAria2JsonProp -Item $bt -Name 'info'
        $infoName = Get-AppAria2JsonProp -Item $info -Name 'name'
        if ($infoName) { $name = [string]$infoName }
    }
    $errCode = Get-AppAria2JsonProp -Item $Status -Name 'errorCode'
    $errMsg = Get-AppAria2JsonProp -Item $Status -Name 'errorMessage'
    @{
        gid             = [string](Get-AppAria2JsonProp -Item $Status -Name 'gid')
        status          = [string](Get-AppAria2JsonProp -Item $Status -Name 'status')
        name            = $name
        totalLength     = $total
        completedLength = $completed
        downloadSpeed   = $speed
        percent         = $pct
        errorCode       = if ($errCode) { [string]$errCode } else { $null }
        errorMessage    = if ($errMsg) { [string]$errMsg } else { $null }
    }
}

function Get-AppAria2DownloadsPayload {
    $empty = @{
        daemonRunning = $false
        globalStat    = $null
        active        = @()
        waiting       = @()
        stopped       = @()
    }
    if (-not (Test-AppAria2DaemonRunning)) {
        return $empty
    }
    try {
        if (Test-AppSidecarCommand Sync-AppAria2PromoteJobs) {
            Sync-AppAria2PromoteJobs | Out-Null
        }
        $globalResp = Invoke-AppAria2Rpc -Method 'aria2.getGlobalStat' -Params @()
        $stat = Get-AppAria2RpcResult -Response $globalResp -Method 'aria2.getGlobalStat'

        # tellActive returns download status structs; tellWaiting/tellStopped return gid strings.
        $activeRows = @()
        $activeResult = Get-AppAria2RpcResult -Response (Invoke-AppAria2Rpc -Method 'aria2.tellActive' -Params @()) -Method 'aria2.tellActive'
        foreach ($status in @($activeResult)) {
            $row = ConvertTo-AppAria2DownloadRow -Status $status
            if ($row) {
                $gid = Get-AppAria2JsonProp -Item $status -Name 'gid'
                if ($gid -and (Test-AppSidecarCommand Merge-AppAria2JobIntoDownloadRow)) {
                    $row = Merge-AppAria2JobIntoDownloadRow -Row $row -Gid ([string]$gid)
                }
                $activeRows += $row
            }
        }
        $waitingRows = @()
        $waitingGids = @(Get-AppAria2RpcResult -Response (Invoke-AppAria2Rpc -Method 'aria2.tellWaiting' -Params @(0, 50)) -Method 'aria2.tellWaiting')
        foreach ($gid in $waitingGids) {
            $gidStr = [string]$gid
            if (-not $gidStr) { continue }
            $stResp = Invoke-AppAria2Rpc -Method 'aria2.tellStatus' -Params @($gidStr)
            $row = ConvertTo-AppAria2DownloadRow -Status (Get-AppAria2RpcResult -Response $stResp -Method 'aria2.tellStatus')
            if ($row) {
                if (Test-AppSidecarCommand Merge-AppAria2JobIntoDownloadRow) {
                    $row = Merge-AppAria2JobIntoDownloadRow -Row $row -Gid $gidStr
                }
                $waitingRows += $row
            }
        }
        $stoppedRows = @()
        $stoppedGids = @(Get-AppAria2RpcResult -Response (Invoke-AppAria2Rpc -Method 'aria2.tellStopped' -Params @(0, 50)) -Method 'aria2.tellStopped')
        foreach ($gid in $stoppedGids) {
            $gidStr = [string]$gid
            if (-not $gidStr) { continue }
            $stResp = Invoke-AppAria2Rpc -Method 'aria2.tellStatus' -Params @($gidStr)
            $row = ConvertTo-AppAria2DownloadRow -Status (Get-AppAria2RpcResult -Response $stResp -Method 'aria2.tellStatus')
            if ($row) {
                if (Test-AppSidecarCommand Merge-AppAria2JobIntoDownloadRow) {
                    $row = Merge-AppAria2JobIntoDownloadRow -Row $row -Gid $gidStr
                }
                $stoppedRows += $row
            }
        }

        return @{
            daemonRunning = $true
            globalStat    = $stat
            active        = @($activeRows)
            waiting       = @($waitingRows)
            stopped       = @($stoppedRows)
        }
    } catch {
        Write-SidecarLog "aria2: GetAria2Downloads failed - $($_.Exception.Message)"
        return @{
            daemonRunning = $true
            globalStat    = $null
            active        = @()
            waiting       = @()
            stopped       = @()
        }
    }
}

function Add-AppAria2UriDownload {
    param(
        [Parameter(Mandatory)][string[]]$Uris,
        [hashtable]$Options = @{}
    )
    $clean = @($Uris | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($clean.Count -eq 0) { throw 'aria2: at least one URI is required.' }
    $opts = Merge-AppAria2DownloadOptions -Options $Options
    $resp = Invoke-AppAria2Rpc -Method 'aria2.addUri' -Params @($clean, $opts)
    @{ gid = [string](Get-AppAria2RpcResult -Response $resp -Method 'aria2.addUri') }
}

function Add-AppAria2TorrentDownload {
    param(
        [Parameter(Mandatory)][string]$TorrentBase64,
        [hashtable]$Options = @{}
    )
    if ([string]::IsNullOrWhiteSpace($TorrentBase64)) {
        throw 'aria2: torrent content is empty.'
    }
    $opts = Merge-AppAria2DownloadOptions -Options $Options
    $resp = Invoke-AppAria2Rpc -Method 'aria2.addTorrent' -Params @($TorrentBase64, @(), $opts)
    @{ gid = [string](Get-AppAria2RpcResult -Response $resp -Method 'aria2.addTorrent') }
}

function Invoke-AppAria2DownloadControl {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Gid
    )
    $gid = [string]$Gid.Trim()
    if (-not $gid) { throw 'aria2: gid is required.' }
    switch ($Action.ToLowerInvariant()) {
        'pause' { Invoke-AppAria2Rpc -Method 'aria2.pause' -Params @($gid) | Out-Null }
        'unpause' { Invoke-AppAria2Rpc -Method 'aria2.unpause' -Params @($gid) | Out-Null }
        'remove' { Invoke-AppAria2Rpc -Method 'aria2.remove' -Params @($gid) | Out-Null }
        'forceRemove' { Invoke-AppAria2Rpc -Method 'aria2.forceRemove' -Params @($gid) | Out-Null }
        default { throw "aria2: unknown action $Action" }
    }
    @{ ok = $true; gid = $gid; action = $Action }
}

function Get-AppAria2PluginConfigPayload {
    Ensure-AppAria2StoreLayout | Out-Null
    $cfg = Read-AppAria2Config
    $bin = Get-AppAria2BinaryStatus
    $paths = Get-AppAria2LayoutPaths
    $rpcPortRaw = Get-AppAria2JsonProp -Item $cfg -Name 'rpcPort'
    @{
        rpcPort       = if ($rpcPortRaw) { [int]$rpcPortRaw } else { $script:AppAria2DefaultRpcPort }
        downloadDir   = Get-AppAria2EffectiveDownloadDir
        storeRoot     = $paths.root
        binary        = $bin
        daemonRunning = [bool](Test-AppAria2DaemonRunning)
        daemonPid     = Get-AppAria2DaemonPid
        pluginEnabled = [bool](Test-AppAria2PluginEnabled)
    }
}

function Set-AppAria2PluginConfig {
    Get-AppAria2PluginConfigPayload
}

function Open-AppAria2DownloadFolder {
    # Open the ISO & driver root - where this panel's content actually lands (iso/,
    # Drivers/, WIMs/ via the promote rails; follows Settings -> Downloads, including
    # the macOS TCC divert). The raw aria2 downloadDir only holds unrouted 'other'
    # downloads and previously sent techs to ~/Downloads (Craig, 2026-08-18).
    $dir = $null
    if (Test-AppSidecarCommand Get-AppImageLibraryRoot) {
        try { $dir = Get-AppImageLibraryRoot } catch { $dir = $null }
    }
    if ([string]::IsNullOrWhiteSpace([string]$dir)) { $dir = Get-AppAria2EffectiveDownloadDir }
    if ($IsMacOS -or $IsDarwin) {
        & open $dir
    } elseif ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-AppProcessArgumentList -Arguments @($dir))
    } else {
        throw 'aria2: reveal folder is supported on macOS and Windows only.'
    }
    @{ path = $dir }
}
