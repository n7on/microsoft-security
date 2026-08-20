---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraConditionalAccessPolicy

## SYNOPSIS
Lists every Microsoft Entra Conditional Access policy as flat rows, with
the conditions and grant controls flattened to top-level columns.

## SYNTAX

```
Get-MsecEntraConditionalAccessPolicy [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/identity/conditionalAccess/policies and
projects each policy to a PSCustomObject.
The Graph response is deeply
nested (conditions.users.includeGroups, conditions.applications.*, etc.);
the projection flattens the audit-relevant arrays to top-level columns
so Where-Object / Group-Object / Export-Excel work naturally.

Use this for inventory ("what CA policies are configured, what do they
enforce, who are they targeted at").
For effectiveness data ("did the
policy fire?
was anyone blocked?"), see Get-MsecEntraConditionalAccessSignInLog
- that comes from sign-in events, not policy objects.

Requires the 'Policy.Read.All' application permission.
A clearer error is
raised on the typical 403.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraConditionalAccessPolicy | Group-Object State
```

### EXAMPLE 2
```
# Policies that DO require MFA - the headline CA evidence for an audit.
Get-MsecEntraConditionalAccessPolicy |
    Where-Object Requires -contains 'mfa' |
    Select DisplayName, State, IncludedGroups
```

### EXAMPLE 3
```
# Report-only policies - they don't enforce, just observe. Worth tracking.
Get-MsecEntraConditionalAccessPolicy |
    Where-Object State -eq 'enabledForReportingButNotEnforced'
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per policy. See .NOTES for the projection.
## NOTES
Each row is a \[PSCustomObject\] with PSTypeName 'MsecEntraConditionalAccessPolicy'.
That type has a DefaultDisplayPropertySet (DisplayName, State, Requires,
IncludedGroups) registered in the module's .psm1 - so Format-Table shows a
clean 4-column view by default.
The Raw column is fully accessible via
$row.Raw or | Format-List, it just doesn't clutter the default table.

Projection (Graph field path -\> output property):
  id                                            -\> Id
  displayName                                   -\> DisplayName
  state                                         -\> State
  createdDateTime / modifiedDateTime            -\> CreatedDateTime / ModifiedDateTime
  conditions.users.includeUsers/Groups/Roles    -\> IncludedUsers / IncludedGroups / IncludedRoles
  conditions.users.excludeUsers/Groups/Roles    -\> ExcludedUsers / ExcludedGroups / ExcludedRoles
  conditions.applications.includeApplications   -\> IncludedApps
  conditions.applications.excludeApplications   -\> ExcludedApps
  conditions.applications.includeUserActions    -\> UserActions
  conditions.platforms.includePlatforms         -\> IncludedPlatforms
  conditions.platforms.excludePlatforms         -\> ExcludedPlatforms
  conditions.locations.includeLocations         -\> IncludedLocations
  conditions.locations.excludeLocations         -\> ExcludedLocations
  conditions.clientAppTypes                     -\> ClientAppTypes
  conditions.signInRiskLevels                   -\> SignInRiskLevels
  conditions.userRiskLevels                     -\> UserRiskLevels
  grantControls.operator                        -\> GrantOperator    ('OR' / 'AND')
  grantControls.builtInControls                 -\> Requires         (mfa, compliantDevice, ...)
  \<entire policy object verbatim from Graph\>    -\> Raw             (PSObject; full detail)

Use Raw for audit dives, JSON backup, or change-diff:
  Get-MsecEntraConditionalAccessPolicy |
      ForEach-Object { $_.Raw | ConvertTo-Json -Depth 20 |
                       Set-Content "./ca-policies/$($_.Id).json" }

## RELATED LINKS
