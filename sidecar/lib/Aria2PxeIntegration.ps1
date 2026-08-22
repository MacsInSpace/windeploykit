# aria2 <-> Netboot PXE store integration - staging, promote, driver alias resolver, tracker catalog.
# Loaded after PxeBootPlugin.ps1 (see the sidecar entry script).

# Product identity helpers (no-op when the host already dot-sourced AppProductIdentity.ps1;
# needed when this lib is loaded standalone by scripts or child runspaces).
if (-not (Get-Command Get-AppUserAgent -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppProductIdentity.ps1')
}

$script:AppAria2TrackerManifestCacheHours = 168
$script:AppAria2TrackerManifestDefaultUrl = Get-AppProductAssetFeedUrl -Name 'aria2-tracker.json'
$script:AppAria2TrackerManifestFetchBackoffMinutes = 15
$script:AppAria2TrackerManifestMemory = $null
$script:AppAria2TrackerManifestFetchBackoffUntil = $null
$script:AppAria2TrackerManifestFetchFailureLoggedAt = $null

function Get-AppAria2TrackerManifestCachePath {
    Join-Path (Get-AppAria2StoreRoot) 'aria2-tracker-manifest.json'
}

function Write-AppAria2TrackerManifestCache {
    param([Parameter(Mandatory)]$Manifest)
    $path = Get-AppAria2TrackerManifestCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $wrapper = @{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        manifest  = $Manifest
    }
    ($wrapper | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function ConvertTo-AppAria2JobHashtable {
    param($Job)
    $hash = @{}
    if ($Job -is [System.Collections.IDictionary]) {
        foreach ($k in $Job.Keys) { $hash[$k] = $Job[$k] }
    } elseif ($Job) {
        foreach ($prop in $Job.PSObject.Properties) { $hash[$prop.Name] = $prop.Value }
    }
    return $hash
}

function Get-AppAria2JobsPath {
    Join-Path (Get-AppAria2StoreRoot) 'jobs.json'
}

function Read-AppAria2JobsStore {
    $path = Get-AppAria2JobsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ jobs = @{} }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{ jobs = @{} } }
        $obj = $raw | ConvertFrom-Json
        $jobs = @{}
        $objJobs = Get-AppSidecarJsonProp -Item $obj -Name 'jobs'
        if ($objJobs) {
            foreach ($prop in $objJobs.PSObject.Properties) {
                $jobs[$prop.Name] = $prop.Value
            }
        }
        return @{ jobs = $jobs }
    } catch {
        Write-SidecarLog "aria2: jobs store read failed - $($_.Exception.Message)"
        return @{ jobs = @{} }
    }
}

function Write-AppAria2JobsStore {
    param([Parameter(Mandatory)]$Store)
    $path = Get-AppAria2JobsPath
    $jobsObj = [ordered]@{}
    if ($Store.jobs) {
        foreach ($key in @($Store.jobs.Keys)) {
            $jobsObj[$key] = $Store.jobs[$key]
        }
    }
    (@{ jobs = $jobsObj } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function Get-AppAria2DefaultExtensionRoutes {
    @(
        @{ ext = '.iso'; assetKind = 'iso'; usePxeStaging = $true; dir = $null }
        @{ ext = '.wim'; assetKind = 'wim'; usePxeStaging = $true; dir = $null }
        @{ ext = '.7z';  assetKind = 'driver'; usePxeStaging = $true; dir = $null }
        @{ ext = '.cab'; assetKind = 'driver'; usePxeStaging = $true; dir = $null }
        @{ ext = '.zip'; assetKind = 'driver'; usePxeStaging = $true; dir = $null }
        @{ ext = '.exe'; assetKind = 'driver'; usePxeStaging = $true; dir = $null }
        @{ ext = '*';   assetKind = 'other'; usePxeStaging = $false; dir = $null }
    )
}

function Get-AppAria2NormalizedExtensionRoutes {
    param($Cfg)
    $routesRaw = Get-AppAria2JsonProp -Item $Cfg -Name 'extensionRoutes'
    # @() around the if: assignment from an if-expression unwraps empty arrays to $null,
    # and $null.Count throws under the sidecar's Set-StrictMode (latent until a config
    # without extensionRoutes came through).
    $routes = @(if ($routesRaw) { $routesRaw })
    if ($routes.Count -eq 0) {
        return @(Get-AppAria2DefaultExtensionRoutes)
    }
    $out = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($r in $routes) {
        [void]$out.Add((ConvertTo-AppAria2ExtensionRouteHashtable -Route $r))
    }
    @($out)
}

function Test-AppAria2PxeIntegrationEnabled {
    param($Cfg)
    return $true
}

function Get-AppAria2PxeIncomingRoot {
    # Staging lives under the user-chosen ISO & driver root (off the system
    # drive), not the PXE store: <image library>/.incoming/<guid>/.
    if (-not (Get-Command Get-AppImageLibraryPaths -ErrorAction SilentlyContinue)) {
        return $null
    }
    $incoming = (Get-AppImageLibraryPaths).incomingDir
    if (-not (Test-Path -LiteralPath $incoming)) {
        $null = New-Item -Path $incoming -ItemType Directory -Force
    }
    $incoming
}

function Resolve-AppAria2DriverModelEntry {
    param(
        [string]$Alias,
        [string]$Vendor,
        [string]$Folder
    )
    if (-not (Get-Command Read-AppPxeBootFieldIsoDriversSeed -ErrorAction SilentlyContinue)) {
        return $null
    }
    $seed = Read-AppPxeBootFieldIsoDriversSeed
    if (-not $seed -or -not $seed.vendors) { return $null }

    $vendorNeedle = if ($Vendor) { $Vendor.Trim() } else { $null }
    $folderNeedle = if ($Folder) { $Folder.Trim() } else { $null }
    $aliasNeedle = if ($Alias) { $Alias.Trim() } else { $null }

    foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
        $vendorName = [string]$vendorProp.Name
        if ($vendorNeedle -and $vendorName -ne $vendorNeedle) { continue }
        foreach ($model in @($vendorProp.Value.models)) {
            $folderName = Get-AppPxeBootFieldIsoDriverSeedStringProp -Model $model -Name 'folder'
            if ([string]::IsNullOrWhiteSpace($folderName)) { continue }

            $matched = $false
            if ($folderNeedle -and $vendorNeedle -and $folderName -eq $folderNeedle) {
                $matched = $true
            } elseif ($folderNeedle -and $folderName -ne $folderNeedle) {
                foreach ($candidate in @($aliasNeedle, $folderNeedle)) {
                    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                    if ($folderName -eq $candidate) { $matched = $true; break }
                    foreach ($pat in @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')) {
                        if ([string]$pat -eq $candidate) { $matched = $true; break }
                        if ($candidate -match [regex]::Escape([string]$pat)) { $matched = $true; break }
                    }
                    if ($matched) { break }
                    if (Get-Command Get-AppAcerSccmPatternVariants -ErrorAction SilentlyContinue) {
                        foreach ($variant in @(Get-AppAcerSccmPatternVariants -Pattern $candidate)) {
                            foreach ($pat in @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')) {
                                if ([string]$pat -eq $variant) { $matched = $true; break }
                            }
                            if ($matched) { break }
                        }
                    }
                    if ($matched) { break }
                }
            } elseif ($aliasNeedle) {
                if ($folderName -eq $aliasNeedle) { $matched = $true }
                else {
                    foreach ($pat in @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')) {
                        if ([string]$pat -eq $aliasNeedle) { $matched = $true; break }
                        if ($aliasNeedle -match [regex]::Escape([string]$pat)) { $matched = $true; break }
                    }
                    if (-not $matched) {
                        foreach ($label in @(Get-AppPxeBootFieldIsoDriverNsspCatalogLabels -Model $model)) {
                            if ([string]$label -eq $aliasNeedle) { $matched = $true; break }
                        }
                    }
                }
            } else {
                continue
            }
            if (-not $matched) { continue }

            $relPath = "drivers/$vendorName/$folderName"
            return @{
                vendor      = $vendorName
                folder      = $folderName
                relPath     = $relPath
                displayName = $folderName
                aliases     = @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')
            }
        }
    }
    return $null
}

function New-AppAria2DriverPromoteTargetFromVendorFolder {
    param(
        [string]$Vendor,
        [string]$Folder
    )
    if ([string]::IsNullOrWhiteSpace($Vendor) -or [string]::IsNullOrWhiteSpace($Folder)) {
        return $null
    }
    $vendorName = $Vendor.Trim()
    $folderName = $Folder.Trim()
    if ($vendorName -match '[/\\]' -or $folderName -match '[/\\]' -or $vendorName -match '\.\.' -or $folderName -match '\.\.') {
        return $null
    }
    $relPath = "drivers/$vendorName/$folderName"
    @{
        vendor      = $vendorName
        folder      = $folderName
        relPath     = $relPath
        displayName = $folderName
        aliases     = @()
    }
}

function Test-AppAria2UriIsHttp {
    param([string]$Uri)
    if ([string]::IsNullOrWhiteSpace($Uri)) { return $false }
    return ([string]$Uri).Trim() -match '^https?://'
}

function Get-AppAria2ExtensionFromName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $ext = [IO.Path]::GetExtension([string]$Name)
    if ($ext) { return $ext.ToLowerInvariant() }
    return $null
}

function Resolve-AppAria2AssetKindFromInput {
    param(
        [string]$AssetKind,
        [string]$FileNameHint,
        [string]$UriHint,
        $Cfg
    )
    $kindNorm = if ($AssetKind) { ([string]$AssetKind).Trim().ToLowerInvariant() } else { 'auto' }
    if ($kindNorm -in @('iso', 'wim', 'driver', 'other')) { return $kindNorm }

    $name = $FileNameHint
    if (-not $name -and $UriHint) {
        try {
            $uri = [Uri]$UriHint
            $leaf = [IO.Path]::GetFileName($uri.LocalPath)
            if ($leaf) { $name = $leaf }
        } catch { }
    }
    $ext = Get-AppAria2ExtensionFromName -Name $name
    $routes = Get-AppAria2NormalizedExtensionRoutes -Cfg $Cfg
    foreach ($route in $routes) {
        $routeExt = [string]$route['ext']
        if ($routeExt -eq '*') {
            return [string]$route['assetKind']
        }
        if ($ext -and $routeExt -eq $ext) {
            return [string]$route['assetKind']
        }
    }
    return 'other'
}

function Test-AppAria2RouteUsesPxeStaging {
    param(
        [Parameter(Mandatory)][string]$AssetKind,
        $Cfg
    )
    if (-not (Test-AppAria2PxeIntegrationEnabled -Cfg $Cfg)) { return $false }
    $routes = Get-AppAria2NormalizedExtensionRoutes -Cfg $Cfg
    foreach ($route in $routes) {
        if ([string]$route['assetKind'] -eq $AssetKind) {
            return [bool]$route['usePxeStaging']
        }
    }
    return $false
}

function Get-AppAria2CustomDirForAssetKind {
    param(
        [Parameter(Mandatory)][string]$AssetKind,
        $Cfg
    )
    $routes = Get-AppAria2NormalizedExtensionRoutes -Cfg $Cfg
    foreach ($route in $routes) {
        if ([string]$route['assetKind'] -eq $AssetKind -and $route['dir']) {
            return [string]$route['dir']
        }
    }
    return $null
}

function New-AppAria2DownloadPlan {
    param(
        [string]$AssetKind = 'auto',
        [string]$ModelAlias,
        [string]$Vendor,
        [string]$Folder,
        [string]$FileNameHint,
        [string[]]$Uris,
        $Cfg
    )
    if (-not $Cfg) { $Cfg = Read-AppAria2Config }
    $uriHint = if ($Uris -and $Uris.Count -gt 0) { [string]$Uris[0] } else { $null }
    $resolvedKind = Resolve-AppAria2AssetKindFromInput -AssetKind $AssetKind -FileNameHint $FileNameHint -UriHint $uriHint -Cfg $Cfg

    $promoteTarget = $null
    if ($resolvedKind -eq 'driver') {
        $promoteTarget = Resolve-AppAria2DriverModelEntry -Alias $ModelAlias -Vendor $Vendor -Folder $Folder
        if (-not $promoteTarget) {
            $promoteTarget = New-AppAria2DriverPromoteTargetFromVendorFolder -Vendor $Vendor -Folder $Folder
        }
        if (-not $promoteTarget) {
            throw "aria2: unknown driver model - use a WMI alias (e.g. P414-53), folder name, or pick from Tracker."
        }
    }

    $useStaging = Test-AppAria2RouteUsesPxeStaging -AssetKind $resolvedKind -Cfg $Cfg
    $stagingDir = $null
    $aria2Dir = Get-AppAria2EffectiveDownloadDir

    if ($useStaging) {
        $incomingRoot = Get-AppAria2PxeIncomingRoot
        if (-not $incomingRoot) {
            throw 'aria2: Netboot store unavailable - enable Netboot once or disable PXE staging.'
        }
        $stagingDir = Join-Path $incomingRoot ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $stagingDir -ItemType Directory -Force
        $aria2Dir = $stagingDir
    } else {
        $custom = Get-AppAria2CustomDirForAssetKind -AssetKind $resolvedKind -Cfg $Cfg
        if ($custom) {
            if (-not (Test-Path -LiteralPath $custom)) {
                $null = New-Item -Path $custom -ItemType Directory -Force
            }
            $aria2Dir = (Resolve-Path -LiteralPath $custom).Path
        }
    }

    @{
        assetKind     = $resolvedKind
        aria2Dir      = $aria2Dir
        stagingDir    = $stagingDir
        promoteTarget = $promoteTarget
        useStaging    = [bool]$useStaging
    }
}

