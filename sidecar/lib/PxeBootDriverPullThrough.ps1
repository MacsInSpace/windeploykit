# Driver pull-through + alias map (Craig, 2026-08-20).
#
# WinPE imaging clients already announce make/model/serial to the sidecar via the
# imaging-log ingest at Connect. Two features ride on that:
#
#   * Pull-through: the housekeeping tick spots an active imaging client whose model
#     resolves in a vendor catalog but has no pack in the driver store, and starts
#     the verified direct download ONCE per make|model (ledger, no auto-retry). The
#     first device deploys as today (ImageDeployer's own client-side vendor download
#     fallback); every later device of that model cache-hits the store.
#
#   * Alias map: Drivers/aliases.json maps model names / Lenovo machine types /
#     seed wmiPatterns to the pack folder actually on disk - the baked ImageDeployer
#     consults it when its exact-name search misses (Dell packs live under systemId
#     folders that never equal Win32 Model; Lenovo under 4-char machine types).
#     Installed packs only, so the file stays small and every entry is actionable.

$script:AppPxeBootDriverRowsCache = $null
$script:AppPxeBootPullThroughLastSyncUtc = [DateTime]::MinValue
$script:AppPxeBootAliasMapSignature = $null

function Get-AppPxeBootCatalogDriverRowsCached {
    # Tracker driver rows from the CACHED vendor catalogs (no live fetch), memoised
    # for 10 minutes - the payload build walks all five catalogs.
    param([int]$MaxAgeMinutes = 10)
    $now = (Get-Date).ToUniversalTime()
    if ($script:AppPxeBootDriverRowsCache -and ($now - $script:AppPxeBootDriverRowsCache.at).TotalMinutes -lt $MaxAgeMinutes) {
        return @($script:AppPxeBootDriverRowsCache.rows)
    }
    if (-not (Get-Command Get-AppAria2TrackerCatalogPayload -ErrorAction SilentlyContinue)) { return @() }
    try {
        $payload = Get-AppAria2TrackerCatalogPayload
        $rows = @(Get-AppAria2JsonProp -Item $payload -Name 'drivers')
        $script:AppPxeBootDriverRowsCache = @{ at = $now; rows = $rows }
        return $rows
    } catch {
        Write-SidecarLogVerbose "PXE boot: catalog driver rows unavailable - $($_.Exception.Message)"
        return @()
    }
}

function Resolve-AppPxeBootCatalogVendorFromMake {
    # Raw WMI Manufacturer -> the catalog vendor bucket ('Dell Inc.' -> Dell).
    param([string]$Make)
    $m = [string]$Make
    if ($m -match '(?i)dell') { return 'Dell' }
    if ($m -match '(?i)lenovo') { return 'LENOVO' }
    if ($m -match '(?i)hp|hewlett') { return 'HP' }
    if ($m -match '(?i)acer') { return 'Acer' }
    if ($m -match '(?i)microsoft') { return 'Microsoft' }
    return $null
}

function Resolve-AppPxeBootDriverRowForDevice {
    # Match a device's WMI make/model to one catalog row (exact, case-insensitive,
    # against modelName + aliases; Lenovo also tries the 4-char machine type).
    param([string]$Make, [string]$Model)
    $vendor = Resolve-AppPxeBootCatalogVendorFromMake -Make $Make
    $model = ([string]$Model).Trim()
    if (-not $vendor -or [string]::IsNullOrWhiteSpace($model)) { return $null }
    $candidates = @($model)
    if ($vendor -eq 'LENOVO' -and $model.Length -ge 4) { $candidates += $model.Substring(0, 4) }
    foreach ($row in @(Get-AppPxeBootCatalogDriverRowsCached)) {
        if ([string](Get-AppAria2JsonProp -Item $row -Name 'vendor') -ne $vendor) { continue }
        $names = @()
        $mn = [string](Get-AppAria2JsonProp -Item $row -Name 'modelName')
        if ($mn) { $names += $mn }
        $names += @(Get-AppAria2JsonProp -Item $row -Name 'aliases' | ForEach-Object { [string]$_ } | Where-Object { $_ })
        foreach ($cand in $candidates) {
            foreach ($n in $names) {
                if ($n -ieq $cand) { return $row }
            }
        }
    }
    return $null
}

