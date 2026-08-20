# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
  `Get-MsecIntuneDevice`.
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
  `msec.format.ps1xml` flattens them for display only. An assignment count cannot tell
  *All Users plus an exclusion group* from *two unrelated groups*.
- **Unmeasured is `$null`, measured-and-zero is `0`.** A failed read never reports the same
  value as a successful one that found nothing; where a command can say why, it does.
