# Tools registry - every third-party executable the product uses, where it comes from,
# how it is installed, and how the user updates or rolls it back.
#
# Rules (Craig, 2026-08-29):
#   - Each tool comes from ITS OWN PROJECT (GitHub releases, 7-zip.org) or is built from
#     upstream source and bundled inside the app. No package manager is ever probed;
#     Homebrew is treated as not installed on every Mac.
#   - Runtime installs stay as they are: Ensure-* installs the PINNED version silently when
#     a plug-in is enabled or a service starts. Only the Tools panel / setup wizard obtain a
#     NEWER release, and only on a click. Updates are never automatic.
#   - Two version concepts: the pin in packaging/*.json (the known-good default for a fresh
#     install) and what the user actually installed (tools-state.json). A user update must
#     not be reinstalled over by the next Ensure - Get-AppToolExpectedVersion is what the
#     Ensure-*/Test-*Installed pinned-version checks compare against.
#   - The previous binary is kept (tools/<id>/<version>/) so "Use previous" is one copy,
#     not a re-download - the network may not be there on site.
#
# Product-neutral: the registry names the resolver / ensure functions the products share
# (Caddy, Tftpd64, aria2, 7-Zip from the netboot and downloads libs); a product adds rows
# through $script:AppToolsRegistryExtra before Get-AppToolsRegistry is first called.

