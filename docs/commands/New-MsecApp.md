---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# New-MsecApp

## SYNOPSIS
Sets up (or updates) the msec app registration: app + service principal + certificate
in Key Vault + admin consent.
Safe to re-run.

## SYNTAX

```
New-MsecApp [[-DisplayName] <String>] [-KeyVaultName] <String> [[-CertificateName] <String>]
 [[-ValidityMonths] <Int32>] [[-Workload] <String[]>] [[-DirectoryRole] <String>] [<CommonParameters>]
```

## DESCRIPTION
Idempotent.
Re-run this whenever permissions change (e.g.
when msec adds a new
Graph scope) and it will *adjust* the existing app rather than creating a duplicate.
Concretely each step is find-or-create / merge-don't-clobber:

  1.
Verifies an Azure context (Connect-AzAccount must have been run first).
  2.
Acquires a Microsoft Graph access token for *the user* via Az.Accounts and uses
     it for all Graph create/consent calls (we cannot use the app's own token here -
     the app may not exist yet).
  3.
Resolves the Graph and Defender resource service principals + the app role IDs
     for every required permission, by name (no hardcoded role GUIDs).
  4.
Finds an app registration by displayName, or creates one if missing.
  5.
PATCHes requiredResourceAccess - existing entries for unrelated resources are
     preserved; for Graph / WindowsDefenderATP, missing role IDs are added.
  6.
Finds or creates the matching service principal.
  7.
Finds or issues the self-signed certificate inside the named Key Vault.
  8.
Stamps the cert with AppId / TenantId tags (overwrites - idempotent).
  9.
Attaches the cert to the app only if a credential with that thumbprint is not
     already present.
 10.
Grants admin consent by creating appRoleAssignments - only for (resource, role)
     pairs not already assigned.
 11.
Returns an object with TenantId, ClientId, KeyVaultName, CertificateName.

Current required permissions (configured at the top of the function in $resources):
  - Microsoft Graph: SecurityEvents.Read.All, DeviceManagementConfiguration.Read.All,
                     DeviceManagementManagedDevices.Read.All, DeviceManagementScripts.Read.All,
                     ThreatHunting.Read.All,
                     SecurityIncident.Read.All, Policy.Read.All, AuditLog.Read.All,
                     Organization.Read.All, RoleManagement.Read.Directory,
                     User.Read.All, Group.Read.All, Application.Read.All,
                     PrivilegedEligibilitySchedule.Read.AzureADGroup
  - Office 365 Exchange Online: Exchange.ManageAsApp - only with -Workload Exchange,
    and NOT sufficient on its own; see the directory role note below.
  - Skype and Teams Tenant Admin API: application_access - only with -Workload Teams.
    A separate audience from Graph: Connect-MicrosoftTeams needs a token for each, and
    Graph permissions buy nothing against it.
  - Office 365 SharePoint Online: Sites.Read.All - only with -Workload SharePoint.
  - Microsoft Graph: SharePointTenantSettings.Read.All - also added by -Workload
    SharePoint.
Reads /admin/sharepoint/settings: the tenant-wide sharing capability,
    domain allow/block-list and restriction mode.
Sites.Read.All does NOT cover these -
    they are tenant settings, not site properties - and without it the call returns a
    403 naming no permission.
  - Microsoft Graph: Sites.Read.All - also added by -Workload SharePoint, and NOT the
    same permission as the line above despite the name.
Graph's enumerates sites;
    SharePoint's reads what is inside one.
Enumerating through PnP instead would need
    Sites.FullControl.All, which is write access to every site in the tenant.
    This is a DIFFERENT permission from the identically-named one on Microsoft Graph:
    a token is issued for a resource and carries only the roles granted on THAT
    resource, so PnP presenting a SharePoint-audience token needs the SharePoint one.
  - WindowsDefenderATP: Score.Read.All, Machine.Read.All, Vulnerability.Read.All -
    commercial-only.
Skipped automatically in
    clouds without a Defender for Endpoint presence (e.g.
Azure China), since its
    service principal doesn't exist there; the rest of the app is still created.

Prerequisites (the user running this command needs):
  - Azure RBAC to create certificates in the target Key Vault.
  - Microsoft Entra role allowing application creation AND admin consent of application
    permissions (Global Administrator, Privileged Role Administrator, or Application
    Administrator + Cloud Application Administrator).

EXCHANGE AND TEAMS ALSO NEED A DIRECTORY ROLE, and this is the step that is easy to
miss.
The app role is necessary but not sufficient: the app's service principal must
also hold a directory role.
Without one, Connect-MsecExchangeOnline and Connect-MsecTeams
both SUCCEED and then every Get-EXO* / Get-Cs* call fails with a plain authorisation
error naming no permission - from the service's point of view the app authenticated and
has no rights.

-Workload Exchange or -Workload Teams assigns it.
That is a real tenant-wide
privilege grant rather than an API permission, which is why the workloads are
opt-in and why creating the assignment needs Privileged Role Administrator - a
higher bar than the rest of this command.
If the caller lacks it, everything else
is still configured and a warning says exactly what to assign by hand.

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
$app = New-MsecApp -KeyVaultName 'kv-mysec'
# Hand $app.TenantId / $app.ClientId / $app.KeyVaultName / $app.CertificateName to anyone
# who should run reports; they Connect-Msec with those values.
```

## PARAMETERS

### -DisplayName
Display name for the new app registration.
Default: 'msec'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: Msec
Accept pipeline input: False
Accept wildcard characters: False
```

### -KeyVaultName
Name of an existing Azure Key Vault that will store the certificate.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CertificateName
Name of the certificate object inside Key Vault.
Default: 'msec-app'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: Msec-app
Accept pipeline input: False
Accept wildcard characters: False
```

### -ValidityMonths
Certificate lifetime in months.
Default: 24.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: 24
Accept pipeline input: False
Accept wildcard characters: False
```

### -Workload
Extra workloads to configure: any of Exchange, SharePoint and Teams.
Omitted by
default - each needs fresh admin consent, and Exchange and Teams each need a
directory role on top of their app role.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DirectoryRole
Which directory role to give the app.
Assigned when -Workload includes Exchange or
Teams; neither works without one.
Default 'Global Reader' - the least-privilege option
that satisfies both.
Aliased to -ExchangeDirectoryRole, the name this had in 0.2.0.

```yaml
Type: String
Parameter Sets: (All)
Aliases: ExchangeDirectoryRole

Required: False
Position: 6
Default value: Global Reader
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES
AZURE DEVOPS IS NOT CONFIGURED HERE, AND CANNOT BE.
There is no -Workload for it and
nothing useful to grant.
The Azure DevOps resource exposes exactly two application app
roles - vso.loadtest and vso.loadtest_write, both load testing - and neither touches the
identity graph, organization settings or service endpoints that msec reads.
Those are
not exposed as application permissions at all: authorisation for them happens inside
Azure DevOps rather than in Entra, so the token this app can already mint for Azure
DevOps is not the missing piece.

What IS needed is a manual step, once per organization: add the app's service principal
under Organization Settings \> Users, with at least Basic access and Reader on the
project collection.
Until that is done Get-MsecAzureDevOpsUser, Get-MsecAzureDevOpsOrganizationPolicy
and Get-MsecAzureDevOpsServiceConnection all fail with a 401 that reads like a missing API
permission and is not one - so running New-MsecApp again will never fix it.
Those
commands say as much in their own errors.

## RELATED LINKS
