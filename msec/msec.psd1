@{
    RootModule        = 'msec.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5a8c1f2b-9d4e-4b7c-8a3f-1e6d2b9c4a7f'
    Author            = 'Anton Lindstrom'
    CompanyName       = 'Viedoc'
    Copyright         = '(c) Viedoc. All rights reserved.'
    Description       = 'Microsoft Security (msec): one PowerShell module for Microsoft Secure Score, Defender XDR exposure / device-configuration scores, and a combined posture-report summary. Authentication is certificate-based via an app registration; the certificate lives in Azure Key Vault.'
    PowerShellVersion = '7.0'

    # Az.Accounts: the user logs into Azure (their own identity) to reach Key Vault and is used for
    #   the bootstrap Graph token in New-MsecApp.
    # Az.KeyVault: fetch the certificate (public + private key) used for client-credentials auth.
    # No Microsoft.Graph.*, no MSAL.PS: token acquisition is a JWT client assertion signed locally
    # by the cert, and all API calls go through Invoke-RestMethod.
    RequiredModules   = @(
        'Az.Accounts',
        'Az.KeyVault',
        'Az.Compute',
        'Az.ResourceGraph'
    )

    FunctionsToExport = @(
        'New-MsecApp',
        'Connect-Msec',
        'Disconnect-Msec',
        'Get-MsecSecureScore',
        'Get-MsecAzureSecureScore',
        'Get-MsecDefenderScoreExposure',
        'Get-MsecDefenderScoreDeviceConfiguration',
        'Get-MsecDefenderEmailStats',
        'Get-MsecDefenderIncidentStats',
        'Get-MsecIntuneConfigurationProfile',
        'Get-MsecIntuneCompliancePolicy',
        'Get-MsecIntuneDevice',
        'Get-MsecEntraConditionalAccessPolicy',
        'Get-MsecEntraConditionalAccessSignInLog',
        'Get-MsecEntraConditionalAccessStats',
        'Search-MsecAzureResourceGraph',
        'Invoke-MsecAzureVMScript',
        'Select-MsecAzureContext',
        'Get-MsecAdoServiceConnection',
        'Export-MsecWordReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('MicrosoftSecurity', 'SecureScore', 'XDR', 'Defender', 'ExposureManagement', 'KeyVault')
        }
    }
}
