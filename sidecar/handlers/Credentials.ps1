# Sidecar IPC handlers -- Credentials
#
# These seven commands were declared in app/src/lib/types.ts and invoked by
# InfrastructureCredentialsOverlay.tsx, but no handler existed - every action in
# that dialog failed. They are backed by the shared secret vault
# (docs/handover/SHARED_SECRET_VAULT_CONTRACT.md): device credentials under
# netboot/join/<id>, the workstation admin under local-machine/admin.
#
# EVERY handler works with the vault unavailable. The store libs fall back to the
# legacy Clixml files, so a vault problem degrades to yesterday's behaviour and
# never locks a technician out. GetSecretVaultStatus is how the UI explains a
# degraded state - in particular keyMatches = false, which means the store was
# created on another machine and the answer is "sign in again", not "corrupt".
#
# Functions only -- no top-level code. Dispatch resolves Handle-$Cmd by name.

function Handle-ListInfraSshCredentials {
    param([int]$Id, $Params)
    $siteId = [string](Get-AppSidecarParam -Params $Params -Name 'siteId')
    $creds = @(Get-AppInfraSshCredentials -SiteId $siteId)
    Write-SidecarResponse -Id $Id -Data @{
        credentials = $creds
        vault       = Get-AppSharedSecretVaultStatus
    }
}

