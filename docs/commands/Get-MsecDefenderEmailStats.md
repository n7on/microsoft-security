---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderEmailStats

## SYNOPSIS
Inbound email volume and threat breakdown over the last N days.

## SYNTAX

```
Get-MsecDefenderEmailStats [[-Days] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
Queries Microsoft 365 Defender's advanced-hunting EmailEvents table via
Microsoft Graph (/security/runHuntingQuery) and returns a single summary
row covering the requested window:

  - Total inbound volume
  - DeliveryAction counts: Delivered / Junked / Blocked / Replaced
  - ThreatTypes counts:    Phishing / Spam / Malware
  - Percentages of Total for each of the above

Direction is filtered to Inbound only - "phishing stats" almost always
means "what attackers sent into the org".
Outbound/intra-org are excluded
by the KQL.

Counting note: ThreatTypes is a comma-separated multi-value column.
A
single email can simultaneously be Phish AND Spam, in which case it
counts in both \`Phishing\` and \`Spam\`.
Means \`Phishing + Spam + Malware\`
will not in general add up to Total.

Requires the 'ThreatHunting.Read.All' application permission on the msec
app registration (admin-consent required).
A clearer error is raised on
the typical 403.

## EXAMPLES

### EXAMPLE 1
```
# Last 7 days, single summary row.
Get-MsecDefenderEmailStats
```

### EXAMPLE 2
```
Get-MsecDefenderEmailStats -Days 30 | Format-Table -AutoSize
```

### EXAMPLE 3
```
# Combine with the other Defender scores for an archive snapshot.
$snapshot = [pscustomobject]@{
    CapturedAtUtc = (Get-Date).ToUniversalTime().ToString('u')
    SecureScore   = Get-MsecSecureScore -Top 1
    Email         = Get-MsecDefenderEmailStats -Days 30
}
```

## PARAMETERS

### -Days
Window size in days.
Default 7 (Microsoft 365 Defender portal default).

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 7
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject with StartDate, EndDate, Total, the four DeliveryAction
### counts, the three ThreatTypes counts, and their percentages of Total.
## NOTES

## RELATED LINKS
