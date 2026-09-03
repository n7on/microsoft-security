@{
    RootModule        = 'Msec.psm1'
    ModuleVersion     = '0.1.1'
    GUID              = '5a8c1f2b-9d4e-4b7c-8a3f-1e6d2b9c4a7f'
    Author            = 'Anton Lindstrom'
    Copyright         = '(c) 2026 Anton Lindström. Licensed under the MIT License.'
    # Shown at the top of the Gallery listing, so it names every area the module covers.
    # Kept in step with the first paragraph of README.md.
    Description       = 'Read Microsoft security posture - Secure Score, Defender XDR, Entra ID (directory roles, Conditional Access, MFA, licensing), Intune, Azure and Azure DevOps - as flat PowerShell objects you can filter, group and export. Read-only by design: every Get-Msec* command reads, and nothing writes to a tenant except New-MsecApp, which creates its own app registration. Authentication is certificate-based via that app registration, and the private key never leaves Azure Key Vault - signing happens there.'
    PowerShellVersion = '7.0'

    # Az.Accounts: the user logs into Azure (their own identity) to reach Key Vault and is used for
    #   the bootstrap Graph token in New-MsecApp.
    # Az.KeyVault: fetch the certificate (public + private key) used for client-credentials auth.
    # No Microsoft.Graph.*, no MSAL.PS: token acquisition is a JWT client assertion signed locally
    # by the cert, and all API calls go through Invoke-RestMethod.
    # Az.OperationalInsights: Search-MsecLogAnalytics runs the bundled Kql/Law queries. It also
    #   leans on Az.ResourceGraph to resolve a workspace NAME to its customerId across every
    #   accessible subscription, which is why that dependency is not Resource-Graph-only.
    RequiredModules   = @(
        'Az.Accounts',
        'Az.KeyVault',
        'Az.Compute',
        'Az.ResourceGraph',
        'Az.OperationalInsights'
    )

    # Table views for the types whose columns are collections - a DefaultDisplayPropertySet
    # can pick columns but not render them, so a string[] would print as '{a, b}'.
    #
    # Belt and braces: Msec.psm1 loads this itself with Update-FormatData, because the test
    # suite imports the .psm1 directly and would skip a manifest key entirely. Declaring it
    # here as well is what a consumer who does `Import-Module Msec` by name gets, and the
    # double load is harmless - the second registration replaces the first for the same
    # type names.
    FormatsToProcess  = 'Msec.format.ps1xml'

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
        'Get-MsecIntuneScriptResult',
        'Get-MsecEntraConditionalAccessPolicy',
        'Get-MsecEntraConditionalAccessSignInLog',
        'Get-MsecEntraConditionalAccessStats',
        'Get-MsecEntraTenantSecuritySetting',
        'Get-MsecEntraLicense',
        'Get-MsecEntraRoleHolder',
        'Get-MsecEntraAppCredential',
        'Get-MsecEntraMfaRegistration',
        'Get-MsecEntraMfaEvidence',
        'Get-MsecEntraMfaRegistrationStats',
        'Get-MsecEntraDisabledUser',
        'Convert-MsecEntraSid',
        'Search-MsecAzureResourceGraph',
        'Search-MsecLogAnalytics',
        'Invoke-MsecAzureVMScript',
        'Select-MsecAzureContext',
        'Get-MsecAdoServiceConnection',
        'Export-MsecPostureReport',
        'Export-MsecVMUpdateReport',
        'Export-MsecVMNtpReport',
        'Export-MsecEntraDisabledUserReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            # Tags are how anyone finds this on the Gallery, so they name the products the
            # module actually reads rather than only the abstract category.
            Tags = @(
                'MicrosoftSecurity', 'Security', 'SecureScore', 'Defender', 'DefenderXDR',
                'ExposureManagement', 'Entra', 'EntraID', 'AzureAD', 'ConditionalAccess',
                'MFA', 'PIM', 'PrivilegedAccess', 'Intune', 'MDM', 'Compliance', 'Azure',
                'KeyVault', 'Graph', 'Audit', 'Posture', 'CrossPlatform', 'Windows',
                'Linux', 'macOS'
            )

            LicenseUri = 'https://github.com/n7on/microsoft-security/blob/main/LICENSE'
            ProjectUri = 'https://github.com/n7on/microsoft-security'

            ReleaseNotes = @'
v0.1.0
- First release. Read-only Microsoft security posture as flat objects: Secure Score,
  Defender XDR, Entra ID (roles, Conditional Access, MFA, licensing), Intune and Azure.
- Certificate-based auth against an app registration; the private key stays in Azure
  Key Vault and signing happens there.

See CHANGELOG.md for full version history.
'@
        }
    }
}
