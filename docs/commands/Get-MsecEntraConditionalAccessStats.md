---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraConditionalAccessStats

## SYNOPSIS
Aggregated Conditional Access insights over the last N days - the data
behind the "Conditional Access insights and reporting" workbook in the
Entra portal, in a single summary row.

## SYNTAX

```
Get-MsecEntraConditionalAccessStats [[-Days] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
Internally calls Get-MsecEntraConditionalAccessSignInLog -Days $Days and
aggregates the sign-in events.
Returns one PSCustomObject covering:

  - Volume:   TotalSignIns, UniqueUsers
  - CA mix:   CaSuccess / CaFailure / CaNotApplied (mutually exclusive,
              sum to TotalSignIns) + their percentages
  - Risk:     HighRiskSignIns, MediumRiskSignIns (from Identity Protection)
  - Report-only impact: ReportOnlyWouldBlock - sign-ins that a report-only
              policy WOULD HAVE blocked if it were enforced.
The single
              most useful metric for "is it safe to flip this report-only
              policy to enabled?"
  - TopFailingPolicies: top-5 policies by failure count (nested array of
              {Name, Count} objects).

This function is a thin aggregation over the raw sign-in log.
It pulls
every sign-in event for the window once, so the API cost is the same as
a single Get-MsecEntraConditionalAccessSignInLog call - heavy in busy
tenants.
The default -Days 7 matches the portal workbook's default view
and keeps the cost bounded.

Permission requirement is inherited from Get-MsecEntraConditionalAccessSignInLog
(AuditLog.Read.All).

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraConditionalAccessStats              # last 7 days
```

### EXAMPLE 2
```
Get-MsecEntraConditionalAccessStats -Days 30 | Format-List
```

### EXAMPLE 3
```
# Slot it into the bi-weekly archive snapshot:
$snapshot = [pscustomobject]@{
    CapturedAtUtc = (Get-Date).ToUniversalTime().ToString('u')
    SecureScore   = Get-MsecSecureScore -Top 1
    EmailStats    = Get-MsecDefenderEmailStats -Days 30
    IncidentStats = Get-MsecDefenderIncidentStats -Days 30
    CaStats       = Get-MsecEntraConditionalAccessStats -Days 7
}
```

## PARAMETERS

### -Days
Window size in days.
Default 7, max 30 (Graph signIn retention cap).

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

### PSCustomObject with StartDate, EndDate, volume + CA-outcome + risk +
### report-only + TopFailingPolicies columns.
## NOTES

## RELATED LINKS
