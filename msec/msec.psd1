@{
    RootModule        = 'msec.psm1'
    ModuleVersion     = '0.4.0'
    GUID              = '5a8c1f2b-9d4e-4b7c-8a3f-1e6d2b9c4a7f'
    Author            = 'Anton Lindstrom'
    Copyright         = '(c) 2026 Anton Lindström. Licensed under the MIT License.'
    # Shown at the top of the Gallery listing, so it names every area the module covers.
    # Kept in step with the first paragraph of README.md.
    Description       = 'Read Microsoft security posture - Secure Score, Defender XDR, Entra ID (directory roles, Conditional Access, MFA, licensing), Intune, Exchange Online, SharePoint Online, Microsoft Teams, Azure and Azure DevOps - as flat PowerShell objects you can filter, group and export. Read-only by default: every Get-Msec* command reads, and the app registration is consented read permissions only, so the certificate cannot change your tenant. Commands that write run as the signed-in user via Connect-MsecAdmin, never as the app - currently Set-MsecDefenderAlert. New-MsecApp creates that app registration and grants it read permissions - and, when asked with -Workload Exchange or Teams, assigns it a directory role, which those services require and which is a tenant-wide privilege grant rather than an API permission. Authentication is certificate-based via that app registration, and the private key never leaves Azure Key Vault - signing happens there, so no key material reaches the machine running the module.'
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
    FormatsToProcess  = 'msec.format.ps1xml'

    FunctionsToExport = @(
        'New-MsecApp',
        'Grant-MsecAzureDevOpsPermission',
        'Connect-Msec',
        'Disconnect-Msec',
        'Connect-MsecAdmin',
        'Connect-MsecGraphSdk',
        'Connect-MsecExchangeOnline',
        'Connect-MsecSharePointOnline',
        'Connect-MsecTeams',
        'Connect-MsecPurview',
        'Get-MsecPurviewDlpPolicy',
        'Get-MsecPurviewSensitivityLabel',
        'Get-MsecPurviewRetention',
        'Get-MsecPurviewAutoLabelingPolicy',
        'Get-MsecPurviewInformationBarrier',
        'Get-MsecPurviewAlertPolicy',
        'Get-MsecPowerPlatformEnvironment',
        'Get-MsecSecureScore',
        'Get-MsecAzureCost',
        'Get-MsecAzureRoleAssignment',
        'Get-MsecAzureSecureScore',
        'Get-MsecSentinelRule',
        'Get-MsecAzureDomainService',
        'Get-MsecDefenderScoreExposure',
        'Get-MsecDefenderScoreDeviceConfiguration',
        'Get-MsecDefenderAlert',
        'Get-MsecDefenderIncident',
        'Get-MsecDefenderDevice',
        'Get-MsecDefenderEmailStats',
        'Get-MsecDefenderIncidentStats',
        'Set-MsecDefenderAlert',
        'Set-MsecDefenderIncident',
        'Get-MsecKeyVaultCertificate',
        'Get-MsecIntuneConfigurationProfile',
        'Get-MsecIntuneCompliancePolicy',
        'Get-MsecIntuneDevice',
        'Get-MsecIntuneScriptResult',
        'Get-MsecEntraConditionalAccessPolicy',
        'Get-MsecEntraConditionalAccessSignInLog',
        'Get-MsecEntraConditionalAccessStats',
        'Get-MsecEntraTenantSecuritySetting',
        'Get-MsecExchangeMailbox',
        'Get-MsecExchangeOrganizationSetting',
        'Get-MsecExchangeTransportRule',
        'Get-MsecDefenderOfficePolicy',
        'Get-MsecExchangeMailboxPermission',
        'Get-MsecExchangeInboxRule',
        'Get-MsecSharePointSite',
        'Get-MsecTeamsPolicy',
        'Get-MsecTeamsPolicyAssignment',
        'Get-MsecSharePointSiteUser',
        'Get-MsecSharePointTenantSetting',
        'Get-MsecEntraGroupMember',
        'Get-MsecEntraLicense',
        'Get-MsecEntraRoleHolder',
        'Get-MsecEntraPimPolicy',
        'Get-MsecEntraAppCredential',
        'Get-MsecEntraAppConsent',
        'Get-MsecEntraMfaRegistration',
        'Get-MsecEntraMfaEvidence',
        'Get-MsecEntraMfaRegistrationStats',
        'Get-MsecEntraDisabledUser',
        'Convert-MsecEntraSid',
        'Search-MsecAzureResourceGraph',
        'Search-MsecLogAnalytics',
        'Search-MsecDefenderHunting',
        'Invoke-MsecAzureVMScript',
        'Select-MsecAzureContext',
        'Get-MsecAzureDevOpsOrganization',
        'Get-MsecAzureDevOpsOrganizationPolicy',
        'Get-MsecAzureDevOpsAlert',
        'Get-MsecAzureDevOpsAgentPool',
        'Get-MsecAzureDevOpsEnvironment',
        'Get-MsecAzureDevOpsExtension',
        'Get-MsecAzureDevOpsPipelineSetting',
        'Get-MsecAzureDevOpsRepository',
        'Get-MsecAzureDevOpsSecureFile',
        'Get-MsecAzureDevOpsServiceConnection',
        'Get-MsecAzureDevOpsUser',
        'Get-MsecAzureDevOpsWorkItem',
        'Get-MsecAzureDevOpsVariableGroup',
        'Export-MsecAzureDevOpsReport',
        'Export-MsecPostureReport',
        'Export-MsecVMUpdateReport',
        'Export-MsecVMNtpReport',
        'Export-MsecEntraDisabledUserReport',
        'Export-MsecDefenderDeviceReport',
        'Export-MsecEntraGroupMemberReport'
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
                'ExchangeOnline', 'SharePointOnline', 'MicrosoftTeams', 'Teams', 'Microsoft365',
                'KeyVault', 'Graph', 'Audit', 'Posture', 'CrossPlatform', 'Windows',
                'Linux', 'macOS'
            )

            LicenseUri = 'https://github.com/n7on/microsoft-security/blob/main/LICENSE'
            ProjectUri = 'https://github.com/n7on/microsoft-security'

            ReleaseNotes = @'
v0.4.0
- Microsoft Purview: Connect-MsecPurview plus Get-MsecPurviewDlpPolicy,
  Get-MsecPurviewSensitivityLabel, Get-MsecPurviewRetention, Get-MsecPurviewAutoLabelingPolicy,
  Get-MsecPurviewInformationBarrier and Get-MsecPurviewAlertPolicy. No new consent needed - the
  existing Key Vault certificate reaches Security & Compliance PowerShell. Rows separate what is
  CONFIGURED from what is IN FORCE, because a disabled DLP policy, an unpublished retention
  label and a label whose encryption is switched off all look healthy in a policy list.
- Search-MsecDefenderHunting: advanced hunting KQL against the Defender XDR event store, with
  nine bundled queries under kql/Hunting. The .kql files carry no time filter - the window is
  the API's own timespan parameter. A table belonging to an un-onboarded product fails to
  resolve rather than returning zero rows, and the error says so.
- FIRST WRITE COMMANDS: Connect-MsecAdmin establishes a delegated, interactive session, and
  Set-MsecDefenderAlert / Set-MsecDefenderIncident use it. The app registration still holds only
  *.Read.All, so the certificate cannot change anything - writes run as a named person, subject
  to Conditional Access and bounded by that person's own RBAC. Both re-read after writing and
  report the OBSERVED state, polling briefly because XDR settles asynchronously.
- Grant-MsecAzureDevOpsPermission replaces tools/Grant-MsecAzureDevOpsPermission.ps1, which was
  referenced by four help texts and never shipped with the module. It no longer needs a personal
  access token - the namespace, ACL and identity APIs all accept an ordinary Entra token - and
  -Apply is replaced by -WhatIf / -Confirm.
- Get-MsecIntuneCompliancePolicy now reports OsMinimumVersion, ConfiguredCheckCount and
  ChecksNothing. A policy with no settings configured reports every device compliant because
  there is nothing to fail, and was previously indistinguishable from a healthy one.
- Get-MsecIntuneDevice now reports EnrollmentType and IsAutomatedEnrollment. An Apple device
  enrolled manually has a management profile the user can remove; one enrolled through Automated
  Device Enrollment does not. IsAutomatedEnrollment is $null on Windows, where the enum cannot
  tell Autopilot from a manual Entra join.
- Get-MsecDefenderAlert and Get-MsecDefenderIncident: row-level Defender XDR, with redirected
  incidents visible and droppable rather than silently double-counted.
- Get-MsecAzureDomainService, plus KQL for Entra Domain Services sign-ins, Azure resource change
  history and SQL Server posture.
- "Read-only by design" is now stated accurately: the app registration holds read permissions
  only, and the commands that write do so as the signed-in user.

v0.3.0
- Microsoft Teams: Connect-MsecTeams and Get-MsecTeamsPolicy - external access and federation,
  guest access, meeting lobby and anonymous join, recording, app installation, and file sharing
  in chats with external users. One row per SETTING, so policies diff between tenants.
- SharePoint: Get-MsecSharePointTenantSetting reads the tenant-wide sharing posture that no
  per-site review can show - sharing capability, domain allow/block lists, legacy auth.
- Azure DevOps: Get-MsecAzureDevOpsUser (users and their group memberships, paginated) and
  Get-MsecAzureDevOpsOrganizationPolicy (guest access, third-party OAuth, SSH, public projects).
- Connect-MsecTeams -AsCurrentUser borrows the Azure session, because the Teams module cannot
  sign in interactively off Windows and Conditional Access refuses device code flow.
- New-MsecApp: -Workload Teams, and -ExchangeDirectoryRole is now -DirectoryRole (the old name
  still works). -Workload SharePoint also grants SharePointTenantSettings.Read.All.
- Azure RBAC: Get-MsecAzureRoleAssignment across every subscription, with role and principal
  names resolved and deleted principals kept rather than dropped.
- FIXED ON LINUX: the module folder and manifest are lowercase, matching the Gallery id. Before
  this, Install-Module created msec/<version>/Msec.psd1 and Import-Module failed on Linux with
  "no valid module file was found in any module directory" - a module that installed fine and
  could not be loaded. macOS and Windows were unaffected.
- The Azure DevOps commands are now named Get-MsecAzureDevOps* rather than Get-MsecAdo*.
  Get-MsecAdoServiceConnection from 0.2.0 is renamed; there is no alias.

v0.2.0
- Exchange Online and SharePoint Online: mailbox permissions, site inventory, and site
  owners/members with security groups expanded to the people inside them.
- Bridges that let the Microsoft.Graph SDK, ExchangeOnlineManagement and PnP.PowerShell
  run as the msec app without the certificate's private key reaching the machine.
- Azure: unused resources, network exposure across twelve resource types, Key Vault
  certificate expiry, Cost Management, App Service inventory and stack settings.
- Entra: group members (nested groups expanded, PIM-eligible included), app registration
  and service principal credential expiry.
- Defender: device inventory with per-device vulnerability counts.
- Evidence reports for Defender devices and Entra group membership; the posture report
  gained privileged access, device platform and OS release measurements.
- New-MsecApp -Workload Exchange, SharePoint grants those workloads' permissions. Exchange
  additionally needs a DIRECTORY ROLE - an app role alone is not enough, and without one
  every Exchange call fails with an authorisation error that names nothing.

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
