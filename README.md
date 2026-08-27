# Msec

[![CI](https://github.com/n7on/microsoft-security/actions/workflows/ci.yml/badge.svg)](https://github.com/n7on/microsoft-security/actions/workflows/ci.yml)
[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/Msec)](https://www.powershellgallery.com/packages/Msec)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/Msec)](https://www.powershellgallery.com/packages/Msec)
[![License](https://img.shields.io/github/license/n7on/microsoft-security)](https://github.com/n7on/microsoft-security/blob/main/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-blue)](#)

A PowerShell module for reading Microsoft security posture - Secure Score, Defender XDR, Entra ID, Intune, Azure - as flat objects you can filter, group and export. Read-only by design. Authentication is certificate-based against an app registration, and the private key never leaves Azure Key Vault. Requires PowerShell 7 on Windows, Linux, or macOS.

## Install

```powershell
Install-Module Msec

# One-time setup: creates the app registration, its certificate in Key Vault, and
# consents the read permissions. Safe to re-run - it updates rather than duplicates.
New-MsecApp -KeyVaultName kv-msec -TenantId <guid>

Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
```

Every `Get-Msec*` command reads. Nothing in this module writes to a tenant except
`New-MsecApp`, which exists to create its own app registration.

## Commands

### Session
- [New-MsecApp](./docs/commands/New-MsecApp.md) - Create or update the msec app registration, its Key Vault certificate, and admin consent
- [Connect-Msec](./docs/commands/Connect-Msec.md) - Open a session bound to a certificate in Azure Key Vault
- [Disconnect-Msec](./docs/commands/Disconnect-Msec.md) - Clear the session and its cached tokens
- [Select-MsecAzureContext](./docs/commands/Select-MsecAzureContext.md) - Switch Azure context by subscription name, warning if it leaves the msec session on another tenant

### Secure Score
- [Get-MsecSecureScore](./docs/commands/Get-MsecSecureScore.md) - Microsoft Secure Score over time, overall and per category
- [Get-MsecAzureSecureScore](./docs/commands/Get-MsecAzureSecureScore.md) - Defender for Cloud Secure Score, per subscription
- [Get-MsecDefenderScoreExposure](./docs/commands/Get-MsecDefenderScoreExposure.md) - Defender Vulnerability Management exposure score
- [Get-MsecDefenderScoreDeviceConfiguration](./docs/commands/Get-MsecDefenderScoreDeviceConfiguration.md) - Secure Score for Devices

### Defender XDR
- [Get-MsecDefenderIncidentStats](./docs/commands/Get-MsecDefenderIncidentStats.md) - Incident severity, classification and status breakdown, plus current backlog
- [Get-MsecDefenderEmailStats](./docs/commands/Get-MsecDefenderEmailStats.md) - Inbound email volume and threat breakdown

### Entra ID
- [Get-MsecEntraTenantSecuritySetting](./docs/commands/Get-MsecEntraTenantSecuritySetting.md) - Tenant-wide posture in one row: security defaults, licensed workloads, default user permissions, privileged-role counts
- [Get-MsecEntraLicense](./docs/commands/Get-MsecEntraLicense.md) - Subscribed SKUs and the service plans each one turns on
- [Get-MsecEntraRoleHolder](./docs/commands/Get-MsecEntraRoleHolder.md) - Who holds which directory role, separating what a role is assigned to from who effectively holds it, including PIM-eligible assignments and role-assignable groups expanded
- [Get-MsecEntraConditionalAccessPolicy](./docs/commands/Get-MsecEntraConditionalAccessPolicy.md) - Conditional Access policies with conditions and grant controls flattened to columns
- [Get-MsecEntraConditionalAccessStats](./docs/commands/Get-MsecEntraConditionalAccessStats.md) - Aggregated Conditional Access outcomes over a period
- [Get-MsecEntraConditionalAccessSignInLog](./docs/commands/Get-MsecEntraConditionalAccessSignInLog.md) - Raw sign-in events with their Conditional Access outcomes
- [Get-MsecEntraMfaRegistration](./docs/commands/Get-MsecEntraMfaRegistration.md) - Per-user authentication-method registration: who can actually do MFA, with what
- [Get-MsecEntraMfaRegistrationStats](./docs/commands/Get-MsecEntraMfaRegistrationStats.md) - MFA coverage in one row, overall and for admins
- [Get-MsecEntraMfaEvidence](./docs/commands/Get-MsecEntraMfaEvidence.md) - Per-user evidence that MFA was demanded and met at sign-in, for an access review
- [Convert-MsecEntraSid](./docs/commands/Convert-MsecEntraSid.md) - Convert an Entra SID (`S-1-12-1-...`) to its objectId and back

### Intune
- [Get-MsecIntuneConfigurationProfile](./docs/commands/Get-MsecIntuneConfigurationProfile.md) - Settings Catalog and classic configuration profiles merged, with assignment targets resolved
- [Get-MsecIntuneCompliancePolicy](./docs/commands/Get-MsecIntuneCompliancePolicy.md) - Compliance policies: what makes a device compliant, and therefore allowed through Conditional Access
- [Get-MsecIntuneDevice](./docs/commands/Get-MsecIntuneDevice.md) - Every managed device known to Intune
- [Get-MsecIntuneScriptResult](./docs/commands/Get-MsecIntuneScriptResult.md) - Per-device results from every kind of Intune script: remediations, platform scripts, macOS custom attributes and custom compliance scripts

### Azure
- [Search-MsecAzureResourceGraph](./docs/commands/Search-MsecAzureResourceGraph.md) - Run a bundled KQL query against Azure Resource Graph
- [Search-MsecLogAnalytics](./docs/commands/Search-MsecLogAnalytics.md) - Run a bundled KQL query against a Log Analytics workspace
- [Invoke-MsecAzureVMScript](./docs/commands/Invoke-MsecAzureVMScript.md) - Run a bundled script on one or more Azure VMs

### Reporting
- [Export-MsecPostureReport](./docs/commands/Export-MsecPostureReport.md) - Append this run's posture measurements to an Excel workbook, building a charted time series

### Azure DevOps
- [Get-MsecAdoServiceConnection](./docs/commands/Get-MsecAdoServiceConnection.md) - Every service connection in an organization, with its auth scheme

Every command has full help, including the reasoning behind its output shape:

```powershell
Get-Help Get-MsecEntraRoleHolder -Full
```

## Examples

### Who can administer this tenant?

The question every access review starts with. Directory roles can be held directly, or
inherited through a role-assignable group, or held as a PIM eligibility nobody has
activated - and the last two are invisible to the older `/directoryRoles` endpoint that
most scripts use.

```powershell
Get-MsecEntraRoleHolder -Role 'Global Administrator' |
    Format-Table EffectiveName, EffectiveType, RoleName, AssignmentType, PrincipalName

# EffectiveName    EffectiveType    RoleName              AssignmentType PrincipalName
# -------------    -------------    --------              -------------- -------------
# anna@contoso.com user             Company Administrator Active         anna@contoso.com
# break-glass      servicePrincipal Company Administrator Active         break-glass
# erik@contoso.com user             Company Administrator Eligible       sg-tier0-admins
```

Two things worth noticing in that output. `RoleName` reads *Company Administrator* -
Graph's legacy name for Global Administrator - which is why `-Role` matches on
`roleTemplateId` and never on the display name. And Erik holds the role through a group
he can activate into: `PrincipalName` is the group, `EffectiveName` is the person.

```powershell
# Standing tenant-wide privilege - the assignments PIM was meant to remove.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly -AssignmentType Active |
    Where-Object IsTenantScoped

# Distinct humans who can administer the tenant. Count holders, not rows: one person
# inheriting a role through two groups is one administrator.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
    Where-Object { $_.EffectiveType -eq 'user' -and $_.IsResolved } |
    Sort-Object EffectiveId -Unique
```

### What is this Intune policy actually aimed at?

A policy's assignment count tells you almost nothing: "All Users plus an exclusion group"
and "two unrelated groups" are both `2`, and they are very different deployments.

```powershell
Get-MsecIntuneConfigurationProfile |
    Format-Table DisplayName, Source, Platform, AssignmentType, AssignmentGroup

# DisplayName      Source          Platform  AssignmentType             AssignmentGroup
# -----------      ------          --------  --------------             ---------------
# Windows Baseline SettingsCatalog windows10 AllUsers
# BitLocker        SettingsCatalog windows10 AllDevices, ExclusionGroup excluding sg-executives
# Ring Rollout     SettingsCatalog windows10 Group                      sg-pilot-ring, sg-broad-ring
# Kiosk Lockdown   SettingsCatalog windows10 AllDevices
# Old Draft        SettingsCatalog windows10
```

```powershell
# Tenant-wide policies: these apply to everyone who enrols tomorrow.
Get-MsecIntuneConfigurationProfile |
    Where-Object { $_.AssignmentType -contains 'AllUsers' -or
                   $_.AssignmentType -contains 'AllDevices' }

# Configured, reviewed, and doing nothing.
Get-MsecIntuneConfigurationProfile | Where-Object AssignmentCount -eq 0

# Assignments narrowed by a device filter, where the stated target overstates the reach.
Get-MsecIntuneConfigurationProfile | Where-Object HasAssignmentFilter
```

The collection columns are arrays, not joined strings, so `-contains` is an exact test.
The table renders them comma-separated; the data underneath is not flattened.

### Which SID is this?

Windows event logs, `whoami /user` and local group membership on Entra-joined devices all
report cloud accounts as `S-1-12-1-...`, which is the objectId with its bytes rearranged.

```powershell
Convert-MsecEntraSid -Sid 'S-1-12-1-2640853384-1293864314-2707107988-2394433369' -Resolve

# Sid                                                  ObjectId                             DisplayName          ObjectType
# ---                                                  --------                             -----------          ----------
# S-1-12-1-2640853384-1293864314-2707107988-2394433369  9d683988-cd7a-4d1e-9430-5ba15927b88e Company Administrator directoryRole
```

Expect roles, not just people: role-based local admin on an Entra-joined device puts the
*role's* SID in the local Administrators group, not the SIDs of the people holding it.

### Is this workload even licensed?

The difference between a real gap and a not-applicable one. A tenant with no
`AAD_PREMIUM` plan cannot have Conditional Access at all, so an empty policy list is
expected rather than alarming.

```powershell
Get-MsecEntraTenantSecuritySetting |
    Select-Object SecurityDefaultsEnabled, ConditionalAccessAvailable, EntraIdPremium,
                  GlobalAdministratorCount, HighlyPrivilegedMemberCount |
    Format-List

# SecurityDefaultsEnabled     : False
# ConditionalAccessAvailable  : True
# EntraIdPremium              : P2
# GlobalAdministratorCount    : 3
# HighlyPrivilegedMemberCount : 11
```

## Requirements

- PowerShell 7.0 or later
- `Az.Accounts`, `Az.KeyVault`, `Az.Compute`, `Az.ResourceGraph`, `Az.OperationalInsights`
- An Azure Key Vault you can read a certificate from, and rights to create an app
  registration the first time (`New-MsecApp`)

There is no dependency on `Microsoft.Graph.*` or `MSAL.PS`. Tokens are JWT client
assertions signed by the Key Vault key, and every API call goes through
`Invoke-RestMethod`.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup and how to run the tests.