function Handle-SetInfraSshCredential {
    param([int]$Id, $Params)
    $label = [string](Get-AppSidecarParam -Params $Params -Name 'label')
    if ([string]::IsNullOrWhiteSpace($label)) { throw 'label is required.' }
    $saved = Save-AppInfraSshCredential `
        -Id ([string](Get-AppSidecarParam -Params $Params -Name 'id')) `
        -SiteId ([string](Get-AppSidecarParam -Params $Params -Name 'siteId')) `
        -Label $label `
        -PlainPassword ([string](Get-AppSidecarParam -Params $Params -Name 'password')) `
        -LoginName ([string](Get-AppSidecarParam -Params $Params -Name 'loginName'))
    Write-SidecarResponse -Id $Id -Data @{
        credential = $saved
        vault      = Get-AppSharedSecretVaultStatus
    }
}

function Handle-ClearInfraSshCredentialPassword {
    param([int]$Id, $Params)
    $credId = [string](Get-AppSidecarParam -Params $Params -Name 'id')
    if ([string]::IsNullOrWhiteSpace($credId)) { throw 'id is required.' }
    Clear-AppInfraSshCredentialPassword -Id $credId
    Write-SidecarResponse -Id $Id -Data @{ cleared = $true; id = $credId }
}

function Handle-DeleteInfraSshCredential {
    param([int]$Id, $Params)
    $credId = [string](Get-AppSidecarParam -Params $Params -Name 'id')
    if ([string]::IsNullOrWhiteSpace($credId)) { throw 'id is required.' }
    Remove-AppInfraSshCredential -Id $credId
    Write-SidecarResponse -Id $Id -Data @{ removed = $true; id = $credId }
}

function Handle-GetLocalMachineCredential {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data (Get-AppLocalMachineCredentialStatus)
}

function Handle-SetLocalMachineCredential {
    param([int]$Id, $Params)
    $login = [string](Get-AppSidecarParam -Params $Params -Name 'loginName')
    if ([string]::IsNullOrWhiteSpace($login)) { throw 'loginName is required.' }
    $status = Save-AppLocalMachineCredential `
        -LoginName $login `
        -PlainPassword ([string](Get-AppSidecarParam -Params $Params -Name 'password'))
    Write-SidecarResponse -Id $Id -Data $status
}

function Handle-ClearLocalMachineCredentialPassword {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data (Clear-AppLocalMachineCredentialPassword)
}

function Handle-GetSecretVaultStatus {
    <# Status only - never returns secret material. #>
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data (Get-AppSharedSecretVaultStatus)
}

function Handle-PrefetchMacOsAdminCredential {
    <#
    .SYNOPSIS
        Warm the macOS administrator credential before a step that needs sudo.
    .NOTES
        The panel calls this before starting Netboot services so the password
        dialog (or the vault read) happens up front rather than mid-start. It was
        missing here, so every service start answered "Unknown command" and the
        credential ladder never got its head start (field, 2026-08-22).
    #>
    param([int]$Id, $Params)
    $purpose = Get-AppSidecarParam -Params $Params -Name 'purpose'
    if ([string]::IsNullOrWhiteSpace($purpose)) { $purpose = 'pxe' }
    if ($purpose -notin @('pxe', 'general')) { $purpose = 'pxe' }
    $started = $false
    if (Get-Command Start-AppMacOsAdminCredentialPrefetch -ErrorAction SilentlyContinue) {
        $state = Start-AppMacOsAdminCredentialPrefetch -Purpose $purpose
        $started = ($null -ne $state)
    }
    $cache = if (Get-Command Get-AppMacOsAdminCredentialCacheStatus -ErrorAction SilentlyContinue) {
        Get-AppMacOsAdminCredentialCacheStatus
    } else {
        @{ cached = $false }
    }
    Write-SidecarResponse -Id $Id -Data @{
        started       = $started
        cached        = [bool]$cache.cached
        username      = $cache.username
        # The saved credential was refused by sudo this session; the dialog is being used.
        savedRejected = [bool]$cache.savedRejected
    }
}

function Handle-GetMacOsAdminCredentialCacheStatus {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data (Get-AppMacOsAdminCredentialCacheStatus)
}

function Handle-ClearMacOsAdminCredentialCache {
    param([int]$Id, $Params)
    Clear-AppMacOsAdminCredentialCache
    Write-SidecarResponse -Id $Id -Data (Get-AppMacOsAdminCredentialCacheStatus)
}

# --- Vault editor -------------------------------------------------------------
# The UI can list, write and delete secrets, but can never READ one back: a value
# leaves the sidecar only when a publish step needs it. That is what keeps "from the
# vault" meaningfully different from typing a password into a sequence.

function Handle-ListVaultSecrets {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data @{
        vault   = (Get-AppSharedSecretVaultStatus)
        secrets = @(Get-AppVaultSecretList)
    }
}

function Handle-SetVaultSecret {
    <#
    .SYNOPSIS
        Store a credential (or, for internal callers, a bare secret) in the shared vault.
    .NOTES
        The UI asks for Label / Full name / Username / Password (Craig, 2026-08-23:
        "Name v Username are confusing... 'Value' means nothing and wheres the password
        field?"). The storage key is DERIVED from the label so nobody has to invent one,
        and the label is what every picker shows - the key is plumbing.
    #>
    param([int]$Id, $Params)
    $label = ([string](Get-AppSidecarParam -Params $Params -Name 'label')).Trim()
    $name = ([string](Get-AppSidecarParam -Params $Params -Name 'name')).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        # Derive a storage key from the label: lower case, non-word runs to a dash.
        if ([string]::IsNullOrWhiteSpace($label)) { throw 'SetVaultSecret: a label is required.' }
        $slug = ($label.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if ($slug.Length -gt 96) { $slug = $slug.Substring(0, 96).Trim('-') }
        if ([string]::IsNullOrWhiteSpace($slug)) { throw 'SetVaultSecret: that label has no letters or numbers in it.' }
        $name = $slug
        # Do not silently overwrite a different credential that happens to slug the same.
        $existingNames = @(Get-AppVaultSecretList | ForEach-Object { [string]$_.name })
        if ($existingNames -contains $name) {
            $n = 2
            while ($existingNames -contains "$name-$n") { $n++ }
            $name = "$name-$n"
        }
    }
    if ($name -notmatch '^[A-Za-z0-9._-]{1,128}$') {
        throw 'SetVaultSecret: use letters, numbers, dot, dash or underscore (max 128).'
    }
    $secret = [string](Get-AppSidecarParam -Params $Params -Name 'secret')
    if ([string]::IsNullOrEmpty($secret)) { throw 'SetVaultSecret: a password is required.' }
    $userName = ([string](Get-AppSidecarParam -Params $Params -Name 'userName')).Trim()
    if ($userName -match '\s') { throw 'SetVaultSecret: a user name cannot contain spaces.' }
    $fullName = ([string](Get-AppSidecarParam -Params $Params -Name 'fullName')).Trim()

    # A user name makes it a PSCredential (both halves), which is what a domain join and
    # a local account need. Without one it is a bare secret - still supported for
    # internal callers, but the editor always sends a user name.
    $value = if ($userName) {
        New-Object pscredential($userName, (ConvertTo-SecureString -String $secret -AsPlainText -Force))
    } else {
        ConvertTo-SecureString -String $secret -AsPlainText -Force
    }
    $meta = @{}
    if ($label) { $meta['label'] = $label }
    if ($fullName) { $meta['fullName'] = $fullName }
    if ($userName) { $meta['userName'] = $userName }
    $written = Set-AppVaultSecret -Name $name -Secret $value -Metadata $meta
    if (-not $written) { throw 'SetVaultSecret: the secret vault is not available.' }
    Write-SidecarLog "Secret vault: wrote '$name'$(if ($userName) { " (credential for $userName)" })"
    Write-SidecarResponse -Id $Id -Data @{
        saved   = $true
        vault   = (Get-AppSharedSecretVaultStatus)
        secrets = @(Get-AppVaultSecretList)
    }
}

function Handle-RemoveVaultSecret {
    param([int]$Id, $Params)
    $name = ([string](Get-AppSidecarParam -Params $Params -Name 'name')).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'RemoveVaultSecret: name required.' }
    $removed = Remove-AppVaultSecret -Name $name
    if ($removed) { Write-SidecarLog "Secret vault: removed '$name'" }
    Write-SidecarResponse -Id $Id -Data @{
        removed = [bool]$removed
        vault   = (Get-AppSharedSecretVaultStatus)
        secrets = @(Get-AppVaultSecretList)
    }
}