$script:AppToolsStateFileName = 'tools-state.json'
$script:AppToolsUpdateCheckFileName = 'update-check.json'
$script:AppToolsUpdateCheckMaxAgeHours = 24
$script:AppToolsGitHubApiBase = 'https://api.github.com'
if (-not (Get-Variable -Name AppToolsRegistryExtra -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AppToolsRegistryExtra = @()
}

# --- platform ---------------------------------------------------------------------------

function Test-AppToolsIsWindows { return [bool]($IsWindows -or ($env:OS -eq 'Windows_NT')) }
function Test-AppToolsIsMacOS { return [bool]($IsMacOS -or ((Get-Variable -Name IsDarwin -Scope Global -ErrorAction SilentlyContinue) -and $IsDarwin)) }

function Get-AppToolsPlatformName {
    if (Test-AppToolsIsWindows) { return 'windows' }
    if (Test-AppToolsIsMacOS) { return 'macos' }
    return 'linux'
}

function Get-AppToolsPlatformKey {
    $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
    $arch = if ($isArm) { 'arm64' } else { 'amd64' }
    return "$(Get-AppToolsPlatformName)_$arch"
}

function Get-AppToolsDir {
    $dir = Join-Path (Get-AppDataRoot) 'tools'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    return $dir
}

function Get-AppToolVersionsDir {
    param([Parameter(Mandatory)][string]$Id)
    $dir = Join-Path (Get-AppToolsDir) $Id
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    return $dir
}

# --- registry ---------------------------------------------------------------------------

function Get-AppToolsRegistry {
    <#
    .SYNOPSIS
        The tool table. Scriptblocks are evaluated lazily and guarded (a product without the
        function reads as "missing"), so the same table serves both products.
        kind: github  - upstream release archive from GitHub; updatable from the panel
              manifest - pinned archive from the tool's own site (no release API); ensure only
              bundled  - built from upstream source and shipped inside the app; updates with it
              prereq   - not ours to install; version shown, newer upstream reported
    #>
    $isWin = Test-AppToolsIsWindows
    $rows = [System.Collections.Generic.List[object]]::new()

    [void]$rows.Add(@{
        id = 'caddy'; label = 'Caddy (HTTP server)'; kind = 'github'; platforms = @('windows', 'macos')
        optional = $false; offline = $true; source = 'github.com/caddyserver/caddy'; repo = 'caddyserver/caddy'
        assetPattern = @{
            macos_arm64   = '^caddy_[\d.]+_mac_arm64\.tar\.gz$'
            macos_amd64   = '^caddy_[\d.]+_mac_amd64\.tar\.gz$'
            windows_amd64 = '^caddy_[\d.]+_windows_amd64\.zip$'
            windows_arm64 = '^caddy_[\d.]+_windows_arm64\.zip$'
        }
        binaryName = $(if ($isWin) { 'caddy.exe' } else { 'caddy' })
        pinned  = { $script:AppPxeBootCaddyVersion }
        resolve = { Get-AppPxeBootCaddyPath }
        live    = { Join-Path (Get-AppPxeBootLayoutPaths).caddyBinaryDir (Get-AppPxeBootCaddyBinaryFileName) }
        marker  = { Get-AppPxeBootCaddyMarkerPath }
        ensure  = { Ensure-AppPxeBootCaddy }
    })

    [void]$rows.Add(@{
        id = 'tftpd64'; label = 'Tftpd64 (TFTP server)'; kind = 'github'; platforms = @('windows')
        optional = $false; offline = $true; source = 'github.com/PJO2/tftpd64'; repo = 'PJO2/tftpd64'
        assetPattern = @{
            windows_amd64 = '^tftpd64_portable_v[\d.]+\.zip$'
            windows_arm64 = '^tftpd64_portable_v[\d.]+\.zip$'
        }
        binaryName = 'tftpd64.exe'
        pinned  = { $script:AppPxeBootTftpd64Version }
        resolve = { Get-AppPxeBootTftpd64Path }
        live    = { Join-Path (Get-AppPxeBootLayoutPaths).tftpd64BinaryDir (Get-AppPxeBootTftpd64BinaryFileName) }
        marker  = { Get-AppPxeBootTftpd64MarkerPath }
        ensure  = { Ensure-AppPxeBootTftpd64 }
    })

    [void]$rows.Add(@{
        id = 'dnsmasq'; label = 'dnsmasq (TFTP / ProxyDHCP)'; kind = 'bundled'; platforms = @('macos')
        optional = $false; offline = $true; source = 'thekelleys.org.uk/dnsmasq - built from source, bundled'
        resolve = { Get-AppPxeBootBundledDnsmasqPath }
        installedVersion = { Get-AppToolVersionFromCommand -Path (Get-AppPxeBootBundledDnsmasqPath) }
        note = 'Ships inside the app; updates with it.'
    })

    [void]$rows.Add(@{
        id = 'wimlib'; label = 'wimlib-imagex (WIM tools)'; kind = 'bundled'; platforms = @('windows', 'macos')
        optional = $false; offline = $true; source = 'wimlib.net - bundled'
        resolve = { Get-AppPxeBootBundledWimlibImagexPath }
        installedVersion = { Get-AppToolVersionFromCommand -Path (Get-AppPxeBootBundledWimlibImagexPath) }
        note = 'Ships inside the app; updates with it.'
    })

    # aria2: Windows from the upstream release archives; macOS either the build this
    # product ships (WinDeployKit: Get-AppAria2BundledBinaryPath) or, when the product
    # publishes an asset feed (USM: gitlab.edustar.tech), the archive from that feed.
    $aria2Bundled = $false
    if (Test-AppSidecarCommand Get-AppAria2BundledBinaryPath) {
        try { $aria2Bundled = [bool](Get-AppAria2BundledBinaryPath) } catch { $aria2Bundled = $false }
    }
    if ($aria2Bundled) {
        [void]$rows.Add(@{
            id = 'aria2'; label = 'aria2 (downloads)'; kind = 'bundled'; platforms = @('macos')
            optional = $false; offline = $false; source = 'aria2/aria2 source - built by us, bundled'
            resolve = { Get-AppAria2BundledBinaryPath }
            installedVersion = { Get-AppToolVersionFromCommand -Path (Get-AppAria2BundledBinaryPath) }
            note = 'aria2 publishes no macOS binary; the app carries its own build. Updates with the app.'
        })
    } elseif ($isWin) {
        [void]$rows.Add(@{
            id = 'aria2'; label = 'aria2 (downloads)'; kind = 'github'; platforms = @('windows')
            optional = $false; offline = $false; source = 'github.com/aria2/aria2 (arm64: minnyres/aria2-windows-arm64)'
            repo = 'aria2/aria2'
            repoByPlatform = @{ windows_arm64 = 'minnyres/aria2-windows-arm64' }
            assetPattern = @{
                windows_amd64 = '^aria2-[\d.]+-win-64bit-build\d+\.zip$'
                windows_arm64 = '^aria2_[\d.]+_arm64\.zip$'
            }
            binaryName = 'aria2c.exe'
            pinned  = { $script:AppAria2PinnedVersion }
            resolve = { Get-AppAria2BinaryPath }
            live    = { Join-Path (Get-AppAria2LayoutPaths).binaryDir (Get-AppAria2BinaryFileName) }
            marker  = { Get-AppAria2MarkerPath }
            ensure  = { Ensure-AppAria2Binary }
        })
    } else {
        [void]$rows.Add(@{
            id = 'aria2'; label = 'aria2 (downloads)'; kind = 'manifest'; platforms = @('macos')
            optional = $false; offline = $false; source = "$(Get-AppToolsProductFeedLabel) - our build from aria2 source"
            binaryName = 'aria2c'
            pinned  = { $script:AppAria2PinnedVersion }
            resolve = { Get-AppAria2BinaryPath }
            live    = { Join-Path (Get-AppAria2LayoutPaths).binaryDir (Get-AppAria2BinaryFileName) }
            marker  = { Get-AppAria2MarkerPath }
            ensure  = { Ensure-AppAria2Binary }
            note = 'aria2 publishes no macOS binary; the archive on the product feed is our own build from source (no Homebrew). The pin is bumped with the app.'
        })
    }

    # 7-Zip on macOS: upstream 7zz in both products. WinDeployKit fetches it from 7-zip.org
    # on demand (Ensure- has a -Download switch); USM installs the pinned archive from its
    # product feed with 7-zip.org as the fallback.
    $sevenEnsure = {
        $cmd = Get-Command Ensure-AppPxeBootP7zipTools -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Parameters.ContainsKey('Download')) { Ensure-AppPxeBootP7zipTools -Download } else { Ensure-AppPxeBootP7zipTools }
    }
    $sevenSource = if (Get-AppToolsProductFeedLabel -Quiet) { "$(Get-AppToolsProductFeedLabel), 7-zip.org fallback" } else { '7-zip.org' }
    [void]$rows.Add(@{
        id = 'sevenzip'; label = '7-Zip (7zz)'; kind = 'manifest'; platforms = @('macos')
        optional = $true; offline = $false; source = $sevenSource
        binaryName = '7zz'
        pinned  = { $script:AppPxeBootP7zipPinnedVersion }
        resolve = { Get-AppPxeBootHost7zPath }
        # 7zz prints its banner with no arguments: "7-Zip (z) 25.01 (arm64) : Copyright ..."
        installedVersion = { Get-AppToolVersionFromCommand -Path (Get-AppPxeBootHost7zPath) -ArgumentList @() -Pattern '7-Zip[^\d]*(\d+\.\d+)' }
        ensure  = $sevenEnsure
        note = 'Optional: speeds up driver-pack and cab work. ISOs are read by mounting them. No release feed to check - the pin is bumped with the app.'
    })

    [void]$rows.Add(@{
        id = 'powershell'; label = 'PowerShell 7 (prerequisite)'; kind = 'prereq'; platforms = @('windows', 'macos', 'linux')
        optional = $false; offline = $true; source = 'github.com/PowerShell/PowerShell'; repo = 'PowerShell/PowerShell'
        resolve = { (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path }
        installedVersion = { [string]$PSVersionTable.PSVersion }
        note = 'Installed by the technician; the app cannot replace the runtime it is running in. A newer release is reported, not installed.'
    })

    foreach ($extra in @($script:AppToolsRegistryExtra)) { if ($extra) { [void]$rows.Add($extra) } }

    $platform = Get-AppToolsPlatformName
    return @($rows.ToArray() | Where-Object { $platform -in @($_['platforms']) })
}

function Get-AppToolsProductFeedLabel {
    # 'gitlab.edustar.tech' when this product publishes an asset feed (USM), else $null
    # (-Quiet) or 'the product asset feed' - the wording the source column shows.
    param([switch]$Quiet)
    $base = ''
    if (Test-AppSidecarCommand Get-AppProductAssetFeedBaseUrl) {
        try { $base = [string](Get-AppProductAssetFeedBaseUrl) } catch { $base = '' }
    }
    if ([string]::IsNullOrWhiteSpace($base)) { return $(if ($Quiet) { $null } else { 'the product asset feed' }) }
    try { return ([uri]$base).Host } catch { return 'the product asset feed' }
}

function Get-AppToolSpec {
    param([Parameter(Mandatory)][string]$Id)
    $spec = @(Get-AppToolsRegistry | Where-Object { $_['id'] -eq $Id }) | Select-Object -First 1
    if (-not $spec) { throw "Tools: unknown tool '$Id' on this platform." }
    return $spec
}

function Invoke-AppToolScript {
    # Guarded evaluation of a registry scriptblock: a product without the function, a store
    # that is not initialised yet, or a resolver that throws all read as $null.
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Name)
    if (-not $Spec.Contains($Name) -or $null -eq $Spec[$Name]) { return $null }
    try { return (& $Spec[$Name]) } catch { return $null }
}

