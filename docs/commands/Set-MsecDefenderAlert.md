---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Set-MsecDefenderAlert

## SYNOPSIS
Resolve, classify or assign Defender XDR alerts.
Runs as YOU - the app cannot do this.

## SYNTAX

```
Set-MsecDefenderAlert [-Id] <String[]> [[-Status] <String>] [[-Classification] <String>]
 [[-Determination] <String>] [[-AssignedTo] <String>] [-WhatIf] [-Confirm]
 [<CommonParameters>]
```

## DESCRIPTION
Requires the delegated session from Connect-MsecAdmin and refuses the app session: every
permission New-MsecApp consents is *.Read.All, so the certificate in Key Vault could not
do this even if asked, and failing here with a sentence beats failing later with a 403
that names nothing.

ONE IDENTITY THROUGHOUT.
Every call this command makes goes through that one delegated
session.
That is deliberate and was not always true: a -Comment switch existed briefly,
routed to the Defender for Endpoint API on a separate Az-context token, which put two
different user identities inside a single command - the alert could be resolved by one
person and commented by another.

THERE IS NO COMMENT HERE.
Microsoft Graph has no writable comment on an alert -
\`comments\` on alerts_v2 is read-only in v1.0 and beta alike, with no navigation property
and no action.
The Defender for Endpoint API does have one, but it only knows ENDPOINT
alerts: measured on one tenant, 29 of 569, and none of the alerts anyone actually
triaged.
Covering five per cent of the fleet did not justify a second authentication
path inside one command.

Put the note on the incident instead - Set-MsecDefenderIncident -ResolvingComment, which
Microsoft describes as explaining the resolution and the classification choice, and which
works for every incident whatever its alerts came from.

THERE IS NO CAP ON HOW MANY ALERTS IT WILL CHANGE.
\`Get-… | Set-…\` works through
everything the filter selected - on one tenant \`Get-MsecDefenderAlert -Status new\`
returns 201 rows.
What stands between you and that is ConfirmImpact 'High', so a bare
call prompts per alert, and -WhatIf, which lists every id it would touch and changes
nothing.
Use -WhatIf first on any pipeline you have not run before; -Confirm:$false
turns off the only remaining prompt.

Ids are collected before the first write rather than acted on as they arrive, so
duplicates in the pipeline are written once.

IT RE-READS AFTER WRITING, AND WAITS FOR THE SERVICE TO SETTLE.
The PATCH response is
the service echoing the request; a separate GET is the service being asked what the
alert now IS.
But XDR is eventually consistent - measured live, an alert PATCHed at
16:37:00 still read as unchanged immediately afterwards and was correct moments later -
so the read-back polls briefly (about ten seconds at most) and stops as soon as the
values match.
A warning is raised only when a field is STILL wrong after the last read,
which makes it worth acting on.
Changed is $null when it could not be verified - an
unverified write must never render as a confirmed one.

DETERMINATION VALUES ARE NOT THE OBVIOUS ONES.
From Graph's own $metadata:
'notMalicious' and 'notEnoughDataToValidate', not 'clean' and 'insufficientData'.
Microsoft's Update alert page still lists the retired names for this shared enum while
the Update incident page and $metadata agree with the values here - so do not "fix"
these from that page.
Note too that the CSDL calls the first status member 'newAlert'
while the wire value is 'new'; the wire value is what this takes.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Connect-MsecAdmin
```

Get-MsecDefenderAlert -Days 90 -Severity informational -Status new |
    Set-MsecDefenderAlert -Status resolved -Determination notMalicious -WhatIf

Shows exactly which alerts would change, and nothing else.
Drop -WhatIf once the list
is the list you meant.

### EXAMPLE 2
```
Set-MsecDefenderAlert -Id $alertId -Status inProgress -AssignedTo me@contoso.com
```

One alert, taken for investigation.

## PARAMETERS

### -Id
Alert ids.
Takes pipeline input from Get-MsecDefenderAlert by property name.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: True (ByPropertyName, ByValue)
Accept wildcard characters: False
```

### -Status
new, inProgress or resolved.

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

### -Classification
unknown, falsePositive, truePositive or informationalExpectedActivity.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Determination
The analyst's call on what it actually was.
See the note above on the value names.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AssignedTo
User principal name to assign the alert to.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
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

### One PSCustomObject per alert: Id, Title, Severity, ServiceSource, the status before, the
### state read back afterwards, and Changed.
## NOTES
Needs Connect-MsecAdmin with SecurityAlert.ReadWrite.All.
One identity throughout: every
call this command makes goes through that delegated session.

Resolving an alert is a state change in Defender, not a local edit.
-WhatIf lists the
ids that would be touched.

## RELATED LINKS
