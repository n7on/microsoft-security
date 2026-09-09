# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.3.0] - 2026-09-08

### Changed
- **Fixed on Linux:** the module folder and its manifest are lowercase - `msec/msec.psd1`,
  `msec.psm1`, `msec.format.ps1xml` - matching the PowerShell Gallery id.

  The id was set by the first publish and a Gallery id keeps the casing it was first published
  with, so `Install-Module` created `.../Modules/msec/<version>/Msec.psd1`: a lowercase directory
  holding a capitalised manifest. PowerShell resolves a module as
  `<directory>/<version>/<directory>.psd1`, and on Linux that lookup is CASE-SENSITIVE - so
  `Import-Module Msec` failed there with "no valid module file was found in any module
  directory", which reads as a module that was never installed. macOS and Windows never showed
  it. Every Linux consumer was affected, not only CI.

  The internal folders are lowercase too (`public/`, `private/`, `tests/`, `kql/`, `scripts/`).
  Folders whose names are user-facing parameter values are NOT: `kql/Graph/VM/` still backs
  `-ResourceType VM`, and `scripts/VM/Windows/` still backs `-Os Windows`. Lowercasing those
  would have changed what callers type, and broken them on Linux only.

  Command names, the `-Msec` noun prefix and the `Msec*` type names are unchanged.

- **Breaking:** the Azure DevOps commands are named `*AzureDevOps*` rather than `*Ado*`.
  `Get-MsecAdoServiceConnection`, which shipped in 0.2.0, is now
  `Get-MsecAzureDevOpsServiceConnection`. No alias is kept: an abbreviation that appears in one
  command family and nowhere else in the module is worse than a one-line fix at the call site.

### Added
- `Connect-MsecTeams` / `Get-MsecTeamsPolicy` - the Teams settings that decide who can reach
  your people: external access and federation, guest access, meeting lobby and anonymous join,
  recording, which apps users may install, and file sharing in chats with external users.

  Teams admin policy is NOT in Graph, so this goes through the MicrosoftTeams module - the
  third workload msec reaches that way, after Exchange and SharePoint. It has a wrinkle the
  others do not: `Connect-MicrosoftTeams -AccessTokens` takes an ARRAY of TWO tokens, for
  Microsoft Graph and for the 'Skype and Teams Tenant Admin API'. Separate audiences, separate
  app roles, and passing only the Graph one fails in a way that reads as a permission problem.
  Teams also needs a DIRECTORY ROLE on top of app permissions, exactly as Exchange does.

  `Get-MsecTeamsPolicy` signs in to Teams itself, so it is one call after `Connect-Msec` like
  everything else here.

  `Connect-MsecTeams -AsCurrentUser` connects as the signed-in Azure user instead of the app,
  reusing the tokens from `Connect-AzAccount`. This exists because the Teams module cannot sign
  in interactively off Windows at all - its browser flow calls into `kernel32.dll` and dies with
  a dlopen error - and device code flow, the documented workaround, is refused by any
  Conditional Access policy requiring a compliant device. Borrowing the Az session avoids both,
  since that session already cleared CA. It is also the one place msec hands over an identity
  that can WRITE: msec has no `Set-*` commands, but the connection it leaves behind carries your
  rights, so `Set-Cs*` works afterwards. `Get-MsecTeamsPolicy` will not silently replace such a
  session with the app's.

  There is deliberately NO SharePoint equivalent. Teams accepts a token whose audience is the
  service; SharePoint validates the audience against the HOST, and `Get-AzAccessToken` normalises
  every sharepoint.com URL to the service GUID. The token is issued and then refused by every
  site with a bare 401. Verified on a live tenant against both the root and the admin host, and
  written up in `Connect-MsecSharePointOnline`'s notes so nobody adds the switch back.

  ONE ROW PER SETTING, NOT PER POLICY. A meeting policy object carries roughly eighty
  properties, most about layout and captions; returning whole objects makes the handful that
  matter impossible to see and impossible to diff between two policies or two tenants. Only the
  security-relevant settings are projected - which ones is a judgement the command makes, so it
  is written out in the source and `-All` returns everything for checking it.

  `IsGlobal` marks the tenant-wide policy, because that is what a user gets unless assigned
  another: a permissive Global is a tenant-wide finding where a permissive custom policy may
  apply to nobody. A policy area that cannot be read emits an `Unreadable` row rather than
  being skipped - a missing federation configuration would otherwise read as a tenant with no
  external access, the opposite of the truth.
- `Get-MsecAzureRoleAssignment` + `Kql/Graph/Authorization/RoleAssignments.kql` - Azure RBAC
  assignments across every subscription, with role and principal names resolved.

  THE LOOKUPS ARE DELIBERATELY SPLIT ACROSS TWO IDENTITIES. `Get-AzRoleAssignment` resolves
  principal names by calling Graph ITSELF, using whatever identity holds the Az context. That
  works for a person - who has directory read by default - and silently returns BLANK names for
  a service principal without Graph permissions. A pipeline running the same code as a laptop
  therefore produces a report full of GUIDs and no error. Here assignments and role names come
  from ARM, principals from the msec Graph session, so the ARM identity needs no directory
  access at all and the answer is the same in both places.

  Principals resolve in BULK through `/directoryObjects/getByIds`, up to 1000 per call - one
  call per assignment would be 2415 round trips on a real tenant. Role names come from ARM REST
  rather than `Get-AzRoleDefinition`, which lives in Az.Resources and is NOT a msec dependency:
  using it works on a developer machine and fails on a clean agent.

  An assignment whose principal no longer exists is KEPT, with `IsResolved = $false`. On a live
  tenant that was 94 of 233 subscription-scope assignments, 85 of them deleted service
  principals whose Azure rights outlived them - the finding, not an error.

  One Resource Graph query covers the estate: 2415 assignments against the 400
  `Get-AzRoleAssignment` returns for the current subscription, and without mutating the
  caller's Az context.

### Changed
- `Get-MsecAzureDevOpsUser` - every user in an Azure DevOps organization and the groups they belong to,
  one row per membership. Replaces the hand-rolled PAT-authenticated helpers in the Reporting
  repo, and fixes three things they got wrong.

  IT PAGES. The ADO graph APIs return one page and put the cursor in the X-MS-ContinuationToken
  RESPONSE HEADER, not in the body. Reading `$response.value` gives page one with no error and
  no sign more existed - and in an access review the users that go missing look exactly like
  users who do not exist.

  Group names are resolved from ONE fetch rather than a call per membership: the direct
  translation is thousands of round trips on a few hundred users for a few dozen distinct
  groups. A user in no group still gets a row (`(none)`), because emitting nothing drops the
  account from the review; a user whose memberships could not be read gets `(unreadable)`, which
  is a different claim. `Origin` separates Entra-backed accounts from `vsts` accounts that exist
  only inside Azure DevOps, with no Conditional Access and no leaver process behind them.

- `Get-MsecAzureDevOpsOrganizationPolicy` - the organization-wide Azure DevOps security policies: Entra
  guest access, third-party OAuth apps, SSH keys, alternate credentials, public projects, who
  may invite users, audit logging and the pipeline job-token scopes.

  The same ceiling the SharePoint tenant settings and the Teams Global policy describe. Every
  policy the API returns is a security control, so unlike the Teams command there is no
  projection to argue with - all of them come back, grouped by Category, and one this module has
  never heard of still appears under `Other` rather than being dropped.

  `IsExplicit` CARRIES AS MUCH AS THE VALUE. A policy nobody ever set reports a default; a
  default that happens to be safe today is not a decision anyone made. It is `$null`, not
  `$true`, when the API does not say - "we do not know whether this was deliberate" is a
  different claim from "it was". An empty response warns and returns nothing, because an account
  that authenticates but cannot see organization settings would otherwise look like a clean org.