function Get-AppToolPathQuiet {
    param([Parameter(Mandatory)]$Spec)
    $v = Invoke-AppToolScript -Spec $Spec -Name 'resolve'
    if ($null -eq $v) { return $null }
    $s = [string]$v
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { return $null }
    return $s
}

# --- state ------------------------------------------------------------------------------

function ConvertTo-AppToolIsoText {
    # ConvertFrom-Json -AsHashtable turns ISO-8601 strings back into [datetime]; a bare
    # [string] cast of that is culture-formatted ("08/29/2026 01:33"). Always hand out ISO.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Get-AppToolsStatePath { Join-Path (Get-AppToolsDir) $script:AppToolsStateFileName }

function Read-AppToolsState {
    $path = Get-AppToolsStatePath
    $empty = @{ tools = @{} }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if (-not ($obj -is [System.Collections.IDictionary])) { return $empty }
        if (-not $obj.Contains('tools') -or -not ($obj['tools'] -is [System.Collections.IDictionary])) { $obj['tools'] = @{} }
        return $obj
    } catch {
        Write-SidecarLog "Tools: state file unreadable, starting fresh - $($_.Exception.Message)"
        return $empty
    }
}

function Save-AppToolsState {
    param([Parameter(Mandatory)]$State)
    $path = Get-AppToolsStatePath
    # -Depth explicit: nested per-tool records must survive (APP_DATA_LAYOUT section 10).
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

function Get-AppToolStateEntry {
    param([Parameter(Mandatory)][string]$Id)
    $state = Read-AppToolsState
    if ($state['tools'].Contains($Id)) { return $state['tools'][$Id] }
    return $null
}

function Get-AppToolExpectedVersion {
    <#
    .SYNOPSIS
        The version the Ensure-*/Test-*Installed pinned checks should expect: what the user
        installed through the Tools panel when they did, else the product's pin. Without this
        a user update is "wrong version" to the next Ensure and gets reinstalled over.
    #>
    param([Parameter(Mandatory)][string]$Id, [AllowNull()][string]$Default)
    try {
        $entry = Get-AppToolStateEntry -Id $Id
        if ($entry -and $entry.Contains('installedVersion') -and -not [string]::IsNullOrWhiteSpace([string]$entry['installedVersion'])) {
            return [string]$entry['installedVersion']
        }
    } catch { }
    return $Default
}

function Get-AppToolVersionFromCommand {
    <#
    .SYNOPSIS
        Run a binary with a version flag and pull the first dotted number out of its first
        lines - how bundled tools (no marker, no state) report what they are. Guarded: a
        missing path or a tool that will not answer reads as $null, never a throw.
    #>
    param([AllowNull()][string]$Path, [string[]]$ArgumentList = @('--version'), [string]$Pattern = '(\d+(?:\.\d+)+)')
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $out = @(& $Path @ArgumentList 2>&1 | Select-Object -First 4 | ForEach-Object { [string]$_ }) -join ' '
        if ($out -match $Pattern) { return $Matches[1] }
    } catch { }
    return $null
}

