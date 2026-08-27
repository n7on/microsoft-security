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
