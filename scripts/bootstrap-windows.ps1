#requires -Version 5.1
<#
.SYNOPSIS
    One-time setup for building WinDeployKit on Windows.

.EXAMPLE
    pwsh -File .\scripts\bootstrap-windows.ps1

#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppDir = Join-Path $RepoRoot 'app'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

Write-Step 'Removing macOS transfer artifacts (._*, .DS_Store)'
$macArtifacts = @(
    (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -Filter '._*' -ErrorAction SilentlyContinue)
    (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -Filter '.DS_Store' -ErrorAction SilentlyContinue)
) | Where-Object { $_ }
if ($macArtifacts) {
    Write-Host "  Removing $($macArtifacts.Count) file(s) copied from macOS" -ForegroundColor Yellow
    $macArtifacts | Remove-Item -Force
}

Write-Step 'Checking PowerShell 7+'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Install PowerShell 7+ from https://github.com/PowerShell/PowerShell/releases'
}

Write-Step 'Checking Node.js'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Install Node.js 18+ LTS from https://nodejs.org'
}
node --version
npm --version

Write-Step 'Checking Rust'
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host 'Rust not found. Install from https://rustup.rs (Visual Studio C++ Build Tools required).' -ForegroundColor Yellow
    throw 'cargo not on PATH'
}
cargo --version
rustc --version

$rustHostLine = & rustc -vV 2>&1 | Select-String '^host: '
$rustHost = if ($rustHostLine) { ($rustHostLine -replace '^host: ', '').ToString().Trim() } else { '' }
if ($rustHost -match '^aarch64-' -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
    Write-Host '  Windows ARM host detected with x64 build intent - ensuring x86_64 Rust toolchain for MSVC parity' -ForegroundColor Yellow
    $x64Toolchain = 'stable-x86_64-pc-windows-msvc'
    if (-not ((rustup toolchain list 2>$null) -match [regex]::Escape($x64Toolchain))) {
        rustup toolchain install $x64Toolchain --force-non-host
    }
}

Write-Step 'Checking WebView2'
$wv2 = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7EAC2}' -ErrorAction SilentlyContinue
if (-not $wv2) {
    Write-Host 'WebView2 Runtime may be missing. Win11 usually has it; otherwise install Evergreen WebView2 Runtime from Microsoft.' -ForegroundColor Yellow
}

Write-Step 'Checking MSVC (link.exe) for Rust/Tauri'
if (-not (Get-Command link -ErrorAction SilentlyContinue)) {
    Write-Host '  link.exe not on PATH - package-windows.ps1 will load VS 2022 dev env automatically.' -ForegroundColor Yellow
    Write-Host '  If builds fail, install VS 2022 with workload "Desktop development with C++".' -ForegroundColor Yellow
}

$tauriCmd = Join-Path $AppDir 'node_modules\.bin\tauri.cmd'
$needsNpmInstall = -not (Test-Path -LiteralPath $tauriCmd)
if (-not $needsNpmInstall) {
    $nativeX64 = Join-Path $AppDir 'node_modules\@tauri-apps\cli-win32-x64-msvc'
    if (-not (Test-Path -LiteralPath $nativeX64)) { $needsNpmInstall = $true }
}
if (-not $needsNpmInstall -and (Test-Path -LiteralPath (Join-Path $AppDir 'node_modules\.bin\tauri'))) {
    $binHead = Get-Content -LiteralPath (Join-Path $AppDir 'node_modules\.bin\tauri') -TotalCount 1 -ErrorAction SilentlyContinue
    if ($binHead -eq 'XSym') {
        Write-Host '  node_modules came from macOS (Unix symlinks) - reinstalling for Windows' -ForegroundColor Yellow
        Remove-Item -LiteralPath (Join-Path $AppDir 'node_modules') -Recurse -Force
        $needsNpmInstall = $true
    }
}

Write-Step 'Installing npm dependencies'
$systemNode = Join-Path ${env:ProgramFiles} 'nodejs'
if (Test-Path -LiteralPath (Join-Path $systemNode 'node.exe')) {
    $pathParts = $env:PATH -split ';' | Where-Object { $_ -and $_ -notmatch 'cursor\\resources\\app\\resources\\helpers' }
    if ($pathParts -notcontains $systemNode) {
        $env:PATH = ($systemNode, ($pathParts -join ';')) -join ';'
    }
}
Push-Location $AppDir
try {
    if ($needsNpmInstall) { npm install }
    else { Write-Host '  node_modules OK (tauri.cmd present)' }
}
finally { Pop-Location }

Write-Step 'Bootstrap complete.'
Write-Host ''
Write-Host 'Next:' -ForegroundColor Green
Write-Host '  pwsh -File .\scripts\package-windows.ps1'
