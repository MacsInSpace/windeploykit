# Shared secret vault - this product's registration of SecretManagement.LocalVault.
#
# docs/handover/SHARED_SECRET_VAULT_CONTRACT.md: one per-user store shared by every
# product (this one and its two sibling products), the SecretManagement API in front of it,
# and no OS credential UI behind it. This file is the product-specific glue only: find
# the two vendored modules, import them, register the vault under the contract's
# single vault name. The vault module is product-neutral and lives in its own
# repository (github.com/MacsInSpace/SecretManagement.LocalVault); every product
# vendors a tagged release of it, pinned by scripts/sync-secret-vault-modules.ps1.
#
# Layout the resolver expects, for BOTH modules (contract section 8):
#   bundle : <ProjectRoot>/modules/<Name>/<ver>/           (prepare-bundle-deps.ps1)
#   dev    : <ProjectRoot>/vendor/psmodules/<Name>/<ver>/  (sync-secret-vault-modules.ps1)
#
# Startup must NEVER fail on this. If the vault cannot be registered, credential
# features degrade and the status handler says why. Nothing here prompts, nothing
# here resets - there is no reset concept in this vault (contract section 4a
# withdrew the SecretStore bootstrap that had one).
#
# Register at EVERY start-up (contract section 8b): SecretManagement's in-process
# registry cache only refreshes on a file-watcher event, so a running process may
# never see a sibling product's registration change. Register-LocalVault is
# idempotent and self-heals a dead registration left by an uninstalled product.

$script:AppSharedSecretVaultName = 'shared'
$script:AppSharedSecretVaultState = @{ ready = $false; error = $null; info = $null }

# Contract section 3 names this product uses.
$script:AppVaultNameLocalMachineAdmin = 'local-machine/admin'
$script:AppVaultNameDeptEdu001 = 'dept/edu001'

function Get-AppVaultNetbootJoinName {
    <# Task-sequence domain-join credential. Contract section 3: netboot/join/<id>. #>
    param([Parameter(Mandatory)][string]$Id)
    $safe = ([string]$Id).Trim().ToLowerInvariant() -replace '[^a-z0-9._-]', '-'
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw 'Get-AppVaultNetbootJoinName: id is required'
    }
    return "netboot/join/$safe"
}

function Get-AppPowerShellModuleManifestPath {
    param(
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][string]$ModuleName
    )
    if (-not (Test-Path -LiteralPath $ModuleRoot)) { return $null }
    $direct = Join-Path $ModuleRoot "$ModuleName.psd1"
    if (Test-Path -LiteralPath $direct) { return $direct }
    $nested = Get-ChildItem -LiteralPath $ModuleRoot -Filter "$ModuleName.psd1" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object { $_.Directory.Name } -Descending |
        Select-Object -First 1
    if ($nested) { return $nested.FullName }
    return $null
}

function Get-AppVendoredPsModuleManifestPath {
    <# modules/<Name>/<ver>/ (bundle) first, then vendor/psmodules/<Name>/<ver>/ (dev). #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($root in @(
        (Join-Path $ProjectRoot "modules/$Name"),
        (Join-Path $ProjectRoot "vendor/psmodules/$Name")
    )) {
        $manifest = Get-AppPowerShellModuleManifestPath -ModuleRoot $root -ModuleName $Name
        if ($manifest) { return $manifest }
    }
    return $null
}

function Get-AppSecretManagementManifestPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return Get-AppVendoredPsModuleManifestPath -ProjectRoot $ProjectRoot -Name 'Microsoft.PowerShell.SecretManagement'
}

function Get-AppLocalVaultManifestPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return Get-AppVendoredPsModuleManifestPath -ProjectRoot $ProjectRoot -Name 'SecretManagement.LocalVault'
}

