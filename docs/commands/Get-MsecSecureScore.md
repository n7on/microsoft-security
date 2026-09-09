---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSecureScore

## SYNOPSIS
Returns Microsoft Secure Score snapshots as flat rows: ScoreType / Date /
ScorePercent.
Covers both the overall score and every category surfaced by
Microsoft Graph (Identity, Device, Apps, Data, Infrastructure, plus anything
Microsoft adds later).

## SYNTAX

```
Get-MsecSecureScore [[-Category] <String>] [[-Top] <Int32>]
 [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/security/secureScores.
For each snapshot, emits
one 'Overall' row (currentScore / maxScore) plus one row per category in the
snapshot's controlScores collection.
Per-category percentages are computed by
summing achieved 'score' values and dividing by the matching sum of maxScore
values from /v1.0/security/secureScoreControlProfiles.
Profiles are stable
across snapshots, so they're fetched once per call.

Use this as the single source for Secure Score history.
Trend math (diff vs
previous snapshot, month-over-month, etc.) lives in the consumer - msec's
job is to expose the raw shape.

## EXAMPLES

### EXAMPLE 1
```
# Today's overall + categories, one row each.
Get-MsecSecureScore -Top 1
```

### EXAMPLE 2
```
# Just Identity, full history (~90 days). Suitable for trend charts.
Get-MsecSecureScore -Category Identity
```

### EXAMPLE 3
```
# Bootstrap an archive with the full 90-day window across every category.
Get-MsecSecureScore | ConvertTo-Json -Depth 4 | Set-Content ./archive/seed.json
```

## PARAMETERS

### -Category
Restrict the output to one ScoreType: 'Overall' for the overall row, or a
category name (Identity, Device, Apps, Data, Infrastructure).
When omitted,
every category present in the snapshot is emitted alongside Overall.
Tab
completes against the known categories but accepts any string in case
Microsoft adds a new one.

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

### -Top
Only process the N most recent snapshots.
When omitted, every snapshot in
the API's window (~90 days) is returned.
Pass -Top 1 for today's snapshot.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per (snapshot, ScoreType) combination, with:
###   - ScoreType    : 'Overall' or a category name.
###   - Date         : DateTime of the snapshot.
###   - ScorePercent : 0-100 percentage (null if maxScore was 0/missing).
## NOTES

## RELATED LINKS
