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
 [[-ValidityMonths] <Int32>] [<CommonParameters>]
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
  - WindowsDefenderATP: Score.Read.All - commercial-only.
Skipped automatically in
    clouds without a Defender for Endpoint presence (e.g.
Azure China), since its
    service principal doesn't exist there; the rest of the app is still created.

Prerequisites (the user running this command needs):
  - Azure RBAC to create certificates in the target Key Vault.
  - Microsoft Entra role allowing application creation AND admin consent of application
    permissions (Global Administrator, Privileged Role Administrator, or Application
    Administrator + Cloud Application Administrator).

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES

## RELATED LINKS
