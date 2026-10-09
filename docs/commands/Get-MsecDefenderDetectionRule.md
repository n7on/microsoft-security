---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderDetectionRule

## SYNOPSIS
Defender XDR custom detection rules - the scheduled advanced hunting queries that raise
alerts - with their run status, schedule and the query behind each.

## SYNTAX

```
Get-MsecDefenderDetectionRule [[-Name] <String>] [[-Status] <String>] [[-Query] <String>] [<CommonParameters>]
```

## DESCRIPTION
A custom detection rule is an advanced hunting query Defender runs on a schedule and
turns into alerts.
This lists them, so "do we detect that?" is answerable without
opening the portal.

NOT THE SAME THING AS Get-MsecSentinelRule, AND THE TWO ARE EASY TO CONFUSE because
Microsoft calls both "detection rules".
They live in different products, read different
data, and neither can see the other's:

    Get-MsecDefenderDetectionRule  Defender XDR    queries advanced hunting tables
    Get-MsecSentinelRule           Sentinel        queries a Log Analytics workspace

A tenant whose Defender data is not connected to Sentinel cannot write a Sentinel rule
over DeviceEvents at all - measured on one tenant, 53 Sentinel rules and not one of them
able to see a Defender device event, because no Device* table exists in the workspace.
Asking the wrong command returns a confident list of the wrong rules.

'AUTODISABLED' IS THE REASON THIS IS WORTH RUNNING.
Defender switches a custom detection
off by itself when its query starts failing - a renamed column, a table that stopped
resolving, a schema change.
The rule still exists, still appears in the portal list, and
has silently stopped running.
That is indistinguishable from a rule that is working and
finding nothing, which is the most expensive failure a detection can have.

STATUS, NOT ISENABLED.
The isEnabled property was REMOVED from this resource on
2026-10-01, along with detectorId and lastRunDetails.
Code still reading isEnabled gets
$null, which is falsy, and reports every rule as disabled.
Status carries the same
information plus the autoDisabled value isEnabled could never express.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderDetectionRule | Where-Object Status -eq 'autoDisabled'
```

Rules Defender has switched off because their query broke.
They look live in the portal
and are not running.

### EXAMPLE 2
```
Get-MsecDefenderDetectionRule -Query 'Asr'
```

Whether anything detects on attack surface reduction events.
Most ASR rules raise no
alert of their own, so without a custom detection a block is invisible.

### EXAMPLE 3
```
Get-MsecDefenderDetectionRule | Select-Object DisplayName, Status, Frequency, NextRun, Severity
```

The whole detection surface at a glance.

## PARAMETERS

### -Name
Substring match on the display name, case-insensitive.

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

### -Status
Only rules in this run state: 'enabled', 'disabled' or 'autoDisabled'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Query
Substring match on the rule's hunting query.
'DeviceEvents', 'Asr', a table name -
answers "is anything watching this?" without reading every rule.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per rule, PSTypeName 'MsecDefenderDetectionRule'.
## NOTES
Needs the 'CustomDetection.Read.All' application permission, which New-MsecApp grants.
An app created before that was added must re-run New-MsecApp and re-consent.

Reads the beta endpoint: custom detection rules are beta-only in Microsoft Graph at the
time of writing, and the run-detail properties are not exposed in v1.0 at all.

## RELATED LINKS