- `Get-MsecSharePointTenantSetting` - the tenant-wide SharePoint and OneDrive settings, one row
  per setting grouped into a Category, the same shape as `Get-MsecTeamsPolicy`.

  THESE ARE THE CEILING EVERY SITE SITS UNDER. A site can be locked down and still live in a
  tenant where anyone-links are on; reviewing sites one at a time never surfaces that. Covers
  the sharing capability and domain lists, external resharing, legacy auth protocols (which
  bypass Conditional Access entirely), unmanaged-device sync, and site/Loop creation.

  AN EMPTY LIST READS AS `(none)` AND A MISSING VALUE AS `(not set)`, never blank. With
  `SharingDomainRestrictionMode` set to `allowList`, an EMPTY `SharingAllowedDomainList` means
  nobody outside can be invited at all - the opposite of what a blank cell suggests.

- `New-MsecApp -Workload SharePoint` also grants `SharePointTenantSettings.Read.All` on Graph,
  which is what `/admin/sharepoint/settings` needs - the tenant-wide sharing posture:
  `SharingCapability`, the domain allow/block-list and the restriction mode. `Sites.Read.All`
  does not cover it, those being site properties rather than tenant settings, and the call
  returns a bare 403 naming no permission. It is also the only route msec has to those
  settings: the PnP equivalent needs an admin-host token that `Get-AzAccessToken` cannot mint.

- `New-MsecApp -Workload Teams` grants `application_access` on the Skype and Teams Tenant
  Admin API and assigns the directory role. Without this `Connect-MsecTeams` could not get a
  token for that audience at all, so the Teams commands shipped unusable until the app was
  configured by hand.

- `-ExchangeDirectoryRole` is now `-DirectoryRole`, because Teams needs the same role for the
  same reason and the old name said otherwise. The old name still works as an alias, so
  nothing that passed it in 0.2.0 breaks.

## [0.2.0] - 2026-09-07

### Added
- `Get-MsecSharePointSite` - every site in the tenant, classified. Completes the SharePoint
  access review: enumerate with this, then read each site's owners and members with
  `Get-MsecSharePointSiteUser -Url`.

  ENUMERATED THROUGH GRAPH, NOT THE TENANT-ADMIN API, and the reason is privilege.
  `Get-PnPTenantSite` talks to the SharePoint tenant-admin endpoint, which accepts nothing less
  than `Sites.FullControl.All` - full read, WRITE and DELETE over every site in the tenant. For
  a list of site names, in a read-only module, that is a bad trade. Graph answers the same
  question with `Sites.Read.All`.

  MOST OF WHAT GRAPH CALLS A SITE IS NOT ONE. On a live tenant `/sites?search=*` returned 432
  results of which 286 were app containers - the backing storage for Loop workspaces, Designer
  files and similar, one per artefact. Running a site access review across those is noise and
  hundreds of wasted calls, so `SiteType` classifies them (SiteCollection / AppContainer /
  Personal / Root) and the default excludes all but real sites: 146 instead of 432. `-All`
  returns everything classified, because "146 of 432" is a finding and "146" is not.

- `New-MsecApp -Workload SharePoint` now also grants `Sites.Read.All` on MICROSOFT GRAPH,
  alongside the SharePoint one it already granted. Despite the identical name these are
  separate permissions on separate resources, and both are needed: Graph's enumerates sites,
  SharePoint's lets PnP read what is inside one. Having either alone fails in a way that looks
  like the other is missing.
- Exchange Online and SharePoint support, reached the same way everything else is - a token
  signed inside Key Vault, so no certificate reaches the machine:
  - `Connect-MsecExchangeOnline` / `Get-MsecExchangeMailboxPermission` - who can open which
    shared mailbox. Standing delegated access that appears in NO Entra-side review: not in
    group membership, not in a directory role, not in Conditional Access.
  - `Connect-MsecSharePointOnline` / `Get-MsecSharePointSiteUser` - site Owners and Members,
    with security groups expanded to the people inside them.

  THESE ARE THREE DIFFERENT TOKENS, NOT ONE. Entra issues a token FOR a resource, carrying only
  the app roles granted on that resource's service principal - so Graph's `User.Read.All` buys
  nothing in Exchange or SharePoint, and a Graph token presented to either is rejected outright.
  Only the signing key is shared.

  | Command | Audience | Roles come from |
  |---|---|---|
  | `Connect-MsecGraphSdk` | `graph.microsoft.com` | Microsoft Graph SP |
  | `Connect-MsecExchangeOnline` | `outlook.office365.com` | Office 365 Exchange Online SP |
  | `Connect-MsecSharePointOnline` | the site HOST | Office 365 SharePoint Online SP |

  A SharePoint token's audience is the site HOST, so `contoso.sharepoint.com` and
  `contoso-admin.sharepoint.com` need separate tokens - which matters because tenant cmdlets
  like `Get-PnPTenantSite` only work against the admin host.

  Both modules take `-AccessToken` as a plain STRING; `Connect-MgGraph` is the odd one out in
  wanting a SecureString. Verified against ExchangeOnlineManagement 3.10.1 and PnP.PowerShell
  3.4.1. Neither is an msec dependency - both are imported only when their command is called.

  Neither workload could reach Graph anyway: mailbox permissions have no Graph endpoint at all,
  and a site's own SharePoint groups - the permission model for classic sites - are not exposed
  there either.

- `New-MsecApp -Workload Exchange, SharePoint` configures the permissions those need. OPT-IN,
  because each needs fresh admin consent and Exchange needs more than a permission.

  EXCHANGE NEEDS A DIRECTORY ROLE, NOT JUST AN APP ROLE, and this is the step that is missed.
  With `Exchange.ManageAsApp` granted and consented but no directory role, the connection
  SUCCEEDS and then every `Get-EXO*` call fails with a plain authorisation error naming no
  missing permission - from Exchange's point of view the app authenticated and has no rights.
  `-Workload Exchange` assigns one (`Global Reader` by default, the least-privilege option that
  can read mailbox permissions).

  That is a real tenant-wide privilege grant rather than an API permission, which is why the
  workloads are opt-in, why it is announced before being made, and why it is idempotent. It
  needs Privileged Role Administrator - a higher bar than the rest of the command - and a
  caller without it still gets everything else configured plus a warning saying exactly what to
  assign by hand.

  `Sites.Read.All` is granted on the SHAREPOINT service principal, not the Graph one. The two
  permissions share a name and are not the same: PnP presents a SharePoint-audience token, so
  granting the Graph one looks right in the portal and still fails.

  A resource whose service principal does not exist in the tenant - no Exchange Online, a
  sovereign cloud without SharePoint - is now skipped with a warning rather than aborting the
  bootstrap, matching how unavailable app roles were already handled.
- `Kql/Graph/Resource/NetworkExposure.kql`, reached as
  `Search-MsecAzureResourceGraph -ResourceType Resource -Name NetworkExposure` - one row per
  resource that has a network exposure setting, across twelve types: what is reachable from the
  public internet and what restricts by IP.

  It complements rather than duplicates `KeyVault/NetworkRules.kql` and
  `Storage/NetworkRules.kql`. Those answer the question per RULE for one type - which addresses
  are allowed in, and whether each rule is actually enforcing. This answers it per RESOURCE
  across the estate, so finding where to look no longer needs one query per type.

  EVERY TYPE STORES IT SOMEWHERE DIFFERENT, verified against ~1300 live resources. MySQL
  flexible servers carry `publicNetworkAccess` at `properties.network.publicNetworkAccess` and
  nothing at the top level, so the paths are coalesced nested-first; the other order reports
  every one of them as unset, which then defaults to Enabled and looks like an answer.
  Container registries use `networkRuleSet.defaultAction` where vaults and storage use
  `networkAcls.defaultAction`.

  An absent `publicNetworkAccess` means ENABLED, not unknown - defaulting it the safe-looking
  way would under-report exposure on every resource that never had it explicitly set.

  App Service IP restrictions are reported as `IpRuleCount = $null` rather than 0: they live in
  `siteConfig.ipSecurityRestrictions`, which the ARM GET returns trimmed (empty on 315 of 315
  sites), so a site that IS restricted would otherwise read as having no rules.

  `ReachableFromAnyIp` is deliberately a separate column from `NetworkExposure`. A resource with
  a Deny default and no rules at all is restricted to nobody, which is a different finding from
  one that lets anyone in - and the practical question behind a build agent, a home connection
  or anything else without a fixed address is the former.
