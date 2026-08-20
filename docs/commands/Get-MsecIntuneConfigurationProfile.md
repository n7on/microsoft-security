---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneConfigurationProfile

## SYNOPSIS
Lists Intune configuration profiles - Settings Catalog policies and classic device
configuration profiles - merged into one stream, with the full Graph object kept
in a Raw column for audit / backup / diff.

## SYNTAX

```
Get-MsecIntuneConfigurationProfile [[-Source] <String>] [-IncludeStatus] [-IncludeSettings]
 [-NoGroupNameLookup] [<CommonParameters>]
```

## DESCRIPTION
Microsoft is migrating Intune configuration from the older "device configuration
profiles" (Templates) model to the newer "Settings Catalog" model.
The Intune
portal under Devices \> Configuration profiles shows both side by side, and most
tenants have a mix.

This function queries both Graph endpoints:
  - /beta/deviceManagement/configurationPolicies (Settings Catalog - new; still beta-only)
  - /v1.0/deviceManagement/deviceConfigurations  (classic templates - legacy; GA)

and projects each entry to a uniform shape with a Source discriminator
('SettingsCatalog' or 'Templates') so the rows can be combined or filtered.

Each row also carries:

  - Assignments: pulled via $expand in the same call - no extra round trip.
    AssignmentCount is how many; the rest say WHO, as separate typed columns so
    each can be filtered on its own:

    All of the collection columns are ARRAYS, not joined strings, so they can be
    tested exactly - \`Where-Object AssignmentGroup -contains 'sg-pilot-ring'\`.
The
    default table renders them comma-separated via Msec.format.ps1xml, so the
    display is flat while the data is not; a joined property would force
    -like '*sg-pilot-ring*' and match 'sg-pilot' too.

      AssignmentType          'AllUsers', 'AllDevices', 'Group',
                              'ExclusionGroup', 'ConfigManagerCollection' -
                              distinct, so three groups report 'Group' once
      AssignmentGroup         the INCLUDED group names (or ids)
      AssignmentExcludedGroup the EXCLUDED group names, kept apart because a
                              carve-out changes what the policy means
      HasAssignmentFilter     true when a device filter narrows any assignment
      AssignmentDetail        one structured row per assignment

    The target type costs nothing extra - it is already on the expanded
    assignment.
Group display NAMES are resolved by default, one cached Graph
    call per DISTINCT group; -NoGroupNameLookup skips that for a zero-extra-call
    sweep and reports group ids instead.

  - Status (optional, -IncludeStatus): per-policy check-in counts.
Templates use
    /deviceStatusOverview (one call per policy); Settings Catalog uses the Intune
    Reports API exportJob (one job per tenant, ~5-15s, results cached in a
    hashtable for the per-policy loop).

  - Raw: the verbatim Graph object for the policy.
For Templates this includes
    every configured setting inline (the Graph response is naturally deep).
For
    Settings Catalog, Raw only contains the policy metadata unless you pass
    -IncludeSettings, which fetches /configurationPolicies/{id}/settings per
    policy and merges the result into Raw.settings.

The Raw column replaces the old Export-MsecIntuneConfiguration function - JSON
backup, change diffs, and audit drill-downs all work directly off Raw:

    # Backup all SC policies' full config as JSON files
    Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -IncludeSettings |
        ForEach-Object {
            $name = $_.DisplayName -replace '\[\/:*?"\<\>|\]', '_'
            $_.Raw | ConvertTo-Json -Depth 20 | Set-Content "./intune/$name.json"
        }

Required Graph permission: DeviceManagementConfiguration.Read.All (Application).

## EXAMPLES

### EXAMPLE 1
```
# Standard inventory. Target types and named groups are in the default table.
Get-MsecIntuneConfigurationProfile | Format-Table
```

### EXAMPLE 2
```
# Fastest possible sweep: two Graph calls total, no per-group lookups. Groups
# come back as ids; the target TYPES are unaffected.
Get-MsecIntuneConfigurationProfile -NoGroupNameLookup |
    Format-Table DisplayName, AssignmentType, AssignmentCount
```

### EXAMPLE 3
```
# Which policies are tenant-wide? These apply to everyone who enrols tomorrow.
# An exact test on a typed column, not a match against a rendered phrase.
Get-MsecIntuneConfigurationProfile |
    Where-Object { $_.AssignmentType -contains 'AllUsers' -or
                   $_.AssignmentType -contains 'AllDevices' }
