---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecAzureCost

## SYNOPSIS
Actual Azure spend for a subscription or a resource group over a window, from Cost
Management.

## SYNTAX

```
Get-MsecAzureCost [[-ResourceGroupName] <String[]>] [[-SubscriptionId] <String>] [[-DaysBack] <Int32>]
 [-MonthToDate] [<CommonParameters>]
```

## DESCRIPTION
Queries the Cost Management API for pre-tax cost, one row per scope asked about.

THE CURRENCY IS RETURNED, NEVER DISCARDED.
Cost Management answers with an amount AND
the billing currency, and dropping the currency is how a report ends up adding SEK to
EUR and printing a total that means nothing.
It is a column here, and a run spanning
two billing currencies warns rather than summing them.

NOT ROUNDED.
The API answers to full precision and this passes it through; round at
the point of display, where you know how many places you want.
Rounding in the
collector loses the difference between "0.4" and "0" - the second reads as free.

WHY Invoke-AzRestMethod AND NOT A HAND-BUILT REQUEST.
Cost Management has no Az cmdlet
for this query shape, so the obvious implementation acquires a token with
Get-AzAccessToken and builds the call by hand.
That breaks twice over: the ARM endpoint
differs per cloud and has to be branched on, and since Az.Accounts 5 the token comes
back as a SecureString, so interpolating it yields the literal string
'Bearer System.Security.SecureString' and every call answers 401.
Invoke-AzRestMethod
handles both - it signs with the current context and resolves the endpoint for the
cloud the context is in.

COST DATA LAGS.
Cost Management is not real time; the most recent day or two is
usually incomplete, and a window ending today will under-report slightly.
That is a
property of the source, not of this command - but it means a day-over-day comparison
of the last two days is measuring latency, not spending.

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
Get-MsecAzureCost
```

### EXAMPLE 2
```
# Per resource group, dearest first.
Get-AzResourceGroup | Get-MsecAzureCost -DaysBack 30 |
    Sort-Object Cost -Descending |
    Format-Table Scope, Cost, Currency, From, To
```

### EXAMPLE 3
```
# What the invoice will say.
Get-MsecAzureCost -MonthToDate
```

## PARAMETERS

### -ResourceGroupName
Scope to these resource groups.
Accepts pipeline input.
Omit for the whole
subscription.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: True (ByPropertyName, ByValue)
Accept wildcard characters: False
```

### -SubscriptionId
The subscription to query.
Defaults to the current Az context.

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

### -DaysBack
How far back the window runs from today.
Default 30.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -MonthToDate
Query the current billing month instead of a rolling window - which is what an invoice
is reconciled against.
Overrides -DaysBack.

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

### PSCustomObject per scope, PSTypeName 'MsecAzureCost'.
## NOTES
Uses your Az context, not the msec app session.
Needs Cost Management Reader, or a
role that includes it - Reader on the subscription is NOT enough for this API, which
is the usual reason for a 401 here.

Costs are PRE-TAX and exclude credits, reservations amortisation and marketplace
charges billed separately - the same figure the portal's Cost Analysis shows for
'Actual cost'.

## RELATED LINKS
