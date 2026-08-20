---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraRoleHolder

## SYNOPSIS
Every principal holding ANY Entra directory role - not only privileged ones -
separating what the role is ASSIGNED TO from who EFFECTIVELY holds it, with the
activation state of each.

## SYNTAX

### AllRoles (Default)
```
Get-MsecEntraRoleHolder [-AssignmentType <String>] [-HighlyPrivilegedOnly] [-NoGroupExpansion] [<CommonParameters>]
```

### ByRole
```
Get-MsecEntraRoleHolder [[-Role] <String[]>] [-AssignmentType <String>] [-NoGroupExpansion] [<CommonParameters>]
```

## DESCRIPTION
Answers "who and what can administer this tenant".

EVERY ROLE BY DEFAULT, privileged or not: Global Reader and Message Center
Reader come back alongside Global Administrator.
Pass -HighlyPrivilegedOnly for
the escalation-capable subset.
The command was once called
Get-MsecEntraPrivilegedPrincipal, which read as though the filter were always on
- it never was, and the old name misled often enough to be worth changing.

TWO PRINCIPALS PER ROW, which is the whole shape of this output.
A directory
role can be assigned to a user, a service principal, or a role-assignable
group - so the thing assigned is not always the thing that ends up with the
privilege, and a row that conflates them cannot describe a group assignment
honestly:

  PrincipalName / PrincipalType / PrincipalId
      What the role is assigned to.
This is Graph's own principalId on the
      assignment, so it is a GROUP whenever a group holds the role, and it is
      the object you would act on to revoke the assignment itself.

  EffectiveName / EffectiveType / EffectiveId
      Who ends up holding the role.
The same object as the assignee for a
      direct assignment; a member of the group for a group assignment; $null
      when an assigned group's membership could not be determined.

  MembershipType
      How the effective principal sits inside the assignee: 'Active' or
      'Eligible', and $null when the two are the same object.

So a group of five yields five rows with one assignee and five holders.
Count
holders (EffectiveId) for "how many administrators", count assignments (Raw.id)
for "how many grants", and neither question contaminates the other.

It reads the unified role-management endpoints rather than the older
/directoryRoles, which has four blind spots this does not - msec used to have a
second command built on that endpoint, and these are why it was retired rather
than kept as a lighter alternative:

  1.
PIM-eligible assignments.
/directoryRoles returns *activated* roles and
     their *active* members, so in a tenant using PIM most administrators are
     absent entirely - the report reads "two Global Admins" for a tenant with
     fourteen.

  2.
Group membership.
/directoryRoles/{id}/members returns the role-assignable
     *group* object; the principals inside it never appear.
Here a group is
     expanded transitively, so adding someone to a group cannot hide them from
     a review.
Both ACTUAL and PIM-ELIGIBLE members are read - see PIM FOR
     GROUPS below, because the second kind is invisible to every /members
     endpoint.

  3.
Scope.
A User Administrator confined to one administrative unit is not the
     same risk as a tenant-wide one, and /directoryRoles cannot tell them apart.

  4.
Custom roles.
They are roleDefinitions and never appear as directoryRole
     objects, so a bespoke role granting
     microsoft.directory/roleAssignments went unseen entirely.

A principal that is both actively assigned and separately eligible for the same
role produces two rows.
Those are two distinct facts, and collapsing them would
hide a standing assignment behind a well-governed one.

Because expansion is transitive, the assignee is the group the ROLE is on, not
the innermost nested group a member happens to sit in - the former is what you
would act on, the latter is an implementation detail of the directory.

PIM FOR GROUPS.
A group governed by PIM has ELIGIBLE members, who activate the
membership before they hold anything the group carries.
/transitiveMembers
returns only ACTUAL members, so such a group reads as empty there - the tenant
appears to have nobody in the role while a queue of administrators sits one
activation away from it.
Eligible memberships are therefore read separately from
/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances and
emitted with MembershipType = 'Eligible'.

