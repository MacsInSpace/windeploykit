#requires -Version 7.0
<#
.SYNOPSIS
    Download curl.exe and 7z.exe into sidecar/pxe/tools/ - the WinPE tools the deploy client injects.

.EXAMPLE
    pwsh -File ./scripts/fetch-winpe-tools.ps1
#>
[CmdletBinding()]
param(
    [string] $ToolsDir,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ToolsDir) {
    $ToolsDir = Join-Path $RepoRoot 'sidecar/pxe/tools'
}
$null = New-Item -ItemType Directory -Path $ToolsDir -Force

function Get-ScriptTempRoot {
    foreach ($candidate in @($env:TEMP, $env:TMPDIR, [IO.Path]::GetTempPath())) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim().TrimEnd('\', '/')
        }
    }
    throw 'No temp directory (TEMP, TMPDIR, or GetTempPath).'
}

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Save-Download {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
        Write-Host "  skip (exists): $(Split-Path -Leaf $OutFile)"
        return
    }
    Write-Step "Downloading $(Split-Path -Leaf $OutFile)"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -UserAgent 'WinDeployKit'
}

$tempRoot = Get-ScriptTempRoot
$curlStage = Join-Path $tempRoot ("windeploykit-winpe-curl-" + [guid]::NewGuid().ToString('N'))
$curlZip = Join-Path $curlStage 'curl.zip'
$null = New-Item -ItemType Directory -Path $curlStage -Force

try {
    Save-Download `
        -Uri 'https://curl.se/windows/latest.cgi?p=win64-mingw.zip' `
        -OutFile $curlZip
    Expand-Archive -LiteralPath $curlZip -DestinationPath $curlStage -Force
    $curlSrc = Get-ChildItem -LiteralPath $curlStage -Recurse -Filter 'curl.exe' -File | Select-Object -First 1
    if (-not $curlSrc) { throw 'curl.exe not found in curl zip.' }
    Copy-Item -LiteralPath $curlSrc.FullName -Destination (Join-Path $ToolsDir 'curl.exe') -Force
    Write-Host '  curl.exe OK' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $curlStage -Recurse -Force -ErrorAction SilentlyContinue
}

$sevenStage = Join-Path $tempRoot ("windeploykit-winpe-7z-" + [guid]::NewGuid().ToString('N'))
$sevenArchive = Join-Path $sevenStage '7z-extra.7z'
$null = New-Item -ItemType Directory -Path $sevenStage -Force

try {
    Save-Download -Uri 'https://www.7-zip.org/a/7z2501-extra.7z' -OutFile $sevenArchive
    $sevenCmd = Get-Command 7z -ErrorAction SilentlyContinue
    if (-not $sevenCmd) {
        throw 'Need 7z on PATH to extract 7z2409-extra.7z (brew install p7zip).'
    }
    & $sevenCmd.Source x $sevenArchive "-o$sevenStage" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z extract failed (exit $LASTEXITCODE)" }
    $sevenSrc = Get-ChildItem -LiteralPath $sevenStage -Recurse -Filter '7za.exe' -File |
        Where-Object { $_.FullName -match '[/\\]x64[/\\]7za\.exe$' } |
        Select-Object -First 1
    if (-not $sevenSrc) {
        $sevenSrc = Get-ChildItem -LiteralPath $sevenStage -Filter '7za.exe' -File | Select-Object -First 1
    }
    if (-not $sevenSrc) { throw '7za.exe missing from 7-zip extra archive.' }
    Copy-Item -LiteralPath $sevenSrc.FullName -Destination (Join-Path $ToolsDir '7z.exe') -Force
    foreach ($dll in @('7za.dll', '7zxa.dll')) {
        $dllSrc = Join-Path $sevenSrc.DirectoryName $dll
        if (Test-Path -LiteralPath $dllSrc) {
            Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $ToolsDir $dll) -Force
        }
    }
    Write-Host '  7z.exe OK (from 7za.exe + DLLs)' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $sevenStage -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($name in @('curl.exe', '7z.exe', '7za.dll', '7zxa.dll')) {
    $path = Join-Path $ToolsDir $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item -LiteralPath $path).Length
    Write-Host "$name  $([math]::Round($size / 1KB, 1)) KB  SHA256=$hash" -ForegroundColor Green
}

Write-Host "Tools ready in $ToolsDir" -ForegroundColor Green
