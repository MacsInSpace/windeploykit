@{
    RootModule        = 'SecretManagement.LocalVault.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b2e4d6f8-0a1c-4e3b-8d5f-7a9c1e2b3d40'
    Author            = 'Craig Hair'
    Description       = 'File-based, machine-bound SecretManagement extension vault with no OS credential UI (no Keychain, no Credential Manager). DPAPI on Windows; AES-256-GCM under a machine+user-derived key on macOS/Linux.'
    PowerShellVersion = '5.1'
    NestedModules     = @('./SecretManagement.LocalVault.Extension/SecretManagement.LocalVault.Extension.psd1')
    RequiredModules   = @(@{ ModuleName = 'Microsoft.PowerShell.SecretManagement'; ModuleVersion = '1.1.2' })
    FunctionsToExport = @('Register-LocalVault', 'Get-LocalVaultInfo', 'Get-LocalVaultMachineBoundKey')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('SecretManagement', 'SecretVault', 'Vault'); LicenseUri = 'https://opensource.org/licenses/MIT' } }
}
