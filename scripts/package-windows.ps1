#requires -Version 7.0
<#
.SYNOPSIS
    Build Windows installers for WinDeployKit (same role as package-macos.sh on Mac).

.DESCRIPTION
    Develop on macOS (package-macos.sh). On the Windows build PC, run only this script:

      pwsh -File .\scripts\package-windows.ps1

    It pulls latest source from GitLab, builds MSI + zip, then prompts you to
    test and optionally upload to GitLab Releases (GITLAB_TOKEN in environment).

    One-time setup: pwsh -File .\scripts\bootstrap-windows.ps1

.PARAMETER NoSync
    Skip test + GitLab upload prompts at the end (like package-macos.sh --no-sync).

.PARAMETER SkipPull
    Do not git pull before building.

.PARAMETER Bundles
    Comma-separated Tauri bundle kinds: msi, nsis (default: msi).
    NSIS is NOT distributed since 0.4.2 — setup.exe cannot upgrade MSI installs and
    creates duplicate Installed-apps entries (field policy: MSI only). Pass
    -Bundles msi,nsis only for local dev/testing; release-public never uploads it.

.PARAMETER Arch
    x64 | arm64 — PowerShell payload and build target (default: x64)

.PARAMETER BundlePowerShell
    Also download and embed portable PowerShell (~250 MB) in the installer.

.PARAMETER SkipPrepare
    Skip prepare-bundle-deps.ps1 (staging already done).

.PARAMETER SkipNpmInstall
    Skip npm install in app/

.PARAMETER SkipClean
    Do not delete app/src-tauri/target before building.

.EXAMPLE
    pwsh -File .\scripts\package-windows.ps1
#>
[CmdletBinding()]
param(
    [string] $Bundles = 'msi',

    [ValidateSet('x64', 'arm64')]
    [string] $Arch = 'x64',

    [switch] $BundlePowerShell,

    [switch] $SkipPrepare,

    [switch] $SkipNpmInstall,

    [switch] $SkipClean,

    [switch] $NoSync,

    [switch] $SkipPull
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'package-windows.ps1 must run on Windows. Use package-macos.sh on macOS.'
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

$cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if (Test-Path -LiteralPath $cargoBin) {
    $env:PATH = "$cargoBin;$env:PATH"
}

function Get-VcVarsBatch {
    param(
        [ValidateSet('x64', 'arm64')]
        [string] $Arch
    )
    $names = if ($Arch -eq 'arm64') {
        @('vcvarsarm64.bat', 'vcvarsarm64_amd64.bat')
    }
    else {
        @('vcvars64.bat', 'vcvarsamd64_x86.bat')
    }
    $roots = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build"
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build"
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build"
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build"
    )
    foreach ($root in $roots) {
        foreach ($name in $names) {
            $path = Join-Path $root $name
            if (Test-Path -LiteralPath $path) { return $path }
        }
    }
    return $null
}