function Initialize-AppSharedSecretVault {
    <#
    .SYNOPSIS
        Import the API + vault modules and register the 'shared' vault. Idempotent,
        never throws, never prompts, never resets. Returns the state hashtable.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        # Tests only: register under another name / store so the real 'shared' vault
        # is untouched.
        [string]$VaultName,
        [string]$StoreRoot
    )
    if ($VaultName) { $script:AppSharedSecretVaultName = $VaultName }
    try {
        $smManifest = Get-AppSecretManagementManifestPath -ProjectRoot $ProjectRoot
        if (-not $smManifest) {
            throw 'Microsoft.PowerShell.SecretManagement is not bundled (modules/) or vendored (vendor/psmodules/). Dev: pwsh ./scripts/sync-secret-vault-modules.ps1'
        }
        $lvManifest = Get-AppLocalVaultManifestPath -ProjectRoot $ProjectRoot
        if (-not $lvManifest) {
            throw 'SecretManagement.LocalVault is not bundled (modules/) or vendored (vendor/psmodules/). Dev: pwsh ./scripts/sync-secret-vault-modules.ps1'
        }
        if (-not (Get-Module Microsoft.PowerShell.SecretManagement)) {
            Import-Module $smManifest -ErrorAction Stop
        }
        if (-not (Get-Module SecretManagement.LocalVault)) {
            Import-Module $lvManifest -ErrorAction Stop
        }
        $regArgs = @{ Name = $script:AppSharedSecretVaultName }
        if ($StoreRoot) { $regArgs['StoreRoot'] = $StoreRoot } else { $regArgs['DefaultVault'] = $true }
        $info = Register-LocalVault @regArgs
        $script:AppSharedSecretVaultState = @{ ready = [bool]$info.keyMatches; error = $null; info = $info }
        if (-not $info.keyMatches) {
            # Store came from another machine or user. Surface as "sign in again",
            # never as corruption - contract section 7.
            $script:AppSharedSecretVaultState.error = "vault store at $($info.storeRoot) was created on another machine or by another user (store $($info.storeKeyId), here $($info.thisKeyId)); sign in again to re-create secrets"
            Write-SidecarLog "Secret vault: WARN $($script:AppSharedSecretVaultState.error)"
        } else {
            $what = if ($info['healed']) { 'registered (healed a dead registration left by another copy)' } elseif ($info.registered) { 'registered' } else { 'already registered' }
            $had = if ($info.exists) { "$($info.secretCount) secret(s)" } else { 'no store yet (created on first write)' }
            $from = if ($info.registered) { $lvManifest } else { [string]$info['modulePath'] }
            Write-SidecarLog "Secret vault: '$($info.vault)' $what from $from; $had at $($info.storeRoot)"
        }
    } catch {
        $msg = $_.Exception.Message
        $script:AppSharedSecretVaultState = @{ ready = $false; error = $msg; info = $null }
        Write-SidecarLog "Secret vault: unavailable - $msg"
    }
    return $script:AppSharedSecretVaultState
}

function Get-AppSharedSecretVaultStatus {
    <#
    .SYNOPSIS
        IPC-shaped status for the credentials UI. Never returns secret material.
    #>
    $state = $script:AppSharedSecretVaultState
    $out = [ordered]@{
        vault = $script:AppSharedSecretVaultName
        ready = [bool]$state.ready
        error = $state.error
    }
    if ($state.info) {
        # Live read - the init-time snapshot goes stale after the first write.
        $live = $state.info
        if (Get-Command Get-LocalVaultInfo -ErrorAction SilentlyContinue) {
            try { $live = Get-LocalVaultInfo -StoreRoot ([string]$state.info['storeRoot']) } catch { }
        }
        foreach ($k in @('storeRoot', 'exists', 'scheme', 'keyMatches', 'secretCount', 'createdAt')) {
            $out[$k] = $live[$k]
        }
        $out['modulePath'] = $state.info['modulePath']
    }
    return $out
}

function Test-AppSharedSecretVaultReady {
    return [bool]$script:AppSharedSecretVaultState.ready
}

# --- Store-facing helpers ------------------------------------------------------
# Every helper is safe when the vault is not ready: it returns $null/$false so the
# caller degrades rather than throwing. A broken vault must never lock a technician
# out of the app.

$script:AppSharedSecretVaultFallbackLogged = @{}

function Write-AppSharedSecretVaultFallbackOnce {
    param([Parameter(Mandatory)][string]$Store)
    if ($script:AppSharedSecretVaultFallbackLogged.ContainsKey($Store)) { return }
    $script:AppSharedSecretVaultFallbackLogged[$Store] = $true
    $why = if ($script:AppSharedSecretVaultState.error) { $script:AppSharedSecretVaultState.error } else { 'not initialised' }
    Write-SidecarLog "Secret vault: $Store unavailable - vault $why"
}

function Get-AppVaultSecretInfo {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AppSharedSecretVaultReady)) { return $null }
    try {
        return (Get-SecretInfo -Name $Name -Vault $script:AppSharedSecretVaultName -ErrorAction SilentlyContinue | Select-Object -First 1)
    } catch { return $null }
}

function Test-AppVaultSecret {
    param([Parameter(Mandatory)][string]$Name)
    return ($null -ne (Get-AppVaultSecretInfo -Name $Name))
}

