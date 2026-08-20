#requires -Version 7.0
<#
.SYNOPSIS
    Upload SOE .torrent files + aria2-tracker.json to GitLab generic package /latest/.

.EXAMPLE
    export GITLAB_TOKEN='glpat-...'
    pwsh -File ./scripts/publish-aria2-torrents.ps1

.EXAMPLE
    pwsh -File ./scripts/publish-aria2-torrents.ps1 -ManifestOnly
#>
[CmdletBinding()]
param(
    [string] $ProjectPath = 'MacsInSpace/windeploykit',
    [string] $GitLabHost = 'artifacts.example.com',
    [string] $Token = $env:GITLAB_TOKEN,
    [string] $PackageName = 'windeploykit',
    [switch] $ManifestOnly
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $RepoRoot 'packaging/aria2-tracker.json'
$torrentsDir = Join-Path $RepoRoot 'packaging/torrents'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest: $manifestPath"
}
if (-not $Token) {
    # Fall back to the repo-root .env.local (gitignored): GITLAB_TOKEN=...
    $envFile = Join-Path $RepoRoot '.env.local'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^\s*GITLAB_TOKEN\s*=\s*(.+?)\s*$') {
                $Token = $Matches[1].Trim('"').Trim("'")
                break
            }
        }
    }
}
if (-not $Token) { throw 'Set GITLAB_TOKEN (env var or .env.local) before publishing.' }

$ProjectEnc = [uri]::EscapeDataString($ProjectPath)
$Headers = @{ 'PRIVATE-TOKEN' = $Token.Trim() }
$BasePackageUrl = "https://$GitLabHost/api/v4/projects/$ProjectEnc/packages/generic/$PackageName/latest"

function Publish-GenericFile {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$UploadName,
        [Parameter(Mandatory)][string]$ContentType
    )
    $encName = [uri]::EscapeDataString($UploadName)
    $uri = "$BasePackageUrl/$encName"
    Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -InFile $FilePath -ContentType $ContentType | Out-Null
    Write-Host "  uploaded $UploadName" -ForegroundColor Cyan
    return $uri
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest.manifestUrl = "$BasePackageUrl/aria2-tracker.json"
$manifest.updated = (Get-Date).ToString('yyyy-MM-dd')

if (-not $ManifestOnly) {
    foreach ($entry in @($manifest.torrents)) {
        $rel = [string]$entry.torrentPath
        if (-not $rel) { continue }
        $local = Join-Path $RepoRoot ("packaging/$rel")
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
            throw "Bundled torrent missing: $local (id=$($entry.id))"
        }
        $fileName = Split-Path -Leaf $local
        $size = (Get-Item -LiteralPath $local).Length
        $entry | Add-Member -NotePropertyName sizeBytes -NotePropertyValue ([long]$size) -Force
        $entry | Add-Member -NotePropertyName downloadUrl -NotePropertyValue "$BasePackageUrl/$([uri]::EscapeDataString($fileName))" -Force
        Publish-GenericFile -FilePath $local -UploadName $fileName -ContentType 'application/x-bittorrent'
    }
}

($manifest | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
$manifestUri = Publish-GenericFile -FilePath $manifestPath -UploadName 'aria2-tracker.json' -ContentType 'application/json'
Write-Host "Done. Manifest: $manifestUri" -ForegroundColor Green
