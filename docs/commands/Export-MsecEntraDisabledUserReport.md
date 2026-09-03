---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Export-MsecEntraDisabledUserReport

## SYNOPSIS
Evidence of every disabled ("archived") account in the tenant - one row per account,
how long it has been disabled, and what it still costs in licences.

## SYNTAX

```
Export-MsecEntraDisabledUserReport [-Path] <String> [-Days <Int32>] [-UserType <String>] [-TableStyle <String>]
 [-ChartWidth <Int32>] [-ChartHeight <Int32>] [-PassThru] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
The same evidence shape as the VM reports: one row per subject, a worksheet named after
the tenant, a shared Summary counting them by category, and a chart per tenant.
A
snapshot, not a trend - nothing is appended, and a sheet written twice is replaced.

Rows come from Get-MsecEntraDisabledUser, so everything it knows about the limits of
the answer applies here and is carried into the table rather than smoothed over.

THE AGE BUCKET IS THE CATEGORY, AND 'Unknown' IS ONE OF THEM.
Entra stores no
disabledDateTime; the date comes from the directory audit log, which retains 30 days on
P1/P2 and 7 on the free tier.
An account disabled inside that window gets an exact
date, and one disabled before it gets a bracket - so its bucket is genuinely unknown,
not zero and not recent.
Lumping those in with '\< 30 days' would be the one reading
that is certainly wrong, since anything the audit log cannot see is OLDER than the
window, never newer.

THE CHART COUNTS TWICE PER BUCKET: accounts, and how many of those still hold licences.
A disabled account with licences assigned is both spend and standing attack surface, and
it is the finding most likely to get acted on - so it belongs in the picture rather than
only in a column.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Export-MsecEntraDisabledUserReport -Path "./disabled-users-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
```

### EXAMPLE 2
```
# The rows a reviewer will ask about: dead accounts still holding licences.
Export-MsecEntraDisabledUserReport -Path ./evidence.xlsx -PassThru |
    Where-Object LicenseCount -gt 0 |
    Sort-Object LicenseCount -Descending |
    Format-Table UserPrincipalName, DisabledFor, LicenseCount, LastSuccessfulSignIn
```

## PARAMETERS

### -Path
The .xlsx to write.
Created if absent; an existing file is added to rather than
replaced, so several tenants can share one document.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Days
How far back to search the audit log for the disable event, passed through to
Get-MsecEntraDisabledUser.
Default 30, the P1/P2 retention ceiling.
Drop to 7 on a
free-tier tenant - asking for more cannot find more.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -UserType
'Member', 'Guest' or 'All'.
Default All.
A disabled guest is usually a finished
engagement nobody cleaned up, which is worth being able to separate.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -TableStyle
Excel table style.
One of Light1-21, Medium1-28 or Dark1-11.
Default Medium2.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: Medium2
Accept pipeline input: False
Accept wildcard characters: False
```

### -ChartWidth
Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 600
Accept pipeline input: False
Accept wildcard characters: False
```

### -ChartHeight
Chart height in pixels, default 370.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 370
Accept pipeline input: False
Accept wildcard characters: False
```

### -PassThru
Emit the per-account rows as objects as well as writing them.

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

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### With -PassThru, one PSCustomObject per disabled account, PSTypeName
### 'MsecEntraDisabledUserEvidence'.
## NOTES
Needs Connect-Msec - this is Graph, so no Az context is involved, unlike the VM
reports.
User.Read.All and AuditLog.Read.All, both of which New-MsecApp already grants.

The tenant's display name is read from /organization to name the worksheet.
If that
call fails the tenant id is used instead, which is ugly but unambiguous.

## RELATED LINKS