function Get-AppVaultCredential {
    # PSCredential or $null. Strings/SecureStrings stored under the name are wrapped
    # with an empty user name so callers always get the same shape back.
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AppSharedSecretVaultReady)) { return $null }
    try {
        $v = Get-Secret -Name $Name -Vault $script:AppSharedSecretVaultName -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -notmatch 'was not found') {
            Write-SidecarLog "Secret vault: read failed for '$Name' - $($_.Exception.Message)"
        }
        return $null
    }
    if ($null -eq $v) { return $null }
    if ($v -is [pscredential]) { return $v }
    if ($v -is [securestring]) { return (New-Object pscredential(' ', $v)) }
    if ($v -is [string]) { return (New-Object pscredential(' ', (ConvertTo-SecureString -String $v -AsPlainText -Force))) }
    return $null
}

function Get-AppVaultPlainSecret {
    param([Parameter(Mandatory)][string]$Name)
    $cred = Get-AppVaultCredential -Name $Name
    if (-not $cred -or -not $cred.Password) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-AppVaultSecretList {
    <#
    .SYNOPSIS
        Every secret in the shared vault: names and metadata only, never values.
        Used by the vault editor so a technician can see and manage what is stored
        without the app ever handing a secret back to the UI.
    #>
    if (-not (Test-AppSharedSecretVaultReady)) { return @() }
    $out = [System.Collections.Generic.List[hashtable]]::new()
    try {
        foreach ($info in @(Get-SecretInfo -Vault $script:AppSharedSecretVaultName -ErrorAction Stop)) {
            $meta = @{}
            try { if ($info.Metadata) { foreach ($k in $info.Metadata.Keys) { $meta[[string]$k] = [string]$info.Metadata[$k] } } } catch { }
            [void]$out.Add([ordered]@{
                name      = [string]$info.Name
                type      = [string]$info.Type
                updatedAt = [string]$meta['updatedAt']
                createdBy = [string]$meta['createdBy']
                note      = [string]$meta['note']
            })
        }
    } catch {
        Write-SidecarLog "Secret vault: listing failed - $($_.Exception.Message)"
        return @()
    }
    @($out | Sort-Object { [string]$_.name })
}

function Set-AppVaultSecret {
    # $true when written; $false when the vault is not ready. Throws only on a real
    # vault error.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Secret,
        [hashtable]$Metadata
    )
    if (-not (Test-AppSharedSecretVaultReady)) { return $false }
    $meta = @{ createdBy = (Get-AppProductSlug); updatedAt = [DateTime]::UtcNow.ToString('o') }
    if ($Metadata) { foreach ($k in $Metadata.Keys) { $meta[[string]$k] = $Metadata[$k] } }
    Set-Secret -Name $Name -Secret $Secret -Metadata $meta -Vault $script:AppSharedSecretVaultName -ErrorAction Stop
    return $true
}

function Remove-AppVaultSecret {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AppSharedSecretVaultReady)) { return $false }
    if (-not (Test-AppVaultSecret -Name $Name)) { return $false }
    Remove-Secret -Name $Name -Vault $script:AppSharedSecretVaultName -ErrorAction Stop
    return $true
}

# --- Cross-product names -------------------------------------------------------

function Get-AppVaultLocalMachineAdmin {
    <#
    .SYNOPSIS
        The workstation admin credential (macOS sudo elevation, SMB share auth).
    .DESCRIPTION
        Contract section 3 / USM's 2026-08-21 evening note: UserName IS the login
        (e.g. st00447), not a tag. USM owns writing it; we read it.
    #>
    return (Get-AppVaultCredential -Name $script:AppVaultNameLocalMachineAdmin)
}

function Get-AppVaultDeptCredential {
    <# The DE sign-in (contract section 3: dept/edu001). #>
    return (Get-AppVaultCredential -Name $script:AppVaultNameDeptEdu001)
}

function Set-AppVaultDeptCredential {
    <#
    .SYNOPSIS
        Write dept/edu001 from a sign-in in this product.
    .DESCRIPTION
        Contract section 5a (2026-08-21, night): any kit may write dept/edu001 at any
        time, with no knowledge of USM's paths. USM treats its DeptCredentials.xml as
        authoritative WHEN PRESENT and refreshes the vault from it on its next read,
        so this write is either adopted (USM has no file - promoted to the file for
        every downstream tool) or superseded (the file wins). Neither is harmful, so
        the old "do not write while the file exists" guard - which failed open on any
        path it did not know - is gone.

        Returns $true when written, $false when the vault is not ready.
    #>
    param([Parameter(Mandatory)][pscredential]$Credential)
    return (Set-AppVaultSecret -Name $script:AppVaultNameDeptEdu001 -Secret $Credential -Metadata @{ label = 'DE sign-in' })
}
