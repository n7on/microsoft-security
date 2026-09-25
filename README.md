# Msec

[![CI](https://github.com/n7on/microsoft-security/actions/workflows/ci.yml/badge.svg)](https://github.com/n7on/microsoft-security/actions/workflows/ci.yml)
[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/Msec)](https://www.powershellgallery.com/packages/Msec)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/Msec)](https://www.powershellgallery.com/packages/Msec)
[![License](https://img.shields.io/github/license/n7on/microsoft-security)](https://github.com/n7on/microsoft-security/blob/main/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-blue)](#)

A PowerShell module for reading Microsoft security posture - Secure Score, Defender XDR, Entra ID, Intune, Azure - as flat objects you can filter, group and export. The app registration holds read permissions only, so the certificate in Key Vault cannot change your tenant; the few commands that write run as YOU, through a separate ``Connect-MsecAdmin`` sign-in. Authentication is certificate-based against that app registration, and the private key never leaves Azure Key Vault. Requires PowerShell 7 on Windows, Linux, or macOS.

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

## Setup by workload

`New-MsecApp` grants everything that Entra controls - API permissions, admin consent, and the
directory role Exchange and Teams need. Some products keep their own permission system on top of
that, and an app with perfect Entra permissions still reads nothing there until it is granted
access **inside the product**. Those steps are listed per workload below; nothing else needs
doing.

| Workload | `New-MsecApp` grants | You must also do |
|---|---|---|
| Secure Score, Defender, Entra, Intune, Azure | everything | nothing |
| Exchange Online | `Exchange.ManageAsApp` + directory role | nothing |
| SharePoint Online | `Sites.Read.All` on Graph **and** on SharePoint | nothing |
| Microsoft Teams | `application_access` + directory role | nothing |
| Azure DevOps | nothing - Entra has no say here | organization membership, and permissions per namespace |

### Which identity a command uses

Most commands run as the **app registration** - the certificate in Key Vault, read-only, and
whatever `New-MsecApp` consented. A handful run as **you**, through the Az context, and need
Azure RBAC on top of anything Entra granted. Two use both, deliberately.

| Command | Runs as | Needs |
|---|---|---|
| `Search-MsecAzureResourceGraph` | you | Reader on the subscriptions |
| `Search-MsecLogAnalytics` | you | Log Analytics Reader on the workspace |
| `Get-MsecAzureCost` | you | Cost Management Reader - Reader is not enough |
| `Get-MsecAzureSecureScore` | you | Reader (Defender for Cloud) |
| `Get-MsecAzureDomainService` | you | Reader on the subscriptions holding the managed domain |
| `Get-MsecKeyVaultCertificate` | you | list/get on the vault |
| `Invoke-MsecAzureVMScript` | you | **Virtual Machine Contributor** - `runCommand/action`, which Reader does NOT grant |
| `Set-MsecDefenderAlert` | you | delegated `SecurityAlert.ReadWrite.All` via `Connect-MsecAdmin` - the app cannot do this |
| `Set-MsecDefenderIncident` | you | delegated `SecurityIncident.ReadWrite.All` via `Connect-MsecAdmin` |
| `Get-MsecAzureRoleAssignment` | both | Reader for the assignments; the app resolves principal names through Graph |
| `Select-MsecAzureContext` | both | an Az context to switch, and the app session to reconnect afterwards |

`Invoke-MsecAzureVMScript` is the one to know about on the Azure side: Reader alone gets a 403
there, because `runCommand/action` is a Contributor-level right even though the bundled scripts
only read.

`Set-MsecDefenderAlert` is the first command that changes something outside the module's own app
registration, and it does so as you, not as the app - `New-MsecApp` consents only `*.Read.All`, so
the certificate has no write permission to reach for. It refuses the app session by name rather
than letting the write fail as an unexplained 403.

`Set-MsecDefenderIncident` is the same shape. Comments are split across two APIs, because Graph has
no writable comment on an alert - `comments` is read-only on `alerts_v2` in both v1.0 and beta. The
Defender for Endpoint API does have one, so `Set-MsecDefenderAlert -Comment` writes there, keyed on
`ProviderAlertId` and authenticated from your Az context rather than the Graph session. That API only
knows ENDPOINT alerts (29 of 569 on one measured tenant), so `-Comment` refuses by name on anything
else and points at `Set-MsecDefenderIncident -ResolvingComment`, which covers every incident.

`Get-MsecAzureRoleAssignment` splits its lookups on purpose - assignments and role names
through ARM, principals through the app's Graph session. `Get-AzADUser` on an ARM service
connection with no Graph permissions does not fail, it returns blank names, so a report would
come back full of empty principals with no error.

### Exchange Online, SharePoint Online, Teams

```powershell
New-MsecApp -KeyVaultName kv-msec -Workload Exchange, SharePoint, Teams
```

Exchange and Teams need a **directory role** as well as an app role. An app role alone leaves the
app authenticated with no rights, and neither service says so - `Connect-MsecExchangeOnline` and
`Connect-MsecTeams` both succeed, then every call fails with an authorisation error that names
nothing. `-Workload` assigns Global Reader, the least-privilege option that satisfies both.
Assigning it needs Privileged Role Administrator; without that the rest is still configured and a
warning says exactly what to assign by hand.

### Azure DevOps

Azure DevOps has its own permission system. Entra API permissions buy nothing here - the Azure
DevOps resource exposes only two application roles, both for load testing - so `New-MsecApp` has
no `-Workload` for it and never will.

**1. Add the app to the organization.** Organization Settings > Users > Add, with **Basic** access
(Stakeholder cannot read the identity graph). This alone is enough for:

- `Get-MsecAzureDevOpsUser`
- `Get-MsecAzureDevOpsOrganizationPolicy`

**2. Grant permissions for anything further.** Create an organization-level group, put the app in
it, and grant the group what it needs. A group rather than the app directly: the permission is
then granted once and membership becomes the control.

```powershell
$pat = Read-Host -AsSecureString 'PAT'   # Security (manage) scope, short-lived

# What can be granted?
./tools/Grant-MsecAzureDevOpsPermission.ps1 -Organization contoso -Pat $pat -ListPermissions

# Advanced Security alerts, once, for the whole organization
./tools/Grant-MsecAzureDevOpsPermission.ps1 -Organization contoso `
    -Identity 'Security Reporting Readers' -Permission ViewAdvSecAlerts `
    -Scope Organization -Pat $pat -Apply
```

Drop `-Apply` for a dry run; it reads the current ACL and reports what it would change.

A PAT is needed because the delegated Azure token cannot read or write ACLs - Azure DevOps
answers 403. The permission bit and namespace id are resolved by NAME at run time, so a
renumbered bit fails loudly rather than granting something else.

Which permission each command needs:

| Command | Permission | Why |
|---|---|---|
| `Get-MsecAzureDevOpsUser`, `Get-MsecAzureDevOpsOrganizationPolicy` | organization membership | organization-scoped data |
| `Get-MsecAzureDevOpsAlert` | `ViewAdvSecAlerts` | alerts are per repository and 403 without it |
| `Get-MsecAzureDevOpsRepository` | `GenericRead` | Azure DevOps returns only the repositories the caller can read, with a 200 |
| `Get-MsecAzureDevOpsAgentPool` | organization membership | pools, agents and `-IncludeExposure` need nothing extra; `-IncludeSecurity` needs a write-capable permission and is best left alone |
| `Get-MsecAzureDevOpsOrganization` | none beyond the session | a tenant-level query - it lists organizations the app is not a member of |
| `Get-MsecAzureDevOpsExtension` | organization membership | the extension management API is readable by any member |
| `Get-MsecAzureDevOpsSecureFile` | organization membership | the library list and its pipeline permissions are readable by any member; the contents are never fetched |
| `Get-MsecAzureDevOpsServiceConnection` | `Use` on `ServiceEndpoints` | surfaces as the inherited `User` role, which is what the list API checks - `ViewEndpoint` gives only `Reader` and returns nothing |

`GenericRead` is "Read" on Git Repositories, and it is a real step up - it also permits reading
source. It is required because repository enumeration truncates SILENTLY: measured on a live
organization, an app without it saw 95 repositories where a person saw 220, with nothing in the
response to say so.

**Azure DevOps has two permission systems and they are not interchangeable.** Repositories and
Advanced Security use the classic security namespaces (`-Permission`, ACL bits). Pipeline
resources - service connections, agent pools, variable groups - use role assignments
(`-RoleName`, Reader/User/Administrator) and have no organization root, so those are granted per
project. Choosing the wrong one fails silently: an allow on the `ServiceEndpoints` namespace is
accepted, stored, reported back, and confers nothing.

The two systems are connected, which is what makes an organization-wide grant possible: an allow
at a namespace ROOT token surfaces as an inherited ROLE on every project and resource beneath it.

```powershell
# Service connections, once for the whole organization
./tools/Grant-MsecAzureDevOpsPermission.ps1 -Organization contoso `
    -Identity 'Security Reporting Readers' -Namespace ServiceEndpoints `
    -Permission Use -Scope Organization -Pat $pat -Apply
```

`Use` surfaces as the `User` role, which is what the endpoints list API checks. `ViewEndpoint`
surfaces as `Reader` and returns an empty list - an identity can hold Reader on every connection
in a project, inherited and effective, and still see none of them.

`Use` means "may authenticate through this connection", which reads alarming for a read-only
module. In practice exploiting it would also require authoring and running a pipeline, which
needs repository Contribute and build permissions msec does not have. Grant it knowingly, or
leave it and accept that the inventory reports what it could not see.

**Never grant `DismissAdvSecAlerts`, `ManageAdvSecScanning`, `GenericContribute`, or the
`Administrator` role.** Those write, and msec never calls anything that needs them.

**Why not just add the app to `Project Collection Service Accounts`?** It works in one click and
it is the wrong trade: that group carries service-account rights across the whole collection. A
tool whose purpose is finding over-privileged identities should not become one.

### Checking it worked

Every command that depends on product-side permissions says so when it cannot read. They report
what was refused rather than returning an empty result, because an inventory that silently omits
most of the estate is worse than none:

```powershell
Get-MsecAzureDevOpsAlert -Organization contoso
# WARNING: 39 of 87 enabled repository(ies) refused their alerts: ...
#          Those findings are NOT in this output.
```

That warning going quiet is the confirmation. Treat an empty result with no warning as the
answer, and an empty result with one as unread.
## Commands

### Session
- [New-MsecApp](./docs/commands/New-MsecApp.md) - Create or update the msec app registration, its Key Vault certificate, and admin consent
- [Connect-Msec](./docs/commands/Connect-Msec.md) - Open a session bound to a certificate in Azure Key Vault
- [Disconnect-Msec](./docs/commands/Disconnect-Msec.md) - Clear the session and its cached tokens
- [Select-MsecAzureContext](./docs/commands/Select-MsecAzureContext.md) - Switch Azure context by subscription name, warning if it leaves the msec session on another tenant
- [Connect-MsecAdmin](./docs/commands/Connect-MsecAdmin.md) - Sign in AS YOU with delegated write scopes, for the commands that change something
- [Connect-MsecGraphSdk](./docs/commands/Connect-MsecGraphSdk.md) - Hand the msec session's token to the Microsoft.Graph SDK, so Get-Mg* runs as the msec app
- [Connect-MsecExchangeOnline](./docs/commands/Connect-MsecExchangeOnline.md) - Same for ExchangeOnlineManagement
- [Connect-MsecSharePointOnline](./docs/commands/Connect-MsecSharePointOnline.md) - Same for PnP.PowerShell, with the token audience derived from the site host
- [Connect-MsecTeams](./docs/commands/Connect-MsecTeams.md) - Same for MicrosoftTeams, which needs two tokens for two audiences

### Secure Score
- [Get-MsecSecureScore](./docs/commands/Get-MsecSecureScore.md) - Microsoft Secure Score over time, overall and per category
- [Get-MsecAzureSecureScore](./docs/commands/Get-MsecAzureSecureScore.md) - Defender for Cloud Secure Score, per subscription
- [Get-MsecDefenderScoreExposure](./docs/commands/Get-MsecDefenderScoreExposure.md) - Defender Vulnerability Management exposure score
- [Get-MsecDefenderScoreDeviceConfiguration](./docs/commands/Get-MsecDefenderScoreDeviceConfiguration.md) - Secure Score for Devices

### Defender XDR
- [Get-MsecDefenderIncidentStats](./docs/commands/Get-MsecDefenderIncidentStats.md) - Incident severity, classification and status breakdown, plus current backlog
- [Get-MsecDefenderEmailStats](./docs/commands/Get-MsecDefenderEmailStats.md) - Inbound email volume and threat breakdown
- [Get-MsecDefenderIncident](./docs/commands/Get-MsecDefenderIncident.md) - Defender XDR incidents, one row each, with triage state and time to resolve
- [Get-MsecDefenderAlert](./docs/commands/Get-MsecDefenderAlert.md) - Defender XDR alerts across endpoint, Office 365, identity and DLP, with the incident each belongs to
- [Get-MsecDefenderDevice](./docs/commands/Get-MsecDefenderDevice.md) - Device inventory with per-device vulnerability counts
- [Set-MsecDefenderAlert](./docs/commands/Set-MsecDefenderAlert.md) - **Writes.** Resolve, classify or comment on alerts; needs `Connect-MsecAdmin`
- [Set-MsecDefenderIncident](./docs/commands/Set-MsecDefenderIncident.md) - **Writes.** Resolve, classify or comment on incidents - the resolution comment lives here, not on the alert; needs `Connect-MsecAdmin`

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
- [Get-MsecEntraDisabledUser](./docs/commands/Get-MsecEntraDisabledUser.md) - Disabled ("archived") accounts, how long each has been off, and what licences they still hold
- [Convert-MsecEntraSid](./docs/commands/Convert-MsecEntraSid.md) - Convert an Entra SID (`S-1-12-1-...`) to its objectId and back
- [Get-MsecEntraGroupMember](./docs/commands/Get-MsecEntraGroupMember.md) - Members of named groups, with nested groups expanded to the people inside them
- [Get-MsecEntraAppCredential](./docs/commands/Get-MsecEntraAppCredential.md) - App registration and service principal secrets and certificates, and when they expire

### Intune
- [Get-MsecIntuneConfigurationProfile](./docs/commands/Get-MsecIntuneConfigurationProfile.md) - Settings Catalog and classic configuration profiles merged, with assignment targets resolved
- [Get-MsecIntuneCompliancePolicy](./docs/commands/Get-MsecIntuneCompliancePolicy.md) - Compliance policies: what makes a device compliant, and therefore allowed through Conditional Access
- [Get-MsecIntuneDevice](./docs/commands/Get-MsecIntuneDevice.md) - Every managed device known to Intune
- [Get-MsecIntuneScriptResult](./docs/commands/Get-MsecIntuneScriptResult.md) - Per-device results from every kind of Intune script: remediations, platform scripts, macOS custom attributes and custom compliance scripts

### Azure
- [Search-MsecAzureResourceGraph](./docs/commands/Search-MsecAzureResourceGraph.md) - Run a bundled KQL query against Azure Resource Graph
- [Search-MsecLogAnalytics](./docs/commands/Search-MsecLogAnalytics.md) - Run a bundled KQL query against a Log Analytics workspace
  - -ResourceType ResourceChange answers what changed on a resource in the last 14 days, who changed it and from what value
- [Invoke-MsecAzureVMScript](./docs/commands/Invoke-MsecAzureVMScript.md) - Run a bundled script on one or more Azure VMs
- [Get-MsecAzureRoleAssignment](./docs/commands/Get-MsecAzureRoleAssignment.md) - Azure RBAC across every subscription, with role and principal names resolved and deleted principals kept
- [Get-MsecAzureCost](./docs/commands/Get-MsecAzureCost.md) - Cost per subscription or resource group, with the billing currency
- [Get-MsecKeyVaultCertificate](./docs/commands/Get-MsecKeyVaultCertificate.md) - Certificates in every accessible Key Vault and when they expire
- [Get-MsecAzureDomainService](./docs/commands/Get-MsecAzureDomainService.md) - Entra Domain Services managed domains: which weak protocols they still accept, and where their audit logs go

### Reporting
- [Export-MsecPostureReport](./docs/commands/Export-MsecPostureReport.md) - Append this run's posture measurements to an Excel workbook, building a charted time series
- [Export-MsecVMUpdateReport](./docs/commands/Export-MsecVMUpdateReport.md) - Evidence of when every VM in the current subscription was last patched, one worksheet per subscription
- [Export-MsecVMNtpReport](./docs/commands/Export-MsecVMNtpReport.md) - Evidence that every VM in the current subscription has its clock synchronised against a real time source
- [Export-MsecEntraDisabledUserReport](./docs/commands/Export-MsecEntraDisabledUserReport.md) - Evidence of every disabled account, how long it has been disabled, and what it still costs in licences
- [Export-MsecDefenderDeviceReport](./docs/commands/Export-MsecDefenderDeviceReport.md) - Evidence of every Defender-onboarded device and its vulnerability exposure
- [Export-MsecEntraGroupMemberReport](./docs/commands/Export-MsecEntraGroupMemberReport.md) - Evidence of who is in which group, one worksheet per group
- [Export-MsecAzureDevOpsReport](./docs/commands/Export-MsecAzureDevOpsReport.md) - A whole Azure DevOps organization's security posture in one workbook: a sheet per area and a chart per area

### Exchange Online
- [Get-MsecExchangeMailboxPermission](./docs/commands/Get-MsecExchangeMailboxPermission.md) - Who can open, send as, or send on behalf of each mailbox

### SharePoint Online
- [Get-MsecSharePointSite](./docs/commands/Get-MsecSharePointSite.md) - Every site in the tenant, classified, with Loop and Designer containers separated out
- [Get-MsecSharePointSiteUser](./docs/commands/Get-MsecSharePointSiteUser.md) - A site's owners and members, with security groups expanded to the people inside them
- [Get-MsecSharePointTenantSetting](./docs/commands/Get-MsecSharePointTenantSetting.md) - Tenant-wide sharing posture: sharing capability, domain lists, legacy auth

### Microsoft Teams
- [Get-MsecTeamsPolicy](./docs/commands/Get-MsecTeamsPolicy.md) - External access, guest access, meeting lobby, recording, app installation and file sharing, one row per setting

### Azure DevOps
- [Get-MsecAzureDevOpsOrganization](./docs/commands/Get-MsecAzureDevOpsOrganization.md) - Every organization in the tenant and who owns it - the list every other command needs
- [Get-MsecAzureDevOpsUser](./docs/commands/Get-MsecAzureDevOpsUser.md) - Users and the groups they belong to, for an access review
- [Get-MsecAzureDevOpsVariableGroup](./docs/commands/Get-MsecAzureDevOpsVariableGroup.md) - Variable groups, what secrets they hold, and whether any pipeline may use them
- [Get-MsecAzureDevOpsOrganizationPolicy](./docs/commands/Get-MsecAzureDevOpsOrganizationPolicy.md) - Organization policies: guest access, OAuth, SSH, PAT creation, public projects
- [Get-MsecAzureDevOpsAlert](./docs/commands/Get-MsecAzureDevOpsAlert.md) - Advanced Security alerts: secrets, dependencies and code scanning findings
- [Get-MsecAzureDevOpsAgentPool](./docs/commands/Get-MsecAzureDevOpsAgentPool.md) - Agent pools, whether they run on your own machines, and what versions and operating systems those agents are on
- [Get-MsecAzureDevOpsEnvironment](./docs/commands/Get-MsecAzureDevOpsEnvironment.md) - Deployment environments, the checks guarding them, and who approves
- [Get-MsecAzureDevOpsExtension](./docs/commands/Get-MsecAzureDevOpsExtension.md) - Marketplace extensions and the access each one holds over code, builds and service connections
- [Get-MsecAzureDevOpsPipelineSetting](./docs/commands/Get-MsecAzureDevOpsPipelineSetting.md) - Project pipeline security: fork builds and fork secrets, job authorization scope, settable variables, shell argument sanitising
- [Get-MsecAzureDevOpsSecureFile](./docs/commands/Get-MsecAzureDevOpsSecureFile.md) - Certificates and keys stored in the pipeline library, how old they are, and which pipelines may use them
- [Export-MsecAzureDevOpsReport](./docs/commands/Export-MsecAzureDevOpsReport.md) - Every area above in one snapshot workbook, with a chart apiece
- [Get-MsecAzureDevOpsRepository](./docs/commands/Get-MsecAzureDevOpsRepository.md) - Every repository with the protections on its default branch: reviewers, build validation, secret push protection
- [Get-MsecAzureDevOpsServiceConnection](./docs/commands/Get-MsecAzureDevOpsServiceConnection.md) - Every service connection in an organization, with its auth scheme and the projects it is shared to

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
