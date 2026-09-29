---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneCompliancePolicy

## SYNOPSIS
Lists Intune compliance policies - what defines whether a device is "compliant"
(and therefore allowed through Conditional Access).

## SYNTAX

```
Get-MsecIntuneCompliancePolicy [-IncludeStatus] [-IncludeSettings]
 [<CommonParameters>]
```

## DESCRIPTION
A POLICY THAT CHECKS NOTHING LOOKS EXACTLY LIKE A HEALTHY ONE.
Name, platform and
assignment count say nothing about whether the policy enforces anything, and a policy
with no settings configured reports every device as compliant because there is nothing
to fail.
Measured live: a macOS baseline assigned to all licensed users since 2021 had
osMinimumVersion empty and password, encryption, firewall and system-integrity all
False - 17 of 19 devices "compliant", including two on an unsupported major version.

So ConfiguredCheckCount and ChecksNothing are on every row, not behind a switch.
The
rules for deciding whether a setting counts are written down in
Get-MsecCompliancePolicyCheck rather than guessed at per platform.

OsMinimumVersion IS PROMOTED OUT OF THE SETTINGS because it is the one compliance
setting that turns a device inventory into a patch-compliance answer.
Empty means the
policy does not care what version a device runs, which is a finding rather than a blank. 
Compliance policies are *separate from* configuration policies in Intune:
  - Configurations enforce a state on a device (e.g.
"BitLocker on").
  - Compliance policies measure whether a state is met (e.g.
"Encryption required"),
    and report compliant/non-compliant per device.
Conditional Access then gates
    access on that.

Queries /v1.0/deviceManagement/deviceCompliancePolicies, including assignments via
$expand (one call, no extra round trip).
Per-policy device check-in counts are opt-in
via -IncludeStatus (one extra Graph call per policy).

Required Graph permission: DeviceManagementConfiguration.Read.All (Application) -
the same permission Get-MsecIntuneConfigurationProfile uses.

## EXAMPLES

### EXAMPLE 1
```
# Assigned, reporting compliant, and enforcing nothing.
Get-MsecIntuneCompliancePolicy |
    Where-Object { $_.AssignmentCount -gt 0 -and $_.ChecksNothing }
```

### EXAMPLE 2
```
# Which platforms have a minimum OS version, and which do not.
Get-MsecIntuneCompliancePolicy |
    Format-Table DisplayName, Platform, AssignmentCount, OsMinimumVersion, ConfiguredCheckCount
```

### EXAMPLE 3
```
# Quick inventory:
Get-MsecIntuneCompliancePolicy | Format-Table -AutoSize
```

### EXAMPLE 4
```
# Compliance policies with devices failing:
Get-MsecIntuneCompliancePolicy -IncludeStatus |
    Where-Object SuccessPercent -lt 100 |
    Sort-Object SuccessPercent |
    Select-Object DisplayName, Platform, SuccessPercent, ErrorCount
```

## PARAMETERS

### -IncludeStatus
Fetch the per-policy device check-in counts.
Off by default to keep the call cheap
on large tenants.

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
Attach every compliance setting and its value as a Settings property.
Costs nothing
extra - the list endpoint already returns them.

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

### PSCustomObject: Id, DisplayName, Description, Platform, Type, AssignmentCount,
### CreatedDateTime, LastModifiedDateTime; with -IncludeStatus also Status, SuccessCount,
### ErrorCount, ConflictCount, NotApplicableCount, PendingCount, SuccessPercent.
### See Get-MsecIntuneConfigurationProfile for Status value semantics.
## NOTES

## RELATED LINKS
