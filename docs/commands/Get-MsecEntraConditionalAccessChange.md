---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraConditionalAccessChange

## SYNOPSIS
Changes to Conditional Access policies - who altered what, when - with the before and
after values of each setting that actually moved.

## SYNTAX

```
Get-MsecEntraConditionalAccessChange [[-Days] <Int32>] [[-PolicyName] <String>] [[-Actor] <String>]
 [-IncludeUnchanged] [<CommonParameters>]
```

## DESCRIPTION
Entra records a CA change as a single audit property called 'ConditionalAccessPolicy'
whose old and new values are the ENTIRE POLICY as a JSON string.
Read raw that is two
multi-kilobyte blobs and no answer.
This parses both and reports only the fields that
differ, so "MFA was removed from policy X" is a row rather than an exercise.

MODIFIEDDATETIME IS EXCLUDED FROM THE DIFF because it changes on every edit by
definition.
Left in, every single change carries a meaningless entry and the real one is
harder to see.
Same for the policy id and createdDateTime, which cannot change at all.

STATE IS CALLED OUT SEPARATELY.
A policy moving enabled -\> disabled or -\> enabledForReportingButNotEnforced
is the highest-signal CA change there is, and it is one field inside a large object.
StateBefore and StateAfter are columns so it can be filtered without reading diffs.

AN APP CAN CHANGE CONDITIONAL ACCESS, AND OFTEN DOES.
Measured on one tenant, 11 of 15
changes came from a Microsoft365DSC orchestrator service principal and only 4 from
people.
Actor therefore falls back from user principal name to application display
name - taking only the user would report the majority of changes as having no author.

THE AUDIT WINDOW IS 30 DAYS ON ENTRA ID P1/P2 AND 7 ON THE FREE TIER, and that ceiling
cannot be raised by asking.
A policy altered before it shows no change here at all.
The
window actually returned is reported on the verbose stream, and
Get-MsecEntraConditionalAccessPolicy's ModifiedDateTime persists indefinitely - so a
policy whose ModifiedDateTime predates this window was changed by someone whose identity
is simply gone.
Compare the two rather than reading silence as stability.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraConditionalAccessChange
```

Every Conditional Access change in the retention window.

### EXAMPLE 2
```
Get-MsecEntraConditionalAccessChange | Where-Object { $_.StateAfter -eq 'disabled' }
```

Policies that were switched off.
The change most worth knowing about.

### EXAMPLE 3
```
Get-MsecEntraConditionalAccessChange |
    Where-Object { $_.ChangedProperties -match 'grantControls' } |
    Select-Object ActivityDateTime, PolicyName, Actor, ChangedProperties
```

Changes that touched what a policy actually enforces, as opposed to its name or scope.

### EXAMPLE 4
```
# Policies altered outside the audit window - changed, but by whom is unrecoverable.
$changed = (Get-MsecEntraConditionalAccessChange).PolicyId
Get-MsecEntraConditionalAccessPolicy |
    Where-Object { $_.Id -notin $changed -and $_.ModifiedDateTime -gt $_.CreatedDateTime }
```

## PARAMETERS

### -Days
How far back to search.
Default 30, the P1/P2 ceiling.
Drop to 7 on a free tenant.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -PolicyName
Substring match on the policy name, case-insensitive.

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

### -Actor
Substring match on who made the change - user principal name or application name.

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

### -IncludeUnchanged
Keep rows where nothing but the excluded noise fields moved.
Off by default: an edit
that changed nothing of substance is not a change anyone needs to read.

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

### PSCustomObject per change, PSTypeName 'MsecEntraConditionalAccessChange'.
## NOTES
Needs 'AuditLog.Read.All', which New-MsecApp already grants, plus Entra ID P1/P2 for a
directory audit log at all.

## RELATED LINKS
