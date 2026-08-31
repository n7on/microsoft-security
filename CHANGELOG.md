# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
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
