---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewRetention

## SYNOPSIS
Retention labels and retention policies, with whether either is actually in force.

## SYNTAX

```
Get-MsecPurviewRetention [[-Kind] <String>] [<CommonParameters>]
```

## DESCRIPTION
Records management has two halves that are easy to mistake for one.
A retention LABEL
says what to do with an item; a retention POLICY says where the rule applies.
A label
with no policy publishing it does nothing at all, and the label list gives no hint of
that - which is how a tenant ends up appearing to have retention while retaining
nothing.
Measured on one tenant: one label, published by nothing, and zero policies.

BOTH KINDS COME BACK IN ONE STREAM, tagged by Kind ('Label' or 'Policy'), because the
question is almost always "what retention do we have" rather than one or the other.
Use
-Kind to take a side.
IsInForce is the column that matters: false on an unpublished
label, false on a disabled policy.

THE DEFAULT FOR A TENANT WITH NOTHING CONFIGURED IS AN EMPTY RESULT, and that is a real
answer rather than a failure - which is exactly why the command does not throw on it.
Callers writing a report should say "no retention is configured" rather than omitting
the section.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewRetention | Format-Table Kind, Name, Action, Duration, IsInForce
```

### EXAMPLE 2
```
# Labels that exist but are published by no policy, so retain nothing.
Get-MsecPurviewRetention -Kind Label | Where-Object { -not $_.IsInForce }
```

## PARAMETERS

### -Kind
Limit to 'Label' or 'Policy'.
Both by default.

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

### One PSCustomObject per label or policy, PSTypeName 'MsecPurviewRetention'.
## NOTES
Needs Connect-Msec.
The compliance session is opened automatically on first use - that
handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
than done silently.
Call Connect-MsecPurview yourself to control -Organization, or to
choose when those 102 cmdlet names land in your runspace.

Read-only.

## RELATED LINKS