- Three commands that between them replace the ViedocAz module the Reporting repo depended on:

  `Kql/Graph/Resource/Unused.kql`, reached as
  `Search-MsecAzureResourceGraph -ResourceType Resource -Name Unused` - unattached public IPs,
  disks, NICs, NSGs, deallocated VMs, stopped app services and empty app service plans, in ONE
  Resource Graph query rather than a Set-AzContext loop running seven Get-Az* per subscription.
  Never mutates the caller's Az context, which such a loop does and has to remember to undo.

  Two predicates in the Az-based original were wrong or missing and are fixed here. Disks: the
  attachment marker is `managedBy` at the TOP level of the resource, not under `properties`,
  and reading the latter reports every disk in the estate as unused - verified 53 of 53 against
  a live tenant where the answer is 21. NICs: a private endpoint's NIC has no virtual machine
  and is very much in use, so excluding them takes the same tenant from 58 unused NICs to 1.

  The query returns the tag bag and applies NO deferral policy. An ArchivedUntil convention is
  organisational rather than an Azure fact, so it belongs to the caller - and Resource Graph is
  the wrong place for it anyway: `todynamic()` re-parses tag JSON and infers types, so a tag
  stored as '2026-06-15' read back through a lowercased copy of the bag arrives as
  '6/15/2026 12:00:00 AM'. Verified against a real tag in a live tenant. In PowerShell the same
  filter is a case-insensitive dictionary and a TryParseExact, with no round-trip to corrupt
  the value.

  `Get-MsecKeyVaultCertificate` - certificate expiry across the accessible vaults. Certificates
  are DATA-PLANE, so Resource Graph cannot see them (`microsoft.keyvault/vaults/certificates`
  returns no rows) and this walks the vaults with Az.KeyVault instead.

  A vault that can be LISTED but not READ INTO emits an `Unreadable` row rather than
  contributing nothing. Listing vaults is control-plane (Reader); listing certificates inside
  one is data-plane, granted separately - and having the first without the second is the normal
  state for an auditor's account. On a live tenant 185 of 258 vaults were unreadable, so
  without that row the inventory would have read as "18 certificates" with nothing to say that
  71% of the estate was never examined.

  `Get-MsecAzureCost` - actual pre-tax spend per subscription or resource group, from Cost
  Management.

  THE CURRENCY IS RETURNED AND THE FIGURE IS NOT ROUNDED. The API answers with both; dropping
  the currency is how a report adds SEK to EUR, and a run spanning two warns rather than
  summing. Rounding in the collector loses the difference between 0.4 and 0, and 0 reads as
  free.

  It goes through `Invoke-AzRestMethod` rather than building the call by hand, which fixes two
  faults in the original: the ARM endpoint had to be branched on per cloud, and since
  Az.Accounts 5 `Get-AzAccessToken` returns a SecureString - so
  `"Bearer $($t.Token)"` interpolates to the literal 'Bearer System.Security.SecureString' and
  every call 401s. Verified against Az.Accounts 5.4.0.

  Cost Management throttles aggressively and the natural use - a loop over every resource group
  - is the shape that trips it. 429s are retried honouring Retry-After, and a scope still lost
  after five attempts warns that the total is short by its cost rather than contributing a
  fabricated 0.
- `Connect-MsecGraphSdk` - signs the Microsoft.Graph PowerShell SDK in with the msec session's
  token, so `Get-Mg*` commands run as the msec app while the certificate's private key stays
  in Key Vault.

  THE USUAL CERTIFICATE ROUTE CANNOT PRESERVE THAT.
  `Connect-MgGraph -CertificateThumbprint` needs the private key present on the machine, so
  anything shipping a PFX or a base64 certificate to a build agent is putting the key
  somewhere it can be copied. The token handoff is the only form that does not.

  The cloud comes from the session and is matched on the Graph ENDPOINT, not by name - the SDK
  calls the Chinese cloud `China` where Azure calls it `AzureChinaCloud`, and an endpoint no
  environment matches warns rather than silently signing in to the wrong cloud.

  The SDK is handed a STATIC token and cannot renew it, unlike msec's own commands.
  `-MinimumMinutes` is how a long report asserts it has the time it needs before starting,
  rather than working for twenty minutes and then failing partway through.

  Microsoft.Graph.Authentication is NOT a module dependency - it is imported only when this
  command is called, so msec still installs and runs on a machine without the Graph SDK.
- `Scripts/Intune/` now also holds the two hand-written scripts that used to live at
  `windows/intune/` and `macos/intune/`, moved verbatim:
  - `Windows/entra-local-admins/detect.ps1` - inventories the Entra principals in the local
    Administrators group. Detection-ONLY: Intune allows a remediation with no remediation
    script, which turns the detection output column into a fleet inventory report.
  - `macOS/local-admins/custom-attribute.sh` - the same question for Macs, as a macOS Custom
    Attribute (macOS has no Remediations feature).

  Their techniques were folded back into `remove-local-admin`, and one of them fixed a real
  bug there - see below.
- `Scripts/Intune/Windows/remove-local-admin` - the first bundled Intune Remediation: a
  detection half that reports whether a named account is in the local Administrators group,
  and a remediation half that removes it.

  A NEW SCRIPT CHANNEL, AND THE FIRST THAT WRITES. Everything under `Scripts/VM/` is read-only
  and safe to run blindly across a fleet; these change a security group on every device the
  Intune assignment covers. `Scripts/README.md` now says so explicitly - an undocumented
  exception is how someone assigns a destructive script fleet-wide expecting a report. It is
  also the one channel msec does not execute: Intune runs it, and
  `Get-MsecIntuneScriptResult -Source Remediation` reads back what happened.

  THE GROUP IS RESOLVED BY SID (`S-1-5-32-544`), NEVER BY NAME. 'Administrators' is localised -
  Administratoren, Administradores - so a script hard-coding the English name finds no group at
  all on those builds and reports every one of them as clean, which is the most dangerous way
  for this to fail.

  MEMBERS ARE ENUMERATED THROUGH ADSI, not `Get-LocalGroupMember`, which throws
  "Failed to compare two elements in the array" whenever the group holds a SID it cannot
  resolve - an orphaned domain account, an Entra principal on some builds. It throws rather
  than skipping, so one stale member makes the whole group unreadable.

  Two safety rails, both checked BEFORE anything is removed so a refusal leaves the group
  untouched: the built-in Administrator (SID ending -500, whatever it has been renamed to) is
  protected, and the group is never emptied - a device with no local administrator cannot be
  recovered locally, and a fleet-wide assignment would do it everywhere at once. After removing,
  the group is RE-READ rather than the call being trusted: the WinNT provider reports success
  for a removal that policy quietly undid, and "fixed" while the account is still an
  administrator is worse than "failed".

  MATCHING AN ENTRA ACCOUNT BY UPN NOW WORKS, AND DID NOT BEFORE. ADSI and LSA give an Entra
  member its SAM-COMPATIBLE name - 'AzureAD\JaneDoe' - never the UPN, so a `$TargetAccount`
  written as 'AzureAD\jane@contoso.com' could never match: the account stayed an administrator
  and the device reported clean. The UPN is recovered from the two IdentityStore caches, and
  the lookup is UNCONDITIONAL rather than skipped when the name already contains an '@' - the
  20-character SAM truncation can cut mid-domain and leave 'anton@examp', which looks like a
  UPN and is not one.
  Detection throws rather than exiting non-zero when the group cannot be read. Intune treats any
  non-zero exit as "issue found, run the remediation", so a machine that could not be read would
  otherwise have its administrators edited on the strength of a failed check.

  `msec/tests/IntuneRemediationScripts.Tests.ps1` guards what is testable off-Windows: both
  halves present and parsing, the group resolved by SID, the safety rails still there, and -
  the hazard the scripts warn about - `$TargetAccount` identical across the pair, since they are
  separate uploads and nothing in Intune enforces that they agree.
