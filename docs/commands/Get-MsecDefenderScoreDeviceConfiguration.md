---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderScoreDeviceConfiguration

## SYNOPSIS
Returns the current Microsoft Secure Score for Devices (raw configuration score).

## SYNTAX

```
Get-MsecDefenderScoreDeviceConfiguration [<CommonParameters>]
```

## DESCRIPTION
Calls the Defender for Endpoint API (/api/configurationScore).
The API returns a raw
score in *points*, not a percentage - and exposes no maximum from which a percentage
could be derived.
The output field is therefore named 'Score' (not 'ScorePercent') to
avoid implying a 0-100 scale.

For an apples-to-apples device-control percentage in your posture report, prefer
the 'Device' row from \`Get-MsecSecureScore -Category Device\` (a 0-100 percentage
normalised against control maxima).
Use this function only when you specifically
need the raw Defender configuration points.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderScoreDeviceConfiguration
```

### EXAMPLE 2
```
# The normalised 0-100 device figure most reports want, for comparison. Score and
# ScorePercent are different scales and must not be charted on one axis.
Get-MsecSecureScore -Category Device
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject with ScoreType ('DeviceConfiguration'), Date (today), Score (raw points).
## NOTES

## RELATED LINKS
