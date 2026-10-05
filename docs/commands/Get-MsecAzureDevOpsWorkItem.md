---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsWorkItem

## SYNOPSIS
Work items from an Azure DevOps project with their tags, state category and age - for
tracking whether security findings are actually being closed.

## SYNTAX

```
Get-MsecAzureDevOpsWorkItem [-Organization] <String> [[-Project] <String>] [[-Tag] <String>] [[-Team] <String>]
 [[-AreaPath] <String[]>] [[-Type] <String[]>] [-OpenOnly] [[-ChangedWithinDays] <Int32>] [[-MaxItems] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
THIS MEASURES YOUR PROCESS, NOT YOUR TENANT.
Every other Get-Msec* command reads a
Microsoft system and tells you how it is configured.
This one reads your own backlog
and tells you how your team is responding to it.
Both are security questions, but they
are different ones, and this deliberately stays out of Export-MsecPostureReport so a
remediation count never blurs into a posture score.

NO BUNDLED QUERIES.
Area paths, tags, states and work item type names differ in every
organisation - 'Tech Backlog Item' is not even a type in a default project - so the
conventions are PARAMETERS rather than shipped WIQL files.
That is what keeps the
command useful in a tenant other than the one it was written in.

'OPEN' IS NOT A STATE NAME, IT IS A STATE CATEGORY.
Agile uses New/Active/Resolved/
Closed, Scrum uses New/Approved/Committed/Done, Basic uses To Do/Doing/Done, and a
custom process may use anything.
Filtering on a state name would silently return
nothing on a process that does not use it.
So -OpenOnly resolves each type's states to
their CATEGORY (Proposed, InProgress, Resolved, Completed, Removed) and keeps anything
not Completed or Removed.
StateCategory is returned on every row for the same reason.

A STATE THAT COULD NOT BE CLASSIFIED IS KEPT, NOT DROPPED.
If a type's state list is
unreadable, StateCategory is $null and -OpenOnly still returns the row - excluding an
item because msec could not work out whether it was closed would quietly shrink exactly
the list someone is using to chase outstanding work.

WORK ITEMS THE CALLER CANNOT SEE ARE SIMPLY ABSENT.
Azure DevOps answers a WIQL query
with the items the identity may read and no indication that anything was withheld, so
a short answer is not proof of a short backlog.
Compare against the portal before
treating a count as complete.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
    Sort-Object BacklogRank | Format-Table Id, BacklogRank, BoardColumn, Title
```

Backlog order.
Rows come back newest-first by Id, NOT in board order - that order is a
drag-and-drop rank, so sort on BacklogRank to reproduce it.
Two caveats: a board shows
one backlog LEVEL at a time with children nested underneath, so a flat sort over mixed
types will not look identical; and an item never ranked on a backlog has a null rank,
which Sort-Object puts first.

### EXAMPLE 2
```
Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
    ForEach-Object Tags | Group-Object | Sort-Object Count -Descending
```

A count per individual tag.
Tags is a string\[\], so expanding it first counts each tag
separately - Group-Object Tags would instead group by the whole combination and report
'Exchange; Internal IT' as its own bucket.

### EXAMPLE 3
```
Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Viedoc4 `
    -Team 'Security and Regulatory compliance' -OpenOnly
```

One team's backlog.
The team's area paths are resolved from Azure DevOps, including
whether each one takes its children, so the result matches what the team sees in the
portal rather than a guess at the path.

### EXAMPLE 4
```
Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
    Where-Object Tags -contains 'Internal IT'
```

Every open item carrying that tag, including those that carry others alongside it.
Use -contains, not -in or -eq: those compare against the whole array and silently miss
any item with more than one tag.

### EXAMPLE 5
```
Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -Tag security -OpenOnly |
    Where-Object AgeDays -gt 90 | Sort-Object AgeDays -Descending
```

Security findings open for more than ninety days, oldest first.

### EXAMPLE 6
```
Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
    Where-Object { -not $_.Tags } | Format-Table Id, Type, Title
```

Open items nobody has tagged - the ones no tag-based report will ever show.

## PARAMETERS

### -Organization
Azure DevOps organization name.

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

### -Project
Project name.
Omit to query every project the identity can see.

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

### -Tag
Only items carrying this tag.
Matched with CONTAINS, so it also matches one tag out of
a semicolon-separated list.

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

### -Team
A team name in -Project.
The team's area paths are read from Azure DevOps and turned
into the query, honouring each path's includeChildren flag.
A team backlog is usually
several area paths and not all of them take their children, so this is safer than
writing -AreaPath by hand.

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

### -AreaPath
One or more area paths, OR'd together.
Each matches the path and everything beneath it.
Prefer -Team when you mean a team's backlog.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Type
Only these work item types, e.g.
'Task', 'Bug'.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -OpenOnly
Only items whose state category is neither Completed nor Removed.

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

### -ChangedWithinDays
Only items changed within this many days.
Narrows the query server-side, which is the
only thing that helps when a project exceeds the 20,000-item limit Azure DevOps
enforces before returning any result.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -MaxItems
Safety cap on how many items are fetched.
Default 2000.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: 2000
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
