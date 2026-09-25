---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Set-MsecDefenderIncident

## SYNOPSIS
Resolve, classify or comment on Defender XDR incidents.
Runs as YOU, through
Connect-MsecAdmin.

## SYNTAX

```
Set-MsecDefenderIncident [-Id] <String[]> [[-Status] <String>] [[-Classification] <String>]
 [[-Determination] <String>] [[-ResolvingComment] <String>] [[-AssignedTo] <String>] [[-Severity] <String>]
 [[-CustomTags] <String[]>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
THE RESOLUTION COMMENT LIVES HERE, NOT ON THE ALERT.
Graph has no writable comment on
an alert: \`comments\` is read-only on alerts_v2 in both v1.0 and beta, there is no
comments navigation property and no action to add one, and neither Update alert doc
lists it as updatable.
Incidents have -ResolvingComment, described by Microsoft as
"user input that explains the resolution of the incident and the classification
choice" - which is the note people actually want when they close something.
Alerts roll
up into incidents, so commenting on the incident is both the supported path and the one
an analyst reads first.

Same guards as Set-MsecDefenderAlert.
It requires the Connect-MsecAdmin session and
refuses the app one; it collects piped ids before the first write so duplicates are written
once; and it re-reads each incident afterwards and reports what came back,
not what was asked for - polling briefly, because XDR settles asynchronously and a single
immediate read reports changes as lost that in fact land a moment later.

-CustomTags REPLACES the tag array, it does not append - that is how Graph treats the
collection.
The existing tags are shown as CustomTagsBefore so a replacement is at
least visible; read them first if you meant to add one.

-Status takes the values that can actually be SET.
'redirected' is excluded on purpose:
it is what Defender assigns when it merges an incident into another, not a state you
move an incident to.
Note also that 'inProgress' and 'awaitingAction' are real - they
are in Graph's $metadata even though the Update incident doc lists only active,
resolved and redirected.

DETERMINATION VALUES: 'notMalicious' and 'notEnoughDataToValidate', from $metadata.
Microsoft's own Update alert page still lists the retired 'clean' and 'insufficientData'
for the very same shared enum - the Update incident page and $metadata agree with each
other and with this command, so do not "fix" these from that stale page.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Connect-MsecAdmin -Scope SecurityIncident.ReadWrite.All
```

Get-MsecDefenderIncident -Days 90 -Status active |
    Where-Object Severity -eq 'informational' |
    Set-MsecDefenderIncident -Status resolved -Classification informationalExpectedActivity \`
        -Determination notMalicious -ResolvingComment 'Expected scanner activity - see CHG0042' -WhatIf

### EXAMPLE 2
```
Set-MsecDefenderIncident -Id 4711 -Status resolved -Classification falsePositive `
    -Determination notMalicious -ResolvingComment 'Pen test, authorised, ticket SEC-88'
```

## PARAMETERS

### -Id
Incident ids.
Takes pipeline input from Get-MsecDefenderIncident by property name.

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
active, inProgress, awaitingAction or resolved.
See the note above on 'redirected'.

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

### -ResolvingComment
Free text explaining the resolution and the classification choice.

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
User principal name to assign the incident to.

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

### -Severity
Re-grade the incident: informational, low, medium or high.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CustomTags
REPLACES the incident's custom tags.
Not an append.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
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

### One PSCustomObject per incident: Id, DisplayName, Severity, the status before, the
### state read back afterwards, and Changed.
## NOTES
Needs Connect-MsecAdmin with SecurityIncident.ReadWrite.All.

displayName, summary and description are updatable through Graph but are deliberately
not exposed here - they are the incident's narrative, not a triage decision, and
rewriting them from a pipeline is a good way to lose Defender's own text.

## RELATED LINKS
