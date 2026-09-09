---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsUser

## SYNOPSIS
Every user in an Azure DevOps organization and the groups they belong to - one row per
membership, for an access review.

## SYNTAX

```
Get-MsecAzureDevOpsUser [-Organization] <String> [-SubjectType <String[]>]
 [<CommonParameters>]
```

## DESCRIPTION
Answers "who can reach this organization, and through what".
ADO permissions are almost
always granted through group membership, so a user list without groups says nothing
about what anyone can do.

PAGINATED, WHICH THE OBVIOUS IMPLEMENTATION IS NOT.
The ADO graph APIs return one page
and put the cursor in the X-MS-ContinuationToken RESPONSE HEADER.
Reading only
$response.value returns the first page with no error and no sign that more existed - in
an access review the users that go missing look exactly like users who do not exist.

GROUP NAMES ARE RESOLVED FROM ONE FETCH, not one call per membership.
The direct
translation of "for each user, for each membership, get the group" is a call per
membership - on a few hundred users that is thousands of round trips for a few dozen
distinct groups.

A USER IN NO GROUP STILL GETS A ROW, with Group '(none)'.
Emitting nothing for them
would drop the account from the review entirely, and an account nobody granted anything
to is worth seeing rather than losing.

ORIGIN SEPARATES ENTRA-BACKED ACCOUNTS FROM LOCAL ONES.
An 'aad' user is governed by
Conditional Access, MFA and the joiner/leaver process; a 'vsts' user is an account that
exists only inside Azure DevOps and survives everything that happens in Entra.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecAzureDevOpsUser -Organization 'contoso' | Format-Table DisplayName, PrincipalName, Group
```

### EXAMPLE 2
```
# The membership that matters most.
Get-MsecAzureDevOpsUser -Organization 'contoso' |
    Where-Object Group -match 'Project Collection Administrators'
```

### EXAMPLE 3
```
# Accounts that exist only in Azure DevOps - no Conditional Access, no leaver process.
Get-MsecAzureDevOpsUser -Organization 'contoso' | Where-Object Origin -ne 'aad' |
    Select-Object DisplayName, PrincipalName -Unique
```

### EXAMPLE 4
```
# Service identities only.
Get-MsecAzureDevOpsUser -Organization 'contoso' -SubjectType svc
```

## PARAMETERS

### -Organization
Azure DevOps organization name: the path segment after dev.azure.com/, e.g.
'contoso'.

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

### -SubjectType
Restrict to particular subject SUBTYPES: 'aad' (Entra-backed), 'msa' (Microsoft
account), 'svc' (service identity), 'imp' (imported).
Omitted by default, which returns
every kind - including service identities, so a service principal quietly holding
Project Collection Administrators shows up without asking for it.

These are the codes the API uses.
Passing anything else - 'user', 'group' - is not
rejected: it matches no subtype and returns an EMPTY LIST, which reads as an
organization with nobody in it.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per (user, group), PSTypeName 'MsecAzureDevOpsUser'.
## NOTES
Needs Connect-Msec, and the msec app's service principal must be a member of the ADO
organization (Organization Settings \> Users \> Add) with at least Reader.
That is granted
INSIDE Azure DevOps, not through Entra API permissions, so New-MsecApp cannot do it.

One call per user is unavoidable - memberships are only addressable per subject - so
this is O(users) round trips and takes a while on a large organization.

## RELATED LINKS
