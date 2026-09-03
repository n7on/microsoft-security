# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
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

### Fixed
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

### Fixed
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
- **Azure DevOps** - `Get-MsecAdoServiceConnection`.
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
  `Msec.format.ps1xml` flattens them for display only. An assignment count cannot tell
  *All Users plus an exclusion group* from *two unrelated groups*.
- **Unmeasured is `$null`, measured-and-zero is `0`.** A failed read never reports the same
  value as a successful one that found nothing; where a command can say why, it does.