```

### EXAMPLE 4
```
# Assigned to nobody - configured, reviewed, and doing nothing.
Get-MsecIntuneConfigurationProfile | Where-Object AssignmentCount -eq 0
```

### EXAMPLE 5
```
# Tenant-wide but carved into by an exclusion. The riskiest thing to misread as
# "applies to everyone", and the reason a count was never enough.
Get-MsecIntuneConfigurationProfile |
    Where-Object { $_.AssignmentExcludedGroup } |
    Format-Table DisplayName, AssignmentType, AssignmentExcludedGroup
```

### EXAMPLE 6
```
# Every group that any profile is scoped to, and how many profiles each carries.
Get-MsecIntuneConfigurationProfile |
    ForEach-Object { $_.AssignmentDetail } |
    Where-Object TargetType -in 'Group', 'ExclusionGroup' |
    Group-Object GroupName -NoElement | Sort-Object Count -Descending
```

### EXAMPLE 7
```
# Assignments narrowed by a device filter, where the stated target overstates
# the real reach.
Get-MsecIntuneConfigurationProfile |
    Where-Object HasAssignmentFilter |
    Select-Object DisplayName, AssignmentType, AssignmentGroup
```

### EXAMPLE 8
```
# Find policies failing on many devices
Get-MsecIntuneConfigurationProfile -IncludeStatus |
    Where SuccessPercent -lt 95 |
    Sort SuccessPercent | Select DisplayName, SuccessPercent, ErrorCount
```

### EXAMPLE 9
```
# Audit drill-down: pull one specific SC policy's full settings
$row = Get-MsecIntuneConfigurationProfile -IncludeSettings |
    Where Id -eq 'sc-1'
$row.Raw | ConvertTo-Json -Depth 20
```

## PARAMETERS

### -Source
Restrict to one generation:
  - 'All'             (default) both endpoints
  - 'SettingsCatalog' only Settings Catalog policies
  - 'Templates'       only classic device configuration profiles

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeStatus
Fetch the per-policy device check-in counts.
Adds one extra Graph call per policy
(the Settings Catalog call also paginates per device), so it can be noticeably
slower on large tenants.
Off by default.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeSettings
For Settings Catalog policies: fetch each policy's settings via
/configurationPolicies/{id}/settings and merge them into Raw.settings.
Adds one
extra Graph call per SC policy.
Off by default.
Templates already include their
settings inline in the list response - this switch is a no-op for them.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -NoGroupNameLookup
Report assignment groups by id instead of resolving their display names.

Names are resolved by DEFAULT, because a GUID in an AssignmentGroup column is not
an answer to "who is this aimed at" - it is the question again.
The cost is one
Graph call per DISTINCT group, cached for the run, which is what makes this
different in kind from -IncludeStatus and -IncludeSettings: those scale with the
number of policies, this scales with the (much smaller) number of groups Intune
assignments actually use.
A tenant with 200 policies sharing 12 groups pays 12
calls, not 200.

Resolution needs 'Group.Read.All', which New-MsecApp already grants.
If it is
missing, one warning is raised for the whole run and ids are used - so a missing
permission degrades the names, never the target types.

Use this switch when you want the inventory with provably no per-group calls, or
to silence the lookup entirely on an app that cannot read groups.
AssignmentType,
AssignmentCount and HasAssignmentFilter are unaffected by it: those come from the
expanded assignment and cost nothing either way.

A group that no longer exists is reported as '\<deleted group {id}\>' rather than
as a blank: a policy assigned only to a deleted group is deployed to nobody,
which is a finding and not a gap in the output.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject with PSTypeName 'MsecIntuneConfigurationProfile'. Default
### Format-Table view is: DisplayName, Source, Platform, AssignmentType,
### AssignmentGroup, Status
### (last column only present with -IncludeStatus). All other columns including
### Raw remain available via Select-Object / Format-List / direct property access.
### Status values (only present with -IncludeStatus):
###   - NotDeployed   - AssignmentCount=0
###   - NotReporting  - assigned but no devices currently evaluated
###   - Healthy       - 100% success, no errors or conflicts
###   - Degraded      - any errors / conflicts / pending or partial success
## NOTES

## RELATED LINKS