function Register-AppAria2Job {
    param(
        [Parameter(Mandatory)][string]$Gid,
        [Parameter(Mandatory)]$Plan,
        # Tracker catalog row id (e.g. 'site-soe-win11-24h2-v2') - lets the OS
        # images table match its rows to live transfers without name guessing
        # (aria2 row names are file paths / torrent info names, never the
        # manifest display string).
        [string]$CatalogRowId
    )
    $store = Read-AppAria2JobsStore
    $record = @{
        gid           = $Gid
        assetKind     = [string](Get-AppAria2JsonProp -Item $Plan -Name 'assetKind')
        stagingDir    = [string](Get-AppAria2JsonProp -Item $Plan -Name 'stagingDir')
        aria2Dir      = [string](Get-AppAria2JsonProp -Item $Plan -Name 'aria2Dir')
        useStaging    = [bool](Get-AppAria2JsonProp -Item $Plan -Name 'useStaging')
        promoteTarget = Get-AppAria2JsonProp -Item $Plan -Name 'promoteTarget'
        status        = 'downloading'
        addedAt       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if (-not [string]::IsNullOrWhiteSpace($CatalogRowId)) { $record.catalogRowId = [string]$CatalogRowId }
    $store.jobs[$Gid] = $record
    Write-AppAria2JobsStore -Store $store
    $record
}

function Get-AppAria2JobRecord {
    param([Parameter(Mandatory)][string]$Gid)
    $store = Read-AppAria2JobsStore
    if (-not $store.jobs.ContainsKey($Gid)) { return $null }
    $store.jobs[$Gid]
}

function Get-AppAria2DriverPackFileNameFromUri {
    param([string]$Uri)
    if ([string]::IsNullOrWhiteSpace($Uri)) { return $null }
    try {
        $path = ([Uri]$Uri).AbsolutePath
        if ([string]::IsNullOrWhiteSpace($path)) { return $null }
        return [IO.Path]::GetFileName($path)
    } catch {
        return $null
    }
}

function Get-AppAria2StagingFiles {
    param([Parameter(Mandatory)][string]$StagingDir)
    if (-not (Test-Path -LiteralPath $StagingDir)) { return @() }
    @(Get-ChildItem -LiteralPath $StagingDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ne '.aria2' -and $_.Name -ne 'aria2.session' })
}