function Get-AppPxeBootPullThroughLedgerPath {
    Join-Path (Get-AppAria2StoreRoot) 'driver-pull-through.json'
}

function Sync-AppPxeBootDriverPullThrough {
    <#
    .SYNOPSIS
        Housekeeping tick (30s throttle): for each imaging client active in the last
        10 minutes, fetch its catalog driver pack ONCE if the store lacks it. Every
        outcome is recorded in the ledger so a make|model is never retried
        automatically - a tech re-downloads from the Drivers tab if needed.
    #>
    $now = (Get-Date).ToUniversalTime()
    if (($now - $script:AppPxeBootPullThroughLastSyncUtc).TotalSeconds -lt 30) { return }
    $script:AppPxeBootPullThroughLastSyncUtc = $now
    if (-not (Get-Command Get-AppPxeBootImagingClients -ErrorAction SilentlyContinue)) { return }
    $clients = @(Get-AppPxeBootImagingClients | Where-Object {
            [int]$_.ageSeconds -le 600 -and $_.make -and $_.model
        })
    if ($clients.Count -eq 0) { return }

    $ledgerPath = Get-AppPxeBootPullThroughLedgerPath
    $ledger = @{}
    if (Test-Path -LiteralPath $ledgerPath) {
        try {
            $raw = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in @($raw.PSObject.Properties)) { $ledger[[string]$p.Name] = $p.Value }
        } catch { $ledger = @{} }
    }

    $changed = $false
    foreach ($client in $clients) {
        $lkey = ("$($client.make)|$($client.model)").ToLowerInvariant()
        if ($ledger.ContainsKey($lkey)) { continue }
        $entry = @{
            at    = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
            make  = [string]$client.make
            model = [string]$client.model
        }
        $row = Resolve-AppPxeBootDriverRowForDevice -Make $client.make -Model $client.model
        if (-not $row) {
            $entry.result = 'no-catalog-match'
        } else {
            $vendor = [string](Get-AppAria2JsonProp -Item $row -Name 'vendor')
            $folder = [string](Get-AppAria2JsonProp -Item $row -Name 'folder')
            $uri = [string](Get-AppAria2JsonProp -Item $row -Name 'uri')
            $entry.vendor = $vendor
            $entry.folder = $folder
            $modelDir = Join-Path (Join-Path (Get-AppPxeBootFieldIsoDriversOsRoot) $vendor) $folder
            $havePack = (Test-Path -LiteralPath $modelDir) -and (Get-AppPxeBootFieldIsoDriverPackInFolder -FolderPath $modelDir)
            if ($havePack) {
                $entry.result = 'already-present'
            } elseif ([string]::IsNullOrWhiteSpace($uri) -or -not [bool](Get-AppAria2JsonProp -Item $row -Name 'downloadable')) {
                $entry.result = 'no-download-source'
            } else {
                try {
                    # Same key the Drivers tab uses, so the row lights up live there.
                    $null = Add-AppAria2DirectHttpDownload `
                        -Uris @($uri) `
                        -AssetKind 'driver' `
                        -ModelAlias ([string]$client.model) `
                        -Vendor $vendor `
                        -Folder $folder `
                        -FileNameHint ([string](Get-AppAria2JsonProp -Item $row -Name 'expectedArchive')) `
                        -ProgressKey "$vendor|$folder" `
                        -ExpectedHash ([string](Get-AppAria2JsonProp -Item $row -Name 'expectedHash')) `
                        -ExpectedHashAlgorithm ([string](Get-AppAria2JsonProp -Item $row -Name 'expectedHashAlgorithm'))
                    $entry.result = 'download-started'
                } catch {
                    $entry.result = "download-failed: $($_.Exception.Message)"
                }
            }
        }
        $ledger[$lkey] = $entry
        $changed = $true
        Write-SidecarLog "PXE boot: driver pull-through $($entry.result) for $($client.make) $($client.model) (announced by $($client.serial))"
    }
    if ($changed) {
        ($ledger | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ledgerPath -Encoding UTF8
    }
}

function Write-AppPxeBootDriverAliasMap {
    <#
    .SYNOPSIS
        Publish Drivers/aliases.json for the baked ImageDeployer: aliases (model
        names, Lenovo machine types, seed wmiPatterns - wildcards allowed) -> the
        vendor/folder of a pack ACTUALLY on disk. Regenerated only when the set of
        installed pack folders changes, so the store-sync poll stays cheap.
    #>
    $root = Get-AppPxeBootFieldIsoDriversOsRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return }
    $installed = [System.Collections.Generic.List[string]]::new()
    foreach ($vendorDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($modelDir in @(Get-ChildItem -LiteralPath $vendorDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            if (Get-AppPxeBootFieldIsoDriverPackInFolder -FolderPath $modelDir.FullName) {
                [void]$installed.Add("$($vendorDir.Name)|$($modelDir.Name)")
            }
        }
    }
    $mapPath = Join-Path $root 'aliases.json'
    $sig = (@($installed) | Sort-Object) -join ';'
    if ($sig -eq $script:AppPxeBootAliasMapSignature -and (Test-Path -LiteralPath $mapPath)) { return }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Catalog rows give installed packs their model-name/machine-type aliases.
    foreach ($row in @(Get-AppPxeBootCatalogDriverRowsCached)) {
        $vendor = [string](Get-AppAria2JsonProp -Item $row -Name 'vendor')
        $folder = [string](Get-AppAria2JsonProp -Item $row -Name 'folder')
        if (-not $vendor -or -not $folder) { continue }
        if (-not $installed.Contains("$vendor|$folder")) { continue }
        if (-not $seen.Add("$vendor|$folder")) { continue }
        $aliases = [System.Collections.Generic.List[string]]::new()
        $mn = [string](Get-AppAria2JsonProp -Item $row -Name 'modelName')
        if ($mn) { [void]$aliases.Add($mn) }
        foreach ($a in @(Get-AppAria2JsonProp -Item $row -Name 'aliases' | ForEach-Object { [string]$_ } | Where-Object { $_ })) {
            if ($aliases -notcontains $a) { [void]$aliases.Add($a) }
        }
        if ($aliases.Count -eq 0) { continue }
        [void]$entries.Add(@{ vendor = $vendor; folder = $folder; aliases = @($aliases) })
    }
    # Seed wmiPatterns (wildcards) for the pre-seeded vendor tree.
    if (Get-Command Read-AppPxeBootFieldIsoDriversSeed -ErrorAction SilentlyContinue) {
        try {
            $seed = Read-AppPxeBootFieldIsoDriversSeed
            if ($seed -and $seed.vendors) {
                foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
                    $vendorName = [string]$vendorProp.Name
                    foreach ($model in @($vendorProp.Value.models)) {
                        $folder = [string](Get-AppAria2JsonProp -Item $model -Name 'folder')
                        if (-not $folder) { continue }
                        if (-not $installed.Contains("$vendorName|$folder")) { continue }
                        if (-not $seen.Add("$vendorName|$folder")) { continue }
                        $patterns = @(Get-AppAria2JsonProp -Item $model -Name 'wmiPatterns' | ForEach-Object { [string]$_ } | Where-Object { $_ })
                        if ($patterns.Count -eq 0) { continue }
                        [void]$entries.Add(@{ vendor = $vendorName; folder = $folder; aliases = @($patterns) })
                    }
                }
            }
        } catch { }
    }

    $doc = [ordered]@{
        schema    = 1
        generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        entries   = @($entries)
    }
    ($doc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $mapPath -Encoding UTF8 -Force
    $script:AppPxeBootAliasMapSignature = $sig
    Write-SidecarLog "PXE boot: driver alias map published ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }))"
}