function Get-AppToolInstalledVersion {
    param([Parameter(Mandatory)]$Spec)
    $fromSpec = Invoke-AppToolScript -Spec $Spec -Name 'installedVersion'
    if ($fromSpec) { return [string]$fromSpec }
    $marker = Invoke-AppToolScript -Spec $Spec -Name 'marker'
    if ($marker -and (Test-Path -LiteralPath ([string]$marker) -PathType Leaf)) {
        $v = [string](Get-Content -LiteralPath ([string]$marker) -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    $entry = Get-AppToolStateEntry -Id ([string]$Spec['id'])
    if ($entry -and $entry.Contains('installedVersion') -and $entry['installedVersion']) { return [string]$entry['installedVersion'] }
    # No marker, no state, no answer from the binary: a plug-in installed it at the pin
    # (bundled tools ship at the pin by definition), so the pin is the honest answer.
    $pinned = Invoke-AppToolScript -Spec $Spec -Name 'pinned'
    if ($pinned) { return [string]$pinned }
    return $null
}

# --- versions and GitHub -----------------------------------------------------------------

function ConvertTo-AppToolVersionText {
    # 'v2.11.4' / 'release-1.37.0' / 'openssl-3.5.4' -> '2.11.4' / '1.37.0' / '3.5.4'
    param([AllowNull()][string]$Tag)
    if ([string]::IsNullOrWhiteSpace($Tag)) { return $null }
    $t = $Tag.Trim()
    $t = $t -replace '^(release-|openssl-|v)', ''
    return $t
}

function Compare-AppToolVersion {
    # -1 when A < B, 0 equal, 1 when A > B. Numeric dotted versions compare as [version];
    # anything else falls back to an ordinal string compare so nothing throws.
    param([AllowNull()][string]$A, [AllowNull()][string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -and [string]::IsNullOrWhiteSpace($B)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($A)) { return -1 }
    if ([string]::IsNullOrWhiteSpace($B)) { return 1 }
    $va = $null; $vb = $null
    $pa = ($A -replace '[^\d.].*$', '').Trim('.')
    $pb = ($B -replace '[^\d.].*$', '').Trim('.')
    if ($pa -match '^\d+(\.\d+)+$' -and $pb -match '^\d+(\.\d+)+$') {
        try { $va = [version]$pa; $vb = [version]$pb } catch { $va = $null; $vb = $null }
    } elseif ($pa -match '^\d+$' -and $pb -match '^\d+$') {
        try { $va = [version]"$pa.0"; $vb = [version]"$pb.0" } catch { $va = $null; $vb = $null }
    }
    if ($va -and $vb) {
        if ($va -lt $vb) { return -1 }
        if ($va -gt $vb) { return 1 }
        return 0
    }
    return [Math]::Sign([string]::CompareOrdinal($A, $B))
}

function Get-AppToolRepoForPlatform {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PlatformKey)
    if ($Spec.Contains('repoByPlatform') -and $Spec['repoByPlatform'] -and $Spec['repoByPlatform'].Contains($PlatformKey)) {
        return [string]$Spec['repoByPlatform'][$PlatformKey]
    }
    if ($Spec.Contains('repo')) { return [string]$Spec['repo'] }
    return $null
}

function Get-AppToolLatestRelease {
    <#
    .SYNOPSIS
        GitHub's latest release for a repo: tag, normalised version, published date, assets
        (name, url, size, sha256 digest when GitHub supplies one). Unauthenticated - 60
        calls an hour per address, far above one check a day.
    #>
    param([Parameter(Mandatory)][string]$Repo, [int]$TimeoutSeconds = 15)
    $uri = "$($script:AppToolsGitHubApiBase)/repos/$Repo/releases/latest"
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $ua = if (Test-AppSidecarCommand Get-AppUserAgent) { Get-AppUserAgent } else { 'tools-registry' }
    $r = Invoke-RestMethod -Uri $uri -Headers $headers -UserAgent $ua -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    $tag = [string](Get-AppToolProp -Item $r -Name 'tag_name')
    $assets = @()
    foreach ($a in @(Get-AppToolProp -Item $r -Name 'assets')) {
        if ($null -eq $a) { continue }
        $digest = [string](Get-AppToolProp -Item $a -Name 'digest')
        $assets += , @{
            name   = [string](Get-AppToolProp -Item $a -Name 'name')
            url    = [string](Get-AppToolProp -Item $a -Name 'browser_download_url')
            size   = [long](Get-AppToolProp -Item $a -Name 'size' -Default 0)
            sha256 = if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLowerInvariant() } else { '' }
        }
    }
    return @{
        repo        = $Repo
        tag         = $tag
        version     = (ConvertTo-AppToolVersionText -Tag $tag)
        publishedAt = [string](Get-AppToolProp -Item $r -Name 'published_at')
        htmlUrl     = [string](Get-AppToolProp -Item $r -Name 'html_url')
        assets      = @($assets)
    }
}

function Get-AppToolProp {
    # StrictMode-safe property read on JSON objects and hashtables.
    param($Item, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Item) { return $Default }
    if ($Item -is [System.Collections.IDictionary]) { if ($Item.Contains($Name)) { return $Item[$Name] } return $Default }
    $p = $Item.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Select-AppToolAsset {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$PlatformKey)
    if (-not $Spec.Contains('assetPattern') -or -not $Spec['assetPattern'].Contains($PlatformKey)) { return $null }
    $pattern = [string]$Spec['assetPattern'][$PlatformKey]
    foreach ($a in @($Release['assets'])) {
        if ([string]$a['name'] -match $pattern) { return $a }
    }
    return $null
}

# --- update check -------------------------------------------------------------------------

function Get-AppToolsUpdateCheckPath { Join-Path (Get-AppToolsDir) $script:AppToolsUpdateCheckFileName }

function Read-AppToolsUpdateCheck {
    $path = Get-AppToolsUpdateCheckPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $obj = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -is [System.Collections.IDictionary] -and $obj.Contains('tools')) { return $obj }
    } catch { }
    return $null
}