TWO LINKS, TWO COLUMNS, ONE ANSWER.
Using a role held through a group requires
both the assignment (AssignmentType) and the membership (MembershipType) to be
active.
Each column stays faithful to its own link rather than being folded
together, because "the assignment is active" and "this person can use it right
now" are different facts and a report needs both.
IsActiveNow is the conjunction
- true only when nothing needs activating - and is $null where no holder is
known.

Group OWNERS are excluded.
An owner of a role-assignable group does not hold the
role - they can add themselves as a member and then hold it.
That is a genuine
escalation path and worth its own review, but counting owners as role holders
would overstate the privileged population.

AZURE RBAC IS NOT COVERED.
A directory role can only be assigned to a user,
group, or service principal, so an assignee here is never a management group or
subscription.
Azure RBAC - Owner and User Access Administrator over the
management-group hierarchy - is a separate plane and a separate route to
effective control; see Search-MsecAzureResourceGraph.

PERMISSIONS.
Reading role assignments and reading the identities they point at
are separate grants, and having only the first is the failure mode that looks
like success: 'RoleManagement.Read.Directory' returns every assignment, but
Graph then hands back each principal as an id-and-type shell with every
property null, so the report is complete and entirely anonymous.
Naming the
principals needs 'User.Read.All', 'Group.Read.All' and 'Application.Read.All';
Group.Read.All also covers expanding groups to their members.
PIM-eligible group
membership needs 'PrivilegedEligibilitySchedule.Read.AzureADGroup'.
Anything
missing produces a warning - never a silent blank.

DEGRADED, NOT FAILED, on a tenant without Entra ID P2: eligibility cannot exist
without premium licensing, so /roleEligibilityScheduleInstances is rejected.
That is warned about and the active assignments are still returned - and in such
a tenant those ARE the whole privileged population.
Get-MsecEntraLicense
confirms which case you are in.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly
```

### EXAMPLE 2
```
# One role. Works whether the directory calls it 'Global Administrator' or
# 'Company Administrator', and costs one request rather than a tenant sweep.
Get-MsecEntraRoleHolder -Role 'Global Administrator'
```

### EXAMPLE 3
```
# Several, mixing a canonical name with a raw template id.
Get-MsecEntraRoleHolder -Role 'Global Administrator', 'User Administrator',
                              'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'
```

### EXAMPLE 4
```
# The tier-0 review: who can administer identity, and can they use it today?
Get-MsecEntraRoleHolder -Role 'Global Administrator', 'Privileged Role Administrator' |
    Format-Table EffectiveName, RoleName, AssignmentType, IsActiveNow
```

### EXAMPLE 5
```
# A custom role, by its definition id - the canonical map only covers built-ins.
Get-MsecEntraRoleHolder -Role '4f9c8e21-0d3b-4a77-9e18-7c2d5b6a1f04'
```

### EXAMPLE 6
```
# People only, then applications only. EffectiveType is the HOLDER's kind -
# PrincipalType would say 'group' for anyone who inherited the role.
Get-MsecEntraRoleHolder | Where-Object EffectiveType -eq 'user'
Get-MsecEntraRoleHolder | Where-Object EffectiveType -eq 'servicePrincipal'
```

### EXAMPLE 7
```
# How the privileged population splits between people and applications.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
    Group-Object EffectiveType -NoElement
```

### EXAMPLE 8
```
# Privilege that arrives through a group - the path most reviews miss. The
# assignee differs from the holder exactly when the role was inherited.
Get-MsecEntraRoleHolder | Where-Object PrincipalType -eq 'group' |
    Format-Table EffectiveName, RoleName, PrincipalName, MembershipType
```

### EXAMPLE 9
```
# PIM for Groups: people who hold nothing today but can activate into a group
# that carries a role. Invisible to every /members endpoint.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
    Where-Object MembershipType -eq 'Eligible' |
    Format-Table EffectiveName, RoleName, PrincipalName
```

### EXAMPLE 10
```
# Privilege usable right now - nothing left to activate on either link.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
    Where-Object IsActiveNow
```

### EXAMPLE 11
```
# Standing tenant-wide privilege: the assignments PIM was meant to remove.
Get-MsecEntraRoleHolder -AssignmentType Active -HighlyPrivilegedOnly |
    Where-Object IsTenantScoped
