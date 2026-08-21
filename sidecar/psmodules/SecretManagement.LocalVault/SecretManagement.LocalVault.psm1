# SecretManagement.LocalVault - a file-based, machine-bound SecretManagement vault
# with no OS credential UI. See LocalVault.Core.ps1 for the design and the contract
# reference. This outer module only adds the two conveniences every consumer needs.
. (Join-Path $PSScriptRoot 'LocalVault.Core.ps1')

function Register-LocalVault {
    <#
    .SYNOPSIS
        Register this module as a SecretManagement vault, by full path, idempotently.
        Every product calls this once at startup with the same -Name so they share
        one store. There is no reset: an existing store is opened, never replaced.
    .PARAMETER Name
        Vault name. Keep the default - the contract fixes it so that Get-Secret
        without -Vault never searches duplicates.
    .PARAMETER StoreRoot
        Override the store directory (tests, or a deliberately separate store).
        Omit for the shared per-user default.
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
    if ($existing -and $existing.ModulePath -ne $PSScriptRoot) {
        $theirManifest = Join-Path $existing.ModulePath 'SecretManagement.LocalVault.psd1'
        if (-not (Test-Path -LiteralPath $theirManifest)) {
            Write-Verbose "LocalVault: vault '$Name' pointed at a missing module copy ($($existing.ModulePath)); re-registering from $PSScriptRoot."
            Unregister-SecretVault -Name $Name -ErrorAction Stop
            $existing = $null
            $healed = $true
        } else {
            Write-Verbose "LocalVault: vault '$Name' is registered from a sibling copy ($($existing.ModulePath)); using it."
        }
    }
    if (-not $existing) {
        $reg = @{ Name = $Name; ModuleName = $PSScriptRoot; VaultParameters = $vaultParams }
        if ($DefaultVault) { $reg['DefaultVault'] = $true }
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
        Never returns secret material.
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
        see the contract. On Windows callers should prefer DPAPI; this still works
        there for parity.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Purpose)
    if ([string]::IsNullOrWhiteSpace($Purpose)) { throw 'Purpose is required.' }
    $ikm  = [System.Text.Encoding]::UTF8.GetBytes("$(Get-LocalVaultMachineId)|$(Get-LocalVaultUserId)")
    $salt = [System.Text.Encoding]::UTF8.GetBytes("SecretManagement.LocalVault|purpose|$Purpose|v1")
    return [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        $ikm, $salt, $script:LocalVaultKdfIter, [System.Security.Cryptography.HashAlgorithmName]::SHA256, 32)
}

Export-ModuleMember -Function Register-LocalVault, Get-LocalVaultInfo, Get-LocalVaultMachineBoundKey