function Invoke-AppAria2PromoteJobFiles {
    param(
        [Parameter(Mandatory)]$JobRecord
    )
    $kind = [string](Get-AppAria2JsonProp -Item $JobRecord -Name 'assetKind')
    $staging = [string](Get-AppAria2JsonProp -Item $JobRecord -Name 'stagingDir')
    if ([string]::IsNullOrWhiteSpace($staging)) {
        throw 'aria2: promote requires a staging directory.'
    }
    $files = @(Get-AppAria2StagingFiles -StagingDir $staging)
    if ($files.Count -eq 0) {
        throw 'aria2: staging folder is empty - nothing to promote.'
    }

    $result = @{ assetKind = $kind; files = @() }

    switch ($kind) {
        'driver' {
            $target = Get-AppAria2JsonProp -Item $JobRecord -Name 'promoteTarget'
            if (-not $target) { throw 'aria2: driver promote target missing.' }
            $folderName = [string](Get-AppAria2JsonProp -Item $target -Name 'folder')
            if ([string]::IsNullOrWhiteSpace($folderName)) { throw 'aria2: driver target folder missing.' }

            $src = @($files | Where-Object { $_.Extension -match '^(?i)\.(7z|cab|zip|exe|msi)$' } | Sort-Object Length -Descending | Select-Object -First 1)
            if ($src.Count -eq 0) {
                $src = @($files | Sort-Object Length -Descending | Select-Object -First 1)
            }
            $srcFile = $src[0]

            # Drivers/<Make>/<Model> - ImageDeployer 1.10's publish/search convention;
            # Caddy serves it at /drivers/<Make>/<Model>/ (see Write-AppPxeBootCaddyfile).
            # Vendor comes from the promote target; tolerate old job records without one.
            $vendorName = [string](Get-AppAria2JsonProp -Item $target -Name 'vendor')
            $destDir = if ([string]::IsNullOrWhiteSpace($vendorName)) {
                Join-Path (Get-AppPxeBootFieldIsoDriversOsRoot) $folderName
            } else {
                Join-Path (Join-Path (Get-AppPxeBootFieldIsoDriversOsRoot) $vendorName) $folderName
            }
            if (-not (Test-Path -LiteralPath $destDir)) {
                $null = New-Item -Path $destDir -ItemType Directory -Force
            }
            foreach ($existing in @(Get-ChildItem -LiteralPath $destDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^(?i)\.(7z|cab|zip|exe|msi)$' })) {
                Remove-Item -LiteralPath $existing.FullName -Force -ErrorAction SilentlyContinue
            }
            $destFile = Join-Path $destDir $srcFile.Name
            Move-Item -LiteralPath $srcFile.FullName -Destination $destFile -Force
            if (Get-Command Sync-AppPxeBootFieldIsoDriverStore -ErrorAction SilentlyContinue) {
                Sync-AppPxeBootFieldIsoDriverStore | Out-Null
            }
            $result.files += @{ path = $destFile; kind = 'driver' }
            Write-SidecarLog "aria2: promoted driver to $destFile"
        }
        'iso' {
            $src = @($files | Where-Object { $_.Extension -match '^\.iso$' } | Sort-Object Length -Descending | Select-Object -First 1)
            if ($src.Count -eq 0) { throw 'aria2: no .iso file in staging folder.' }
            if (-not (Get-Command Import-AppPxeBootIso -ErrorAction SilentlyContinue)) {
                throw 'aria2: Netboot import unavailable.'
            }
            $imported = Import-AppPxeBootIso -SourcePath $src[0].FullName -ReplaceExisting
            $result.files += @{ path = $imported.fileName; kind = 'iso' }
            Write-SidecarLog "aria2: promoted ISO $($imported.fileName) into Netboot store"
        }
        'wim' {
            $src = @($files | Where-Object { $_.Extension -match '^\.wim$' } | Sort-Object Length -Descending | Select-Object -First 1)
            if ($src.Count -eq 0) { throw 'aria2: no .wim file in staging folder.' }
            # Downloaded WIMs are imageable/SOE images -> <root>/WIMs/ (served at
            # /WIMs/, read by ImageDeployer). Boot WIMs are imported separately via
            # the Netboot panel and stay in the PXE store.
            if (-not (Get-Command Import-AppPxeBootImageableWim -ErrorAction SilentlyContinue)) {
                throw 'aria2: imageable WIM import unavailable.'
            }
            $imported = Import-AppPxeBootImageableWim -SourcePath $src[0].FullName -ReplaceExisting
            $result.files += @{ path = $imported.fileName; kind = 'wim' }
            Write-SidecarLog "aria2: promoted imageable WIM $($imported.fileName) into WIMs library"
        }
        default {
            throw "aria2: promote not configured for asset kind $kind."
        }
    }

    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $result
}

function Sync-AppAria2RecoverIncomingDriverStaging {
    if (-not (Get-Command Get-AppAria2PxeIncomingRoot -ErrorAction SilentlyContinue)) { return 0 }
    $incoming = Get-AppAria2PxeIncomingRoot
    if (-not $incoming -or -not (Test-Path -LiteralPath $incoming)) { return 0 }

    # Never touch a folder a direct download is still writing into (running or queued),
    # and never promote an archive that changed in the last two minutes: in-flight files
    # are named <name>.part (excluded by the extension filter below) but archives staged
    # by older builds carry their final name from byte one.
    $activeStaging = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $liveEntries = @()
    if (Get-Variable -Name AppAria2DirectDownloadJobs -Scope Script -ErrorAction SilentlyContinue) {
        $liveEntries += @($script:AppAria2DirectDownloadJobs.Values)
    }
    if (Get-Variable -Name AppAria2DirectDownloadQueue -Scope Script -ErrorAction SilentlyContinue) {
        $liveEntries += @($script:AppAria2DirectDownloadQueue)
    }
    foreach ($live in $liveEntries) {
        $livePlan = Get-AppAria2JsonProp -Item $live -Name 'plan'
        foreach ($name in @('stagingDir', 'aria2Dir')) {
            $liveDir = [string](Get-AppAria2JsonProp -Item $livePlan -Name $name)
            if ($liveDir) { [void]$activeStaging.Add($liveDir.TrimEnd('/', '\')) }
        }
    }

    $recovered = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $incoming -Directory -ErrorAction SilentlyContinue)) {
        if ($activeStaging.Contains($dir.FullName.TrimEnd('/', '\'))) { continue }
        $files = @(Get-AppAria2StagingFiles -StagingDir $dir.FullName)
        $archive = @($files | Where-Object { $_.Extension -match '^\.(7z|cab|zip|exe)$' } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($archive.Count -eq 0) { continue }
        if (((Get-Date) - $archive[0].LastWriteTime).TotalMinutes -lt 2) { continue }

        $target = $null
        if (Get-Command Get-AppAcerSccmModelCodesFromFileName -ErrorAction SilentlyContinue) {
            foreach ($code in @(Get-AppAcerSccmModelCodesFromFileName -FileName $archive[0].Name)) {
                $target = Resolve-AppAria2DriverModelEntry -Alias $code -Vendor 'Acer'
                if ($target) { break }
                $target = Resolve-AppAria2DriverModelEntry -Alias "TravelMate $code" -Vendor 'Acer'
                if ($target) { break }
            }
        }
        if (-not $target) { continue }

        try {
            Invoke-AppAria2PromoteJobFiles -JobRecord @{
                assetKind     = 'driver'
                stagingDir    = $dir.FullName
                promoteTarget = $target
            } | Out-Null
            $recovered++
            Write-SidecarLog "aria2: recovered staged driver from $($dir.Name) -> $($target.folder)"
        } catch {
            Write-SidecarLogVerbose "aria2: recover staged driver failed ($($dir.Name)) - $($_.Exception.Message)"
        }
    }
    return $recovered
}

function Sync-AppAria2PromoteJobs {
    if (Get-Command Sync-AppAria2RecoverIncomingDriverStaging -ErrorAction SilentlyContinue) {
        Sync-AppAria2RecoverIncomingDriverStaging | Out-Null
    }
    if (-not (Test-AppAria2DaemonRunning)) { return @{ promoted = 0; failed = 0 } }
    $store = Read-AppAria2JobsStore
    if ($store.jobs.Count -eq 0) { return @{ promoted = 0; failed = 0 } }

    $promoted = 0
    $failed = 0
    $changed = $false

    foreach ($gid in @($store.jobs.Keys)) {
        $job = $store.jobs[$gid]
        $status = [string](Get-AppAria2JsonProp -Item $job -Name 'status')
        if ($status -in @('promoted', 'failed', 'skipped')) { continue }
        if (-not [bool](Get-AppAria2JsonProp -Item $job -Name 'useStaging')) {
            $jobHash = ConvertTo-AppAria2JobHashtable -Job $job
            $jobHash['status'] = 'skipped'
            $store.jobs[$gid] = $jobHash
            $changed = $true
            continue
        }

        try {
            $st = Invoke-AppAria2Rpc -Method 'aria2.tellStatus' -Params @([string]$gid)
            $result = Get-AppAria2JsonProp -Item $st -Name 'result'
            $aria2Status = [string](Get-AppAria2JsonProp -Item $result -Name 'status')
        } catch {
            continue
        }

        if ($aria2Status -eq 'complete') {
            try {
                $out = Invoke-AppAria2PromoteJobFiles -JobRecord $job
                $jobHash = ConvertTo-AppAria2JobHashtable -Job $job
                $jobHash['status'] = 'promoted'
                $jobHash['promotedAt'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $jobHash['promoteResult'] = $out
                $store.jobs[$gid] = $jobHash
                $changed = $true
                $promoted++
                try {
                    Invoke-AppAria2Rpc -Method 'aria2.removeDownloadResult' -Params @([string]$gid) | Out-Null
                } catch { }
                Write-SidecarEvent -EventName 'aria2-promote' -Data @{
                    gid       = [string]$gid
                    assetKind = [string](Get-AppAria2JsonProp -Item $job -Name 'assetKind')
                    ok        = $true
                }
            } catch {
                $jobHash = ConvertTo-AppAria2JobHashtable -Job $job
                $jobHash['status'] = 'failed'
                $jobHash['error'] = $_.Exception.Message
                $store.jobs[$gid] = $jobHash
                $changed = $true
                $failed++
                Write-SidecarLog "aria2: promote failed for $gid - $($_.Exception.Message)"
                Write-SidecarEvent -EventName 'aria2-promote' -Data @{
                    gid     = [string]$gid
                    ok      = $false
                    message = $_.Exception.Message
                }
            }
        } elseif ($aria2Status -eq 'error') {
            $jobHash = ConvertTo-AppAria2JobHashtable -Job $job
            $jobHash['status'] = 'failed'
            $errMsg = Get-AppAria2JsonProp -Item $result -Name 'errorMessage'
            if ($errMsg) { $jobHash['error'] = [string]$errMsg }
            $store.jobs[$gid] = $jobHash
            $changed = $true
            $failed++
        }
    }

    if ($changed) {
        Write-AppAria2JobsStore -Store $store
    }
    @{ promoted = $promoted; failed = $failed }
}

# --- Background direct HTTP downloads -------------------------------------
# Driver packs used to stream inside the AddAria2Download handler, which held
# the single-threaded dispatch loop for the whole transfer (every other panel's
# IPC queued behind it) and capped the app at one pack at a time. Each download
# now runs in its own in-process runspace (the Start-Job-free pattern from
# BootstrapNetwork.ps1 - Start-Job fails silently in packaged builds) writing
# byte counts into a synchronized hashtable; the main loop's housekeeping tick
# (Sync-AppAria2DirectDownloadJobs) emits the progress events, verifies, and
# promotes each pack as it lands. The handler returns immediately.

$script:AppAria2DirectDownloadJobs = @{}
# Cap + FIFO queue (Craig, 2026-08-20): at most 10 packs stream at once; further
# requests queue and start as slots free. Cancel works on active and queued alike,
# so a tech can line packs up and prune the line when bandwidth gets tight.
$script:AppAria2DirectDownloadMaxActive = 10
$script:AppAria2DirectDownloadQueue = [System.Collections.Generic.List[hashtable]]::new()
# Terminal outcome of the last direct download per progress key ('failed' | 'promoted' |
# 'done'), kept in memory for the Netboot driver pull-through ledger, which reconciles
# its 'download-started' entries against it and retries a failed model on the next
# device of that model (Craig, 2026-08-22). A new start for the same key clears it.
$script:AppAria2DirectDownloadOutcomes = @{}

function Test-AppAria2DirectDownloadActive {
    # True while a direct download for the key is running or queued.
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    if ($script:AppAria2DirectDownloadJobs.ContainsKey($Key)) { return $true }
    return (@($script:AppAria2DirectDownloadQueue | Where-Object { [string]$_.key -eq $Key }).Count -gt 0)
}

function Get-AppAria2DirectDownloadOutcome {
    # @{ status; error; fileName; at } for the last finished direct download of the key, or $null.
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if ($script:AppAria2DirectDownloadOutcomes.ContainsKey($Key)) { return $script:AppAria2DirectDownloadOutcomes[$Key] }
    return $null
}

function Set-AppAria2DirectDownloadOutcome {
    param([string]$Key, [string]$Status, [string]$Error, [string]$FileName)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    $script:AppAria2DirectDownloadOutcomes[$Key] = @{
        status   = [string]$Status
        error    = [string]$Error
        fileName = [string]$FileName
        at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

$script:AppAria2DirectDownloadWorker = {
    # Runs in a bare runspace: NO sidecar function exists here. Everything it needs - the
    # user agent included - arrives as an argument (field regression 2026-08-22: calling
    # Get-AppUserAgent from here threw 'not recognized' and every direct download failed).
    param($Uri, $OutFile, $TimeoutSec, $Sync, $ExpectedHash, $HashAlgorithm, $UserAgent)
    $client = $null; $resp = $null; $inStream = $null; $outStream = $null; $hasher = $null
    try {
        # Hash while streaming (catalog SHA-256/MD5 where published) - zero extra I/O
        # and no dispatch-loop stall; a mismatch fails the job before it can promote.
        if (-not [string]::IsNullOrWhiteSpace([string]$ExpectedHash)) {
            $algName = ([string]$HashAlgorithm).Trim().ToUpperInvariant()
            if ($algName -notin @('SHA256', 'MD5', 'SHA1', 'SHA384', 'SHA512')) { $algName = 'SHA256' }
            $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($algName)
        }
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(30, [int]$TimeoutSec))
        if (-not [string]::IsNullOrWhiteSpace([string]$UserAgent)) { [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd([string]$UserAgent) }
        $resp = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "HTTP $([int]$resp.StatusCode) ($($resp.ReasonPhrase)) for $Uri"
        }
        if ($resp.Content.Headers.ContentLength) { $Sync['totalBytes'] = [long]$resp.Content.Headers.ContentLength }
        $inStream = $resp.Content.ReadAsStream()
        $outStream = [System.IO.File]::Create($OutFile)
        $buffer = [byte[]]::new(262144)
        $bytesDone = [long]0
        while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            if ($hasher) { [void]$hasher.TransformBlock($buffer, 0, $read, $null, 0) }
            $bytesDone += $read
            $Sync['bytesDone'] = $bytesDone
        }
        $total = [long]$Sync['totalBytes']
        if ($total -gt 0 -and $bytesDone -lt $total) {
            throw "incomplete download: $bytesDone of $total bytes from $Uri"
        }
        if ($hasher) {
            [void]$hasher.TransformFinalBlock([byte[]]::new(0), 0, 0)
            $actual = ([BitConverter]::ToString($hasher.Hash) -replace '-', '').ToLowerInvariant()
            $expected = ([string]$ExpectedHash).Trim().ToLowerInvariant()
            if ($actual -ne $expected) {
                throw "hash mismatch (file corrupt or catalog stale): expected $expected, got $actual"
            }
        }
        $Sync['done'] = $true
    } catch {
        $Sync['error'] = $_.Exception.Message
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream) { $inStream.Dispose() }
        if ($resp) { $resp.Dispose() }
        if ($client) { $client.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }
}

function Sync-AppAria2DirectDownloadJobs {
    <#
    .SYNOPSIS
        Main-loop tick for background direct downloads: emits throttled
        'driver-download-progress' events per active job, and on completion
        verifies, promotes, emits the terminal events, and disposes the runspace.
        Runs from Invoke-SidecarDispatchOnce housekeeping (~50ms cadence idle,
        and via the dispatch pump while another long handler holds the loop).
    #>
    if ($script:AppAria2DirectDownloadJobs.Count -eq 0 -and $script:AppAria2DirectDownloadQueue.Count -eq 0) { return 0 }
    $canEmit = [bool](Get-Command Write-SidecarEvent -ErrorAction SilentlyContinue)
    foreach ($key in @($script:AppAria2DirectDownloadJobs.Keys)) {
        $job = $script:AppAria2DirectDownloadJobs[$key]
        $sync = $job.sync
        if (-not $job.handle.IsCompleted) {
            if ($canEmit -and $job.stopwatch.ElapsedMilliseconds -ge 350) {
                Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                    key        = [string]$key
                    bytesDone  = [long]$sync['bytesDone']
                    totalBytes = [long]$sync['totalBytes']
                    done       = $false
                }
                $job.stopwatch.Restart()
            }
            continue
        }

        $script:AppAria2DirectDownloadJobs.Remove($key)
        try { [void]$job.ps.EndInvoke($job.handle) } catch {
            if (-not $sync['error']) { $sync['error'] = $_.Exception.Message }
        }
        try { $job.ps.Dispose() } catch { }
        try { $job.rs.Dispose() } catch { }

        $plan = $job.plan
        $err = $sync['error']
        if (-not $err -and -not [bool]$sync['done']) { $err = 'download worker ended without completing' }

        if ($err) {
            Write-SidecarLog "aria2: direct download failed for $($job.fileName) - $err"
            # A bad file must never look Downloaded: purge the partial/corrupt file so
            # no store scan or staging-recovery sweep can promote it. The row keeps a
            # failed note and the USER retries (the Netboot pull-through retries on the
            # next device of the same model, see PxeBootDriverPullThrough.ps1) - no auto-retry (Craig, 2026-08-20).
            # (v1 promoted the partial here, replacing a good pack with a truncated one.)
            foreach ($partial in @($job.destPath, $job.partPath)) {
                if ($partial -and (Test-Path -LiteralPath $partial)) {
                    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                }
            }
            Set-AppAria2DirectDownloadOutcome -Key ([string]$key) -Status 'failed' -Error ([string]$err) -FileName ([string]$job.fileName)
            if ($canEmit) {
                Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                    key        = [string]$key
                    bytesDone  = [long]$sync['bytesDone']
                    totalBytes = [long]$sync['totalBytes']
                    done       = $true
                    failed     = $true
                    message    = [string]$err
                    fileName   = [string]$job.fileName
                }
            }
            continue
        }

        # Verified complete: give the archive its real name (see Start-AppAria2DirectDownloadEntry).
        if ($job.partPath -and (Test-Path -LiteralPath $job.partPath)) {
            try {
                Move-Item -LiteralPath $job.partPath -Destination $job.destPath -Force -ErrorAction Stop
            } catch {
                $msg = "could not finalise $($job.fileName): $($_.Exception.Message)"
                Write-SidecarLog "aria2: direct download failed for $($job.fileName) - $msg"
                Remove-Item -LiteralPath $job.partPath -Force -ErrorAction SilentlyContinue
                Set-AppAria2DirectDownloadOutcome -Key ([string]$key) -Status 'failed' -Error $msg -FileName ([string]$job.fileName)
                if ($canEmit) {
                    Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                        key = [string]$key; bytesDone = [long]$sync['bytesDone']; totalBytes = [long]$sync['totalBytes']
                        done = $true; failed = $true; message = $msg; fileName = [string]$job.fileName
                    }
                }
                continue
            }
        }

        if ($canEmit) {
            Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                key        = [string]$key
                bytesDone  = [long]$sync['bytesDone']
                totalBytes = [long]$sync['totalBytes']
                done       = $true
            }
        }
        if ($plan.useStaging) {
            try {
                $jobRecord = @{
                    assetKind     = [string]$plan.assetKind
                    stagingDir    = [string]$plan.stagingDir
                    promoteTarget = $plan.promoteTarget
                }
                $null = Invoke-AppAria2PromoteJobFiles -JobRecord $jobRecord
                Set-AppAria2DirectDownloadOutcome -Key ([string]$key) -Status 'promoted' -FileName ([string]$job.fileName)
                # The Drivers/OS lists show what is on disk, so the memoised payload is
                # stale the instant a pack or ISO lands.
                Clear-AppAria2TrackerCatalogPayloadCache
                if ($canEmit) {
                    Write-SidecarEvent -EventName 'aria2-promote' -Data @{
                        ok        = $true
                        assetKind = [string]$plan.assetKind
                        direct    = $true
                        key       = [string]$key
                        fileName  = [string]$job.fileName
                    }
                }
            } catch {
                Write-SidecarLog "aria2: promote failed for $($job.fileName) - $($_.Exception.Message)"
                Set-AppAria2DirectDownloadOutcome -Key ([string]$key) -Status 'failed' -Error ('promote failed: ' + $_.Exception.Message) -FileName ([string]$job.fileName)
                if ($canEmit) {
                    Write-SidecarEvent -EventName 'aria2-promote' -Data @{
                        ok       = $false
                        direct   = $true
                        key      = [string]$key
                        fileName = [string]$job.fileName
                        message  = $_.Exception.Message
                    }
                }
            }
        } else {
            Set-AppAria2DirectDownloadOutcome -Key ([string]$key) -Status 'done' -FileName ([string]$job.fileName)
        }
        if (-not $plan.useStaging -and $canEmit) {
            # No staging route - the file already sits at its final destination,
            # but the row still needs releasing.
            Write-SidecarEvent -EventName 'aria2-promote' -Data @{
                ok        = $true
                assetKind = [string]$plan.assetKind
                direct    = $true
                key       = [string]$key
                fileName  = [string]$job.fileName
            }
        }
    }
    Start-AppAria2QueuedDirectDownloads
    $script:AppAria2DirectDownloadJobs.Count
}

function Stop-AppAria2DirectDownloadJobs {
    # Shutdown cleanup: abandon in-flight transfers and free their runspaces.
    $script:AppAria2DirectDownloadQueue.Clear()
    foreach ($key in @($script:AppAria2DirectDownloadJobs.Keys)) {
        $job = $script:AppAria2DirectDownloadJobs[$key]
        try { $job.ps.Stop() } catch { }
        try { $job.ps.Dispose() } catch { }
        try { $job.rs.Dispose() } catch { }
        $script:AppAria2DirectDownloadJobs.Remove($key)
    }
}

function Add-AppAria2DirectHttpDownload {
    param(
        [Parameter(Mandatory)][string[]]$Uris,
        [string]$AssetKind = 'auto',
        [string]$ModelAlias,
        [string]$Vendor,
        [string]$Folder,
        [string]$FileNameHint,
        [int]$TimeoutSec = 7200,
        [string]$ProgressKey,
        [string]$ExpectedHash,
        [string]$ExpectedHashAlgorithm
    )
    $clean = @($Uris | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($clean.Count -eq 0) { throw 'aria2: at least one URI is required.' }
    $uri = [string]$clean[0]
    if (-not (Test-AppAria2UriIsHttp -Uri $uri)) {
        throw 'aria2: direct download supports HTTP(S) URLs only.'
    }

    $cfg = Read-AppAria2Config
    $plan = New-AppAria2DownloadPlan `
        -AssetKind $AssetKind `
        -ModelAlias $ModelAlias `
        -Vendor $Vendor `
        -Folder $Folder `
        -FileNameHint $FileNameHint `
        -Uris $clean `
        -Cfg $cfg

    $fileName = $FileNameHint
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = Get-AppAria2DriverPackFileNameFromUri -Uri $uri
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        try {
            $fileName = [IO.Path]::GetFileName(([Uri]$uri).LocalPath)
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = 'download.bin'
    }
    # Manual Add-tab driver URLs carry no row key - synthesize one so their
    # progress/completion events still have an address.
    if ([string]::IsNullOrWhiteSpace($ProgressKey)) {
        $ProgressKey = 'manual|' + $fileName
    }
    $alreadyQueued = @($script:AppAria2DirectDownloadQueue | Where-Object { [string]$_.key -eq $ProgressKey }).Count -gt 0
    if ($script:AppAria2DirectDownloadJobs.ContainsKey($ProgressKey) -or $alreadyQueued) {
        return @{
            gid            = $null
            direct         = $true
            accepted       = $true
            alreadyRunning = $true
            key            = [string]$ProgressKey
            fileName       = [string]$fileName
            assetKind      = [string]$plan.assetKind
            promoteTarget  = $plan.promoteTarget
        }
    }

    $script:AppAria2DirectDownloadOutcomes.Remove([string]$ProgressKey)
    $entry = @{
        key                   = [string]$ProgressKey
        uri                   = $uri
        fileName              = [string]$fileName
        timeoutSec            = [int]$TimeoutSec
        plan                  = $plan
        expectedHash          = [string]$ExpectedHash
        expectedHashAlgorithm = [string]$ExpectedHashAlgorithm
    }

    if ($script:AppAria2DirectDownloadJobs.Count -ge $script:AppAria2DirectDownloadMaxActive) {
        [void]$script:AppAria2DirectDownloadQueue.Add($entry)
        if (Get-Command Write-SidecarEvent -ErrorAction SilentlyContinue) {
            Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                key        = [string]$ProgressKey
                bytesDone  = 0
                totalBytes = 0
                done       = $false
                queued     = $true
            }
        }
        Write-SidecarLog "aria2: direct HTTP download queued ($($script:AppAria2DirectDownloadQueue.Count) waiting) $uri"
        return @{
            gid           = $null
            direct        = $true
            accepted      = $true
            queued        = $true
            key           = [string]$ProgressKey
            fileName      = [string]$fileName
            assetKind     = [string]$plan.assetKind
            promoteTarget = $plan.promoteTarget
        }
    }

    Start-AppAria2DirectDownloadEntry -Entry $entry

    @{
        gid           = $null
        direct        = $true
        accepted      = $true
        key           = [string]$ProgressKey
        fileName      = [string]$fileName
        assetKind     = [string]$plan.assetKind
        promoteTarget = $plan.promoteTarget
    }
}

function Start-AppAria2DirectDownloadEntry {
    # Spin up the runspace for one queued/new entry (caller enforces the cap).
    param([Parameter(Mandatory)][hashtable]$Entry)
    $plan = $Entry.plan
    $destDir = [string]$plan.aria2Dir
    if (-not (Test-Path -LiteralPath $destDir)) {
        $null = New-Item -Path $destDir -ItemType Directory -Force
    }
    $destPath = Join-Path $destDir ([string]$Entry.fileName)
    # The worker writes <name>.part; the file only takes its real name once the download
    # verified complete, so a half-written archive can never be promoted - not by the
    # Drivers tab, not by the staging-recovery sweep (field lesson 2026-08-22: an app
    # restart mid-download left a 401 MB partial that the sweep would have promoted over
    # the good 1.25 GB pack).
    $partPath = $destPath + '.part'
    Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue

    $sync = [hashtable]::Synchronized(@{ bytesDone = [long]0; totalBytes = [long]0; done = $false; error = $null })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:AppAria2DirectDownloadWorker.ToString()).AddArgument([string]$Entry.uri).AddArgument($partPath).AddArgument([int]$Entry.timeoutSec).AddArgument($sync).AddArgument([string]$Entry.expectedHash).AddArgument([string]$Entry.expectedHashAlgorithm).AddArgument([string](Get-AppUserAgent))
    $handle = $ps.BeginInvoke()

    $script:AppAria2DirectDownloadJobs[[string]$Entry.key] = @{
        ps        = $ps
        rs        = $rs
        handle    = $handle
        sync      = $sync
        plan      = $plan
        destPath  = $destPath
        partPath  = $partPath
        fileName  = [string]$Entry.fileName
        uri       = [string]$Entry.uri
        stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if (Get-Command Write-SidecarEvent -ErrorAction SilentlyContinue) {
        Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
            key        = [string]$Entry.key
            bytesDone  = 0
            totalBytes = 0
            done       = $false
        }
    }
    Write-SidecarLog "aria2: direct HTTP download started $($Entry.uri) -> $destPath"
}

function Start-AppAria2QueuedDirectDownloads {
    # Fill free slots from the FIFO queue (called whenever a job finishes/cancels).
    while ($script:AppAria2DirectDownloadQueue.Count -gt 0 -and
        $script:AppAria2DirectDownloadJobs.Count -lt $script:AppAria2DirectDownloadMaxActive) {
        $next = $script:AppAria2DirectDownloadQueue[0]
        $script:AppAria2DirectDownloadQueue.RemoveAt(0)
        try {
            Start-AppAria2DirectDownloadEntry -Entry $next
        } catch {
            Write-SidecarLog "aria2: queued download failed to start ($($next.fileName)) - $($_.Exception.Message)"
            if (Get-Command Write-SidecarEvent -ErrorAction SilentlyContinue) {
                Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                    key = [string]$next.key; bytesDone = 0; totalBytes = 0
                    done = $true; failed = $true; message = $_.Exception.Message
                    fileName = [string]$next.fileName
                }
            }
        }
    }
}

function Stop-AppAria2DirectDownload {
    <#
    .SYNOPSIS
        Cancel one direct download by row key - active (runspace stopped, partial file
        purged) or still queued (dequeued). Emits a cancelled terminal event and starts
        the next queued entry. Returns $true when something was cancelled.
    #>
    param([Parameter(Mandatory)][string]$Key)
    $cancelled = $false
    for ($i = 0; $i -lt $script:AppAria2DirectDownloadQueue.Count; $i++) {
        if ([string]$script:AppAria2DirectDownloadQueue[$i].key -eq $Key) {
            $script:AppAria2DirectDownloadQueue.RemoveAt($i)
            $cancelled = $true
            break
        }
    }
    if (-not $cancelled -and $script:AppAria2DirectDownloadJobs.ContainsKey($Key)) {
        $job = $script:AppAria2DirectDownloadJobs[$Key]
        $script:AppAria2DirectDownloadJobs.Remove($Key)
        try { $job.ps.Stop() } catch { }
        try { $job.ps.Dispose() } catch { }
        try { $job.rs.Dispose() } catch { }
        # The worker's finally released the file handles on Stop; purge the partial.
        Start-Sleep -Milliseconds 100
        foreach ($partial in @($job.destPath, $job.partPath)) {
            if ($partial -and (Test-Path -LiteralPath $partial)) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }
        }
        $cancelled = $true
    }
    if ($cancelled) {
        Write-SidecarLog "aria2: direct download cancelled ($Key)"
        if (Get-Command Write-SidecarEvent -ErrorAction SilentlyContinue) {
            Write-SidecarEvent -EventName 'driver-download-progress' -Data @{
                key = [string]$Key; bytesDone = 0; totalBytes = 0
                done = $true; cancelled = $true
            }
        }
        Start-AppAria2QueuedDirectDownloads
    }
    $cancelled
}

function Add-AppAria2ManagedDownload {
    param(
        [string]$Kind = 'uri',
        [string[]]$Uris,
        [string]$TorrentBase64,
        [string]$AssetKind = 'auto',
        [string]$ModelAlias,
        [string]$Vendor,
        [string]$Folder,
        [string]$FileNameHint,
        [string]$ProgressKey,
        [string]$ExpectedHash,
        [string]$ExpectedHashAlgorithm,
        [string]$CatalogRowId
    )
    $cfg = Read-AppAria2Config
    $kindNorm = ([string]$Kind).Trim().ToLowerInvariant()
    $assetKindNorm = if ($AssetKind) { ([string]$AssetKind).Trim().ToLowerInvariant() } else { 'auto' }
    $uriList = @($Uris | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $firstUri = if ($uriList.Count -gt 0) { [string]$uriList[0] } else { $null }
    if ($kindNorm -eq 'uri' -and $assetKindNorm -eq 'driver' -and (Test-AppAria2UriIsHttp -Uri $firstUri)) {
        return Add-AppAria2DirectHttpDownload `
            -Uris $uriList `
            -AssetKind $AssetKind `
            -ModelAlias $ModelAlias `
            -Vendor $Vendor `
            -Folder $Folder `
            -FileNameHint $FileNameHint `
            -ProgressKey $ProgressKey `
            -ExpectedHash $ExpectedHash `
            -ExpectedHashAlgorithm $ExpectedHashAlgorithm
    }
    if (-not (Test-AppAria2DaemonRunning)) {
        throw 'aria2: daemon is not running - start the daemon for torrent/magnet downloads, or use an HTTP driver pack from Tracker.'
    }
    $plan = New-AppAria2DownloadPlan `
        -AssetKind $AssetKind `
        -ModelAlias $ModelAlias `
        -Vendor $Vendor `
        -Folder $Folder `
        -FileNameHint $FileNameHint `
        -Uris $Uris `
        -Cfg $cfg

    $options = @{ dir = [string]$plan.aria2Dir }
    if ($kindNorm -eq 'torrent') {
        $added = Add-AppAria2TorrentDownload -TorrentBase64 $TorrentBase64 -Options $options
    } else {
        $added = Add-AppAria2UriDownload -Uris $Uris -Options $options
    }
    $gid = [string]$added.gid
    $job = Register-AppAria2Job -Gid $gid -Plan $plan -CatalogRowId $CatalogRowId
    @{
        gid           = $gid
        assetKind     = [string]$plan.assetKind
        stagingDir    = $plan.stagingDir
        promoteTarget = $plan.promoteTarget
        job           = $job
    }
}

function Get-AppAria2PackagingSearchPaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(
            $(if ($script:SidecarRoot) { Join-Path $script:SidecarRoot 'packaging' } else { $null })
            $(if ($script:AppSidecarProjectRoot) { Join-Path $script:AppSidecarProjectRoot 'packaging' } else { $null })
            $(if ($script:ProjectRoot) { Join-Path $script:ProjectRoot 'packaging' } else { $null })
            $(Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging')
            $(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'packaging')
        )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($candidate)
        } catch {
            continue
        }
        if (-not $seen.Contains($full)) {
            [void]$seen.Add($full)
            [void]$paths.Add($full)
        }
    }
    @($paths)
}

function Resolve-AppAria2PackagingFile {
    param([Parameter(Mandatory)][string]$FileName)
    foreach ($dir in @(Get-AppAria2PackagingSearchPaths)) {
        $path = Join-Path $dir $FileName
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-AppAria2PackagingDir {
    foreach ($name in @('lenovo-sccm-catalog.json', 'acer-sccm-catalog.json', 'dell-sccm-catalog.json', 'hp-sccm-catalog.json', 'aria2-tracker.json')) {
        $path = Resolve-AppAria2PackagingFile -FileName $name
        if ($path) { return Split-Path -Parent $path }
    }
    $paths = @(Get-AppAria2PackagingSearchPaths)
    if ($paths.Count -gt 0) { return $paths[0] }
    $sidecarRoot = if ($script:SidecarRoot) { $script:SidecarRoot } else { Split-Path $PSScriptRoot -Parent }
    return Join-Path $sidecarRoot 'packaging'
}

function Get-AppAria2TrackerManifestPath {
    $path = Resolve-AppAria2PackagingFile -FileName 'aria2-tracker.json'
    if ($path) { return $path }
    return $null
}

function Get-AppAria2TrackerManifestUrl {
    $bundledPath = Join-Path (Get-AppAria2PackagingDir) 'aria2-tracker.json'
    $manifestUrl = $script:AppAria2TrackerManifestDefaultUrl
    if (Test-Path -LiteralPath $bundledPath) {
        try {
            $bundled = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $urlProp = Get-AppAria2JsonProp -Item $bundled -Name 'manifestUrl'
            if ($urlProp) { $manifestUrl = [string]$urlProp }
        } catch { }
    }
    $manifestUrl
}

function Set-AppAria2TrackerManifestMemoryCache {
    param(
        [Parameter(Mandatory)]$Manifest,
        # Switch, not [bool]: every caller passes a bare -Stale, which a [bool]
        # parameter rejects ("Missing an argument for parameter 'Stale'"). That
        # broke the whole tracker catalog on the stale/bundled fallback path -
        # i.e. any machine that cannot reach the manifest host. (USM bug.)
        [switch]$Stale
    )
    $script:AppAria2TrackerManifestMemory = @{
        manifest = $Manifest
        cachedAt = (Get-Date).ToUniversalTime()
        stale    = [bool]$Stale
    }
}

function Test-AppAria2TrackerManifestFetchBackoffActive {
    return ($script:AppAria2TrackerManifestFetchBackoffUntil -and (Get-Date) -lt $script:AppAria2TrackerManifestFetchBackoffUntil)
}

function Start-AppAria2TrackerManifestFetchBackoff {
    $script:AppAria2TrackerManifestFetchBackoffUntil = (Get-Date).AddMinutes($script:AppAria2TrackerManifestFetchBackoffMinutes)
}

function Clear-AppAria2TrackerManifestFetchBackoff {
    $script:AppAria2TrackerManifestFetchBackoffUntil = $null
    $script:AppAria2TrackerManifestFetchFailureLoggedAt = $null
}

function Write-AppAria2TrackerManifestFetchFailureLog {
    param(
        [Parameter(Mandatory)][string]$ManifestUrl,
        [Parameter(Mandatory)][string]$Message
    )
    $shouldLog = $true
    if ($script:AppAria2TrackerManifestFetchFailureLoggedAt) {
        $elapsed = ((Get-Date) - $script:AppAria2TrackerManifestFetchFailureLoggedAt).TotalMinutes
        $shouldLog = ($elapsed -ge $script:AppAria2TrackerManifestFetchBackoffMinutes)
    }
    if ($shouldLog) {
        Write-SidecarLogVerbose "aria2: tracker manifest fetch failed ($ManifestUrl): $Message"
        $script:AppAria2TrackerManifestFetchFailureLoggedAt = Get-Date
    }
}

function Read-AppAria2TrackerManifestDiskCache {
    param([switch]$AllowStale)
    $cachePath = Get-AppAria2TrackerManifestCachePath
    if (-not (Test-Path -LiteralPath $cachePath)) { return $null }
    try {
        $cached = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $fetchedAtRaw = Get-AppAria2JsonProp -Item $cached -Name 'fetchedAt'
        $manifest = Get-AppAria2JsonProp -Item $cached -Name 'manifest'
        if (-not $manifest) { return $null }
        if (-not $AllowStale -and $fetchedAtRaw) {
            # PS7 ConvertFrom-Json hydrates ISO strings into [DateTime] - parse only strings.
            $fetchedAt = if ($fetchedAtRaw -is [datetime]) {
                [datetime]$fetchedAtRaw
            } else {
                [datetime]::Parse([string]$fetchedAtRaw, $null, [Globalization.DateTimeStyles]::RoundtripKind)
            }
            $ageHours = ((Get-Date).ToUniversalTime() - $fetchedAt.ToUniversalTime()).TotalHours
            if ($ageHours -lt $script:AppAria2TrackerManifestCacheHours) {
                return $manifest
            }
            return $null
        }
        return $manifest
    } catch {
        return $null
    }
}

function Read-AppAria2TrackerManifestBundled {
    $bundledPath = Join-Path (Get-AppAria2PackagingDir) 'aria2-tracker.json'
    if (-not (Test-Path -LiteralPath $bundledPath)) { return $null }
    try {
        return Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-SidecarLogVerbose "aria2: bundled tracker manifest read failed - $($_.Exception.Message)"
        return $null
    }
}

function Read-AppAria2TrackerManifest {
    param([switch]$ForceRefresh)

    if (-not $ForceRefresh -and $script:AppAria2TrackerManifestMemory) {
        $mem = $script:AppAria2TrackerManifestMemory
        $ageHours = ((Get-Date).ToUniversalTime() - [datetime]$mem.cachedAt).TotalHours
        if ($mem.stale) {
            if (Test-AppAria2TrackerManifestFetchBackoffActive) {
                return $mem.manifest
            }
        } elseif ($ageHours -lt $script:AppAria2TrackerManifestCacheHours) {
            return $mem.manifest
        }
    }

    if (-not $ForceRefresh) {
        $freshDisk = Read-AppAria2TrackerManifestDiskCache
        if ($freshDisk) {
            Set-AppAria2TrackerManifestMemoryCache -Manifest $freshDisk
            Clear-AppAria2TrackerManifestFetchBackoff
            return $freshDisk
        }
    }

    $manifestUrl = Get-AppAria2TrackerManifestUrl
    if (-not $ForceRefresh -and (Test-AppAria2TrackerManifestFetchBackoffActive)) {
        $staleDisk = Read-AppAria2TrackerManifestDiskCache -AllowStale
        if ($staleDisk) {
            Set-AppAria2TrackerManifestMemoryCache -Manifest $staleDisk -Stale
            return $staleDisk
        }
        $bundled = Read-AppAria2TrackerManifestBundled
        if ($bundled) {
            Set-AppAria2TrackerManifestMemoryCache -Manifest $bundled -Stale
            return $bundled
        }
    }

    try {
        $remote = Invoke-RestMethod -Uri $manifestUrl -Method Get -UseBasicParsing -TimeoutSec 45
        if ($remote) {
            Write-AppAria2TrackerManifestCache -Manifest $remote
            Set-AppAria2TrackerManifestMemoryCache -Manifest $remote
            Clear-AppAria2TrackerManifestFetchBackoff
            Write-SidecarLogVerbose 'aria2: tracker manifest refreshed from GitLab.'
            return $remote
        }
    } catch {
        Write-AppAria2TrackerManifestFetchFailureLog -ManifestUrl $manifestUrl -Message $_.Exception.Message
        Start-AppAria2TrackerManifestFetchBackoff
    }

    $staleDisk = Read-AppAria2TrackerManifestDiskCache -AllowStale
    if ($staleDisk) {
        Set-AppAria2TrackerManifestMemoryCache -Manifest $staleDisk -Stale
        Write-SidecarLogVerbose 'aria2: tracker manifest using stale disk cache.'
        return $staleDisk
    }

    $bundled = Read-AppAria2TrackerManifestBundled
    if ($bundled) {
        Set-AppAria2TrackerManifestMemoryCache -Manifest $bundled -Stale
        return $bundled
    }
    return $null
}

function Test-AppAria2TorrentManifestEntryIsOem {
    param(
        [Parameter(Mandatory)]$Entry
    )
    $group = [string](Get-AppAria2JsonProp -Item $Entry -Name 'catalogGroup')
    if ($group -eq 'oem') { return $true }
    $kind = [string](Get-AppAria2JsonProp -Item $Entry -Name 'assetKind')
    return ($kind -eq 'iso')
}

function New-AppAria2TorrentCatalogRowFromManifestEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$PackagingDir
    )
    $id = [string](Get-AppAria2JsonProp -Item $Entry -Name 'id')
    if (-not $id) { return $null }
    $rel = [string](Get-AppAria2JsonProp -Item $Entry -Name 'torrentPath')
    $downloadUrlProp = Get-AppAria2JsonProp -Item $Entry -Name 'downloadUrl'
    $downloadUrl = if ($downloadUrlProp) { [string]$downloadUrlProp } else { $null }
    $hasBundled = $false
    if ($rel -and $rel -notmatch '\.\.') {
        $full = Join-Path $PackagingDir $rel
        $hasBundled = Test-Path -LiteralPath $full
    }
    if (-not $hasBundled -and [string]::IsNullOrWhiteSpace($downloadUrl)) { return $null }
    $nameVal = Get-AppAria2JsonProp -Item $Entry -Name 'name'
    $kindVal = Get-AppAria2JsonProp -Item $Entry -Name 'assetKind'
    $sizeVal = Get-AppAria2JsonProp -Item $Entry -Name 'sizeBytes'
    # Real payload size parsed from the torrent (sizeBytes is the .torrent file's
    # own size - the publish script stamps it and the UI must not show it as the image).
    $contentSizeVal = Get-AppAria2JsonProp -Item $Entry -Name 'contentSizeBytes'
    $groupVal = Get-AppAria2JsonProp -Item $Entry -Name 'catalogGroup'
    $subfolderVal = Get-AppAria2JsonProp -Item $Entry -Name 'subfolder'
    $sourceVal = Get-AppAria2JsonProp -Item $Entry -Name 'source'
    @{
        id               = $id
        name             = if ($nameVal) { [string]$nameVal } elseif ($rel) { [IO.Path]::GetFileNameWithoutExtension($rel) } else { $id }
        assetKind        = if ($kindVal) { [string]$kindVal } else { 'wim' }
        catalogGroup     = if ($groupVal) { [string]$groupVal } else { $null }
        torrentPath      = if ($hasBundled) { $rel } else { $null }
        downloadUrl      = $downloadUrl
        contentSizeBytes = if ($contentSizeVal) { [long]$contentSizeVal } else { 0 }
        sizeBytes    = if ($sizeVal) { [long]$sizeVal } else { 0 }
        subfolder    = if ($subfolderVal) { [string]$subfolderVal } else { $null }
        source       = if ($sourceVal) { [string]$sourceVal } else { 'bundled' }
        downloadable = [bool]($hasBundled -or $downloadUrl)
    }
}

function Get-AppAria2TorrentCatalogRows {
    param($Tracker)
    if (-not $Tracker) { $Tracker = Read-AppAria2TrackerManifest }
    if (-not $Tracker) { return @() }
    $packagingDir = Get-AppAria2PackagingDir
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @(Get-AppAria2JsonProp -Item $Tracker -Name 'torrents')) {
        if (Test-AppAria2TorrentManifestEntryIsOem -Entry $entry) { continue }
        $row = New-AppAria2TorrentCatalogRowFromManifestEntry -Entry $entry -PackagingDir $packagingDir
        if ($row) { [void]$rows.Add($row) }
    }
    @($rows)
}

function Get-AppAria2OemIsoCatalogRows {
    param($Tracker)
    if (-not $Tracker) { $Tracker = Read-AppAria2TrackerManifest }
    if (-not $Tracker) { return @() }
    $packagingDir = Get-AppAria2PackagingDir
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $idSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in @(Get-AppAria2JsonProp -Item $Tracker -Name 'oemIsos')) {
        $id = [string](Get-AppAria2JsonProp -Item $entry -Name 'id')
        if (-not $id -or $idSeen.Contains($id)) { continue }
        $uriProp = Get-AppAria2JsonProp -Item $entry -Name 'uri'
        $uri = if ($uriProp) { [string]$uriProp } else { $null }
        $downloadUrlProp = Get-AppAria2JsonProp -Item $entry -Name 'downloadUrl'
        $downloadUrl = if ($downloadUrlProp) { [string]$downloadUrlProp } else { $null }
        if ([string]::IsNullOrWhiteSpace($uri) -and [string]::IsNullOrWhiteSpace($downloadUrl)) { continue }
        [void]$idSeen.Add($id)
        $nameVal = Get-AppAria2JsonProp -Item $entry -Name 'name'
        $kindVal = Get-AppAria2JsonProp -Item $entry -Name 'assetKind'
        $sizeVal = Get-AppAria2JsonProp -Item $entry -Name 'sizeBytes'
        $subfolderVal = Get-AppAria2JsonProp -Item $entry -Name 'subfolder'
        $sourceVal = Get-AppAria2JsonProp -Item $entry -Name 'source'
        [void]$rows.Add(@{
                id           = $id
                name         = if ($nameVal) { [string]$nameVal } else { $id }
                assetKind    = if ($kindVal) { [string]$kindVal } else { 'iso' }
                uri          = $uri
                downloadUrl  = $downloadUrl
                sizeBytes    = if ($sizeVal) { [long]$sizeVal } else { 0 }
                subfolder    = if ($subfolderVal) { [string]$subfolderVal } else { $null }
                source       = if ($sourceVal) { [string]$sourceVal } else { 'manifest' }
                downloadable = $true
            })
    }

    foreach ($entry in @(Get-AppAria2JsonProp -Item $Tracker -Name 'torrents')) {
        if (-not (Test-AppAria2TorrentManifestEntryIsOem -Entry $entry)) { continue }
        $row = New-AppAria2TorrentCatalogRowFromManifestEntry -Entry $entry -PackagingDir $packagingDir
        if (-not $row) { continue }
        if ($idSeen.Contains([string]$row.id)) { continue }
        [void]$idSeen.Add([string]$row.id)
        [void]$rows.Add($row)
    }

    @($rows | Sort-Object { $_.name })
}

function Get-AppAria2TorrentCatalogRowById {
    param(
        [Parameter(Mandatory)][string]$TorrentId
    )
    foreach ($row in @(Get-AppAria2TorrentCatalogRows)) {
        if ([string]$row.id -eq $TorrentId) { return $row }
    }
    foreach ($row in @(Get-AppAria2OemIsoCatalogRows)) {
        if ([string]$row.id -ne $TorrentId) { continue }
        if ($row.torrentPath -or $row.downloadUrl) { return $row }
    }
    return $null
}

function Add-AppAria2BundledTorrentDownload {
    param(
        [Parameter(Mandatory)][string]$TorrentId
    )
    $match = Get-AppAria2TorrentCatalogRowById -TorrentId $TorrentId
    $downloadUrl = $null
    $fileNameHint = $null

    if (-not $match) {
        $tracker = Read-AppAria2TrackerManifest
        if ($tracker) {
            foreach ($entry in @(Get-AppAria2JsonProp -Item $tracker -Name 'torrents')) {
                if ([string](Get-AppAria2JsonProp -Item $entry -Name 'id') -eq $TorrentId) {
                    $match = $entry
                    break
                }
            }
        }
    }
    if (-not $match) { throw "aria2: unknown torrent id '$TorrentId'." }

    $rel = [string](Get-AppAria2JsonProp -Item $match -Name 'torrentPath')
    $downloadUrlProp = Get-AppAria2JsonProp -Item $match -Name 'downloadUrl'
    if ($downloadUrlProp) { $downloadUrl = [string]$downloadUrlProp }
    elseif ($match.downloadUrl) { $downloadUrl = [string]$match.downloadUrl }

    $assetKind = [string](Get-AppAria2JsonProp -Item $match -Name 'assetKind')
    if ([string]::IsNullOrWhiteSpace($assetKind) -and $match.assetKind) { $assetKind = [string]$match.assetKind }
    if ([string]::IsNullOrWhiteSpace($assetKind)) { $assetKind = 'wim' }

    $nameProp = Get-AppAria2JsonProp -Item $match -Name 'name'
    $displayName = if ($nameProp) { [string]$nameProp } elseif ($match.name) { [string]$match.name } else { $TorrentId }
    $fileNameHint = "$displayName.torrent"

    $bytes = $null
    if ($rel -and $rel -notmatch '\.\.') {
        $full = Join-Path (Get-AppAria2PackagingDir) $rel
        if (Test-Path -LiteralPath $full) {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $fileNameHint = Split-Path -Leaf $rel
        }
    }

    if (-not $bytes -and $downloadUrl) {
        try {
            $resp = Invoke-WebRequest -Uri $downloadUrl -Method Get -UseBasicParsing -TimeoutSec 120
            $bytes = $resp.Content
            if ($bytes -is [string]) {
                $bytes = [System.Text.Encoding]::Latin1.GetBytes($bytes)
            }
        } catch {
            throw "aria2: torrent download failed ($downloadUrl) - $($_.Exception.Message)"
        }
    }

    if (-not $bytes) {
        throw "aria2: torrent unavailable (not bundled, no downloadUrl) - $TorrentId"
    }

    $b64 = [Convert]::ToBase64String($bytes)
    return Add-AppAria2ManagedDownload `
        -Kind 'torrent' `
        -TorrentBase64 $b64 `
        -AssetKind $assetKind `
        -FileNameHint $fileNameHint `
        -CatalogRowId $TorrentId
}

function Test-AppLenovoCatalogTypesMatchSeedPatterns {
    param(
        [Parameter(Mandatory)][string[]]$Types,
        [string[]]$SeedPatterns = @()
    )
    foreach ($pattern in @($SeedPatterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        foreach ($typeCode in @($Types)) {
            if (Test-AppLenovoTypeMatchesPattern -TypeCode $typeCode -Pattern $pattern) {
                return $true
            }
        }
    }
    $false
}

function Get-AppAria2AcerCatalogDriverRows {
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [string[]]$SeedFolders = @(),
        [string[]]$SeedPatterns = @(),
        [Parameter(Mandatory)]$IndexReady,
        # Structured entries from AcerCatalog.xml (name/url/os/version/md5) - used to give
        # non-TravelMate remainder rows their friendly names and hashes.
        $XmlModels = $null
    )
    if (-not (Get-Command Get-AppAcerSccmTravelMateCatalogEntries -ErrorAction SilentlyContinue)) {
        return @()
    }
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $seenFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $consumedUrls = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(Get-AppAcerSccmTravelMateCatalogEntries -Urls $Urls)) {
        if ($entry.url) { [void]$consumedUrls.Add([string]$entry.url) }
        if (Get-AppAria2JsonProp -Item $entry -Name 'rnAliasOf') { continue }
        $folder = [string]$entry.folder
        $code = [string]$entry.code
        $vendorName = 'Acer'
        if ([string]::IsNullOrWhiteSpace($folder) -or $seenFolders.Contains($folder)) { continue }
        if (@($SeedFolders) -contains $folder) { continue }
        $seedTarget = Resolve-AppAria2DriverModelEntry -Alias $code -Vendor $vendorName
        if (-not $seedTarget -and $code) {
            $seedTarget = Resolve-AppAria2DriverModelEntry -Alias "TravelMate $code" -Vendor $vendorName
        }
        if ($seedTarget) {
            $folder = [string]$seedTarget.folder
        }
        if ($seenFolders.Contains($folder)) { continue }
        [void]$seenFolders.Add($folder)
        $key = "$vendorName|$folder"
        $family = [string](Get-AppAria2JsonProp -Item $entry -Name 'family')
        if ([string]::IsNullOrWhiteSpace($family)) { $family = 'travelmate' }
        $relPath = if ($seedTarget) { [string]$seedTarget.relPath } else { "drivers/$vendorName/$folder" }
        $modelName = if ($seedTarget) { $folder } else { [string]$entry.displayName }
        $aliasList = [System.Collections.Generic.List[string]]::new()
        foreach ($a in @($code, "TravelMate $code")) {
            if (-not [string]::IsNullOrWhiteSpace($a)) { [void]$aliasList.Add([string]$a) }
        }
        if ($code -match '^P(\d+)-(\d+)$' -and $code -notmatch 'RN') {
            [void]$aliasList.Add("P$($Matches[1])RN-$($Matches[2])")
            [void]$aliasList.Add("TravelMate P$($Matches[1])RN-$($Matches[2])")
            [void]$aliasList.Add("$($Matches[1])RN-$($Matches[2])")
            [void]$aliasList.Add("TMP$($Matches[1])RN-$($Matches[2])")
            [void]$aliasList.Add("TMP$($Matches[1])-$($Matches[2])")
        }
        if ($code -match '^B(.+)') {
            $bRest = $Matches[1]
            [void]$aliasList.Add("TMB$bRest")
            [void]$aliasList.Add("TM-B$bRest")
        }
        if ($code -match '^X(.+)') {
            [void]$aliasList.Add("TMX$($Matches[1])")
        }
        [void]$rows.Add(@{
                kind            = 'driver'
                vendor          = $vendorName
                folder          = $folder
                modelName       = $modelName
                catalogFamily   = $family
                catalogOnly     = $true
                expectedArchive = if ($entry.url) { Get-AppAria2DriverPackFileNameFromUri -Uri ([string]$entry.url) } else { $null }
                relPath         = $relPath
                aliases         = @($aliasList | Select-Object -Unique)
                nsspLabels      = @()
                archiveReady    = if ($IndexReady.ContainsKey($key)) { $IndexReady[$key] } else { $false }
                uri             = [string]$entry.url
                magnet          = $null
                source          = 'acer'
                downloadable    = $true
            })
    }

    # Every remaining catalog URL becomes a row too (Craig, 2026-08-18: show every pack -
    # the filter handles narrowing). These are the Veriton/desktop/Extensa/legacy packs the
    # TravelMate parser has no model entry for. Friendly names + MD5 come from the
    # AcerCatalog.xml entries when the URL matches.
    $xmlByUrl = @{}
    $seenDisplays = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($xm in @($XmlModels)) {
        $xu = [string](Get-AppAria2JsonProp -Item $xm -Name 'url')
        if ($xu -and -not $xmlByUrl.ContainsKey($xu)) { $xmlByUrl[$xu] = $xm }
    }
    foreach ($url in @($Urls)) {
        if ([string]::IsNullOrWhiteSpace([string]$url)) { continue }
        if ($consumedUrls.Contains([string]$url)) { continue }
        $fileName = [System.IO.Path]::GetFileName(([string]$url))
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($fileName) -replace '%20', ' '
        # Base model token = stem up to the first OS marker; the marker itself labels the row.
        $osLabel = $null
        $variant = $null
        $base = $stem
        $m = [regex]::Match($stem, '(?i)[_ ](Windows|Win|W)[ _]?(11|10|8\.1|8|7)')
        if ($m.Success) {
            $base = $stem.Substring(0, $m.Index)
            $osLabel = "Windows $($m.Groups[2].Value)"
            # Distinguish sibling packs that differ past the OS token (x64/x86, Wigig,
            # revision numbers) - 'All' is the common no-op suffix and is dropped.
            $rest = $stem.Substring($m.Index + $m.Length)
            $restTokens = @($rest -split '[_ ]+' | Where-Object { $_ -and $_ -notmatch '^(?i)all$' })
            if ($restTokens.Count -gt 0) { $variant = ($restTokens -join ' ') }
        }
        $base = $base.Trim('_', ' ', '-')
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $stem }
        $folder = $base
        $modelName = $base
        $family = 'other'
        $expectedHash = $null
        if ($xmlByUrl.ContainsKey([string]$url)) {
            $xm = $xmlByUrl[[string]$url]
            $xmName = [string](Get-AppAria2JsonProp -Item $xm -Name 'name')
            if ($xmName) { $modelName = $xmName; $folder = $xmName }
            $md5 = [string](Get-AppAria2JsonProp -Item $xm -Name 'md5')
            if ($md5) { $expectedHash = $md5 }
        }
        $display = if ($osLabel -and $variant) {
            "$modelName ($osLabel, $variant)"
        } elseif ($osLabel) {
            "$modelName ($osLabel)"
        } else {
            $modelName
        }
        # Last-resort uniquifier: display names double as frontend row keys.
        $n = 2
        $candidate = $display
        while (-not $seenDisplays.Add("$folder|$candidate")) { $candidate = "$display ($n)"; $n++ }
        $display = $candidate
        $key = "Acer|$folder"
        [void]$rows.Add(@{
                kind            = 'driver'
                vendor          = 'Acer'
                folder          = $folder
                modelName       = $display
                catalogFamily   = $family
                catalogOnly     = $true
                expectedArchive = $fileName
                expectedHash    = $expectedHash
                expectedHashAlgorithm = if ($expectedHash) { 'MD5' } else { $null }
                relPath         = "drivers/Acer/$folder"
                aliases         = @($base)
                nsspLabels      = @()
                archiveReady    = if ($IndexReady.ContainsKey($key)) { $IndexReady[$key] } else { $false }
                uri             = [string]$url
                magnet          = $null
                source          = 'acer'
                downloadable    = $true
            })
    }
    @($rows)
}

function Get-AppAria2MicrosoftCatalogDriverRows {
    param(
        [Parameter(Mandatory)]$MicrosoftCatalog,
        [Parameter(Mandatory)]$IndexReady
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in @(Get-AppAria2JsonProp -Item $MicrosoftCatalog -Name 'models')) {
        $modelName = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        $folder = [string](Get-AppAria2JsonProp -Item $model -Name 'folder')
        $url = [string](Get-AppAria2JsonProp -Item $model -Name 'url')
        if ([string]::IsNullOrWhiteSpace($modelName) -or [string]::IsNullOrWhiteSpace($url)) { continue }
        if ($seenNames.Contains($modelName)) { continue }
        [void]$seenNames.Add($modelName)
        $family = [string](Get-AppAria2JsonProp -Item $model -Name 'family')
        $vendorName = 'Microsoft'
        $key = "$vendorName|$folder"
        $aliases = [System.Collections.Generic.List[string]]::new()
        [void]$aliases.Add($modelName)
        foreach ($sysId in @(Get-AppAria2JsonProp -Item $model -Name 'systemIds')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$sysId)) { [void]$aliases.Add([string]$sysId) }
        }
        [void]$rows.Add(@{
                kind            = 'driver'
                vendor          = $vendorName
                folder          = $folder
                modelName       = $modelName
                catalogFamily   = if ($family) { $family } else { $null }
                catalogOs       = [string](Get-AppAria2JsonProp -Item $model -Name 'os')
                catalogArch     = [string](Get-AppAria2JsonProp -Item $model -Name 'arch')
                catalogOnly     = $true
                expectedArchive = [string](Get-AppAria2JsonProp -Item $model -Name 'fileName')
                relPath         = "drivers/$vendorName/$folder"
                aliases         = @($aliases | Select-Object -Unique)
                nsspLabels      = @()
                archiveReady    = if ($IndexReady.ContainsKey($key)) { $IndexReady[$key] } else { $false }
                uri             = $url
                magnet          = $null
                source          = 'microsoft'
                downloadable    = $true
            })
    }
    @($rows)
}