```

### EXAMPLE 12
```
# Distinct humans who can administer the tenant. Count holders, not rows: one
# person inheriting a role through two groups is one administrator.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
    Where-Object { $_.EffectiveType -eq 'user' -and $_.IsResolved } |
    Sort-Object EffectiveId -Unique
```

### EXAMPLE 13
```
# External identities holding privileged roles, and privileged accounts synced
# from on-premises AD. Both should be short, deliberate lists.
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly | Where-Object UserType -eq 'Guest'
Get-MsecEntraRoleHolder -HighlyPrivilegedOnly | Where-Object IsDirectorySynced
```

## PARAMETERS

### -Role
One or more roles to report on, given as display names, roleTemplateIds, or a
mix.
Tab completes.
Mutually exclusive with -HighlyPrivilegedOnly, which is a
different way of naming the same kind of subset.

A name is matched against three things, in this order, case-insensitively:
the roleTemplateId or definition id; the display name THIS tenant reports; and
the canonical name msec knows from Get-MsecPrivilegedRoleTemplate.

That third one is the point of the parameter.
Graph returns Global
Administrator under its legacy name 'Company Administrator' on many tenants, so
-Role 'Global Administrator' resolves through the canonical map to
62e90394-69f5-4237-9190-012177145e10 and matches the role anyway.
Matching only
display names would have reproduced the exact defect this module already carried
in its Global Admin count.

AN UNRECOGNISED VALUE IS A TERMINATING ERROR listing the tenant's roles, rather
than an empty result.
A misspelled role that returned nothing would be
indistinguishable from a role nobody holds - a clean bill of health that is
really a typo, which is the worst way for this command to be wrong.
A role that
resolves but has no definition in this tenant is NOT an error: that is a genuine
empty answer, reported as no rows and a verbose note.

Filtering happens server-side, one request per named role, instead of reading
every assignment in the tenant and discarding the rest.
Asking who holds one
role is therefore cheap on a large directory, and group expansion only runs for
groups that hold the named roles.

```yaml
Type: String[]
Parameter Sets: ByRole
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AssignmentType
Which assignments to read: 'All' (default), 'Active' (standing assignments
only - no premium licence needed), or 'Eligible' (PIM eligibility only,
requires Entra ID P2).

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

### -HighlyPrivilegedOnly
Return only roles that can grant further access, reset credentials, or read
broadly.
The set is defined in Get-MsecPrivilegedRoleTemplate.
Mutually
exclusive with -Role: naming roles explicitly already is the filter, and
combining the two invites an empty result that reads as an answer
(-Role 'Global Reader' -HighlyPrivilegedOnly can only ever be zero rows).