function Test-AppToolsUpdateCheckFresh {
    param($Check)
    if (-not $Check -or -not $Check.Contains('checkedAt')) { return $false }
    try {
        $raw = $Check['checkedAt']
        $at = if ($raw -is [DateTime]) { $raw.ToUniversalTime() } else { [DateTime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) }
        return (([DateTime]::UtcNow - $at).TotalHours -lt $script:AppToolsUpdateCheckMaxAgeHours)
    } catch { return $false }
}

function Invoke-AppToolsUpdateCheck {
    <#
    .SYNOPSIS
        Ask each GitHub-sourced tool's project for its latest release and compare with what
        is installed (or the pin when nothing is). Cached for a day; -Force re-asks. Never
        downloads anything.
    #>
    param([switch]$Force, [int]$TimeoutSeconds = 15)
    $cached = Read-AppToolsUpdateCheck
    if (-not $Force -and (Test-AppToolsUpdateCheckFresh -Check $cached)) { return $cached }

    $platformKey = Get-AppToolsPlatformKey
    $now = [DateTime]::UtcNow.ToString('o')
    $result = [ordered]@{ checkedAt = $now; platformKey = $platformKey; tools = [ordered]@{} }
    foreach ($spec in @(Get-AppToolsRegistry)) {
        if ($spec['kind'] -notin @('github', 'prereq')) { continue }
        $repo = Get-AppToolRepoForPlatform -Spec $spec -PlatformKey $platformKey
        if (-not $repo) { continue }
        $entry = [ordered]@{
            repo = $repo; latestVersion = $null; latestTag = $null; publishedAt = $null; htmlUrl = $null
            assetName = $null; assetUrl = $null; assetSize = 0; assetSha256 = ''
            installedVersion = $null; updateAvailable = $false; error = $null
        }
        try {
            $rel = Get-AppToolLatestRelease -Repo $repo -TimeoutSeconds $TimeoutSeconds
            $entry['latestVersion'] = $rel['version']
            $entry['latestTag'] = $rel['tag']
            $entry['publishedAt'] = (ConvertTo-AppToolIsoText -Value $rel['publishedAt'])
            $entry['htmlUrl'] = $rel['htmlUrl']
            if ($spec['kind'] -eq 'github') {
                $asset = Select-AppToolAsset -Spec $spec -Release $rel -PlatformKey $platformKey
                if ($asset) {
                    $entry['assetName'] = $asset['name']; $entry['assetUrl'] = $asset['url']
                    $entry['assetSize'] = $asset['size']; $entry['assetSha256'] = $asset['sha256']
                } else {
                    $entry['error'] = "no release asset matches this platform ($platformKey)"
                }
            }
            $installed = Get-AppToolInstalledVersion -Spec $spec
            if (-not $installed) { $installed = Invoke-AppToolScript -Spec $spec -Name 'pinned' }
            $entry['installedVersion'] = $installed
            $entry['updateAvailable'] = ((Compare-AppToolVersion -A $installed -B $rel['version']) -lt 0) -and (-not $entry['error'] -or $spec['kind'] -eq 'prereq')
        } catch {
            $entry['error'] = $_.Exception.Message
            Write-SidecarLog "Tools: update check for $($spec['id']) failed - $($_.Exception.Message)"
        }
        $result['tools'][[string]$spec['id']] = $entry
    }
    try { $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-AppToolsUpdateCheckPath) -Encoding UTF8 -Force } catch { }
    return $result
}

