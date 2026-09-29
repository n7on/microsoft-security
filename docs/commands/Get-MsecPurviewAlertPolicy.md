---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewAlertPolicy

## SYNOPSIS
Purview alert policies - the detection layer that decides what anyone ever hears about.

## SYNTAX

```
Get-MsecPurviewAlertPolicy [[-Name] <String>] [[-Category] <String>] [-CustomOnly] [<CommonParameters>]
```

## DESCRIPTION
Every other Purview command here reports what is PREVENTED.
This one reports what is
NOTICED, and it is the part people forget to check: a disabled alert policy is silent in
exactly the way a working one is, so the gap is invisible until an incident review asks
why nobody was told.
Measured on one tenant: 65 policies, 7 of them disabled, including
"Shared files externally" and "User copies a file with sensitive data to a removable
drive".

IsEnabled IS THE INVERSE OF THE RAW PROPERTY.
The service stores Disabled; reading it
straight means every filter reads backwards, and \`Where-Object Disabled\` quietly returns
the healthy ones.
Both are on the row, with IsEnabled first, because a positive name is
the one people filter on correctly.

SYSTEM RULES ARE MOST OF THE LIST AND ARE NOT YOUR CONFIGURATION.
Microsoft ships the
majority of these; IsSystemRule separates them from the ones your organisation added, and
-CustomOnly narrows to the latter.
A count that mixes them tells you nothing about how
much alerting anyone here actually set up.

NotificationEnabled IS NOT WHETHER THE ALERT FIRES.
It controls whether an email goes
out.
An enabled policy with notifications off still raises the alert in the portal and
still tells nobody - worth checking separately from IsEnabled, and the reason both are
columns.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewAlertPolicy | Group-Object Category | Sort-Object Count -Descending
```

### EXAMPLE 2
```
# Detection that has been switched off - silent in the same way a working policy is.
Get-MsecPurviewAlertPolicy | Where-Object { -not $_.IsEnabled } |
    Format-Table Name, Category, Severity, IsSystemRule
```

### EXAMPLE 3
```
# Enabled, but nobody is told.
Get-MsecPurviewAlertPolicy |
    Where-Object { $_.IsEnabled -and -not $_.NotificationEnabled -and -not $_.IsSystemRule }
```

## PARAMETERS

### -Name
Limit to policies whose name matches.
Wildcards allowed.

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

### -Category
Limit to one category, e.g.
ThreatManagement or DataLossPrevention.

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

### -CustomOnly
Only policies your organisation created, excluding Microsoft's built-ins.

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

### One PSCustomObject per alert policy, PSTypeName 'MsecPurviewAlertPolicy'.
## NOTES
Needs Connect-Msec; the compliance session opens on first use.
Read-only.

## RELATED LINKS
