---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderScoreExposure

## SYNOPSIS
Returns the current Defender Vulnerability Management Exposure Score.

## SYNTAX

```
Get-MsecDefenderScoreExposure [<CommonParameters>]
```

## DESCRIPTION
Calls Defender for Endpoint /api/exposureScore.
The API exposes only the current value
(no history) so Date is today's date.
Exposure Score is 0-100 where LOWER is better -
keep that in mind when reading the trend against the posture scores.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderScoreExposure
```

### EXAMPLE 2
```
# Snapshot it yourself - the API keeps no history, so a trend only exists if you
# store each reading.
Get-MsecDefenderScoreExposure |
    Export-Csv ./exposure-history.csv -Append -NoTypeInformation
```

### EXAMPLE 3
```
# Read next to the posture scores, remembering this one runs the other way:
# a rising Exposure Score is a worsening estate.
Get-MsecSecureScore, (Get-MsecDefenderScoreExposure) | Format-Table ScoreType, ScorePercent
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject with ScoreType ('Exposure'), Date (today), ScorePercent (0-100,
### lower is better).
## NOTES

## RELATED LINKS
