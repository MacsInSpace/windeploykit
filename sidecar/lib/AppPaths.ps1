# AppPaths.ps1 - single source of truth for app-owned data locations.
#
# Replaces the ~20 copy-pasted "where do I put data" blocks that each hardcoded a
# different parent folder across builds. See
# docs/core/app-data/AGENT_NOTES_APP_DATA_LAYOUT.md for the canonical layout and rationale.
#
# Canonical root per OS (product-name, human-readable):
#   Windows : %LOCALAPPDATA%\WinDeployKit\
#   macOS   : ~/Library/Application Support/WinDeployKit/
#   Linux   : $XDG_DATA_HOME/windeploykit/ (or ~/.local/share/...)
#
# The Tauri identifier dir (com.macsinspace.windeploykit) stays Tauri-internal
# (WebView2 / logs) and is NOT used for app-owned data.
#
# This file only DEFINES functions; it is safe to dot-source early and has no
# side effects until a resolver is called.

function New-AppDir {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'New-AppDir: path is empty'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
    $Path
}

function Get-AppDataRoot {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }
        return (Join-Path $base 'WinDeployKit')
    } elseif ($IsMacOS) {
        return (Join-Path $HOME 'Library/Application Support/WinDeployKit')
    } else {
        $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
        return (Join-Path $base 'windeploykit')
    }
}

function Get-AppPrefsDir {
    New-AppDir (Join-Path (Get-AppDataRoot) 'app')
}

function Get-AppPluginDir {
    param([Parameter(Mandatory)][string]$Plugin)
    New-AppDir (Join-Path (Get-AppDataRoot) (Join-Path 'plugins' $Plugin))
}

function Get-AppSiteDir {
    param([string]$SiteId = 'default')
    $key = if ([string]::IsNullOrWhiteSpace($SiteId)) { 'default' } else { $SiteId.Trim() }
    New-AppDir (Join-Path (Get-AppDataRoot) (Join-Path 'site' $key))
}

function Get-AppCacheDir {
    param([Parameter(Mandatory)][string]$Name)
    New-AppDir (Join-Path (Get-AppDataRoot) (Join-Path 'cache' $Name))
}

# ---------------------------------------------------------------------------
# Image library (ISOs / drivers / imageable WIMs) - user-relocatable root.
#
# The ROOT itself is chosen by the technician in the frontend (Settings ->
# Downloads -> ISO & driver root, default ~/Downloads/WinDeployKit)
# and passed into IPC calls. The sidecar must never silently default large
# downloads to the system drive, so these helpers REQUIRE an explicit root and
# only resolve the recommended sub-structure beneath it.
#
# Structure mirrors what the WinPE client expects on the deploy share so
# the laptop can serve it directly:
#   <root>/iso/<name>.iso
#   <root>/Drivers/<model>/*.inf      (flat model folder - no vendor / Win11x64)
#   <root>/WIMs/<name>.wim
#   <root>/.incoming/<guid>/          (aria2 staging)
# ---------------------------------------------------------------------------

function Test-AppImageLibraryRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($Root)) { return $false }
    return $true
}

# Fallback root when the frontend hasn't pushed one yet. The frontend almost
# always supplies the correct, user-chosen root, so this is only a safety net.
#
# macOS: ~/Downloads (and ~/Desktop, ~/Documents) are TCC-protected, so the SMB
# daemon (smbd) is *denied* read access to anything there - a Deploy$ share rooted
# in Downloads is created but never served ("network name cannot be found" in
# WinPE). We default to ~/Public instead (Apple's purpose-built sharing folder,
# not TCC-protected). Mirrors getImageLibraryRoot() in app/src/lib/imageLibrary.ts.
function Get-AppImageLibraryDefaultRoot {
    if ($IsMacOS) {
        return (Join-Path (Join-Path $HOME 'Public') 'WinDeployKit')
    }
    Join-Path (Join-Path $HOME 'Downloads') 'WinDeployKit'
}

# macOS TCC-protected folders smbd cannot read without a manual Full Disk Access
# grant. A Deploy$ share rooted under any of these is created but never served.
function Get-AppMacOsTccProtectedRoots {
    @(
        (Join-Path $HOME 'Downloads'),
        (Join-Path $HOME 'Desktop'),
        (Join-Path $HOME 'Documents')
    )
}

