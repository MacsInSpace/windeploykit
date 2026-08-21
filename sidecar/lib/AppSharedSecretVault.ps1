# Shared secret vault - WinDeployKit's registration of SecretManagement.LocalVault.
#
# docs/handover/SHARED_SECRET_VAULT_CONTRACT.md: one per-user store shared by every
# product (USM, WinDeployKit, PSOpenAD-FE), the SecretManagement API in front of it,
# and no OS credential UI behind it. This file is the WinDeployKit glue only: find
# the vendored API module, import the first-party vault, register it under the
# contract's single vault name. The vault module itself is product-neutral and is
# vendored byte-identical from USM at sidecar/psmodules/SecretManagement.LocalVault.
#
# Layout the resolvers expect:
#   bundle : <ProjectRoot>/modules/Microsoft.PowerShell.SecretManagement/<ver>/
#   dev    : <ProjectRoot>/vendor/psmodules/Microsoft.PowerShell.SecretManagement/<ver>/
#   both   : <ProjectRoot>/sidecar/psmodules/SecretManagement.LocalVault/
#
# Startup must NEVER fail on this. If the vault cannot be registered, credential
# features degrade and the status handler says why. Nothing here prompts, nothing
# here resets - there is no reset concept in this vault (contract section 4a
# withdrew the SecretStore bootstrap that had one).

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

function Get-AppSecretManagementManifestPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $name = 'Microsoft.PowerShell.SecretManagement'
    foreach ($root in @(
        (Join-Path $ProjectRoot "modules/$name"),
        (Join-Path $ProjectRoot "vendor/psmodules/$name")
    )) {
        $manifest = Get-AppPowerShellModuleManifestPath -ModuleRoot $root -ModuleName $name
        if ($manifest) { return $manifest }
    }
    return $null
}

function Get-AppLocalVaultManifestPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = Join-Path $ProjectRoot 'sidecar/psmodules/SecretManagement.LocalVault/SecretManagement.LocalVault.psd1'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
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
            throw 'SecretManagement.LocalVault module missing under sidecar/psmodules.'
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
            $what = if ($info.registered) { 'registered' } else { 'already registered' }
            $had = if ($info.exists) { "$($info.secretCount) secret(s)" } else { 'no store yet (created on first write)' }
            Write-SidecarLog "Secret vault: '$($info.vault)' $what from $lvManifest; $had at $($info.storeRoot)"
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

function Set-AppVaultSecret {
    # $true when written; $false when the vault is not ready. Throws only on a real
    # vault error.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Secret,
        [hashtable]$Metadata
    )
    if (-not (Test-AppSharedSecretVaultReady)) { return $false }
    $meta = @{ createdBy = 'windeploykit'; updatedAt = [DateTime]::UtcNow.ToString('o') }
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
    <# The DE sign-in. Read-only from here - see Set-AppVaultDeptCredentialIfAbsent. #>
    return (Get-AppVaultCredential -Name $script:AppVaultNameDeptEdu001)
}

function Set-AppVaultDeptCredentialIfAbsent {
    <#
    .SYNOPSIS
        Write dept/edu001 ONLY when USM holds no legacy DeptCredentials.xml.
    .DESCRIPTION
        USM's evening note: the legacy file is the source of truth while
        Set-DeptCreds-era tools exist, and USM refreshes the vault from it. Writing
        over that would be pointless - USM's copy wins on its next read. But when no
        file exists, a sign-in here IS adopted and promoted to the file by USM, so a
        sign-in in this product does reach USM.

        Returns $true only when we actually wrote.
    #>
    param([Parameter(Mandatory)][pscredential]$Credential)
    if (-not (Test-AppSharedSecretVaultReady)) { return $false }
    if (Test-AppVaultDeptLegacyFilePresent) {
        Write-SidecarLog "Secret vault: not writing '$script:AppVaultNameDeptEdu001' - USM's legacy file is the source of truth"
        return $false
    }
    return (Set-AppVaultSecret -Name $script:AppVaultNameDeptEdu001 -Secret $Credential -Metadata @{ label = 'DE sign-in' })
}

function Test-AppVaultDeptLegacyFilePresent {
    <#
        USM keeps DeptCredentials.xml under a shared DECreds folder that several
        first-party tools read. We only need to know whether it EXISTS, never to
        read it - reading is USM's job.
    #>
    $candidates = @()
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }
        $candidates += (Join-Path $base 'DECreds/DeptCredentials.xml')
    } else {
        $candidates += (Join-Path $HOME 'Library/Application Support/DECreds/DeptCredentials.xml')
        $candidates += (Join-Path $HOME '.local/share/DECreds/DeptCredentials.xml')
    }
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $true }
    }
    return $false
}
