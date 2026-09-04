---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraGroupMember

## SYNOPSIS
Lists the members of one or more Entra groups as flat rows - one per (group, member),
so several groups can be asked for at once and the answer stays a table.

## SYNTAX

```
Get-MsecEntraGroupMember [[-Name] <String[]>] [-Id <String[]>] [-Recurse]
 [<CommonParameters>]
```

## DESCRIPTION
Takes group names, resolves each to the groups that match, and emits one row per
member.
The group name is on every row, which is what lets the output of several
groups be sorted, grouped and exported as a single table rather than needing one call
per group.

DISPLAY NAMES ARE NOT UNIQUE IN ENTRA.
Two groups can genuinely share one, so a name
that matches several returns ALL of them rather than picking one, and GroupId is on
every row to tell them apart.
A name that matches nothing is named in a warning rather
than passing silently - an empty result from a typo looks exactly like an empty group.

MEMBERS ARE NOT ONLY USERS.
A group can hold service principals, devices, nested
groups and contacts, and MemberType says which.
Filtering to users here would quietly
drop the service principal somebody added to an access group, which is the member most
worth noticing.
Filter in PowerShell when users are all you want.

PIM-ELIGIBLE MEMBERS ARE INCLUDED, marked MembershipType 'Eligible'.
Where a group is
governed by PIM for Groups, people are ELIGIBLE members rather than actual ones: they
activate the membership and only then hold whatever the group grants.
They appear on
no /members endpoint at all, so a group whose whole membership is eligible reads as
EMPTY - the group looks unused while a queue of people is one activation away.
Anything
that lists group membership and omits them is wrong in the most dangerous direction.

AN EMPTY GROUP EMITS A ROW, with MemberType 'None'.
"The group exists and has nobody in
it" and "the group was not found" are different answers and must not both be silence.
Groups whose membership could not be read at all also emit that row, with a warning -
never an empty group that looks clean.

By default the DIRECT members are listed, which is what the portal shows: a nested
group appears as one row of MemberType 'group'.

-Recurse EXPANDS NESTED GROUPS INSTEAD OF LISTING THEM.
The people inside a nested
group come back as members in their own right, and the nested group itself does not
appear at all - the question being asked is "who is in here", and a group is not a who.
Nesting can be several levels deep and is followed all the way down.

A person reachable through two different nested groups is ONE row, not two.
Active and
Eligible are not collapsed into each other though: someone with standing membership who
is ALSO eligible for it is a real state, and one worth seeing rather than rounding away.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecEntraGroupMember -Name 'sg-admins', 'sg-devops'
```

### EXAMPLE 2
```
# Several groups as one table, grouped for reading.
Get-MsecEntraGroupMember -Name 'sg-prod-*' |
    Sort-Object GroupName, MemberName |
    Format-Table GroupName, MemberName, MemberUserPrincipalName, MemberType, MembershipType
```

### EXAMPLE 3
```
# The members no MFA or Conditional Access policy covers.
Get-MsecEntraGroupMember -Name 'sg-*' |
    Where-Object { $_.MemberType -eq 'servicePrincipal' -or $_.UserType -eq 'Guest' }
```

### EXAMPLE 4
```
# Standing access versus PIM-eligible, per group.
Get-MsecEntraGroupMember -Name 'sg-admins' -Recurse |
    Group-Object GroupName, MembershipType | Select-Object Name, Count
```

### EXAMPLE 5
```
# Everyone who is effectively in the group, however deeply nested - and no group rows.
Get-MsecEntraGroupMember -Name 'sg-admins' -Recurse |
    Sort-Object MemberName |
    Format-Table MemberName, MemberUserPrincipalName, MemberType, MembershipType
```

### EXAMPLE 6
```
# Groups that are empty - which a naive listing cannot tell from a mistyped name.
Get-MsecEntraGroupMember -Name 'sg-*' | Where-Object MemberType -eq 'None'
```

## PARAMETERS

### -Name
Group display names.
Wildcards are supported ('sg-prod-*'), in which case every group
matching is returned.
Without a wildcard the match is exact.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Id
Group object ids, for when a display name is ambiguous or you already have the id.
Combines with -Name.

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
Expand nested groups: a member of a member group is returned as a member, and the
nested group itself is not listed.
Without it, a nested group is one row of MemberType
'group' and its own members are not expanded.

PIM-eligible membership is read for every nested group as well, not only the ones you
named - otherwise a nested group governed by PIM would contribute nobody and the
recursion would quietly be less complete than the single-group case.

Aliased to -Transitive, which is the Graph word for the same idea.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per (group, member), PSTypeName 'MsecEntraGroupMember'.
## NOTES
Needs Connect-Msec and the 'Group.Read.All' application permission, plus
'PrivilegedEligibilitySchedule.Read.AzureADGroup' for the eligible members.
New-MsecApp
grants both.
Without the second, eligible members are missing and a warning says so
rather than the group quietly reading as smaller than it is.

Projection (Graph field -\> output property):
  \<group\> displayName / id     -\> GroupName / GroupId
  \<group\> securityEnabled, mailEnabled, isAssignableToRole
                               -\> GroupType / IsRoleAssignable
  \<member\> @odata.type         -\> MemberType ('user' / 'group' / 'servicePrincipal' / ...)
  \<member\> displayName / id    -\> MemberName / MemberId
  \<member\> userPrincipalName   -\> MemberUserPrincipalName
  \<member\> accountEnabled      -\> AccountEnabled
  \<member\> userType            -\> UserType ('Member' / 'Guest')
  \<member\> onPremisesSyncEnabled -\> OnPremisesSyncEnabled
  \<which endpoint answered\>    -\> MembershipType ('Active' / 'Eligible')
  \<entire member object\>       -\> Raw

## RELATED LINKS