function Get-AppAria2LenovoCatalogDriverRows {
    param(
        [Parameter(Mandatory)]$LenovoCatalog,
        [string[]]$SeedPatterns = @(),
        [Parameter(Mandatory)]$IndexReady
    )
    if (-not (Get-Command Get-AppLenovoSccmBestSccmEntryForModel -ErrorAction SilentlyContinue)) {
        return @()
    }
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $seenModels = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in @(Get-AppAria2JsonProp -Item $LenovoCatalog -Name 'models')) {
        $types = @(Get-AppAria2JsonProp -Item $model -Name 'types')
        if ($types.Count -eq 0) { continue }
        $modelName = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        if ([string]::IsNullOrWhiteSpace($modelName) -or $seenModels.Contains($modelName)) { continue }
        if (Test-AppLenovoCatalogTypesMatchSeedPatterns -Types $types -SeedPatterns $SeedPatterns) {
            continue
        }
        $best = Get-AppLenovoSccmBestSccmEntryForModel -Model $model
        if (-not $best) { continue }
        $folder = Get-AppLenovoSccmPrimaryTypeCode -Types $types
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        [void]$seenModels.Add($modelName)
        $family = [string](Get-AppAria2JsonProp -Item $model -Name 'family')
        $vendorName = 'LENOVO'
        $key = "$vendorName|$folder"
        [void]$rows.Add(@{
                kind            = 'driver'
                vendor          = $vendorName
                folder          = $folder
                modelName       = $modelName
                catalogFamily   = if ($family) { $family } else { $null }
                catalogOnly     = $true
                expectedArchive = if ($best.url) { Get-AppAria2DriverPackFileNameFromUri -Uri ([string]$best.url) } else { $null }
                expectedHash          = [string](Get-AppAria2JsonProp -Item $best -Name 'expectedHash')
                expectedHashAlgorithm = [string](Get-AppAria2JsonProp -Item $best -Name 'expectedHashAlgorithm')
                relPath         = "drivers/$vendorName/$folder"
                aliases         = @($types)
                nsspLabels      = @()
                archiveReady    = if ($IndexReady.ContainsKey($key)) { $IndexReady[$key] } else { $false }
                uri             = [string]$best.url
                magnet          = $null
                source          = 'lenovo'
                downloadable    = $true
            })
    }
    @($rows)
}

