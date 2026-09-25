---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Set-MsecDefenderAlert

## SYNOPSIS
Resolve, classify or comment on Defender XDR alerts.
Runs as YOU - the app cannot do this.

## SYNTAX

```
Set-MsecDefenderAlert [-Id] <String[]> [[-Status] <String>] [[-Classification] <String>]
 [[-Determination] <String>] [[-Comment] <String>] [[-AssignedTo] <String>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Requires the delegated session from Connect-MsecAdmin and refuses the app session: every
permission New-MsecApp consents is *.Read.All, so the certificate in Key Vault could not
do this even if asked, and failing here with a sentence beats failing later with a 403
that names nothing.

THE COMMENT GOES THROUGH A DIFFERENT API, AND ONLY WORKS ON ENDPOINT ALERTS.
Microsoft
Graph has no writable comment on an alert - \`comments\` on alerts_v2 is read-only in both
v1.0 and beta, with no navigation property, no action, and no place in either Update
alert doc's updatable table.
The Defender for Endpoint API does have one, and its docs
say a comment may be submitted with or without updating any other property.
So -Comment
is sent to \`PATCH /api/alerts/{providerAlertId}\` on the Defender host while status and
classification go to Graph.
Splitting them that way is what keeps the two vocabularies
apart: the Defender API spells determinations \`InsufficientData\` and \`CompromisedUser\`
and statuses \`Resolved\`, where Graph spells them \`notEnoughDataToValidate\`,
\`compromisedAccount\` and \`resolved\`.
Nothing here translates between them, because
nothing has to.

The catch is coverage.
That API only knows endpoint alerts - measured on this tenant, 29
of 569 over ninety days; the rest are Defender for Office 365, DLP and serviceSource
'unknownFutureValue'.
-Comment on one of those is REFUSED BY NAME, naming the alert's
serviceSource and pointing at Set-MsecDefenderIncident -ResolvingComment, rather than
being quietly dropped.
The portal's comment box works on every alert because it uses an
internal API that is not published.

-Comment needs an Az sign-in as well as Connect-MsecAdmin, because the Defender host
will not take a Graph token - different audience.
The Az token carries
user_impersonation, so the comment is bounded by your own Defender role.

THERE IS NO CAP ON HOW MANY ALERTS IT WILL CHANGE.
\`Get-… | Set-…\` will work through
everything the filter selected - on this tenant \`Get-MsecDefenderAlert -Status new\`
returns 201 rows.
What stands between you and that is ConfirmImpact 'High', so a bare
call prompts per alert, and -WhatIf, which lists every id it would touch and changes
nothing.
Use -WhatIf first on any pipeline you have not run before; -Confirm:$false
turns off the only remaining prompt.

Ids are still collected before the first write rather than acted on as they arrive, so
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
Changed reports whether the Graph fields held;
CommentAdded reports whether the comment was found on re-read.
Either is $null when it
could not be verified - an unverified write must never render as a confirmed one.

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

Get-MsecDefenderAlert -Days 90 -ServiceSource microsoftDefenderForEndpoint -Status new |
    Set-MsecDefenderAlert -Status resolved -Determination notMalicious \`
        -Comment 'Authorised red-team exercise, ticket SEC-88' -WhatIf

### EXAMPLE 2
```
# A comment on its own, with no other change - the Defender API allows that.
Set-MsecDefenderAlert -Id $alertId -Comment 'Chasing the device owner, see SEC-91'
```

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

### -Comment
Free text added to the alert's comment thread - the same field the portal's Classify
alert box writes.
Endpoint alerts only; see the note above.

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

### -AssignedTo
User principal name to assign the alert to.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
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
### state read back afterwards, Changed and CommentAdded.
## NOTES
Needs Connect-MsecAdmin with SecurityAlert.ReadWrite.All.
-Comment additionally needs an
Az context (Connect-AzAccount) and the Defender 'Alerts investigation' role.

Resolving an alert is a state change in Defender, not a local edit, and a comment cannot
be unsent.
-WhatIf lists the ids that would be touched.

## RELATED LINKS
