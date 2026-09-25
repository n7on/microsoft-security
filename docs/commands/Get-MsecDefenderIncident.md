---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderIncident

## SYNOPSIS
One row per Defender XDR incident - what it is, how severe, whether anyone has
triaged it, and how long it took to resolve.

## SYNTAX

```
Get-MsecDefenderIncident [[-Days] <Int32>] [[-Severity] <String[]>] [[-Status] <String[]>] [-ExcludeRedirected]
 [-IncludeAlerts] [<CommonParameters>]
```

## DESCRIPTION
The row-level companion to Get-MsecDefenderIncidentStats, which answers the same
questions as a single summary.
Use this one to see WHICH incidents, and the stats
command for a trend line.

REDIRECTED INCIDENTS ARE NOT SEPARATE INCIDENTS.
When Defender decides two incidents
are the same attack it merges them, leaving the absorbed one with status 'redirected'
and a RedirectedToIncidentId.
Counting those as incidents double-counts the same
activity - measured on a live tenant, 51 of 474 in ninety days.
They are returned
anyway, because an incident that vanished from a count needs to be explainable, and
-ExcludeRedirected drops them when you want the deduplicated number.

CLASSIFICATION AND DETERMINATION ARE ANALYST JUDGEMENTS, NOT DETECTIONS.
They stay
'unknown' until a human sets them, so they measure triage effort rather than truth.
Measured live: all 474 incidents were 'unknown', which is a finding about the process
rather than about the incidents.

RESOLVEDAYS IS $null WHILE AN INCIDENT IS OPEN, never 0.
Graph reports no resolution
time for an unresolved incident, and a zero there would read as "closed instantly" -
which is the opposite of a still-running investigation.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecDefenderIncident -Days 90 -ExcludeRedirected |
    Where-Object Status -ne 'resolved' | Sort-Object Severity
```

### EXAMPLE 2
```
# The triage gap: open incidents nobody has classified.
Get-MsecDefenderIncident -Days 90 |
    Where-Object { $_.Status -eq 'active' -and $_.Classification -eq 'unknown' }
```

## PARAMETERS

### -Days
How far back to look at CREATION time.
Default 30.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -Severity
Only these severities: informational, low, medium, high.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Status
Only these statuses: active, inProgress, resolved, redirected.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExcludeRedirected
Drop incidents merged into another one.
Use when counting; omit when explaining.

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

### -IncludeAlerts
Also fetch each incident's alerts and report AlertCount and the distinct detection
sources.
One extra call per incident, so it is opt-in.

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

### One PSCustomObject per incident, PSTypeName 'MsecDefenderIncident'.
## NOTES
Needs Connect-Msec and the 'SecurityIncident.Read.All' application permission, which
New-MsecApp grants.

$top is not set: /security/incidents caps it at 50 and rejects larger values.
Paging
is handled by -All regardless of page size.

## RELATED LINKS