- `Export-MsecPostureReport` now measures the device estate itself, on two new sheets fed by
  the Intune device list it already collects - no extra API call:
  - `DevicePlatform` - one column per OS family (Windows, macOS, iOS, Android), device counts.
  - `DeviceOsVersion` - one column per OS RELEASE (Windows 11, Windows 10, iOS 17, macOS 14).

  COUNTS, NOT PERCENTAGES. The question is "how many are still on the old one", and a
  percentage hides an estate that is growing or shrinking underneath it. `TotalDevices` is on
  both sheets so the columns can be checked against it, and a device Intune reported no OS for
  lands in an `Unknown` column rather than being dropped and quietly shrinking the total.

  THE RELEASE, NOT THE RAW VERSION. `10.0.22631.3155` would be a different column on every
  patch Tuesday - the sheet would reshape every run and the chart would become a hundred
  one-point series. `ConvertTo-MsecDeviceOsRelease` collapses builds into their release.

  WINDOWS 11 REPORTS ITSELF AS 10.0, so the build is the only thing separating it from
  Windows 10 - 22000 and above is 11. Splitting on the version string, which is the obvious
  implementation, files every Windows 11 device as Windows 10: exactly backwards for the
  question this exists to answer. Windows Server is NOT guessed at and is documented as such:
  Server 2019 and Windows 10 1809 are both build 17763, and Intune calls both 'Windows'.
- `Export-MsecEntraGroupMemberReport` - the evidence shape applied to group membership: one
  worksheet per group holding its members, a Summary with one row per group, and a chart.

  THE CHART COMPARES GROUPS, not membership types within one. Groups are the x axis, so the
  question it answers is "which of these is the outlier" - the access group that grew, the one
  that is all guests, the one with a service principal in it. A chart per group would be a
  dozen tiny pictures of a number already readable in a cell.

  The Summary is the sheet a reviewer reads first: members per group, how much of that is
  standing versus PIM-eligible, and how much is guests, service principals, nested groups or
  disabled accounts. An empty group still gets a worksheet and a row - "nobody is in it" is a
  finding that disappears if empty groups are skipped - and a group whose membership could not
  be read is marked `Unreadable` rather than counted as a clean zero.

  Sheets are keyed on the group ID, not its name: Entra display names are not unique, and
  keying on the name would put two different groups' members on one sheet under one heading. A
  group actually called 'Summary' or 'Dashboard' is suffixed rather than overwriting the
  report's own sheets.

  The overwrite prompt asks ONCE for the whole run rather than once per group - a wildcard can
  match forty groups, and forty prompts is a prompt nobody reads. It comes after the collection
  here, unlike the VM reports: which worksheets are at stake is not knowable until the names
  have resolved, and reading group membership has no side effects.
- `Get-MsecEntraGroupMember` - the members of one or more Entra groups as flat rows, one per
  (group, member). Takes a list of names, wildcards included, and puts the group name on every
  row so several groups come back as a single table rather than needing a call each.

  PIM-ELIGIBLE MEMBERS ARE INCLUDED, marked `MembershipType 'Eligible'`. Where a group is
  governed by PIM for Groups, people are eligible members rather than actual ones - they appear
  on no `/members` endpoint at all, so a group whose whole membership is eligible reads as
  EMPTY. The group looks unused while a queue of people is one activation away, which is the
  most dangerous direction to be wrong in. Group OWNERS are deliberately excluded: an owner can
  add themselves and then hold what the group grants, which is a real escalation path but a
  different finding, and counting them would overstate the membership.

  MEMBERS ARE NOT ONLY USERS. `MemberType` carries user / group / servicePrincipal / device,
  because filtering to users here would quietly drop the service principal somebody added to an
  access group. A member whose type Graph did not return reads `unknown` rather than being
  assumed to be a user.

  An empty group emits a row with `MemberType 'None'`, and one whose membership could not be
  read emits `'Unreadable'` plus a warning - "the group is empty", "the group does not exist"
  and "I could not look" are three different answers and only the first is good news. A name
  matching nothing is named in a warning; a name matching SEVERAL groups returns all of them,
  since Entra display names are not unique.

  Direct members by default, matching what the portal shows - a nested group is one row.
  `-Recurse` (aliased `-Transitive`) EXPANDS nested groups instead of listing them: the people
  inside come back as members in their own right and the nested group itself does not appear,
  because the question being asked is "who is in here" and a group is not a who. Graph's
  /transitiveMembers returns the nested groups alongside their members, so listing it verbatim
  would show a group as a member AND again as everyone in it.

  Recursion reads PIM-eligible membership for every NESTED group too, not only the ones named.
  Flattening follows actual membership only, so a nested group governed by PIM contributes
  nobody - and the recursion would otherwise be quietly less complete than not recursing.
  A person reachable through two nested groups is one row; Active and Eligible are kept apart,
  since standing membership plus an eligible assignment is a real state worth seeing.- `Export-MsecDefenderDeviceReport` - the evidence shape applied to the Defender estate: one
  row per onboarded device, a worksheet named after the tenant, and a chart per tenant.

  THE CHART IS A DISTRIBUTION, NOT A TOTAL. Devices are banded by discovered-vulnerability
  count (None / 1 to 10 / 11 to 25 / 26 to 50 / 51 to 100 / Over 100), so the chart shows how
  the estate is spread rather than a tenant-wide sum. A long tail of clean machines with three
  disasters and a broad middle where everything is equally behind produce the SAME total and
  need completely different responses.

  It counts twice per band: devices, and how many of those carry at least one CRITICAL
  vulnerability. Critical is a subset of each band rather than its own band, because the two
  do not share an axis - a device with 200 vulnerabilities might have three criticals, so
  plotting them as peers would flatten one into the floor. As a subset it stays readable and
  answers what decides the work order: are the criticals concentrated in the worst machines or
  spread through ones that otherwise look fine?

  'Not assessed' is a band in its own right and sorts to the TOP. It means the vulnerability
  export could not be read at all - no Defender Vulnerability Management licence, or a missing
  permission - so the count is unknown rather than zero, and a warning says how many. Folding
  those into 'None' would report an unmeasured estate as a clean one.
- `Get-MsecDefenderDevice` - the Assets > Devices view from the Defender portal as flat rows:
  one per onboarded device, with its exposure level, risk score and how many vulnerabilities
  have been discovered on it, broken down by severity.

  TWO BULK CALLS, NOT ONE PER DEVICE. The inventory comes from `/api/machines` and the counts
  from `/api/vulnerabilities/machinesVulnerabilities`, the assessment export that returns every
  (device, software, CVE) finding in one paged stream. Per-device
  `/api/machines/{id}/vulnerabilities` would be one round trip per machine - a few thousand
  requests and a throttling wall on a real estate.

  COUNTED AS DISTINCT CVEs, which is what the portal shows. The export is one row per
  (software, CVE), so one CVE affecting three installed versions of a product is three rows and
  one vulnerability; counting rows would inflate every device by a factor that varies with how
  much software it has. `FindingCount` carries the raw row count alongside - the gap between
  the two is the remediation workload.

  A FAILED VULNERABILITY READ GIVES NULL COUNTS, NOT ZERO. Defender Vulnerability Management is
  a separate licence and answers 403 without it; reporting 0 would read as "no device has any
  vulnerability", the most dangerous wrong answer here. The device rows still come back, every
  count is null, and a warning names the permission. A device absent from a SUCCESSFUL export
  reports 0 - which for an inactive device means nobody has looked rather than that it is
  clean, so `HealthStatus` and `LastSeen` are on every row to separate the two.

  The id and severity fields are read under BOTH names Defender uses for them - `machineId` /
  `severity` from `/api/vulnerabilities/machinesVulnerabilities`, and `deviceId` /
  `vulnerabilitySeverityLevel` from `/api/machines/SoftwareVulnerabilitiesByMachine`. Reading
  only one pair is how this first shipped, and against a live tenant it produced a full device
  list with every count reading 0: the call succeeded, every row streamed in, and every row was
  discarded for carrying no id under the name being looked for. A second guard backs it up - if
  rows arrive and NONE can be attributed to a device, the counts are reported as null with a
  warning, because "a response shape this code does not understand" and "an estate with no
  vulnerabilities" are indistinguishable in the output unless one of them says so.
  `Invoke-MsecDefenderRequest` gained `-All`, following `@odata.nextLink`. Reading only the
  first page of an assessment export would silently under-report, which on a vulnerability
  report looks exactly like a clean answer.

  `New-MsecApp` now also requests the WindowsDefenderATP roles `Machine.Read.All` and
  `Vulnerability.Read.All`. An app created before this needs a re-run to pick them up.