function Test-AppDellCatalogModelMatchesSeedPatterns {
    param(
        [Parameter(Mandatory)][string]$SystemId,
        [Parameter(Mandatory)][string]$ModelName,
        [string[]]$SeedPatterns = @()
    )
    foreach ($pattern in @($SeedPatterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if (Test-AppDellSystemIdMatchesPattern -SystemId $SystemId -Pattern $pattern) { return $true }
        if ($ModelName -and $ModelName -like "*$pattern*") { return $true }
    }
    $false
}

function Get-AppAria2DellCatalogDriverRows {
    param(
        [Parameter(Mandatory)]$DellCatalog,
        [string[]]$SeedPatterns = @(),
        [Parameter(Mandatory)]$IndexReady
    )
    if (-not (Get-Command Get-AppDellSccmBestPackForModel -ErrorAction SilentlyContinue)) {
        return @()
    }
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $seenSystemIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in @(Get-AppAria2JsonProp -Item $DellCatalog -Name 'models')) {
        $systemId = [string](Get-AppAria2JsonProp -Item $model -Name 'systemId')
        $modelName = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        if ([string]::IsNullOrWhiteSpace($systemId) -or $seenSystemIds.Contains($systemId)) { continue }
        if (Test-AppDellCatalogModelMatchesSeedPatterns -SystemId $systemId -ModelName $modelName -SeedPatterns $SeedPatterns) {
            continue
        }
        $best = Get-AppDellSccmBestPackForModel -Model $model
        if (-not $best) { continue }
        [void]$seenSystemIds.Add($systemId)
        $family = [string](Get-AppAria2JsonProp -Item $model -Name 'family')
        $brand = [string](Get-AppAria2JsonProp -Item $model -Name 'brand')
        $vendorName = 'Dell'
        $folder = $systemId
        $key = "$vendorName|$folder"
        $aliases = [System.Collections.Generic.List[string]]::new()
        [void]$aliases.Add($systemId)
        if ($modelName) { [void]$aliases.Add($modelName) }
        [void]$rows.Add(@{
                kind            = 'driver'
                vendor          = $vendorName
                folder          = $folder
                modelName       = $modelName
                catalogFamily   = if ($family) { $family } else { $null }
                catalogBrand    = if ($brand) { $brand } else { $null }
                catalogOnly     = $true
                expectedArchive = if ($best.url) { Get-AppAria2DriverPackFileNameFromUri -Uri ([string]$best.url) } else { $null }
                expectedHash          = [string](Get-AppAria2JsonProp -Item $best -Name 'expectedHash')
                expectedHashAlgorithm = [string](Get-AppAria2JsonProp -Item $best -Name 'expectedHashAlgorithm')
                relPath         = "drivers/$vendorName/$folder"
                aliases         = @($aliases)
                nsspLabels      = @()
                archiveReady    = if ($IndexReady.ContainsKey($key)) { $IndexReady[$key] } else { $false }
                uri             = [string]$best.url
                magnet          = $null
                source          = 'dell'
                downloadable    = $true
            })
    }
    @($rows)
}

