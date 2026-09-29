---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewInformationBarrier

## SYNOPSIS
Information barrier policies - who is prevented from communicating with whom.

## SYNTAX

```
Get-MsecPurviewInformationBarrier [[-Name] <String>] [<CommonParameters>]
```

## DESCRIPTION
Information barriers stop defined groups of people contacting each other in Teams,
SharePoint and OneDrive.
Most tenants have none, and that is a legitimate answer: they
exist for regulated separation - trading desks, or clinical staff who must not see each
other's material.
Reporting the absence is the point, because "we have no barriers" is a
decision when it is deliberate and a gap when it is not, and the two look identical until
someone asks.

STATE IS NOT THE SAME AS ACTIVE.
A barrier policy is authored inactive and only takes
effect once applied, so an Inactive policy protects nothing while still appearing in a
policy count.

LIKE THE AUTO-LABELING COMMAND, THIS PROJECTION IS UNVERIFIED AGAINST LIVE DATA - it was
written on a tenant with no barrier policies.
Missing properties resolve to $null rather
than erroring, and Raw keeps the untouched object.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewInformationBarrier | Format-Table Name, State, AssignedSegment
```

## PARAMETERS

### -Name
Limit to policies whose name matches.
Wildcards allowed.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per policy, PSTypeName 'MsecPurviewInformationBarrier'. No rows means
### no barriers are defined.
## NOTES
Needs Connect-Msec; the compliance session opens on first use.
Read-only.

## RELATED LINKS
