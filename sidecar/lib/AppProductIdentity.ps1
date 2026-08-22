# AppProductIdentity.ps1 - read-side helpers over the product identity object.
#
# Contract: docs/handover/PRODUCT_IDENTITY_CONTRACT.md (shared between products by copy).
# The host sidecar entry script assigns $script:AppProductIdentity BEFORE any lib is
# dot-sourced; every lib resolves product names, slugs, binary names, user agents and
# the published-asset feed through the functions below. This file, like every other
# lib, carries no product literal - the drift check is the contract's grep hitting 0.
#
# Fields (strings):
#   DisplayName       user-facing name; spaced / PascalCase storage dirs on Windows + macOS
#   Slug              lowercase; XDG dirs, plugin ids, cache dirs
#   BinaryName        bundle executable (Contents/MacOS/<name>)
#   UserAgentToken    product token only ('<Product>/<ver>'); Get-AppUserAgent owns the header
#   DialogHelperName  optional; bundled native prompt helper basename, default '<BinaryName>-dialog'
#   AssetFeedBaseUrl  optional; base URL of the product's published-asset feed, absent = no feed
#
# Standalone contexts - dev scripts, and the child runspaces / processes that re-dot-source
# libs - never ran the host entry script. Get-AppProductIdentity therefore falls back to
# <sidecar>/product-identity.ps1, the host's own identity file, before giving up.

function Get-AppProductIdentity {
    if ((Test-Path variable:script:AppProductIdentity) -and $script:AppProductIdentity) {
        return $script:AppProductIdentity
    }
    if ($PSScriptRoot) {
        $hostFile = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'product-identity.ps1'
        if (Test-Path -LiteralPath $hostFile) {
            . $hostFile
            if ((Test-Path variable:script:AppProductIdentity) -and $script:AppProductIdentity) {
                return $script:AppProductIdentity
            }
        }
    }
    throw 'Product identity is not set: the host sidecar must assign $script:AppProductIdentity before dot-sourcing any lib (docs/handover/PRODUCT_IDENTITY_CONTRACT.md).'
}

function Get-AppProductIdentityField {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default
    )
    $identity = Get-AppProductIdentity
    $value = $null
    if ($identity -is [System.Collections.IDictionary]) {
        if ($identity.Contains($Name)) { $value = $identity[$Name] }
    } else {
        $prop = $identity.PSObject.Properties[$Name]
        if ($prop) { $value = $prop.Value }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return ([string]$value).Trim() }
    if ($PSBoundParameters.ContainsKey('Default')) { return $Default }
    throw "Product identity field '$Name' is not set (docs/handover/PRODUCT_IDENTITY_CONTRACT.md)."
}

function Get-AppProductDisplayName { Get-AppProductIdentityField -Name 'DisplayName' }
function Get-AppProductSlug { Get-AppProductIdentityField -Name 'Slug' }
function Get-AppProductBinaryName { Get-AppProductIdentityField -Name 'BinaryName' }
function Get-AppProductUserAgentToken { Get-AppProductIdentityField -Name 'UserAgentToken' }

function Get-AppUserAgent {
    # One composition rule for every product so vendor WAFs see one string shape.
    "Mozilla/5.0 (compatible; $(Get-AppProductUserAgentToken))"
}

function Get-AppProductDialogHelperName {
    Get-AppProductIdentityField -Name 'DialogHelperName' -Default "$(Get-AppProductBinaryName)-dialog"
}

function Get-AppProductAssetFeedBaseUrl {
    $base = Get-AppProductIdentityField -Name 'AssetFeedBaseUrl' -Default ''
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    $base.TrimEnd('/')
}

function Get-AppProductAssetFeedUrl {
    # '<AssetFeedBaseUrl>/<Name>', or $null when the product publishes no feed. Callers
    # already treat an unreachable manifest URL as "use the bundled copy"; $null takes
    # the same path without a network round-trip.
    param([Parameter(Mandatory)][string]$Name)
    $base = Get-AppProductAssetFeedBaseUrl
    if (-not $base) { return $null }
    "$base/$($Name.TrimStart('/'))"
}