# --- status -------------------------------------------------------------------------------

function Get-AppToolsStatus {
    $check = Read-AppToolsUpdateCheck
    $state = Read-AppToolsState
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in @(Get-AppToolsRegistry)) {
        $id = [string]$spec['id']
        $path = Get-AppToolPathQuiet -Spec $spec
        $present = -not [string]::IsNullOrWhiteSpace($path)
        $installedVersion = if ($present) { Get-AppToolInstalledVersion -Spec $spec } else { $null }
        $pinned = Invoke-AppToolScript -Spec $spec -Name 'pinned'
        $upd = if ($check -and $check['tools'].Contains($id)) { $check['tools'][$id] } else { $null }
        $stateEntry = if ($state['tools'].Contains($id)) { $state['tools'][$id] } else { $null }
        $kind = [string]$spec['kind']
        $downloadable = ($kind -in @('github', 'manifest')) -and $spec.Contains('ensure')
        $updatable = ($kind -eq 'github') -and $spec.Contains('live') -and $spec.Contains('assetPattern')
        $latest = if ($upd) { [string]$upd['latestVersion'] } else { $null }
        $updateAvailable = $false
        if ($upd -and $latest) {
            $base = if ($installedVersion) { $installedVersion } elseif ($present) { $pinned } else { $null }
            if ($base) { $updateAvailable = ((Compare-AppToolVersion -A $base -B $latest) -lt 0) }
        }
        [void]$rows.Add([ordered]@{
            id               = $id
            label            = [string]$spec['label']
            kind             = $kind
            present          = $present
            path             = if ($present) { $path } else { $null }
            version          = if ($installedVersion) { $installedVersion } else { $null }
            pinnedVersion    = if ($pinned) { [string]$pinned } else { $null }
            latestVersion    = $latest
            latestUrl        = if ($upd) { [string]$upd['htmlUrl'] } else { $null }
            updateAvailable  = [bool]$updateAvailable
            updateCheckError = if ($upd -and $upd['error']) { [string]$upd['error'] } else { $null }
            previousVersion  = if ($stateEntry -and $stateEntry.Contains('previousVersion') -and $stateEntry['previousVersion']) { [string]$stateEntry['previousVersion'] } else { $null }
            installedAt      = if ($stateEntry -and $stateEntry.Contains('installedAt')) { ConvertTo-AppToolIsoText -Value $stateEntry['installedAt'] } else { $null }
            source           = [string]$spec['source']
            optional         = [bool]$spec['optional']
            offline          = [bool]$spec['offline']
            bundled          = ($kind -eq 'bundled')
            downloadable     = [bool]$downloadable
            updatable        = [bool]$updatable
            note             = if ($spec.Contains('note') -and $spec['note']) { [string]$spec['note'] } else { $null }
        })
    }
    $missingRequired = @($rows | Where-Object { -not $_['present'] -and -not $_['optional'] -and $_['kind'] -ne 'prereq' }).Count
    $updates = @($rows | Where-Object { $_['updateAvailable'] -and $_['updatable'] }).Count
    return [ordered]@{
        platform         = (Get-AppToolsPlatformName)
        platformKey      = (Get-AppToolsPlatformKey)
        rows             = @($rows.ToArray())
        missingRequired  = $missingRequired
        updatesAvailable = $updates
        updateCheckedAt  = if ($check) { ConvertTo-AppToolIsoText -Value $check['checkedAt'] } else { $null }
    }
}

