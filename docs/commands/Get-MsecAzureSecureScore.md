---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecAzureSecureScore

## SYNOPSIS
Per-subscription Microsoft Defender for Cloud Secure Score, projected to
flat rows: SubscriptionId / SubscriptionName / ScoreType / ScorePercent / Date.

## SYNTAX

```
Get-MsecAzureSecureScore [[-SubscriptionId] <String[]>] [-IncludeControls]
 [<CommonParameters>]
```

## DESCRIPTION
Calls the Microsoft Defender for Cloud (formerly Azure Security Center) ARM
API:

    GET https://management.azure.com/subscriptions/{id}
        /providers/Microsoft.Security/secureScores?api-version=2020-01-01

Returns one row per (subscription, ScoreType).
By default, only the
'Overall' row per subscription is emitted.
-IncludeControls also emits
one row per Defender for Cloud control (e.g.
'Enable MFA', 'Encrypt data
at rest', ...) - useful when an auditor asks "which categories are
bringing the score down".

Auth uses the CALLER's Az.Accounts identity, not the msec app - Defender
for Cloud is ARM-rooted and access is granted via subscription RBAC, not
Entra app permissions.
You need at least Reader role on each subscription
you want scored.
Same auth boundary as Search-MsecAzureResourceGraph and
Invoke-MsecAzureVMScript.

No historical trend is available - the API only returns the current
snapshot.
Your bi-weekly archive script is the only source of history
for this score.
To match the row shape of Get-MsecSecureScore, a Date
column is included with today's date.

## EXAMPLES

### EXAMPLE 1
```
# Overall score per subscription (the headline number)
Get-MsecAzureSecureScore | Format-Table SubscriptionName, ScorePercent
```

### EXAMPLE 2
```
# Control-level breakdown for a single sub
Get-MsecAzureSecureScore -SubscriptionId '<guid>' -IncludeControls |
    Sort-Object ScorePercent | Select -First 10 ScoreType, ScorePercent
```

## PARAMETERS

### -SubscriptionId
Restrict to specific subscriptions.
Omit to score every accessible
subscription in the current Az context's tenant.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeControls
Also emit one row per Defender for Cloud control (per subscription).
Adds one extra ARM call per subscription, so noticeably slower on
tenants with many subscriptions.
Off by default.

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

### PSCustomObject per (subscription, ScoreType) with SubscriptionId,
### SubscriptionName, ScoreType ('Overall' or a control name), ScorePercent
### (0-100, null if max=0), Date (today).
## NOTES

## RELATED LINKS