# Returns the TCC-protected base folder a path lives under (e.g. ~/Downloads), or
# $null when the path is safe to SMB-serve. macOS only.
function Get-AppMacOsTccProtectedBase {
    param([string]$Path)
    if (-not $IsMacOS) { return $null }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full = try { [System.IO.Path]::GetFullPath($Path.Trim()) } catch { $Path.Trim() }
    $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    foreach ($base in Get-AppMacOsTccProtectedRoots) {
        $b = $base.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ($full -ieq $b -or $full.StartsWith($b + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $base
        }
    }
    return $null
}

# Persist the user-chosen ISO & driver root into runtime config so autonomous
# sidecar flows (startup recovery, aria2 --dir, promote) agree with the UI.
function Set-AppImageLibraryRuntimeRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return }
    if (-not (Test-AppImageLibraryRoot -Root $Root)) { return }
    if (-not $script:AppState['RuntimeConfig']) {
        $script:AppState['RuntimeConfig'] = @{}
    }
    $script:AppState['RuntimeConfig']['imageLibraryRoot'] = [string]$Root.Trim()
}

# Convenience for IPC handlers: pull imageLibraryRoot off the params bag.
function Set-AppImageLibraryRuntimeRootFromParams {
    param($Params)
    if (-not (Get-Command Get-AppSidecarParam -ErrorAction SilentlyContinue)) { return }
    $root = Get-AppSidecarParam -Params $Params -Name 'imageLibraryRoot'
    if ($root) { Set-AppImageLibraryRuntimeRoot -Root ([string]$root) }
}

# Effective ISO & driver root: runtime override -> default. Creates it unless
# -NoCreate is passed.
function Get-AppImageLibraryRoot {
    [CmdletBinding()]
    param([switch]$NoCreate)
    $root = $null
    # $script:AppState only exists inside the running sidecar. Guard so standalone
    # callers (e.g. scripts/provision-smb-test-user.ps1) dot-sourcing this file fall
    # back cleanly to the default root instead of a null-index error.
    $rc = if ($script:AppState) { $script:AppState['RuntimeConfig'] } else { $null }
    if ($rc -and $rc.Contains('imageLibraryRoot')) {
        $candidate = [string]$rc['imageLibraryRoot']
        if (Test-AppImageLibraryRoot -Root $candidate) { $root = $candidate.Trim() }
    }
    if (-not $root) { $root = Get-AppImageLibraryDefaultRoot }
    if (-not $NoCreate) { $null = New-AppDir $root }
    $root
}

function Get-AppImageLibraryPaths {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Get-AppImageLibraryRoot
    }
    if (-not (Test-AppImageLibraryRoot -Root $Root)) {
        throw "Get-AppImageLibraryPaths: invalid image library root '$Root' (must be a non-empty absolute path)"
    }
    @{
        root        = $Root
        isoDir      = Join-Path $Root 'iso'
        driversDir  = Join-Path $Root 'Drivers'
        wimsDir     = Join-Path $Root 'WIMs'
        incomingDir = Join-Path $Root '.incoming'
    }
}

# Sanitise a device model (or make) into a single safe folder name. ImageDeployer
# matches the literal Win32_ComputerSystem.Model (Lenovo: 4-char short), so we keep
# the name as-is apart from characters that are illegal in a path component.
function ConvertTo-AppImageDriverModelFolderName {
    param([Parameter(Mandatory)][string]$Model)
    # Strip the Windows-illegal set (<>:"/\|?* + control chars) regardless of the
    # host OS, since these folders may be created/served on Windows imaging hosts.
    # Mirrors imageDriverModelFolderName() in app/src/lib/imageLibrary.ts.
    $name = ([regex]::Replace($Model.Trim(), '[<>:"/\\|?*\x00-\x1f]', '_')).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "ConvertTo-AppImageDriverModelFolderName: model '$Model' produced an empty folder name"
    }
    $name
}

function Get-AppImageDriverModelDir {
    # Drivers/<Make>/<Model> - ImageDeployer 1.10's publish/search convention.
    # Make omitted -> legacy flat Drivers/<Model> (kept for callers that only
    # know the model; ImageDeployer's -Recurse -Depth 1 search finds both).
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$Make,
        [string]$Root
    )
    $paths = Get-AppImageLibraryPaths -Root $Root
    $folder = ConvertTo-AppImageDriverModelFolderName -Model $Model
    if (-not [string]::IsNullOrWhiteSpace($Make)) {
        $makeFolder = ConvertTo-AppImageDriverModelFolderName -Model $Make
        return Join-Path (Join-Path $paths.driversDir $makeFolder) $folder
    }
    Join-Path $paths.driversDir $folder
}

# Ensure the recommended sub-structure exists beneath the image library root.
function New-AppImageLibraryLayout {
    param([string]$Root)
    $paths = Get-AppImageLibraryPaths -Root $Root
    foreach ($dir in @($paths.root, $paths.isoDir, $paths.driversDir, $paths.wimsDir, $paths.incomingDir)) {
        $null = New-AppDir $dir
    }
    $paths
}