function Test-AppHpCatalogModelMatchesSeedPatterns {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Folder,
        [string[]]$SeedPatterns = @()
    )
    foreach ($pattern in @($SeedPatterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if (Test-AppHpModelNameMatchesPattern -Name $Name -Pattern $pattern) { return $true }
        if ($Folder -and $Folder -like "*$pattern*") { return $true }
    }
    $false
}

function Get-AppAria2HpCatalogDriverRows {
    param(
        [Parameter(Mandatory)]$HpCatalog,
        [string[]]$SeedPatterns = @(),
        [Parameter(Mandatory)]$IndexReady
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in @(Get-AppAria2JsonProp -Item $HpCatalog -Name 'models')) {
        $modelName = [string](Get-AppAria2JsonProp -Item $model -Name 'name')
        $folder = [string](Get-AppAria2JsonProp -Item $model -Name 'folder')
        $url = [string](Get-AppAria2JsonProp -Item $model -Name 'url')
        if ([string]::IsNullOrWhiteSpace($modelName) -or [string]::IsNullOrWhiteSpace($folder) -or [string]::IsNullOrWhiteSpace($url)) {
            continue
        }
        $rowKey = "$folder|$modelName"
        if ($seenKeys.Contains($rowKey)) { continue }
        if (Test-AppHpCatalogModelMatchesSeedPatterns -Name $modelName -Folder $folder -SeedPatterns $SeedPatterns) {
            continue
        }
        [void]$seenKeys.Add($rowKey)
        $family = [string](Get-AppAria2JsonProp -Item $model -Name 'family')
        $softpaq = [string](Get-AppAria2JsonProp -Item $model -Name 'softpaq')
        $vendorName = 'HP'
        $key = "$vendorName|$folder"
        [void]$rows.Add(@{
                kind            = 'driver'
                vendor          = $vendorName
                folder          = $folder
                modelName       = $modelName
                catalogFamily   = if ($family) { $family } else { $null }
                catalogSoftpaq  = if ($softpaq) { $softpaq } else { $null }
                catalogOnly     = $true
                expectedArchive = Get-AppAria2DriverPackFileNameFromUri -Uri $url
                expectedHash          = [string](Get-AppAria2JsonProp -Item $model -Name 'expectedHash')
                expectedHashAlgorithm = [string](Get-AppAria2JsonProp -Item $model -Name 'expectedHashAlgorithm')
                relPath         = "drivers/$vendorName/$folder"
                aliases         = @($modelName)
                nsspLabels      = @()
                archiveReady    = if ($IndexReady.ContainsKey($key)) { $IndexReady[$key] } else { $false }
                uri             = $url
                magnet          = $null
                source          = 'hp'
                downloadable    = $true
            })
    }
    @($rows)
}

