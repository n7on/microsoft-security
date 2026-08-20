---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneCompliancePolicy

## SYNOPSIS
Lists Intune compliance policies - what defines whether a device is "compliant"
(and therefore allowed through Conditional Access).

## SYNTAX

```
Get-MsecIntuneCompliancePolicy [-IncludeStatus] [<CommonParameters>]
```

## DESCRIPTION
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
# Quick inventory:
Get-MsecIntuneCompliancePolicy | Format-Table -AutoSize
```

### EXAMPLE 2
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
