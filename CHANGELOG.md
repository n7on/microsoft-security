# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
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