function Import-VcVars {
    param([string] $BatchPath)
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        cmd /c "`"$BatchPath`" >nul 2>&1 && set > `"$tempFile`""
        Get-Content -LiteralPath $tempFile | ForEach-Object {
            if ($_ -match '^(?<key>[^=]+)=(?<val>.*)$') {
                Set-Item -Path "env:$($Matches.key)" -Value $Matches.val
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-RustHostTriple {
    param([string] $Toolchain)
    $rustupExe = Join-Path $cargoBin 'rustup.exe'
    $rustcExe = Join-Path $cargoBin 'rustc.exe'
    $out = if ($Toolchain -and (Test-Path -LiteralPath $rustupExe)) {
        & $rustupExe run $Toolchain rustc -vV 2>&1
    }
    elseif (Test-Path -LiteralPath $rustcExe) {
        & $rustcExe -vV 2>&1
    }
    else {
        return $null
    }
    foreach ($line in $out) {
        if ($line -match '^host: (.+)$') { return $Matches[1] }
    }
    return $null
}

function Resolve-RustBuildToolchain {
    param(
        [ValidateSet('x64', 'arm64')]
        [string] $Arch
    )
    $rustTarget = if ($Arch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }

    if ($env:RUSTUP_TOOLCHAIN) {
        $buildHost = Get-RustHostTriple -Toolchain $env:RUSTUP_TOOLCHAIN
        if ($buildHost) {
            $buildArch = if ($buildHost -match '^aarch64-') { 'arm64' } else { 'x64' }
            return @{
                RustTarget = $rustTarget
                VcVarsArch = $buildArch
                BuildHost  = $buildHost
            }
        }
    }

    $defaultHost = Get-RustHostTriple
    if (-not $defaultHost) {
        throw 'Could not determine Rust host triple (is rustup installed?)'
    }

    $defaultArch = if ($defaultHost -match '^aarch64-') { 'arm64' } else { 'x64' }
    if ($defaultArch -eq $Arch) {
        return @{
            RustTarget = $rustTarget
            VcVarsArch = $defaultArch
            BuildHost  = $defaultHost
        }
    }

    $toolchain = "stable-$rustTarget"
    $installed = @((rustup toolchain list 2>$null) -match [regex]::Escape($toolchain)) -contains $true
    if (-not $installed) {
        Write-Host "==> Rust host ($defaultHost) differs from build arch ($Arch) — installing $toolchain" -ForegroundColor Cyan
        if ($Arch -eq 'x64') {
            rustup toolchain install $toolchain --force-non-host
        }
        else {
            rustup toolchain install $toolchain
        }
    }

    $env:RUSTUP_TOOLCHAIN = $toolchain
    $buildHost = Get-RustHostTriple -Toolchain $toolchain
    $buildArch = if ($buildHost -match '^aarch64-') { 'arm64' } else { 'x64' }
    Write-Host "==> Using cross-host toolchain $toolchain (build scripts run as $buildHost)" -ForegroundColor Yellow

    return @{
        RustTarget = $rustTarget
        VcVarsArch = $buildArch
        BuildHost  = $buildHost
    }
}

function Ensure-SystemNodeOnPath {
    $systemNode = Join-Path ${env:ProgramFiles} 'nodejs'
    if (-not (Test-Path -LiteralPath (Join-Path $systemNode 'node.exe'))) { return }
    $pathParts = $env:PATH -split ';' | Where-Object { $_ }
    $withoutCursor = @($pathParts | Where-Object { $_ -notmatch 'cursor\\resources\\app\\resources\\helpers' })
    if ($withoutCursor -notcontains $systemNode) {
        $env:PATH = ($systemNode, ($withoutCursor -join ';')) -join ';'
    }
}

function Remove-MacTransferArtifacts {
    param([string] $Root)
    $macArtifacts = @(
        (Get-ChildItem -LiteralPath $Root -Recurse -Force -Filter '._*' -ErrorAction SilentlyContinue)
        (Get-ChildItem -LiteralPath $Root -Recurse -Force -Filter '.DS_Store' -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ }
    if ($macArtifacts) {
        Write-Host "  Removing $($macArtifacts.Count) macOS transfer file(s)" -ForegroundColor Yellow
        $macArtifacts | Remove-Item -Force
    }
}

function Sync-LatestSource {
    param([string] $Root)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not on PATH. Install Git for Windows, then retry.'
    }
    Push-Location $Root
    try {
        $branch = git branch --show-current 2>$null
        if (-not $branch) { $branch = 'main' }

        # Mac file modes show as modified on Windows; ignore locally on the build PC.
        git config core.filemode false 2>$null | Out-Null

        $ignorePattern = '(^.. )?(app/node_modules/|app/src-tauri/target/|dist/|packaging/staged/|\.cursor/)'
        $dirtyLines = @(git status --porcelain 2>$null | Where-Object { $_ -notmatch $ignorePattern })
        $dirtyFiles = @($dirtyLines | ForEach-Object { ($_ -replace '^\S+\s+', '').Trim() })

        Write-Step "Fetching origin/$branch"
        git fetch origin
        if ($LASTEXITCODE -ne 0) { throw 'git fetch failed.' }

        $upstream = "origin/$branch"
        $behind = 0
        $countOut = git rev-list --count "HEAD..$upstream" 2>$null
        if ($LASTEXITCODE -eq 0 -and $countOut) { $behind = [int]$countOut }

        if ($behind -eq 0) {
            if ($dirtyFiles.Count -gt 0) {
                Write-Host "  Already up to date with $upstream — continuing with local changes:" -ForegroundColor Yellow
                $dirtyFiles | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
            else {
                Write-Host "  Already up to date with $upstream" -ForegroundColor DarkGray
            }
            return
        }

        if ($dirtyFiles.Count -gt 0) {
            Write-Host "  Local changes will be stashed during pull, then restored:" -ForegroundColor Yellow
            $dirtyFiles | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Step "Pulling $behind commit(s) from $upstream (git pull --autostash)"
            git pull origin $branch --no-rebase --autostash
        }
        else {
            Write-Step "Pulling $behind commit(s) from $upstream"
            git pull origin $branch --no-rebase
        }
        if ($LASTEXITCODE -ne 0) {
            throw @"
git pull failed. Resolve conflicts on the Mac, push, then retry here.
If you only need to rebuild without pulling: pwsh -File .\scripts\package-windows.ps1 -SkipPull
"@
        }
    }
    finally {
        Pop-Location
    }
}

function Get-WindowsNodeProcessArch {
    Ensure-SystemNodeOnPath
    $raw = (node -p 'process.arch' 2>$null | Out-String).Trim()
    if ($raw -eq 'arm64') { return 'arm64' }
    return 'x64'
}

function Get-TauriCliNativePackageName {
    param(
        [ValidateSet('x64', 'arm64')]
        [string] $CliArch
    )
    if ($CliArch -eq 'arm64') { '@tauri-apps/cli-win32-arm64-msvc' }
    else { '@tauri-apps/cli-win32-x64-msvc' }
}

function Get-TauriCliNativeModulePath {
    param(
        [string] $AppDir,
        [ValidateSet('x64', 'arm64')]
        [string] $CliArch
    )
    $leaf = if ($CliArch -eq 'arm64') { 'cli-win32-arm64-msvc' } else { 'cli-win32-x64-msvc' }
    Join-Path $AppDir (Join-Path 'node_modules\@tauri-apps' $leaf)
}

function Test-WindowsNpmInstall {
    param(
        [string] $AppDir,
        [ValidateSet('x64', 'arm64')]
        [string] $CliArch
    )
    $tauriCmd = Join-Path $AppDir 'node_modules\.bin\tauri.cmd'
    if (-not (Test-Path -LiteralPath $tauriCmd)) { return $false }

    $tauriSh = Join-Path $AppDir 'node_modules\.bin\tauri'
    if (Test-Path -LiteralPath $tauriSh) {
        $binHead = Get-Content -LiteralPath $tauriSh -TotalCount 1 -ErrorAction SilentlyContinue
        # XSym = macOS zip copy; #!/bin/sh is normal on Windows npm .bin stubs (tauri.cmd is used).
        if ($binHead -eq 'XSym') { return $false }
    }

    $nativePkg = Get-TauriCliNativeModulePath -AppDir $AppDir -CliArch $CliArch
    if (-not (Test-Path -LiteralPath $nativePkg)) { return $false }

    return $true
}

function Ensure-TauriCliNativeBinding {
    param(
        [string] $AppDir,
        [ValidateSet('x64', 'arm64')]
        [string] $CliArch
    )
    $nativePath = Get-TauriCliNativeModulePath -AppDir $AppDir -CliArch $CliArch
    if (Test-Path -LiteralPath $nativePath) { return }

    $cliPkgJson = Join-Path $AppDir 'node_modules\@tauri-apps\cli\package.json'
    if (-not (Test-Path -LiteralPath $cliPkgJson)) {
        throw 'Missing @tauri-apps/cli after npm install.'
    }
    $cliVersion = (Get-Content -LiteralPath $cliPkgJson -Raw | ConvertFrom-Json).version
    $nativeName = Get-TauriCliNativePackageName -CliArch $CliArch
    Write-Host "  Installing $nativeName@$cliVersion (Node host arch: $CliArch)" -ForegroundColor Yellow

    Push-Location $AppDir
    try {
        npm install "${nativeName}@${cliVersion}" --no-save
        if ($LASTEXITCODE -ne 0) { throw "npm install $nativeName failed." }
    }
    finally {
        Pop-Location
    }
}

function Initialize-WindowsNpmHostEnvironment {
    <#
    .SYNOPSIS
        @tauri-apps/cli loads a native binding for the Node process arch (not the Rust MSI arch).
        ARM64 Windows + x64 installer => Node arm64 + --target x86_64-pc-windows-msvc.
    #>
    param(
        [string] $AppDir,
        [ValidateSet('x64', 'arm64')]
        [string] $InstallerArch
    )
    Ensure-SystemNodeOnPath
    $cliArch = Get-WindowsNodeProcessArch
    $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($InstallerArch -eq 'x64' -and $cliArch -eq 'arm64') {
        Write-Host "  Node $nodeExe ($cliArch) — Rust target x86_64-pc-windows-msvc for x64 MSI" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Node $nodeExe ($cliArch) — installer arch $InstallerArch" -ForegroundColor DarkGray
    }
    Ensure-TauriCliNativeBinding -AppDir $AppDir -CliArch $cliArch
    if (-not (Test-WindowsNpmInstall -AppDir $AppDir -CliArch $cliArch)) {
        $expected = Get-TauriCliNativePackageName -CliArch $cliArch
        throw "npm install finished but $expected is still missing. Re-run without -SkipNpmInstall or delete app/node_modules."
    }
}

function Install-WindowsNpmDependencies {
    param(
        [string] $AppDir,
        [ValidateSet('x64', 'arm64')]
        [string] $InstallerArch,
        [switch] $Force
    )
    Ensure-SystemNodeOnPath
    $cliArch = Get-WindowsNodeProcessArch

    if (-not $Force -and (Test-WindowsNpmInstall -AppDir $AppDir -CliArch $cliArch)) {
        Write-Host "  node_modules OK for Windows (Node $cliArch)" -ForegroundColor DarkGray
        return
    }

    if ($Force -or (Test-Path -LiteralPath (Join-Path $AppDir 'node_modules'))) {
        Write-Host '  Reinstalling node_modules for Windows (Mac copy, stale lockfile, or wrong native binding)' -ForegroundColor Yellow
        Remove-Item -LiteralPath (Join-Path $AppDir 'node_modules') -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Step "npm install (Tauri CLI binding for Node $cliArch)"
    Push-Location $AppDir
    try {
        npm install
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }
    }
    finally {
        Pop-Location
    }

    Initialize-WindowsNpmHostEnvironment -AppDir $AppDir -InstallerArch $InstallerArch
}

$RustTarget = if ($Arch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$buildCtx = Resolve-RustBuildToolchain -Arch $Arch
$RustTarget = $buildCtx.RustTarget

if (-not (Get-Command link -ErrorAction SilentlyContinue)) {
    $vcvars = Get-VcVarsBatch -Arch $buildCtx.VcVarsArch
    if (-not $vcvars) {
        $workload = if ($buildCtx.VcVarsArch -eq 'arm64') {
            'MSVC v143 - VS 2022 C++ ARM64 build tools (and x64 tools if building x64 installers)'
        }
        else {
            '"Desktop development with C++" (x64)'
        }
        throw @"
MSVC link.exe not on PATH and Visual Studio 2022 C++ tools not found for $($buildCtx.VcVarsArch).
Install $workload via Visual Studio Build Tools, then retry.
"@
    }
    Write-Host "==> Loading Visual Studio C++ environment ($($buildCtx.VcVarsArch), link.exe not on PATH)" -ForegroundColor Cyan
    Import-VcVars -BatchPath $vcvars
    if (Test-Path -LiteralPath $cargoBin) {
        $env:PATH = "$cargoBin;$env:PATH"
    }
    if (-not (Get-Command link -ErrorAction SilentlyContinue)) {
        throw 'Visual Studio C++ environment loaded but link.exe is still not on PATH.'
    }
}

Ensure-SystemNodeOnPath

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $SkipPull) {
    Sync-LatestSource -Root $RepoRoot
}

$AppDir = Join-Path $RepoRoot 'app'
$TauriConf = Join-Path $AppDir 'src-tauri/tauri.conf.json'
$DistRoot = Join-Path $RepoRoot 'dist/windows'
$Version = (Get-Content -Raw (Join-Path $AppDir 'package.json') | ConvertFrom-Json).version
$GitSha = (git -C $RepoRoot rev-parse --short HEAD 2>$null)
if (-not $GitSha) { $GitSha = 'nogit' }
$BuildStamp = Get-Date -Format 'yyyyMMdd-HHmm'

$OutName = "WinDeployKit_${Version}_$Arch"
$OutDir = Join-Path $DistRoot $OutName

Write-Step "WinDeployKit Windows package v$Version ($Arch)"
Remove-MacTransferArtifacts -Root $RepoRoot

if (-not $SkipPrepare) {
    $prepArgs = @{ Platform = 'Windows'; Arch = $Arch }
    if ($BundlePowerShell) {
        Write-Step 'Staging dependencies (including portable PowerShell)'
        $prepArgs['BundlePowerShell'] = $true
    }
    else {
        Write-Step 'Staging dependencies (sidecar + modules; pwsh 7 required on target PCs)'
    }
    & (Join-Path $PSScriptRoot 'prepare-bundle-deps.ps1') @prepArgs

    $psOpenAdManifest = Join-Path $RepoRoot 'packaging/staged/modules/PSOpenAD/PSOpenAD.psd1'
    $psModuleManifest = Join-Path $RepoRoot 'packaging/staged/modules/WinDeployKitPS/WinDeployKitPS.psm1'
    if (-not (Test-Path -LiteralPath $psOpenAdManifest)) {
        throw @"
PSOpenAD was not staged for the installer.
Expected: $psOpenAdManifest
Run: pwsh -File .\scripts\build-psopenad.ps1
Or use a GitLab pipeline artifact from job build:psopenad, then re-run package-windows.ps1 (without -SkipPrepare).
"@
    }
    if (-not (Test-Path -LiteralPath $psModuleManifest)) {
        throw "bundled module staging failed: missing $psModuleManifest"
    }
    Write-Step 'Verified staged PSOpenAD modules'

    $bannerManifest = Join-Path $RepoRoot 'packaging/staged/sidecar/templates/email/banners/manifest.json'
    if (-not (Test-Path -LiteralPath $bannerManifest)) {
        throw @"
Email signature banners were not staged for the installer.
Expected: $bannerManifest
Re-run package-windows.ps1 without -SkipPrepare, or run prepare-bundle-deps.ps1 first.
"@
    }
    Write-Step 'Verified staged email signature banners'

    $stagedBinaries = Join-Path $RepoRoot 'packaging/staged/binaries'
    if (-not (Test-Path -LiteralPath $stagedBinaries)) {
        throw @"
packaging/staged/binaries is missing (required by tauri.conf.json bundle resources).
Re-run without -SkipPrepare, or: pwsh -File .\scripts\prepare-bundle-deps.ps1 -Platform Windows -Arch $Arch
"@
    }
    Write-Step 'Verified staged binaries directory (Tauri bundle resource path)'
}

$TauriConfBackup = "$TauriConf.package-bak"
if ($BundlePowerShell) {
    if (-not (Test-Path -LiteralPath $TauriConfBackup)) {
        Copy-Item -LiteralPath $TauriConf -Destination $TauriConfBackup -Force
    }
    $conf = Get-Content -Raw -LiteralPath $TauriConf | ConvertFrom-Json
    if (-not $conf.bundle.resources) {
        $conf.bundle | Add-Member -NotePropertyName resources -Value ([ordered]@{})
    }
    $conf.bundle.resources.'../../packaging/staged/powershell/' = 'powershell/'
    $conf | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $TauriConf -Encoding utf8
}

if (-not $SkipNpmInstall) {
    Install-WindowsNpmDependencies -AppDir $AppDir -InstallerArch $Arch
}
else {
    Initialize-WindowsNpmHostEnvironment -AppDir $AppDir -InstallerArch $Arch
}

# Ensure Rust target on the active build toolchain
$toolchainArg = if ($env:RUSTUP_TOOLCHAIN) { @('--toolchain', $env:RUSTUP_TOOLCHAIN) } else { @() }
$targetInstalled = (rustup target list --installed @toolchainArg 2>$null) -match [regex]::Escape($RustTarget)
if (-not $targetInstalled) {
    Write-Step "rustup target add $RustTarget$(if ($env:RUSTUP_TOOLCHAIN) { " ($($env:RUSTUP_TOOLCHAIN))" })"
    rustup target add $RustTarget @toolchainArg
}

$bundleArgs = @(
    $Bundles.Split(',', [StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)

$TauriTarget = Join-Path $AppDir 'src-tauri/target'
$env:CARGO_TARGET_DIR = $TauriTarget
$env:VITE_APP_VERSION = $Version
$env:VITE_BUILD_NUMBER = "$GitSha-$BuildStamp"
$env:VITE_BUILD_STAMP = Get-Date -Format 'yyyyMMdd'
$env:VITE_APP_VARIANT = $Arch
Write-Step "Frontend build id: $($env:VITE_APP_VERSION) · $($env:VITE_BUILD_NUMBER) ($($env:VITE_APP_VARIANT))"

if (-not $SkipClean -and (Test-Path -LiteralPath $TauriTarget)) {
    Write-Step 'Cleaning Cargo/Tauri target (avoids stale paths after repo move)'
    Remove-Item -LiteralPath $TauriTarget -Recurse -Force
}

Write-Step "tauri build --target $RustTarget --bundles $Bundles"
Initialize-WindowsNpmHostEnvironment -AppDir $AppDir -InstallerArch $Arch
$nodeExe = (Get-Command node -ErrorAction Stop).Source
$tauriJs = Join-Path $AppDir 'node_modules\@tauri-apps\cli\tauri.js'
if (-not (Test-Path -LiteralPath $tauriJs)) {
    throw "Missing $tauriJs — run without -SkipNpmInstall."
}
Push-Location $AppDir
try {
    $tauriArgs = @($tauriJs, 'build', '--target', $RustTarget)
    foreach ($b in $bundleArgs) {
        $tauriArgs += '--bundles'
        $tauriArgs += $b
    }
    & $nodeExe @tauriArgs
    if ($LASTEXITCODE -ne 0) { throw "tauri build failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
    if ($BundlePowerShell -and (Test-Path -LiteralPath $TauriConfBackup)) {
        Move-Item -LiteralPath $TauriConfBackup -Destination $TauriConf -Force
    }
}

$psOpenAdInBundle = @(Get-ChildItem -Path (Join-Path $AppDir 'src-tauri/target') -Recurse -Filter 'PSOpenAD.psd1' -ErrorAction SilentlyContinue)
if ($psOpenAdInBundle.Count -eq 0) {
    Write-Host 'WARN: PSOpenAD.psd1 not found under src-tauri/target after build — MSI may be missing LDAP module.' -ForegroundColor Yellow
} else {
    Write-Step "Bundle contains PSOpenAD ($($psOpenAdInBundle.Count) manifest(s))"
}

$BundleRoot = Join-Path $AppDir "src-tauri/target/$RustTarget/release/bundle"
if (-not (Test-Path -LiteralPath $BundleRoot)) {
  $BundleRoot = Join-Path $AppDir 'src-tauri/target/release/bundle'
}

Write-Step "Assembling $OutDir"
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$msi = Get-ChildItem -Path (Join-Path $BundleRoot 'msi') -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
$nsis = Get-ChildItem -Path (Join-Path $BundleRoot 'nsis') -Filter '*-setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
$portableExe = Join-Path $AppDir "src-tauri/target/$RustTarget/release/windeploykit.exe"
if (-not (Test-Path -LiteralPath $portableExe)) {
    $portableExe = Join-Path $AppDir 'src-tauri/target/release/windeploykit.exe'
}

$msiName = "WinDeployKit_${Version}_x64_en-US.msi"
$setupName = "WinDeployKit_${Version}_x64-setup.exe"
if ($msi) { Copy-Item -LiteralPath $msi.FullName -Destination (Join-Path $OutDir $msiName) }
if ($nsis) { Copy-Item -LiteralPath $nsis.FullName -Destination (Join-Path $OutDir $setupName) }
if (Test-Path -LiteralPath $portableExe) {
    Copy-Item -LiteralPath $portableExe -Destination (Join-Path $OutDir 'windeploykit.exe')
}

$nsisSection = if ($nsis) {
    @"
2. NSIS setup.exe (interactive wizard — dev/test only; NEVER distribute):
   Run the *-setup.exe installer from this folder.
   If an older MSI or setup.exe is already installed, uninstall all
   "WinDeployKit" entries in Settings -> Apps first.

3. Portable (advanced):
"@
} else {
    @"
NOTE: the NSIS setup.exe is no longer distributed (it does not upgrade
MSI installs and causes duplicate Installed-apps entries). Use the MSI.

2. Portable (advanced):
"@
}

@"

WinDeployKit $Version — Windows install
==============================================

Built (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))
Architecture: $Arch

REQUIREMENTS (install once per PC)
--------------------------------
  - PowerShell 7 or later (pwsh on PATH)
      winget install --id Microsoft.PowerShell
      Or: https://github.com/PowerShell/PowerShell/releases

WHAT IS BUNDLED
---------------
The installers include:
  - WinDeployKit (Tauri UI)
  - PSOpenAD + WinDeployKitPS modules
  - SchoolManager sidecar scripts

INSTALL (pick one)
------------------
0. Install PowerShell 7+ if not already present (see above).

1. MSI (recommended for IT deployment and upgrades):
   Run WinDeployKit_${Version}_x64_en-US.msi
   Installs under Program Files with Start Menu shortcut.
   Replaces a previous MSI of the same product automatically.

$nsisSection
   windeploykit.exe in this folder is NOT sufficient alone — use the MSI above.
   The full app with resources is only inside the MSI install tree.

FIRST RUN
---------
- Sign in with EDU001 credentials when prompted.
- Credentials cache: %LOCALAPPDATA%\WinDeployKitCreds\StoredCredentials.xml
- Network: on-site or VPN to school STADC/EDUDC.

SMARTScreen
-----------
Unsigned builds may show "Windows protected your PC". Click More info → Run anyway,
or sign the MSI in your org (optional future step).

"@ | Set-Content -LiteralPath (Join-Path $OutDir 'README-INSTALL.txt') -Encoding utf8

@"

version=$Version
arch=$Arch
rust_target=$RustTarget
built_utc=$((Get-Date).ToUniversalTime().ToString('o'))

"@ | Set-Content -LiteralPath (Join-Path $OutDir 'VERSION.txt') -Encoding utf8

$zipPath = Join-Path $DistRoot "$OutName.zip"
$outFiles = Get-ChildItem -LiteralPath $OutDir -ErrorAction SilentlyContinue
if ($outFiles) {
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
}
else {
    Write-Host 'No installer files copied to output folder — check tauri build bundle paths above.' -ForegroundColor Yellow
}

Write-Step "Output folder: $OutDir"
Write-Step "Zip: $zipPath"
if ($msi) { Write-Step "MSI: $(Join-Path $OutDir $msiName)" }
if ($nsis) { Write-Step "Setup: $(Join-Path $OutDir $setupName)" }
Write-Host ''
Write-Host 'Done. Installers are under dist\windows\' -ForegroundColor Green

if (-not $NoSync) {
    $extra = @()
    if ($msi) { $extra += (Join-Path $OutDir $msiName) }
    if ($nsis) { $extra += (Join-Path $OutDir $setupName) }
    & (Join-Path $PSScriptRoot 'offer-post-build-sync.ps1') -Platform Windows -Version $Version `
        -ZipPath $zipPath -ExtraPaths $extra
}