```yaml
Type: SwitchParameter
Parameter Sets: AllRoles
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -NoGroupExpansion
Return assignments as Entra records them: one row per assignment, with the
assignee named and the effective principal left $null.
Useful for "what is
assigned to what", and the honest choice when the app cannot read group
membership - but it is NOT the effective privileged population and must not be
counted as one.

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

### PSCustomObject per (role, principal, assignment type). See .NOTES.
## NOTES
Each row is a \[PSCustomObject\] with PSTypeName 'MsecEntraRoleHolder',
whose DefaultDisplayPropertySet (EffectiveName, EffectiveType, RoleName,
AssignmentType, PrincipalName) is registered in msec.psm1.
The holder leads,
because that is who a review is about; the assignee trails, so an inherited role
shows the group it came from.
On a direct assignment the two hold the same value,
which is the truth rather than a redundancy: assigned to X, held by X.

EffectiveName and PrincipalName are identifiers resolved by type -
userPrincipalName for a user, displayName for a service principal or group, the
id if Graph would name neither.
The matching *Type column says which you are
reading, so neither is ever ambiguous.

The detail columns - DisplayName, UserPrincipalName, AccountEnabled, UserType,
IsDirectorySynced - all describe the EFFECTIVE principal, because that is the
identity that would be remediated.
UserPrincipalName is strictly a UPN and $null
for every non-user, so it stays exact for filtering.

Projection:
  roleDefinition.displayName    -\> RoleName
  roleDefinition.templateId     -\> RoleTemplateId
  (derived from the template id)-\> IsHighlyPrivileged
  (which endpoint it came from) -\> AssignmentType     'Active' / 'Eligible'
  assignment.principal          -\> PrincipalName, PrincipalType, PrincipalId
                                   (what the role is assigned to - a group when
                                   a group holds it)
  group member, or the assignee -\> EffectiveName, EffectiveType, EffectiveId
                                   (who holds it; $null if undeterminable)
  (how the holder sits in it)   -\> MembershipType     'Active'/'Eligible'; $null when
                                   holder and assignee are the same object
  (nothing left to activate?)   -\> IsActiveNow        ($null if no known holder)
  effective.displayName         -\> DisplayName
  effective.userPrincipalName   -\> UserPrincipalName  ($null for non-users)
  effective.accountEnabled      -\> AccountEnabled
  effective.userType            -\> UserType           'Member'/'Guest', users only
  effective.onPremisesSyncEnabled -\> IsDirectorySynced (users only; null = cloud-only)
  (is the holder known?)        -\> IsResolved
  assignment.directoryScopeId   -\> Scope, DirectoryScopeId, IsTenantScoped
  instance.endDateTime          -\> EndDateTime        ($null = never expires)
  \<the assignment object\>       -\> Raw

There is no separate direct-or-inherited column: a row is direct exactly when
PrincipalId and EffectiveId are equal and MembershipType is $null.
A third field
asserting the same thing could only ever drift out of agreement with them.

A group assignment whose membership cannot be determined - no active or eligible
members, unreadable, or -NoGroupExpansion - still yields its row, with the
assignee named and the effective principal $null.
Deleting it would remove a live
privilege path from the report: whoever can write that group's membership can
take the role tomorrow without touching a role assignment.
EVERY ASSIGNMENT
YIELDS AT LEAST ONE ROW.

IsResolved answers one question: do we know who ends up with this privilege?
It
is $false for the undeterminable group above, and for a holder Graph returned as
id and type only because the app may read role assignments but not directory
objects.
Filter it out for a headcount; read it when auditing dormant privilege
paths; never present those rows as a completed review.

A BLANK EffectiveName is therefore never a defect - it is an assignment whose
holder is unknown, and the count of them is reported in a warning at the end of
every run so an empty cell is not left to be interpreted.
The usual cause is a
PIM-governed group without 'PrivilegedEligibilitySchedule.Read.AzureADGroup'
granted, which makes a group full of eligible administrators look empty.

EndDateTime is $null for every active assignment (the roleAssignments endpoint
carries no schedule - those are permanent by definition) and for permanent
eligibility.
A non-null value only ever means time-bound eligibility.

Scope is 'Tenant' for directoryScopeId '/', 'AdministrativeUnit:\<id\>' for an
AU-scoped assignment, and the raw scope id otherwise.
AU display names are not
resolved: that needs AdministrativeUnit.Read.All, a wider grant than this
inventory justifies.

A role definition referenced by an assignment but absent from the
roleDefinitions collection - deprecated and hidden built-ins are the usual
culprits - is fetched individually, once per id.
Only if that also fails does
RoleName fall back to '\<unknown role {id}\>'.

CUSTOM ROLES are never flagged IsHighlyPrivileged, because the flag is a lookup
of known built-in template ids.
A custom role holding
microsoft.directory/roleAssignments permissions is genuinely privileged and will
appear with IsHighlyPrivileged = $false.
Review custom roles by hand; there is
no reliable way to score their permission sets.

Graph has historically required a $filter on the directory provider's
assignment collections.
Without -Role the unfiltered list is attempted first
and, only if Graph rejects it, the query fans out to one call per role
definition - correct either way, one round trip in the common case.
With -Role
the fan-out is taken deliberately and narrowed to the named roles, which is
cheaper than the unfiltered sweep rather than a fallback from it.

Each run caches the tenant's role definitions (id, templateId, displayName,
isBuiltIn) so the -Role completer has real names to offer without ever calling
Graph from the prompt.
Nothing sensitive: role names and ids only.

## RELATED LINKS