# Building the tracker payload walks the driver seed and all five vendor catalogs:
# ~1500 rows and about a second of work, EVERY call, on the single-threaded dispatch
# loop. The Drivers panel asks for it on mount and after events, which is what made it
# take 10-15 seconds to appear (field, 2026-08-22). Memoised briefly instead, and
# invalidated the moment anything that feeds it changes.
$script:AppAria2TrackerPayloadCache = $null
$script:AppAria2TrackerPayloadTtlSeconds = 120

function Clear-AppAria2TrackerCatalogPayloadCache {
    $script:AppAria2TrackerPayloadCache = $null
}

function Get-AppAria2TrackerCatalogPayload {
    param([switch]$Force)
    $nowUtc = (Get-Date).ToUniversalTime()
    if (-not $Force -and $script:AppAria2TrackerPayloadCache -and
        ($nowUtc - $script:AppAria2TrackerPayloadCache.at).TotalSeconds -lt $script:AppAria2TrackerPayloadTtlSeconds) {
        return $script:AppAria2TrackerPayloadCache.payload
    }
    $tracker = Read-AppAria2TrackerManifest
    $torrentRows = @(Get-AppAria2TorrentCatalogRows -Tracker $tracker)
    $oemIsoRows = @(Get-AppAria2OemIsoCatalogRows -Tracker $tracker)
    if (Get-Command Add-AppAria2TorrentPeerCountsToRows -ErrorAction SilentlyContinue) {
        $torrentRows = @(Add-AppAria2TorrentPeerCountsToRows -Rows $torrentRows)
        $oemIsoRows = @(Add-AppAria2TorrentPeerCountsToRows -Rows $oemIsoRows)
    }
    $catalogMeta = @{
        torrents    = $torrentRows
        oemIsos     = $oemIsoRows
        announceUrl = [string](Get-AppAria2JsonProp -Item $tracker -Name 'announceUrl')
        statsUrl       = [string](Get-AppAria2JsonProp -Item $tracker -Name 'statsUrl')
        siteStatsUrl = [string](Get-AppAria2JsonProp -Item $tracker -Name 'siteStatsUrl')
        trackerUrl  = [string](Get-AppAria2JsonProp -Item $tracker -Name 'manifestUrl')
        generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if (-not (Get-Command Read-AppPxeBootFieldIsoDriversSeed -ErrorAction SilentlyContinue)) {
        $catalogMeta['drivers'] = @()
        $catalogMeta['note'] = 'FieldIso driver seed unavailable.'
        return $catalogMeta
    }
    $seed = Read-AppPxeBootFieldIsoDriversSeed
    $trackerMap = @{}
    if ($tracker -and (Get-AppAria2JsonProp -Item $tracker -Name 'entries')) {
        foreach ($entry in @(Get-AppAria2JsonProp -Item $tracker -Name 'entries')) {
            $v = [string](Get-AppAria2JsonProp -Item $entry -Name 'vendor')
            $f = [string](Get-AppAria2JsonProp -Item $entry -Name 'folder')
            if ($v -and $f) {
                $trackerMap["$v|$f"] = $entry
            }
        }
    }

    # Downloaded state ("Ready" in the panel) = what is actually in the driver store on
    # disk (<library>/Drivers/<Vendor>/<Model>/ holding a pack file), keyed vendor|folder.
    # The old source - the FieldIso index - only ever listed seed models, so catalog-row
    # downloads could never show as downloaded (Craig, 2026-08-18).
    $indexReady = @{}
    if (Get-Command Get-AppPxeBootFieldIsoDriversOsRoot -ErrorAction SilentlyContinue) {
        try {
            $driversRoot = Get-AppPxeBootFieldIsoDriversOsRoot
            if ($driversRoot -and (Test-Path -LiteralPath $driversRoot)) {
                foreach ($vendorDir in @(Get-ChildItem -LiteralPath $driversRoot -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($modelDir in @(Get-ChildItem -LiteralPath $vendorDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                        $hasPack = @(Get-ChildItem -LiteralPath $modelDir.FullName -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Extension -match '^(?i)\.(7z|cab|zip|exe|msi)$' }).Count -gt 0
                        if ($hasPack) {
                            $indexReady["$($vendorDir.Name)|$($modelDir.Name)"] = $true
                        }
                    }
                }
            }
        } catch {
            Write-SidecarLogVerbose "aria2: driver store ready scan failed - $($_.Exception.Message)"
        }
    }
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $lenovoSeedPatterns = [System.Collections.Generic.List[string]]::new()
    $dellSeedPatterns = [System.Collections.Generic.List[string]]::new()
    $hpSeedPatterns = [System.Collections.Generic.List[string]]::new()
    $acerSeedFolders = [System.Collections.Generic.List[string]]::new()
    $acerSeedPatterns = [System.Collections.Generic.List[string]]::new()
    $acerCatalog = $null
    if (Get-Command Get-AppAcerSccmDriverUrlCatalog -ErrorAction SilentlyContinue) {
        $acerCatalog = Get-AppAcerSccmDriverUrlCatalog -CacheOnly
        if (-not $acerCatalog -and (Get-AppAcerSccmCatalogLastError)) {
            Write-SidecarLogVerbose "aria2: Acer SCCM catalog - $(Get-AppAcerSccmCatalogLastError)"
        }
    }
    $lenovoCatalog = $null
    if (Get-Command Get-AppLenovoSccmDriverCatalog -ErrorAction SilentlyContinue) {
        $lenovoCatalog = Get-AppLenovoSccmDriverCatalog -CacheOnly
        if (-not $lenovoCatalog -and (Get-AppLenovoSccmCatalogLastError)) {
            Write-SidecarLogVerbose "aria2: Lenovo SCCM catalog - $(Get-AppLenovoSccmCatalogLastError)"
        }
    }
    $dellCatalog = $null
    if (Get-Command Get-AppDellSccmDriverCatalog -ErrorAction SilentlyContinue) {
        $dellCatalog = Get-AppDellSccmDriverCatalog -CacheOnly
        if (-not $dellCatalog -and (Get-AppDellSccmCatalogLastError)) {
            Write-SidecarLogVerbose "aria2: Dell SCCM catalog - $(Get-AppDellSccmCatalogLastError)"
        }
    }
    $hpCatalog = $null
    if (Get-Command Get-AppHpSccmDriverCatalog -ErrorAction SilentlyContinue) {
        $hpCatalog = Get-AppHpSccmDriverCatalog -CacheOnly
        if (-not $hpCatalog -and (Get-AppHpSccmCatalogLastError)) {
            Write-SidecarLogVerbose "aria2: HP SCCM catalog - $(Get-AppHpSccmCatalogLastError)"
        }
    }
    $microsoftCatalog = $null
    if (Get-Command Get-AppMicrosoftSccmDriverCatalog -ErrorAction SilentlyContinue) {
        $microsoftCatalog = Get-AppMicrosoftSccmDriverCatalog -CacheOnly
        if (-not $microsoftCatalog -and (Get-AppMicrosoftSccmCatalogLastError)) {
            Write-SidecarLogVerbose "aria2: Microsoft SCCM catalog - $(Get-AppMicrosoftSccmCatalogLastError)"
        }
    }
    $seedVendors = Get-AppAria2JsonProp -Item $seed -Name 'vendors'
    if ($seed -and $seedVendors) {
        foreach ($vendorProp in $seedVendors.PSObject.Properties) {
            $vendorName = [string]$vendorProp.Name
            # Mirror-era ghosts (Craig, 2026-08-18): models.seed.json snapshots the retired
            # deploy.example.com OOBD folder tree, and its rows (bare codes like 20L/82V)
            # rendered ahead of - and folded away - the better-named catalog rows. Catalog
            # rows are canonical for catalog-covered vendors now; the seed keeps its other
            # jobs (FieldIso store/index + WinPE WMI matching, promote alias resolution).
            # Only vendors WITHOUT a vendor catalog (Proxmox VirtIO lab packs) still
            # surface seed rows here.
            if ($vendorName -in @('Acer', 'LENOVO', 'Dell', 'HP', 'Microsoft')) { continue }
            foreach ($model in @($vendorProp.Value.models)) {
                $folderName = Get-AppPxeBootFieldIsoDriverSeedStringProp -Model $model -Name 'folder'
                if ([string]::IsNullOrWhiteSpace($folderName)) { continue }
                $expected = $null
                $key = "$vendorName|$folderName"
                $trackerEntry = if ($trackerMap.ContainsKey($key)) { $trackerMap[$key] } else { $null }
                $uri = $null
                $magnet = $null
                $source = $null
                if ($trackerEntry) {
                    $uriVal = Get-AppAria2JsonProp -Item $trackerEntry -Name 'uri'
                    $magnetVal = Get-AppAria2JsonProp -Item $trackerEntry -Name 'magnet'
                    if ($uriVal) {
                        $uri = [string]$uriVal
                        $source = 'manifest'
                    }
                    if ($magnetVal) { $magnet = [string]$magnetVal }
                }
                $patterns = @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')
                if ($vendorName -eq 'Acer') {
                    [void]$acerSeedFolders.Add($folderName)
                    foreach ($pat in $patterns) {
                        if (-not [string]::IsNullOrWhiteSpace($pat)) { [void]$acerSeedPatterns.Add([string]$pat) }
                    }
                }
                if ($vendorName -eq 'LENOVO') {
                    foreach ($pat in $patterns) {
                        if (-not [string]::IsNullOrWhiteSpace($pat)) { [void]$lenovoSeedPatterns.Add([string]$pat) }
                    }
                }
                if ($vendorName -eq 'Dell') {
                    foreach ($pat in $patterns) {
                        if (-not [string]::IsNullOrWhiteSpace($pat)) { [void]$dellSeedPatterns.Add([string]$pat) }
                    }
                }
                if ($vendorName -eq 'HP') {
                    foreach ($pat in $patterns) {
                        if (-not [string]::IsNullOrWhiteSpace($pat)) { [void]$hpSeedPatterns.Add([string]$pat) }
                    }
                }
                if (-not $uri -and -not $magnet -and $vendorName -eq 'Acer' -and $acerCatalog) {
                    $acerUrls = @(Get-AppAria2JsonProp -Item $acerCatalog -Name 'urls')
                    if ($acerUrls.Count -gt 0) {
                        $resolved = Resolve-AppAcerSccmDriverUrlForWmiPatterns -Patterns $patterns -Urls $acerUrls
                        if ($resolved) {
                            $uri = [string]$resolved.url
                            $source = 'acer'
                        }
                    }
                }
                if (-not $uri -and -not $magnet -and $vendorName -eq 'LENOVO' -and $lenovoCatalog) {
                    $fallbackPage = Get-AppPxeBootFieldIsoDriverSeedStringProp -Model $model -Name 'lenovoSccmFallbackPage'
                    $resolved = Resolve-AppLenovoSccmDriverUrlForWmiPatterns `
                        -Patterns $patterns `
                        -Catalog $lenovoCatalog `
                        -FallbackPageUrl $fallbackPage
                    if ($resolved) {
                        $uri = [string]$resolved.url
                        $source = [string]$resolved.source
                    }
                }
                if (-not $uri -and -not $magnet -and $vendorName -eq 'Dell' -and $dellCatalog) {
                    $resolved = Resolve-AppDellSccmDriverUrlForWmiPatterns -Patterns $patterns -Catalog $dellCatalog
                    if ($resolved) {
                        $uri = [string]$resolved.url
                        $source = [string]$resolved.source
                    }
                }
                if (-not $uri -and -not $magnet -and $vendorName -eq 'HP' -and $hpCatalog) {
                    $resolved = Resolve-AppHpSccmDriverUrlForWmiPatterns -Patterns $patterns -Catalog $hpCatalog
                    if ($resolved) {
                        $uri = [string]$resolved.url
                        $source = [string]$resolved.source
                    }
                }
                if ($uri) {
                    $expected = Get-AppAria2DriverPackFileNameFromUri -Uri $uri
                }
                [void]$rows.Add(@{
                        kind            = 'driver'
                        vendor          = $vendorName
                        folder          = $folderName
                        expectedArchive = $expected
                        relPath         = "drivers/$vendorName/$folderName"
                        aliases         = @(Get-AppPxeBootFieldIsoDriverSeedArrayProp -Model $model -Name 'wmiPatterns')
                        nsspLabels      = @(Get-AppPxeBootFieldIsoDriverNsspCatalogLabels -Model $model)
                        archiveReady    = if ($indexReady.ContainsKey($key)) { $indexReady[$key] } else { $false }
                        uri             = $uri
                        magnet          = $magnet
                        source          = $source
                        downloadable    = [bool]($uri -or $magnet)
                    })
            }
        }
    }

    if ($acerCatalog) {
        $acerUrls = @(Get-AppAria2JsonProp -Item $acerCatalog -Name 'urls')
        if ($acerUrls.Count -gt 0) {
            $acerSupplementArgs = @{
                Urls       = $acerUrls
                IndexReady = $indexReady
                XmlModels  = @(Get-AppAria2JsonProp -Item $acerCatalog -Name 'models')
            }
            if ($acerSeedFolders.Count -gt 0) { $acerSupplementArgs['SeedFolders'] = @($acerSeedFolders) }
            if ($acerSeedPatterns.Count -gt 0) { $acerSupplementArgs['SeedPatterns'] = @($acerSeedPatterns) }
            $supplement = @(Get-AppAria2AcerCatalogDriverRows @acerSupplementArgs)
            foreach ($row in $supplement) {
                [void]$rows.Add($row)
            }
        }
    }

    if ($lenovoCatalog) {
        $lenovoSupplementArgs = @{
            LenovoCatalog = $lenovoCatalog
            IndexReady    = $indexReady
        }
        if ($lenovoSeedPatterns.Count -gt 0) { $lenovoSupplementArgs['SeedPatterns'] = @($lenovoSeedPatterns) }
        $supplement = @(Get-AppAria2LenovoCatalogDriverRows @lenovoSupplementArgs)
        foreach ($row in $supplement) {
            [void]$rows.Add($row)
        }
    }

    if ($dellCatalog) {
        $dellSupplementArgs = @{
            DellCatalog = $dellCatalog
            IndexReady  = $indexReady
        }
        if ($dellSeedPatterns.Count -gt 0) { $dellSupplementArgs['SeedPatterns'] = @($dellSeedPatterns) }
        $supplement = @(Get-AppAria2DellCatalogDriverRows @dellSupplementArgs)
        foreach ($row in $supplement) {
            [void]$rows.Add($row)
        }
    }

    if ($hpCatalog) {
        $hpSupplementArgs = @{
            HpCatalog  = $hpCatalog
            IndexReady = $indexReady
        }
        if ($hpSeedPatterns.Count -gt 0) { $hpSupplementArgs['SeedPatterns'] = @($hpSeedPatterns) }
        $supplement = @(Get-AppAria2HpCatalogDriverRows @hpSupplementArgs)
        foreach ($row in $supplement) {
            [void]$rows.Add($row)
        }
    }

    if ($microsoftCatalog) {
        $supplement = @(Get-AppAria2MicrosoftCatalogDriverRows -MicrosoftCatalog $microsoftCatalog -IndexReady $indexReady)
        foreach ($row in $supplement) {
            [void]$rows.Add($row)
        }
    }

    $lenovoFamilySummary = $null
    if ($lenovoCatalog -and (Get-Command Get-AppLenovoSccmCatalogFamilySummary -ErrorAction SilentlyContinue)) {
        $lenovoFamilySummary = Get-AppLenovoSccmCatalogFamilySummary -Catalog $lenovoCatalog
    }
    $acerCatalogSummary = $null
    if ($acerCatalog -and (Get-Command Get-AppAcerSccmCatalogSummary -ErrorAction SilentlyContinue)) {
        $acerUrls = @(Get-AppAria2JsonProp -Item $acerCatalog -Name 'urls')
        if ($acerUrls.Count -gt 0) {
            $acerCatalogSummary = Get-AppAcerSccmCatalogSummary -Urls $acerUrls
        }
    }
    $dellCatalogSummary = $null
    if ($dellCatalog -and (Get-Command Get-AppDellSccmCatalogFamilySummary -ErrorAction SilentlyContinue)) {
        $dellCatalogSummary = Get-AppDellSccmCatalogFamilySummary -Catalog $dellCatalog
    }
    $hpCatalogSummary = $null
    if ($hpCatalog -and (Get-Command Get-AppHpSccmCatalogFamilySummary -ErrorAction SilentlyContinue)) {
        $hpCatalogSummary = Get-AppHpSccmCatalogFamilySummary -Catalog $hpCatalog
    }
    $microsoftCatalogSummary = $null
    if ($microsoftCatalog -and (Get-Command Get-AppMicrosoftSccmCatalogFamilySummary -ErrorAction SilentlyContinue)) {
        $microsoftCatalogSummary = Get-AppMicrosoftSccmCatalogFamilySummary -Catalog $microsoftCatalog
    }

    $built = @{
        torrents         = $torrentRows
        oemIsos          = $oemIsoRows
        drivers          = @($rows)
        announceUrl      = $catalogMeta['announceUrl']
        statsUrl         = $catalogMeta['statsUrl']
        siteStatsUrl   = $catalogMeta['siteStatsUrl']
        trackerUrl       = $catalogMeta['trackerUrl']
        generatedAt      = $catalogMeta['generatedAt']
        acerCatalogAt      = if ($acerCatalog) { [string](Get-AppAria2JsonProp -Item $acerCatalog -Name 'fetchedAt') } else { $null }
        acerCatalogStale   = if ($acerCatalog) { [bool](Get-AppAria2JsonProp -Item $acerCatalog -Name 'stale') } else { $false }
        acerCatalogSummary = $acerCatalogSummary
        lenovoCatalogAt    = if ($lenovoCatalog) { [string](Get-AppAria2JsonProp -Item $lenovoCatalog -Name 'fetchedAt') } else { $null }
        lenovoCatalogStale = if ($lenovoCatalog) { [bool](Get-AppAria2JsonProp -Item $lenovoCatalog -Name 'stale') } else { $false }
        lenovoCatalogSummary = $lenovoFamilySummary
        dellCatalogAt      = if ($dellCatalog) { [string](Get-AppAria2JsonProp -Item $dellCatalog -Name 'fetchedAt') } else { $null }
        dellCatalogStale   = if ($dellCatalog) { [bool](Get-AppAria2JsonProp -Item $dellCatalog -Name 'stale') } else { $false }
        dellCatalogSummary = $dellCatalogSummary
        hpCatalogAt        = if ($hpCatalog) { [string](Get-AppAria2JsonProp -Item $hpCatalog -Name 'fetchedAt') } else { $null }
        hpCatalogStale     = if ($hpCatalog) { [bool](Get-AppAria2JsonProp -Item $hpCatalog -Name 'stale') } else { $false }
        hpCatalogOsColumn  = if ($hpCatalog) { [string](Get-AppAria2JsonProp -Item $hpCatalog -Name 'osColumn') } else { $null }
        hpCatalogSummary   = $hpCatalogSummary
        microsoftCatalogAt      = if ($microsoftCatalog) { [string](Get-AppAria2JsonProp -Item $microsoftCatalog -Name 'fetchedAt') } else { $null }
        microsoftCatalogStale   = if ($microsoftCatalog) { [bool](Get-AppAria2JsonProp -Item $microsoftCatalog -Name 'stale') } else { $false }
        microsoftCatalogVersion = if ($microsoftCatalog) { [string](Get-AppAria2JsonProp -Item $microsoftCatalog -Name 'catalogVersion') } else { $null }
        microsoftCatalogSummary = $microsoftCatalogSummary
    }
    $script:AppAria2TrackerPayloadCache = @{ at = $nowUtc; payload = $built }
    $built
}

function Merge-AppAria2JobIntoDownloadRow {
    param(
        [Parameter(Mandatory)]$Row,
        [string]$Gid
    )
    $job = Get-AppAria2JobRecord -Gid $Gid
    if (-not $job) { return $Row }
    $Row.assetKind = [string](Get-AppAria2JsonProp -Item $job -Name 'assetKind')
    $Row.promoteStatus = [string](Get-AppAria2JsonProp -Item $job -Name 'status')
    $pt = Get-AppAria2JsonProp -Item $job -Name 'promoteTarget'
    if ($pt) {
        $display = Get-AppAria2JsonProp -Item $pt -Name 'displayName'
        $folder = Get-AppAria2JsonProp -Item $pt -Name 'folder'
        $Row.promoteLabel = if ($display) { [string]$display } elseif ($folder) { [string]$folder } else { $null }
    }
    $err = Get-AppAria2JsonProp -Item $job -Name 'error'
    if ($err) { $Row.promoteError = [string]$err }
    $rowId = Get-AppAria2JsonProp -Item $job -Name 'catalogRowId'
    if ($rowId) { $Row.catalogRowId = [string]$rowId }
    $Row
}

function Get-AppAria2PluginConfigPayloadExtended {
    $base = Get-AppAria2PluginConfigPayload
    $cfg = Read-AppAria2Config
    $routes = Get-AppAria2NormalizedExtensionRoutes -Cfg $cfg
    $pxeAvailable = $null -ne (Get-Command Get-AppPxeBootLayoutPaths -ErrorAction SilentlyContinue)
    $base.pxeIntegrationEnabled = Test-AppAria2PxeIntegrationEnabled -Cfg $cfg
    $base.pxeStoreAvailable = [bool]$pxeAvailable
    $base.extensionRoutes = @($routes | ForEach-Object {
            @{
                ext           = [string]$_['ext']
                assetKind     = [string]$_['assetKind']
                usePxeStaging = [bool]$_['usePxeStaging']
                dir           = if ($_['dir']) { [string]$_['dir'] } else { $null }
            }
        })
    if ($pxeAvailable) {
        $paths = Get-AppPxeBootLayoutPaths
        $base.pxeStoreRoot = $paths.storeRoot
        $base.pxeStagingRoot = Join-Path $paths.shareDir 'incoming'
    }
    $base
}

function Set-AppAria2PluginConfigExtended {
    param(
        [object]$ExtensionRoutes
    )
    $cfg = Read-AppAria2Config
    if (-not (Get-AppAria2JsonProp -Item $cfg -Name 'pxeIntegration') -or (Get-AppAria2JsonProp -Item $cfg -Name 'pxeIntegration') -isnot [hashtable]) {
        $cfg['pxeIntegration'] = @{}
    }
    $cfg['pxeIntegration']['enabled'] = $true
    if ($null -ne $ExtensionRoutes) {
        $list = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($r in @($ExtensionRoutes)) {
            [void]$list.Add((ConvertTo-AppAria2ExtensionRouteHashtable -Route $r))
        }
        $cfg['extensionRoutes'] = @($list)
    }
    Write-AppAria2Config -Config $cfg
    Get-AppAria2PluginConfigPayloadExtended
}
