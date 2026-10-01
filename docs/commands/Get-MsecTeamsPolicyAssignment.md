---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecTeamsPolicyAssignment

## SYNOPSIS
How many users each Teams policy actually applies to - including the ones that apply
to nobody.

## SYNTAX

```
Get-MsecTeamsPolicyAssignment [[-PolicyType] <String[]>] [-IncludeUser]
 [<CommonParameters>]
```

## DESCRIPTION
Get-MsecTeamsPolicy says what each policy CONTAINS.
This says who GETS it, which is
the other half of the question and the half that decides whether a setting matters.

A tenant can hold a carefully restrictive meeting policy and still be wide open,
because the restrictive policy is assigned to three people and everyone else falls
through to a permissive Global.
From the policy list alone those two tenants are
indistinguishable.
This command is what tells them apart.

POLICIES WITH ZERO USERS ARE RETURNED, NOT OMITTED.
That is the finding, not an empty
result - a policy nobody holds is configuration someone wrote and believes is in
force.
The policy list is read separately from the user list precisely so a policy
with no holders still appears.

ONLY PER-USER POLICY TYPES ARE COVERED.
Federation and Client are tenant-wide
configurations with no assignment at all, so asking who holds them is meaningless -
they are in Get-MsecTeamsPolicy and deliberately absent here.

A USER WITH NO EXPLICIT ASSIGNMENT GETS GLOBAL.
Teams reports that as a null property
rather than as the string 'Global', so those users are counted toward Global here.
This is why UserCount for Global is usually the whole tenant.

UNREADABLE IS NOT ZERO.
If the user list cannot be read, UserCount is $null on every
row and a warning says so, rather than reporting every policy as applying to nobody -
which is both wrong and the most alarming possible reading.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecTeamsPolicyAssignment
```

Every per-user policy with the number of users it applies to.

### EXAMPLE 2
```
Get-MsecTeamsPolicyAssignment | Where-Object UserCount -eq 0
```

The policies that apply to nobody.

### EXAMPLE 3
```
Get-MsecTeamsPolicyAssignment -PolicyType Meeting -IncludeUser
```

Who holds a meeting policy other than Global.

## PARAMETERS

### -PolicyType
Which per-user policy areas to report.
Default is all of them.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: @('Meeting', 'Messaging', 'AppPermission', 'Files')
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeUser
Return one row per user holding an EXPLICIT (non-Global) assignment instead of the
per-policy counts.
Use it to see who the exceptions actually are.

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

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