# --- download / install / rollback --------------------------------------------------------

function Invoke-AppToolDownload {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile, [int]$TimeoutSeconds = 600)
    $ua = if (Test-AppSidecarCommand Get-AppUserAgent) { Get-AppUserAgent } else { 'tools-registry' }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -UserAgent $ua -MaximumRedirection 5 -TimeoutSec $TimeoutSeconds -ErrorAction Stop
}

function Get-AppToolFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Expand-AppToolArchive {
    <#
    .SYNOPSIS
        Extract one release asset and return the path of the wanted binary inside it.
        zip -> Expand-Archive; tar.gz / tgz / tar.xz -> tar; anything else is the binary itself.
    #>
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$ExtractDir, [Parameter(Mandatory)][string]$BinaryName)
    if (-not (Test-Path -LiteralPath $ExtractDir)) { $null = New-Item -Path $ExtractDir -ItemType Directory -Force }
    $name = [IO.Path]::GetFileName($Archive).ToLowerInvariant()
    if ($name.EndsWith('.zip')) {
        Expand-Archive -LiteralPath $Archive -DestinationPath $ExtractDir -Force
    } elseif ($name.EndsWith('.tar.gz') -or $name.EndsWith('.tgz')) {
        & tar -xzf $Archive -C $ExtractDir
        if ($LASTEXITCODE -ne 0) { throw "Tools: tar extract failed for $name" }
    } elseif ($name.EndsWith('.tar.xz')) {
        & tar -xJf $Archive -C $ExtractDir
        if ($LASTEXITCODE -ne 0) { throw "Tools: tar.xz extract failed for $name" }
    } else {
        $dest = Join-Path $ExtractDir $BinaryName
        Copy-Item -LiteralPath $Archive -Destination $dest -Force
        return $dest
    }
    $direct = Join-Path $ExtractDir $BinaryName
    if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
    $found = Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $BinaryName } | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "Tools: $BinaryName not found inside $name"
}

function Set-AppToolExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-AppToolsIsMacOS)) { return }
    $null = & chmod '+x' $Path 2>$null
    $null = & xattr -d com.apple.quarantine $Path 2>$null
}

