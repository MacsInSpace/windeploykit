# SecretManagement.LocalVault.Extension - the five functions SecretManagement calls.
# Loaded by SecretManagement itself (NestedModules of the outer manifest); must be
# self-contained, hence the dot-source of the shared core.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'LocalVault.Core.ps1')

function Get-Secret {
    [CmdletBinding()]
    param([string]$Name, [string]$VaultName, [hashtable]$AdditionalParameters)
    return Get-LocalVaultSecretValue -Name $Name -AdditionalParameters $AdditionalParameters
}

function Set-Secret {
    [CmdletBinding()]
    param([string]$Name, [object]$Secret, [string]$VaultName, [hashtable]$AdditionalParameters)
    return Set-LocalVaultSecretValue -Name $Name -Secret $Secret -AdditionalParameters $AdditionalParameters
}

function Set-SecretInfo {
    [CmdletBinding()]
    param([string]$Name, [hashtable]$Metadata, [string]$VaultName, [hashtable]$AdditionalParameters)
    Set-LocalVaultSecretMetadata -Name $Name -Metadata $Metadata -AdditionalParameters $AdditionalParameters
}

function Remove-Secret {
    [CmdletBinding()]
    param([string]$Name, [string]$VaultName, [hashtable]$AdditionalParameters)
    return Remove-LocalVaultSecretValue -Name $Name -AdditionalParameters $AdditionalParameters
}

function Get-SecretInfo {
    [CmdletBinding()]
    param([string]$Filter, [string]$VaultName, [hashtable]$AdditionalParameters)
    return Get-LocalVaultSecretInfoList -Filter $Filter -VaultName $VaultName -AdditionalParameters $AdditionalParameters
}

function Test-SecretVault {
    [CmdletBinding()]
    param([string]$VaultName, [hashtable]$AdditionalParameters)
    try {
        return Test-LocalVaultStore -AdditionalParameters $AdditionalParameters
    } catch {
        Write-Error -Message $_.Exception.Message
        return $false
    }
}

Export-ModuleMember -Function Get-Secret, Set-Secret, Set-SecretInfo, Remove-Secret, Get-SecretInfo, Test-SecretVault
