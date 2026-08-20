---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderIncidentStats

## SYNOPSIS
Microsoft Defender XDR incident summary: severity / classification / status
breakdown for a period, plus current-backlog point-in-time view.

## SYNTAX

```
Get-MsecDefenderIncidentStats [[-Days] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
Queries Microsoft Graph /security/incidents and returns a single PSCustomObject
per call covering three different cuts:

  - "Volume in window"       - incidents CREATED in the last -Days days.
                               Drives Total, severity, classification buckets.
  - "Resolution in window"   - incidents RESOLVED (status='resolved') in the same
                               window, regardless of when they were created.
                               Drives MTTR / median TTR.
  - "Backlog (point-in-time)"- incidents currently in status active OR inProgress,
                               independent of -Days.
Drives CurrentlyOpen and
                               OldestOpenAgeDays.

Field names mirror the Microsoft Defender XDR portal labels: severity is
High/Medium/Low/Informational (no 'Critical' - the API's top severity is high).
Classification follows Microsoft's current naming (TruePositive / FalsePositive /
BenignPositive / Unclassified).
'BenignPositive' bucket includes both the
legacy 'benignPositive' value and the newer 'informationalExpectedActivity'
Microsoft replaced it with.

MTTR best practice: computed only over incidents classified as TruePositive or
BenignPositive.
FalsePositive incidents typically close in minutes and would
artificially deflate the average; not counting them gives a more honest "time
to handle real things" number.

CONSEQUENCE, and read ResolvedClassifiedCount before trusting an MTTR: because
UNCLASSIFIED incidents are excluded too, a team that closes incidents without
setting a classification gets MeanTimeToResolveHours = $null however many
incidents it resolved.
That null means "nothing qualified to be averaged" - it is
neither a collection failure nor a claim that resolution was instant.
Equally, an
MTTR backed by ResolvedClassifiedCount = 1 is one incident, not an average; that
is the case where mean and median come back identical.

Requires the 'SecurityIncident.Read.All' application permission on the msec
app registration (admin consent required).
A clearer error is raised on the
typical 403.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderIncidentStats              # last 30 days + current backlog
```

### EXAMPLE 2
```
Get-MsecDefenderIncidentStats -Days 7      # last week for a posture-meeting view
```

### EXAMPLE 3
```
Get-MsecDefenderIncidentStats -Days 90 |   # quarterly window
    Select-Object TotalCreated, High, Medium, MeanTimeToResolveHours, CurrentlyOpen
```

## PARAMETERS

### -Days
Window size in days, applied to BOTH createdDateTime (for volume) and
lastUpdateDateTime (for resolution).
Default 30.
Backlog metrics
(CurrentlyOpen / OldestOpenAgeDays) ignore this and always show right-now.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject with StartDate, EndDate, volume/severity/classification counts,
### TotalResolvedInWindow + ResolvedClassifiedCount, MTTR (mean + median in hours),
### CurrentlyOpen + OldestOpenAgeDays.
## NOTES

## RELATED LINKS
