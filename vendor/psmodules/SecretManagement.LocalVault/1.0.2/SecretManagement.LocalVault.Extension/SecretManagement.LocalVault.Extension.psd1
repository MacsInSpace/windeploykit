@{
    RootModule        = 'SecretManagement.LocalVault.Extension.psm1'
    ModuleVersion     = '1.0.2'
    GUID              = '3f6c1a0e-5b7d-4c2a-9e8f-1d2c3b4a5f60'
    Author            = 'Craig Hair'
    Description       = 'SecretManagement extension vault implementation for SecretManagement.LocalVault.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-Secret', 'Set-Secret', 'Set-SecretInfo', 'Remove-Secret', 'Get-SecretInfo', 'Test-SecretVault')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
