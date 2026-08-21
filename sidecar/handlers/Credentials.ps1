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