- App Service KQL: `Kql/Graph/AppService/All.kql` (one row per site - TLS enforcement, public
  network access, client certificates, vnet integration, managed identity, plan SKU) and
  `Kql/Graph/AppService/StackSettings.kql` (the runtime stack, for the end-of-life question).
  Reached as `Search-MsecAzureResourceGraph -ResourceType AppService [-Name StackSettings]`.

  BOTH QUERIES DELIBERATELY OMIT MOST OF siteConfig. Resource Graph indexes the trimmed
  siteConfig returned by the ARM GET on a site, not the sites/config child resource, which it
  does not index at all - `microsoft.web/sites/config` returns zero rows. The keys are present
  in the property bag holding null, so projecting them yields a column of blanks that reads as
  "not configured" when it means "not visible from here". Verified against a live tenant:
  `minTlsVersion`, `ftpsState`, `ipSecurityRestrictions`, `netFrameworkVersion`, `phpVersion`,
  `nodeVersion`, `javaVersion`, `appCommandLine`, `managedPipelineMode`, `use32BitWorkerProcess`
  and `healthCheckPath` were empty on 61 of 61 sites. Only `linuxFxVersion`, `alwaysOn`,
  `http20Enabled` and `numberOfWorkers` are populated, and only those are used.

  StackSettings therefore carries a `StackSource` column - `LinuxFxVersion` when Resource Graph
  knows, `Unavailable` when it does not - and Windows sites, whose stack lives entirely in the
  fields above, sort to the TOP as `Unknown (Windows)` rather than appearing as sites with no
  stack. A container reports `DOCKER` with its image reference, because what runs inside the
  image is not something Azure knows either; `MutableTag` flags the images pinned to `latest`,
  `trunk` or a branch name, where what ran last week cannot be reconstructed from the row.
- `Get-MsecEntraAppCredential` - every client secret and certificate on the tenant's app
  registrations, one row per CREDENTIAL rather than per app: rolling up per app would have to
  pick a single expiry, which hides the secret lapsing on Friday behind the two good for a
  year. Carries `DaysUntilExpiry`, `IsExpired` and `LifetimeDays`, so it answers both halves of
  the question - the outage (a credential expiring at 3am on the integration nobody owns) and
  the security posture (a secret minted with a two-year lifetime is two years of standing
  access if it leaks).

  `-ExpiringWithinDays` always keeps ALREADY-EXPIRED credentials, whatever the window: expired
  is not less urgent than expiring, and a filter that dropped them would report the opposite of
  the truth.

  App registrations are inventoried completely, including those with NO credentials
  (`CredentialType 'None'`) - that is usually the good state, an app on federated credentials,
  and a report that omitted them could not tell "no credentials" from "not returned". Service
  principals are opt-in via `-IncludeServicePrincipal` and only appear when they actually hold
  one, because a tenant carries hundreds of Microsoft-owned ones with none. Asking for them is
  how a SAML token-signing certificate - whose expiry is a sign-in outage for every user of
  that app - shows up at all.
- `Export-MsecPostureReport` now measures privileged access, on a `PrivilegedAccess` sheet fed
  by `Get-MsecEntraRoleHolder`: standing versus PIM-eligible admins, plus the holders no MFA or
  PIM policy reaches - service principals, guests, and accounts that are disabled and privileged
  at the same time.

  Counted in PEOPLE, not assignments. Someone holding Global Administrator, Security
  Administrator and Exchange Administrator is one administrator; counting rows would report
  three and would move whenever the same faces swapped roles. Holders are counted, so a role
  reaching someone through a role-assignable group counts the person rather than the group.
  `PrivilegedAssignments` and `AllRoleAssignments` are carried alongside, so the ratio between
  people and assignments stays checkable.

  `GlobalAdminHolders` here can exceed `GlobalAdministratorCount` on the TenantSettings sheet.
  They are not in conflict: this one counts effective holders, including group-inherited and
  PIM-eligible ones; the other counts the assignment side.

- The posture report Dashboard now PACKS CHARTS DENSELY instead of reserving a slot for every
  measurement in the canonical list. A measurement that has never produced a row cost a blank
  page before, so a workbook holding only one measurement put its single chart several pages
  down with nothing in between. The canonical list still fixes the ORDER charts appear in; it
  no longer fixes their spacing.

  The trade, taken deliberately: the first time a new measurement lands, every chart below it
  moves down one page. That is a one-way, one-off move - a data sheet never loses its rows, so
  a chart that exists keeps existing and the layout only ever settles further - and position
  was already reasserted on every run, so it adds no new instability. A permanent blank page
  per uncollected measurement was the worse cost.- The Dashboard now repositions a chart whose columns are DISCOVERED from the data - one per
  subscription, per initiative, per Secure Score category - on a run that did not collect that
  measurement. Such a spec carries an empty series list on a partial run, which previously made
  the whole spec be skipped: the chart kept the row it was drawn at while the slots around it
  moved, so the next chart could be drawn straight on top of it. This is what made adding
  `PrivilegedAccess` mid-list safe to pick up with `-Measurement PrivilegedAccess` alone.- `Export-MsecEntraDisabledUserReport` - the evidence shape applied to the directory: one row
  per disabled account, a worksheet named after the tenant, and a chart counting accounts per
  age bucket with a second series for how many of those still hold licences. Graph rather than
  Az, so `Connect-Msec` and no subscription dimension.

  `Unknown` is a bucket in its own right. Entra stores no `disabledDateTime`, so the date comes
  from the audit log and anything past its retention carries a bracket instead. The bracket
  still places an account when both ends fall inside one bucket - "at least 30, at most 60" is
  squarely 30-to-90 - but where it straddles a boundary the answer is Unknown rather than a
  guess. What it is never allowed to be is "under 30 days": anything the audit log cannot see
  is OLDER than the window, never newer.

  The writing half of all three evidence reports now lives in one `Write-MsecEvidenceWorkbook` -
  worksheet naming and collision handling, replace-not-append, the Summary block, per-block
  timestamps and the dashboard. Reports supply their rows, their categories, and an ordered map
  of count columns (one entry gives one bar per category, two give two). That map is what lets
  this report chart accounts and licensed accounts side by side while the VM reports chart a
  single count.
- `Export-MsecVMNtpReport` - the same evidence shape for time synchronisation, via the bundled
  `ntp-status` script. Both the Windows and Linux versions compute the same A.8.17 rule
  (synchronised AND naming a real upstream source), so the verdict means the same thing on
  both platforms.

  `No time source` is its own verdict rather than being folded into `Not synchronised`: a
  Windows machine fallen back to Local CMOS Clock reports itself perfectly synchronised - to
  its own drifting hardware clock. It is not a machine whose daemon stalled, it is one pointed
  at nothing, and the fix is different.

  Both VM reports are now thin wrappers over a shared `Write-MsecVMEvidenceWorkbook`, which
  owns everything they had in common - discovery, running the script, worksheet naming and
  collision handling, snapshot-replace semantics, the shared Summary sheet, per-block
  timestamps and the dashboard. A report supplies only the script to run, a projection from one
  VM's answer to a row, and its ordered list of verdicts. Duplicating that machinery would have
  meant fixing every bug in it twice.

  Rows now sort worst-first by verdict, so the machines nobody could assess are at the TOP of
  the table rather than buried under the healthy ones. That was the other way round while the
  chart plotted a number per VM and a null must not lead; the chart counts per verdict now, so
  the constraint is gone.
