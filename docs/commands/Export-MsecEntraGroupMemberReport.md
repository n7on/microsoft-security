---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Export-MsecEntraGroupMemberReport

## SYNOPSIS
Evidence of who is in which Entra group - one worksheet per group, a Summary comparing
them, and a chart of the membership mix.

## SYNTAX

```
Export-MsecEntraGroupMemberReport [-Path] <String> [[-Name] <String[]>] [-Id <String[]>] [-Recurse]
 [-TableStyle <String>] [-ChartWidth <Int32>] [-ChartHeight <Int32>] [-Force] [-PassThru] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
A snapshot, not a trend: nothing is appended, and a group written twice is replaced.
Rows come from Get-MsecEntraGroupMember, so everything it knows about the limits of the
answer applies here and is carried into the table rather than smoothed over.

ONE WORKSHEET PER GROUP, named after it, holding that group's members.
The Summary
sheet has one row per group instead, which is the sheet a reviewer actually reads
first - how big each group is, how much of it is standing rather than PIM-eligible, and
how much of it is guests or service principals.

THE CHART COMPARES GROUPS, not membership types within one group.
Groups are the x
axis, so the question it answers is "which of these is the outlier" - the access group
that grew, the one that is all guests, the one with a service principal in it.
A chart
per group would be a dozen tiny pictures of a number you can already read in a cell.

WORKSHEET NAMES ARE NOT GROUP NAMES, quite.
Excel allows 31 characters and forbids
: \ / ?
* \[ \], so a long group name is truncated and a truncation collision is suffixed
to keep two groups apart.
GroupName and GroupId are columns on every row, so the full
name is always readable regardless of what the tab says.

PIM-ELIGIBLE MEMBERS ARE INCLUDED and counted separately, because a group whose
membership is mostly eligible is a different thing from one where everybody has standing
access - and a listing that omitted them would report a PIM-governed group as empty.

AN EMPTY GROUP STILL GETS A WORKSHEET AND A SUMMARY ROW.
"Nobody is in it" is a finding,
and one that disappears if empty groups are skipped.
A group whose membership could not
be read is marked Unreadable rather than reported as empty, and warned about.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Export-MsecEntraGroupMemberReport -Path ./group-members.xlsx -Name 'sg-admins', 'sg-devops'
```

### EXAMPLE 2
```
# Every access group, with nested groups expanded to the people actually inside them.
Export-MsecEntraGroupMemberReport -Path ./access-review.xlsx -Name 'sg-*' -Recurse
```

### EXAMPLE 3
```
# The rows a reviewer will ask about: guests and service principals holding access.
Export-MsecEntraGroupMemberReport -Path ./review.xlsx -Name 'sg-*' -PassThru |
    Where-Object { $_.UserType -eq 'Guest' -or $_.MemberType -eq 'servicePrincipal' } |
    Sort-Object GroupName, MemberName
```

## PARAMETERS

### -Path
The .xlsx to write.
Created if absent; an existing file is added to rather than
replaced, so groups collected in separate runs can share one document.

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

### -Name
Group display names, wildcards supported.
Passed to Get-MsecEntraGroupMember, so a name
matching nothing is warned about and a name matching several groups returns all of them.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Id
Group object ids, for when a display name is ambiguous.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Recurse
Expand nested groups, so the people inside them are reported as members of the outer
group and the nested group itself is not listed.
See Get-MsecEntraGroupMember.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: Transitive

Required: False
Position: Named
Default value: False
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

### -Force
Replace existing worksheets without asking.
Unattended runs need this: there is no one
to answer the prompt.

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

### -PassThru
Emit the per-member rows as objects as well as writing them.

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

### With -PassThru, one PSCustomObject per (group, member) - the rows from
### Get-MsecEntraGroupMember.
## NOTES
Needs Connect-Msec, 'Group.Read.All', and
'PrivilegedEligibilitySchedule.Read.AzureADGroup' for the eligible members.

THE OVERWRITE PROMPT COMES AFTER THE COLLECTION HERE, unlike the VM reports which ask
first.
Which worksheets are at stake is not knowable until the group names have been
resolved - '-Name sg-*' could be one group or forty - and reading group membership has
no side effects, so a declined run costs a Graph read rather than Run Commands against
live machines.

## RELATED LINKS
