# SecretManagement.LocalVault - a file-based, machine-bound SecretManagement vault
# with no OS credential UI. See LocalVault.Core.ps1 and DESIGN.md for the design.
# This outer module only adds the conveniences every consumer needs.
. (Join-Path $PSScriptRoot 'LocalVault.Core.ps1')

function Test-LocalVaultSamePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $na = [IO.Path]::GetFullPath($A).TrimEnd('\', '/')
    $nb = [IO.Path]::GetFullPath($B).TrimEnd('\', '/')
    if (Test-LocalVaultIsWindows) { return ($na -ieq $nb) }
    return ($na -ceq $nb)
}

function Get-LocalVaultOwnModulePaths {
    <#
    .SYNOPSIS
        The path(s) SecretManagement may have recorded for THIS copy. A flat copy is
        recorded as its own folder; a <Name>/<Version>/ copy is recorded as the parent
        (the module base). Both spellings are "us", so neither triggers a re-register.
    #>
    $paths = @($PSScriptRoot)
    $parent = Split-Path -Parent $PSScriptRoot
    $leaf = Split-Path -Leaf $PSScriptRoot
    if ($parent -and ($leaf -as [version]) -and ((Split-Path -Leaf $parent) -eq 'SecretManagement.LocalVault')) {
        $paths += $parent
    }
    return $paths
}

function Test-LocalVaultModulePathAlive {
    <#
    .SYNOPSIS
        Does a recorded module path still hold a copy of this module? True for a flat
        copy (manifest in the folder) and for the versioned layout (manifest in any
        child folder). False once that product has been uninstalled.
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Path 'SecretManagement.LocalVault.psd1')) { return $true }
    $versioned = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SecretManagement.LocalVault.psd1') })
    return ($versioned.Count -gt 0)
}

function Register-LocalVault {
    <#
    .SYNOPSIS
        Register this module as a SecretManagement vault, by full manifest path,
        idempotently. Works from a flat copy and from the <Name>/<Version>/ layout.
        Every product calls this once at startup with the same -Name so they share
        one store. There is no reset: an existing store is opened, never replaced.
    .PARAMETER Name
        Vault name. Products that want to SHARE one store must agree on one name
        (the default, 'shared') so that Get-Secret without -Vault never searches
        duplicates.
    .PARAMETER StoreRoot
        Override the store directory (tests, or a deliberately separate store).
        Omit for the shared per-user default.
    .OUTPUTS
        An ordered HASHTABLE (not a PSObject) so it is identical on PowerShell 5.1
        and 7: read it as $info['keyMatches'] or $info.keyMatches. Probing
        $info.PSObject.Properties finds only the hashtable's own members and
        reports nothing for the keys - it is not "empty", it is a hashtable.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = 'shared',
        [string]$StoreRoot,
        [switch]$DefaultVault
    )
    if (-not (Get-Module Microsoft.PowerShell.SecretManagement)) {
        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    }
    $vaultParams = @{}
    if ($StoreRoot) { $vaultParams['StoreRoot'] = $StoreRoot }

    # The SecretManagement registry is per user and holds ONE module path per vault
    # name, so across products the first to register wins and the others use its copy.
    # That is fine while the copy exists. If that product is uninstalled the path dies
    # and the vault would be broken for everyone - so a registration whose module is
    # gone is replaced by this copy. A different-but-present copy is left alone: the
    # store format is shared and versioned, and churning the registry on every launch
    # of every product would be worse than using a sibling's copy.
    $existing = Get-SecretVault -Name $Name -ErrorAction SilentlyContinue
    $healed = $false
    $isOurs = $false
    if ($existing) {
        foreach ($own in (Get-LocalVaultOwnModulePaths)) {
            if (Test-LocalVaultSamePath -A $existing.ModulePath -B $own) { $isOurs = $true }
        }
    }
    $wasDefault = $false
    if ($existing -and -not $isOurs) {
        if (-not (Test-LocalVaultModulePathAlive -Path $existing.ModulePath)) {
            Write-Verbose "LocalVault: vault '$Name' pointed at a missing module copy ($($existing.ModulePath)); replacing it with $PSScriptRoot."
            $wasDefault = [bool]$existing.IsDefault
            $existing = $null
            $healed = $true
        } else {
            Write-Verbose "LocalVault: vault '$Name' is registered from a sibling copy ($($existing.ModulePath)); using it."
        }
    }
    if (-not $existing) {
        # Register by MANIFEST path, not directory. A directory only resolves when it
        # is named after the module; the <Name>/<Version>/ layout that Install-Module
        # and vendoring scripts produce is not, and a directory registration from it
        # fails with "no valid module file was found". The manifest path resolves from
        # either layout, and SecretManagement records the module base for it.
        $reg = @{ Name = $Name; ModuleName = (Join-Path $PSScriptRoot 'SecretManagement.LocalVault.psd1'); VaultParameters = $vaultParams }
        if ($DefaultVault -or $wasDefault) { $reg['DefaultVault'] = $true }
        if ($healed) {
            # Replace the dead entry in ONE registry write. Unregister-SecretVault first
            # tries to load the dead module (for its unregister hook) and reports that
            # failure as an error - it still removes the entry, but with -ErrorAction
            # Stop it aborted the heal. Measured in a fresh process; in-process tests
            # never saw it because the module was already loaded there.
            $reg['AllowClobber'] = $true
        }
        Register-SecretVault @reg -ErrorAction Stop
    }
    $info = Get-LocalVaultStoreInfo -AdditionalParameters $vaultParams
    $info.Insert(0, 'vault', $Name)
    $info['registered'] = (-not $existing)
    $info['healed'] = $healed
    $info['modulePath'] = (Get-SecretVault -Name $Name).ModulePath
    return $info
}

function Get-LocalVaultInfo {
    <#
    .SYNOPSIS
        Diagnostics for a status panel: where the store is, whether it exists, whether
        this machine/user can read it (keyMatches), and how many secrets it holds.
        Never returns secret material. Returns an ordered HASHTABLE - see
        Register-LocalVault for how to read it.
    #>
    [CmdletBinding()]
    param([string]$StoreRoot)
    $p = @{}
    if ($StoreRoot) { $p['StoreRoot'] = $StoreRoot }
    return Get-LocalVaultStoreInfo -AdditionalParameters $p
}

function Get-LocalVaultMachineBoundKey {
    <#
    .SYNOPSIS
        A 32-byte key bound to this machine + this user for a caller's OWN blobs
        (caches, not secrets), derived with the same inputs as the vault's KEK but a
        purpose-specific salt so it is never the vault key. Binding, not secrecy -
        see DESIGN.md. On Windows callers should prefer DPAPI; this still works
        there for parity.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Purpose)
    if ([string]::IsNullOrWhiteSpace($Purpose)) { throw 'Purpose is required.' }
    $ikm  = [System.Text.Encoding]::UTF8.GetBytes("$(Get-LocalVaultMachineId)|$(Get-LocalVaultUserId)")
    $salt = [System.Text.Encoding]::UTF8.GetBytes("SecretManagement.LocalVault|purpose|$Purpose|v1")
    return Invoke-LocalVaultPbkdf2Sha256 -Ikm $ikm -Salt $salt -Iterations $script:LocalVaultKdfIter -Length 32
}

Export-ModuleMember -Function Register-LocalVault, Get-LocalVaultInfo, Get-LocalVaultMachineBoundKey