- `Export-MsecVMUpdateReport` - an EVIDENCE document of VM patch state: one row per VM,
  showing what that machine itself reported, on a worksheet named after the subscription. A
  fresh file per run rather than a growing one, so nothing is appended and a sheet written
  twice is replaced. Re-run against the same path after `Select-MsecAzureContext` and the next
  subscription gets its own sheet and its own chart in the same document.

  In-guest via the bundled `update-status` Run-Command script rather than
  `Kql/Graph/VM/LastUpdated.kql`, which sees only what Azure Update Manager installed - a VM
  patching itself through Windows Automatic Updates or unattended-upgrades contributes nothing
  there and reads as never updated. The price is a Run-Command per VM: minutes for a fleet, and
  the machines have to be running.

  EVERY VM gets a row, including ones that could not be reached - a stopped machine, a wedged
  agent or a timeout appears with the reason in Error rather than being left out, because
  evidence that quietly omits what it failed on is not evidence. The `Assessment` column keeps
  four states distinct, since they need different follow-up: Up to date, Stale, No update
  history, No answer. Unparseable output (Azure truncates stdout at 4096 bytes) is No answer,
  never a clean machine.

  Rows are ordered worst-first, so the evidence table reads from the most overdue machine down.

  The charts count VMs per assessment rather than plotting days per machine. Days per machine
  left the VMs that could not be assessed with NO BAR - they have no number - so a reviewer
  reading the chart alone saw only the machines that answered and no sign of the ones that did
  not, which on an evidence document is the wrong emphasis entirely. Counts are also readable
  at any fleet size. They come from a shared Summary sheet in long format, one five-row block
  per subscription, and each chart reads only its own block.

  Collection time is on every sheet: `CollectedUtc` per VM row, and per subscription block on
  the Summary sheet. Subscriptions are scanned in separate runs, so one timestamp for the file
  would date every sheet by whichever ran last - claiming a subscription scanned on Monday was
  collected on Friday. The Dashboard heading reports the span rather than a single clock when
  the blocks disagree.
  Worksheet names follow Excel's rules (31 characters, no `: \ / ? * [ ]`), and two
  subscriptions truncating to the same name are told apart by the SubscriptionId on the sheet
  rather than one overwriting the other's evidence.
- `Export-MsecPostureReport` - collects the tenant's posture with the read-only Get-Msec*
  commands and appends one row per measurement to an Excel workbook (via ImportExcel), so
  repeated runs build a time series. One sheet per measurement, each written as an Excel
  TABLE - including Azure Secure Score with one column per subscription, and Intune device
  compliance aggregated from `Get-MsecIntuneDevice`.

  Every chart is on a Dashboard sheet, first in the workbook, stacked one per row and set up
  to print one chart per page - A4 landscape, fit to one page wide, a page break above each
  chart and a print area covering them (charts are drawings anchored to cells, so without a
  print area a PDF export is blank pages).

  Charts are sized for pasting into Word rather than for filling Excel's page, because Word
  pastes at true pixel size with no scaling: A4 portrait at standard margins gives about
  602 px of printable width and landscape about 930, so a chart sized to Excel's own
  landscape page (~1045 px) had to be dragged smaller on every paste. `-ChartWidth` defaults
  to 600 and fits either orientation; `-ChartHeight` defaults to 370 and also sets the row
  band, and therefore where the page breaks fall. Excel printing does not suffer: the print
  area is derived from the chart width, so fit-to-one-page-wide scales the narrow band back
  up to fill the sheet. `-ResetDashboard` rebuilds the sheet, which is how a size change
  reaches charts that already exist - they are otherwise created once and only
  range-refreshed.
  Chart series use ordinary cell ranges. Structured table references were tried first, on
  the theory that Excel would grow the series with the table - EPPlus stores and reads those
  back happily, so it tested green, and Excel rendered every chart BLANK. Ordinary ranges
  are pinned to the row count they were written with, so the ranges are refreshed in place
  as rows are appended; the chart itself is never rebuilt, and its title, position, size,
  colours and any series added by hand all survive.

  No series colours are set: Excel's own theme palette applies, so the charts match the
  workbook and follow it if the theme changes.

  `-TableStyle` sets the Excel table style on every data sheet, default `Medium2`. It is
  applied on the append path as well as on create, so changing it restyles sheets that
  already exist rather than leaving them on the old style.
  `-Target` puts goals on the charts: `@{ MfaCoverage = 95; PolicyCompliance = 80 }` writes a
  Target column holding that number on every row, which Excel draws as a flat line across the
  chart. Only the sheets named get one, so charts without a target are untouched, and the
  series is added last so it takes the final theme colour and reads as an annotation rather
  than as another measurement. The value is in the chart's own units, so a count works too -
  `@{ Incidents = 0 }` draws a zero line under the severity counts. Because it is stored per
  row, raising a target later shows as a step in the line instead of silently restating the
  earlier months at the new number.
  Chart POSITION on the Dashboard is now reasserted on every run rather than set once. Slots
  come from the index in the canonical chart list, so adding a measurement anywhere but the
  end shifts every later slot - and a chart left where it was got the newcomer drawn straight
  on top of it, invisible, with nothing to say so. Everything else about a chart is still left
  alone: title, size, colours and hand-added series.
  A `PolicyCompliance` sheet and chart, one column per Azure Policy initiative, fed by
  `Kql/Graph/Policy/Compliance.kql`. Where an initiative is assigned to several subscriptions
  the figure is recomputed from the resource counts - total compliant over total graded - and
  NOT averaged from the per-subscription percentages, which would give a four-resource sandbox
  the same weight as a four-hundred-resource production subscription. Columns are ordered by
  how much of the estate each initiative grades, so the first chart series is the broadest;
  initiatives grading nothing are left out entirely, and `-PolicyInitiative` takes wildcards
  for narrowing. Past eight initiatives it warns that the chart will be hard to read rather
  than quietly drawing it.

  This is the one measurement needing an Az context rather than just the msec session, so it
  fails on its own and lands in RunLog if `Connect-AzAccount` has not been run. It is also
  SKIPPED when the Az context is on a different tenant than the session: `Connect-Msec` does
  not move the Az context, so a per-tenant export loop would otherwise write tenant A's policy
  compliance into tenant B's workbook - a plausible number, in the wrong file, in a compliance
  report. The skip and its reason are recorded in RunLog.
  Azure Secure Score is per-subscription rather than a tenant-wide average - averaging a
  well-run production subscription with a neglected sandbox describes neither.
  `-Subscription` filters which ones appear, taking names or ids.

  Rows accumulate and are never deduped. Secure Score is trimmed to its newest snapshot,
  because `Get-MsecSecureScore` returns ~90 days on every call and appending all of it would
  add ~90 near-duplicate rows per run.

  Collection degrades rather than fails: a tenant missing a Defender or Entra P1 licence
  gets a 403 on some measurements, and those are recorded in a RunLog sheet while every
  other measurement still lands. A failed measurement contributes no row, leaving a visible
  gap rather than a fabricated zero.
- `Kql/Graph/Policy/Compliance.kql` - compliance score per initiative assignment per
  subscription, run with
  `Search-MsecAzureResourceGraph -ResourceType Policy -Name Compliance`. `-Subscription`
  scopes it server-side; the result aggregates to a few dozen rows, so picking initiatives is
  a `Where-Object` away.

  The score is per RESOURCE, matching the portal. `policystates` holds one row per resource
  per policy, so an initiative with 200 policies over 50 resources is 10,000 rows - counting
  those compliant-vs-total answers "what share of checks passed", a much flatter number where
  one bad resource failing twenty rules barely registers. The query rolls up to the resource
  first (non-compliant if ANY policy in the initiative says so), then counts resources.
  `NonCompliantChecks` is kept alongside for the size of the remediation job.