function Test-AppToolMachOSigned {
    # Apple Silicon refuses to run an unsigned Mach-O ("killed: 9"), so an update that would
    # leave the tool unrunnable is rejected before it replaces the working copy.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-AppToolsIsMacOS)) { return $true }
    & codesign -dv $Path 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Install-AppToolUpdate {
    <#
    .SYNOPSIS
        Obtain the latest release of a GitHub-sourced tool from its own project, verify the
        SHA-256 GitHub publishes for the asset, keep the current binary as "previous", put
        the new one at the tool's live path and record it - so the next Ensure keeps it.
    #>
    param([Parameter(Mandatory)][string]$Id, [scriptblock]$Progress)
    $say = { param([string]$t) if ($Progress) { & $Progress $t }; Write-SidecarLog "Tools: $t" }
    $spec = Get-AppToolSpec -Id $Id
    if ($spec['kind'] -ne 'github' -or -not $spec.Contains('live') -or -not $spec.Contains('assetPattern')) {
        throw "Tools: $Id is not updatable from the panel ($($spec['kind']))."
    }
    $platformKey = Get-AppToolsPlatformKey
    $repo = Get-AppToolRepoForPlatform -Spec $spec -PlatformKey $platformKey
    & $say "$($Id): asking $repo for its latest release"
    $rel = Get-AppToolLatestRelease -Repo $repo
    $asset = Select-AppToolAsset -Spec $spec -Release $rel -PlatformKey $platformKey
    if (-not $asset) { throw "Tools: $repo $($rel['tag']) has no asset for $platformKey." }
    $newVersion = [string]$rel['version']
    $current = Get-AppToolInstalledVersion -Spec $spec
    if ($current -and (Compare-AppToolVersion -A $current -B $newVersion) -ge 0) {
        & $say "$($Id): $current is already the latest ($newVersion)"
        return (Get-AppToolsStatus)
    }

    $binaryName = [string]$spec['binaryName']
    $live = [string](& $spec['live'])
    if ([string]::IsNullOrWhiteSpace($live)) { throw "Tools: $Id has no live path on this platform." }
    $versionsDir = Get-AppToolVersionsDir -Id $Id
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tools-$Id-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $tmp -ItemType Directory -Force
    try {
        $archive = Join-Path $tmp ([string]$asset['name'])
        & $say "$($Id): downloading $($asset['name']) ($([math]::Round(([long]$asset['size']) / 1MB, 1)) MB) from $($asset['url'])"
        Invoke-AppToolDownload -Uri ([string]$asset['url']) -OutFile $archive
        $sha = Get-AppToolFileSha256 -Path $archive
        if ($asset['sha256']) {
            if ($sha -ne [string]$asset['sha256']) { throw "Tools: SHA-256 mismatch for $($asset['name']) - expected $($asset['sha256']), got $sha" }
            & $say "$($Id): SHA-256 verified against the release digest"
        } else {
            & $say "$($Id): the release publishes no digest; recorded SHA-256 $sha"
        }
        $extracted = Expand-AppToolArchive -Archive $archive -ExtractDir (Join-Path $tmp 'extract') -BinaryName $binaryName
        Set-AppToolExecutable -Path $extracted
        if (-not (Test-AppToolMachOSigned -Path $extracted)) {
            throw "Tools: $($asset['name']) contains an unsigned $binaryName - macOS would refuse to run it, so the current copy is kept."
        }

        # Keep the new version and, once, the one it replaces.
        $newDir = Join-Path $versionsDir $newVersion
        if (-not (Test-Path -LiteralPath $newDir)) { $null = New-Item -Path $newDir -ItemType Directory -Force }
        Copy-Item -LiteralPath $extracted -Destination (Join-Path $newDir $binaryName) -Force
        $previousVersion = $null
        if ($current -and (Test-Path -LiteralPath $live -PathType Leaf)) {
            $prevDir = Join-Path $versionsDir $current
            if (-not (Test-Path -LiteralPath $prevDir)) { $null = New-Item -Path $prevDir -ItemType Directory -Force }
            $prevBin = Join-Path $prevDir $binaryName
            if (-not (Test-Path -LiteralPath $prevBin -PathType Leaf)) { Copy-Item -LiteralPath $live -Destination $prevBin -Force }
            $previousVersion = $current
        }

        $liveDir = Split-Path -Parent $live
        if ($liveDir -and -not (Test-Path -LiteralPath $liveDir)) { $null = New-Item -Path $liveDir -ItemType Directory -Force }
        Copy-Item -LiteralPath $extracted -Destination $live -Force
        Set-AppToolExecutable -Path $live
        $marker = Invoke-AppToolScript -Spec $spec -Name 'marker'
        if ($marker) { Set-Content -LiteralPath ([string]$marker) -Value $newVersion -Encoding ASCII -Force }

        $state = Read-AppToolsState
        $state['tools'][$Id] = [ordered]@{
            installedVersion = $newVersion
            previousVersion  = $previousVersion
            source           = "github:$repo"
            url              = [string]$asset['url']
            sha256           = $sha
            installedAt      = [DateTime]::UtcNow.ToString('o')
        }
        Save-AppToolsState -State $state
        & $say "$($Id): $newVersion installed at $live$(if ($previousVersion) { " (previous $previousVersion kept)" })"
        return (Get-AppToolsStatus)
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-AppToolPrevious {
    <#
    .SYNOPSIS
        Put the kept previous binary back at the live path - one copy, no network.
    #>
    param([Parameter(Mandatory)][string]$Id, [scriptblock]$Progress)
    $say = { param([string]$t) if ($Progress) { & $Progress $t }; Write-SidecarLog "Tools: $t" }
    $spec = Get-AppToolSpec -Id $Id
    $state = Read-AppToolsState
    $entry = if ($state['tools'].Contains($Id)) { $state['tools'][$Id] } else { $null }
    if (-not $entry -or -not $entry.Contains('previousVersion') -or [string]::IsNullOrWhiteSpace([string]$entry['previousVersion'])) {
        throw "Tools: $Id has no previous version to go back to."
    }
    $previousVersion = [string]$entry['previousVersion']
    $currentVersion = [string]$entry['installedVersion']
    $binaryName = [string]$spec['binaryName']
    $prevBin = Join-Path (Join-Path (Get-AppToolVersionsDir -Id $Id) $previousVersion) $binaryName
    if (-not (Test-Path -LiteralPath $prevBin -PathType Leaf)) { throw "Tools: the kept copy of $Id $previousVersion is missing ($prevBin)." }
    $live = [string](& $spec['live'])
    Copy-Item -LiteralPath $prevBin -Destination $live -Force
    Set-AppToolExecutable -Path $live
    $marker = Invoke-AppToolScript -Spec $spec -Name 'marker'
    if ($marker) { Set-Content -LiteralPath ([string]$marker) -Value $previousVersion -Encoding ASCII -Force }
    $entry['installedVersion'] = $previousVersion
    # The version we just left is kept too, so "Use previous" can flip back once more.
    $entry['previousVersion'] = if ($currentVersion -and (Test-Path -LiteralPath (Join-Path (Join-Path (Get-AppToolVersionsDir -Id $Id) $currentVersion) $binaryName))) { $currentVersion } else { $null }
    $entry['installedAt'] = [DateTime]::UtcNow.ToString('o')
    $state['tools'][$Id] = $entry
    Save-AppToolsState -State $state
    & $say "$($Id): back on $previousVersion"
    return (Get-AppToolsStatus)
}