- `Get-MsecEntraDisabledUser` - every account with `accountEnabled = false`, how long it has
  been disabled, and how many licences it still holds.

  Entra records no `disabledDateTime`, so the duration comes from the directory audit log -
  an `Update user` event whose `modifiedProperties` show `AccountEnabled` going `[true]` ->
  `[false]`. Those logs retain 30 days on P1/P2 and 7 on the free tier, so an account
  disabled inside that window gets an exact `DisabledSince`, `DisabledDays` and `DisabledBy`,
  and one disabled before it gets a BRACKET instead: `DisabledAtLeastDays` (nothing found in
  the window searched) and `DisabledAtMostDays` (days since its last successful sign-in,
  since a disabled account cannot sign in). `DisabledSource` says which of the two you have
  rather than leaving it to be inferred from a null.

  The upper bound comes from `signInActivity`, which Entra persists on the user object rather
  than serving from a log - so unlike `DisabledSince` it is not capped at the audit retention
  window and reaches back years (it does need Entra ID P1). It rests specifically on
  `lastSuccessfulSignInDateTime`: `lastSignInDateTime` records the last interactive ATTEMPT,
  and a disabled account still gets attempted, so bounding on it would report "disabled at
  most 7 days" for an account switched off three years ago. Where no successful sign-in is
  recorded the bound is left blank rather than guessed. All four timestamps are surfaced -
  `LastSignIn` (newest of any kind), `LastSuccessfulSignIn`, `LastInteractiveSignIn` and
  `LastNonInteractiveSignIn`, the last being how a service account looks dead interactively
  while being busy every hour.
  "Last updated" is three columns, because Graph exposes no `lastModifiedDateTime` on a user
  and the three real signals answer different questions: `LastDirectoryChange` (+ `...What`,
  naming which properties moved) is the newest audit event against the object and is bounded
  by the same retention, so null means "not in the window" rather than "never";
  `LastPasswordChange` is unbounded and usually the best marker of when a disabled account
  was genuinely last in use; `OnPremisesLastSync` catches the orphan case, where sync is
  still enabled but the on-premises source object is gone.
  Degrades rather than fails: a tenant without Entra ID P1 rejects `signInActivity`, so the
  call is retried without it; an unreadable audit log costs the dates but not the user list.
  Needs `User.Read.All` and `AuditLog.Read.All`, both already granted by `New-MsecApp`.
- `Get-MsecIntuneScriptResult` - per-device results from all five Intune script collections:
  remediations (deviceHealthScripts), platform scripts (deviceManagementScripts and
  deviceShellScripts), macOS custom attributes and custom compliance discovery scripts.
  The data behind the portal's Excel export. Reads deviceRunStates only - per-user results
  from user-context scripts are not covered.

### Removed
- `Export-MsecWordReport`. It was the module's only optional-dependency command, requiring
  PSWriteOffice to be installed separately, and its tests skipped entirely when that module
  was absent - so on CI and on most machines it was shipped but never exercised. Pipe to
  `Export-Csv`, or to `Export-Excel` from the ImportExcel module, for the same evidence.

### Changed
- `Get-MsecSharePointSiteUser -Url <site>` now CONNECTS ITSELF. Every other command in the
  module is one call after `Connect-Msec`; requiring a separate `Connect-MsecSharePointOnline`
  first made SharePoint the exception for no good reason.

  It does so WITHOUT moving the caller's session. PnP keeps a single ambient connection, so a
  command that simply called `Connect-PnPOnline` would leave the caller pointed at a different
  site than they were on - a side effect nobody asked for that only shows up later. The
  connection is created with `Connect-MsecSharePointOnline -PassThru` (new switch, wrapping
  PnP's `-ReturnConnection`) and threaded through each PnP call explicitly. Verified live:
  reading site B left `Get-PnPConnection` pointing at site A.

  Omitting `-Url` still uses the ambient connection, so existing scripts are unaffected.- `Select-MsecAzureContext` now RECONNECTS THE MSEC APP SESSION to the tenant it switches to,
  when that tenant has been connected before. `Connect-Msec` remembers the vault name, client
  id and certificate name per tenant on a successful connection; switching context replays
  them.

  msec runs on two identities - the Az context is you, the msec session is the app
  registration - and switching one left the other pointing at the tenant you just left, so
  Graph and Defender calls kept answering for the wrong tenant. That was already detected; it
  was a warning telling you to run Connect-Msec again. Now it is fixed where it can be, and the
  warning remains for the cases it cannot (no saved profile, or -NoConnect).

  NO SECRET IS STORED, and none is needed: msec signs its client assertion inside Key Vault and
  the private key never leaves it. The profile holds what you would type on the command line,
  under the tenant's own folder beside the completion caches, so two tenants can never overwrite
  each other. `-NoSave` on Connect-Msec skips writing one; `-NoConnect` on
  Select-MsecAzureContext skips replaying one.

  Written only AFTER the tokens are obtained, so a saved profile always describes a connection
  that worked rather than one that was merely typed. A missing, malformed or incomplete profile
  is treated as no profile rather than as an error mid-switch, and a reconnect that fails warns
  without failing the context switch - the switch is what was asked for and it stands.
- The four snapshot reports (`Export-MsecVMUpdateReport`, `Export-MsecVMNtpReport`,
  `Export-MsecEntraDisabledUserReport`, `Export-MsecDefenderDeviceReport`) now ASK before
  replacing a worksheet that already holds evidence, and take `-Force` to skip the question.
  They replace rather than append - that is the point of a snapshot - which also means a
  mistyped path silently destroyed last month's evidence.

  Asked only when something would actually be lost. A new file, or a new tenant or subscription
  inside an existing file, is not a question worth interrupting for; a sheet already holding
  THIS subject's rows is. Two owners whose names truncate to the same 31 characters are a
  collision rather than an overwrite - the newcomer gets its own suffixed sheet - so that does
  not prompt either. The prompt names the sheet, its row count and when it was collected, so
  the answer can be given on the facts.

  ASKED BEFORE THE COLLECTION, NOT AFTER, so declining costs nothing: no directory enumeration,
  and on the VM reports no Run Command invocations against live machines.

  `Resolve-MsecEvidenceSheet` is shared by the prompt and by the writer, so the sheet the
  caller was asked about is necessarily the sheet that gets written - asking the question in
  two places is how a confirmation ends up guarding the wrong one.

  Unattended runs need `-Force`: a scheduled task has no one to answer, and `ShouldContinue` in
  a non-interactive host is an error rather than a default.

  `Confirm-MsecEvidenceOverwrite` also takes a SET of subjects, so a report writing many sheets
  in one run asks a single question naming all of them.

### Fixed
- `Get-MsecSharePointSiteUser` read no groups at all. `Get-PnPGroup @($spec.Param)` is an ARRAY
  SUBEXPRESSION, not splatting - it passed a one-element array that bound positionally to
  `-Identity`, so every call failed. Found on the first real run against a live site.

  The symptom was the more instructive half: the catch block reported "this site has no
  associated Owner group", asserting a cause it had not checked, so a code defect read as a
  property of the tenant. The message now says what happened before what might have caused it.
- `PrincipalType` was inconsistent between the two paths that produce it - SharePoint types a
  direct member 'User', Graph types an expanded group member '#microsoft.graph.user'. The same
  person therefore read as 'User' or 'user' depending on how they got access, and a filter on
  either silently missed the other. Both are normalised to Graph's lowercase form now.
- A missing msec session no longer degrades silently. Expanding a security group needs a Graph
  session as well as the PnP one; without it every group came back `IsResolved = $false`, which
  is exactly what a DELETED group looks like - so the output read as a tenant full of orphaned
  groups rather than as a missing connection. It now warns up front, and every unresolved row
  carries an `UnresolvedReason` distinguishing "no session" from "group could not be read".- `Search-MsecAzureResourceGraph` now fingerprints the QUERY into its cache key. The key was the
  resource type, the name and the subscription scope - none of which change when the .kql does -
  so editing a bundled query kept serving rows in the old shape, and the author reasonably
  concluded the edit had not applied. Found the hard way while editing `Resource/Unused.kql`.

  A cached result written before this has no fingerprint and is treated as a miss rather than
  trusted, since it may have been written by a different query.- An OS release or device platform that EMPTIES OUT now reports 0 rather than blank. Those
  columns are discovered from the data, so the run where the last device leaves iOS 26 simply
  stops producing that column - and `Export-Excel -Append` maps by name, leaving the cell
  empty. Excel plots a blank as a GAP, so the line stopped dead exactly where it should have
  descended to zero: "we stopped measuring" instead of "nobody is on it any more", which is the
  good news the sheet exists to show.

  It also stops the sheet being rewritten every time the release set shrinks - a column going
  missing is schema drift as much as a column appearing, and a rewrite is the one operation
  that discards manual formatting.

  Deliberately NOT done generally: this is right for counts and wrong for scores. A
  subscription that drops out of AzureSecureScore was not measured, and writing 0 there would
  report a perfect-zero score rather than an absence. History is left alone too - a release that
  did not exist yet keeps its blank, which is different from nobody being on it.
- A DAMAGED WORKBOOK COULD BE SILENTLY REPLACED BY A FRESH ONE, losing every sheet in it rather
  than just one. Export-Excel can CREATE the file, so it treats "cannot read this" and "nothing
  here yet" identically - and a zero-byte file is indistinguishable from a new one. A OneDrive
  placeholder that never downloaded, or a run killed mid-save, therefore got replaced by a
  workbook holding one sheet and one row, and the write reported success. Reproduced.

  `Assert-MsecExcelWorkbook` now runs before either writer touches the path: a file that exists
  but is empty, unopenable, or holds no worksheets is refused, and left exactly as found so
  version history can still restore it. A path that does not exist is still a normal first run.
- A SHEET REWRITE COULD SILENTLY DISCARD EVERY ROW EVER COLLECTED. `Write-MsecExcelSheet`
  rewrites with `-ClearSheet`, so whatever it reads back first is the entire surviving record -
  and it caught every failure of that read and carried on with an empty history, reporting the
  loss only through `Write-Verbose`. Any transient failure to read the workbook (open in Excel,
  a sync client mid-write) therefore reduced a posture sheet to the single row from that run.
  Reproduced at five rows in, one row out.

  It now reads the sheet's row count from the package BEFORE reading its contents, which is
  what makes "there is nothing to preserve" distinguishable from "I could not read what is
  there". Only the first proceeds; the second throws, and the file is left untouched. Reading
  back FEWER rows than the sheet holds is refused on the same grounds - a truncated history is
  not recoverable, a refusal is.

  This only ever fired on a RESHAPE (a measurement changing its column set); ordinary appends
  go through `Export-Excel -Append` and never took this path.
- A sheet that cannot be written now costs only its own row rather than the whole run, matching
  how the collect half already degraded. The refusal above would otherwise throw away nine
  successfully collected measurements to protect one, and the failure is recorded in RunLog.
- A column that appeared AFTER a posture-report chart was first drawn now gets a series on it.
  The sheets with dynamic columns - one per Azure subscription, per Secure Score category, per
  policy initiative - grow a column whenever the estate does, and the dashboard only ever
  refreshed the ranges of series the chart already carried. So a new subscription landed on the
  AzureSecureScore sheet, appeared in the schema-drift warning, and was then absent from the
  chart indefinitely: the report quietly under-reported the estate while looking complete.
  Series are only ever ADDED, so one added by hand in Excel still survives.
- A series whose column is still on the sheet but which this run did not collect now keeps
  growing with the sheet. A subscription that drops out of the Az context keeps its column
  (`Write-MsecExcelSheet` takes the UNION of old and new columns, so history is never dropped)
  but its chart range stopped at the row count it had when last collected - so the line ended
  early, reading as the data stopping rather than the subscription leaving.
- `New-MsecApp` now requests `DeviceManagementScripts.Read.All`. Intune scripts are a
  separate scope from `DeviceManagementConfiguration.Read.All`, which does not cover
  deviceHealthScripts or deviceCustomAttributeShellScripts even though both sit under
  /deviceManagement beside the configuration policies - they answer 403 without it.
- `New-MsecApp` reported its permission grants only through `Write-Verbose`, so a re-run
  that added a dozen app roles printed one line about finding the app and nothing about the
  grants - indistinguishable from having done nothing. It now prints a summary, returns
  `GrantedNow` / `AlreadyGranted` / `UnavailableRoles`, and says to reconnect: consent does
  not apply to a token that was already issued, so re-running to fix a 403 and retrying in
  the same session hits the same 403.

## [0.1.0] - 2026-08-20

First release.

### Added
- **Secure Score** - `Get-MsecSecureScore` (overall and per category, over time),
  `Get-MsecAzureSecureScore` (Defender for Cloud, per subscription),
  `Get-MsecDefenderScoreExposure`, `Get-MsecDefenderScoreDeviceConfiguration`.
- **Defender XDR** - `Get-MsecDefenderIncidentStats`, `Get-MsecDefenderEmailStats`.
- **Entra ID** - `Get-MsecEntraTenantSecuritySetting`, `Get-MsecEntraLicense`,
  `Get-MsecEntraRoleHolder`, `Get-MsecEntraConditionalAccessPolicy`,
  `Get-MsecEntraConditionalAccessStats`, `Get-MsecEntraConditionalAccessSignInLog`,
  `Get-MsecEntraMfaRegistration`, `Get-MsecEntraMfaRegistrationStats`,
  `Get-MsecEntraMfaEvidence`, `Convert-MsecEntraSid`.
- **Intune** - `Get-MsecIntuneConfigurationProfile`, `Get-MsecIntuneCompliancePolicy`,
  `Get-MsecIntuneDevice`, `Get-MsecIntuneScriptResult`.
- **Azure** - `Search-MsecAzureResourceGraph`, `Search-MsecLogAnalytics`,
  `Invoke-MsecAzureVMScript`, `Select-MsecAzureContext`.
- **Azure DevOps** - `Get-MsecAzureDevOpsServiceConnection`.
- **Session** - `New-MsecApp`, `Connect-Msec`, `Disconnect-Msec`. The private key stays
  in Azure Key Vault; tokens are JWT client assertions signed there.
- **Reporting** - `Export-MsecWordReport`.

### Notes on the output shape

These are the decisions most likely to surprise, and the reasoning is in each command's
help under `.NOTES`:

- **Directory roles are matched by `roleTemplateId`, never by display name.** Graph
  returns Global Administrator as *Company Administrator* on many tenants, display names
  are localisable, and a tenant can rename a role - so a name comparison silently reports
  zero. `Get-MsecEntraRoleHolder -Role 'Global Administrator'` resolves through the
  canonical map and matches either way.
- **`Get-MsecEntraRoleHolder` separates the assignee from the holder.** A role assigned to
  a group reports the group in `Principal*` and each member in `Effective*`, so counting
  administrators and counting grants are different questions that no longer contaminate
  each other. PIM-eligible assignments are included.
- **Intune assignment targets are typed columns, not a summary string.** `AssignmentType`,
  `AssignmentGroup` and `AssignmentExcludedGroup` are arrays, so `-contains` is exact;
  `msec.format.ps1xml` flattens them for display only. An assignment count cannot tell
  *All Users plus an exclusion group* from *two unrelated groups*.
- **Unmeasured is `$null`, measured-and-zero is `0`.** A failed read never reports the same
  value as a successful one that found nothing; where a command can say why, it does.
