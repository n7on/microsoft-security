---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureRoleAssignment

## SYNOPSIS
Azure RBAC role assignments across every accessible subscription, with role and
principal names resolved - who has what, where.

## SYNTAX

```
Get-MsecAzureRoleAssignment [[-Subscription] <String[]>] [[-ScopeLevel] <String[]>]
 [[-PrincipalType] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
Combines three sources, and keeping them apart is the point:

  assignments  Resource Graph, through your Az context.
One query for the whole
               estate rather than a Set-AzContext loop that mutates the caller's
               context - 2415 assignments in one request on a real tenant, against
               400 from Get-AzRoleAssignment in one subscription.
  role names   ARM REST, also your Az context.
No Graph involved.
  principals   Microsoft Graph, through the msec app session.

THIS IS WHY THE TWO IDENTITIES STAY SEPARATE.
Get-AzRoleAssignment resolves principal
names by calling Graph ITSELF, using whatever identity holds the Az context.
That works
for a person - who has directory read by default - and silently returns blank names for
a service principal without Graph permissions.
So a pipeline that ran the same code as
a human would quietly produce a report full of GUIDs.
Splitting the lookups means the
ARM identity needs no directory access at all, and the answer is the same in a pipeline
as it is on a laptop.

PRINCIPALS ARE RESOLVED IN BULK, up to 1000 ids per call, through
/directoryObjects/getByIds.
The obvious implementation is one Graph call per assignment,
which on this tenant would be 2415 round trips.

A PRINCIPAL GRAPH CANNOT NAME IS STILL AN ASSIGNMENT.
Deleted users and service
principals leave their role assignments behind - that is the finding, not an error - so
those rows come back with IsResolved = $false and the raw id rather than being dropped.

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
Get-MsecAzureRoleAssignment | Format-Table PrincipalName, RoleName, ScopeLevel, ScopeName
```

### EXAMPLE 2
```
# The findings worth chasing: broad rights held high up.
Get-MsecAzureRoleAssignment -ScopeLevel Subscription, ManagementGroup |
    Where-Object RoleName -in 'Owner', 'Contributor', 'User Access Administrator' |
    Sort-Object RoleName, PrincipalName
```

### EXAMPLE 3
```
# Assignments left behind by principals that no longer exist.
Get-MsecAzureRoleAssignment | Where-Object { -not $_.IsResolved }
```

## PARAMETERS

### -Subscription
Limit to these subscriptions, by name or id.
Omit for everything the Az context sees.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases: SubscriptionId

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ScopeLevel
Limit to assignments made at these scopes - ManagementGroup, Subscription,
ResourceGroup, Resource.
A Contributor at subscription scope is a very different
finding from one on a single storage account.

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

### -PrincipalType
Limit to User, Group or ServicePrincipal.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per assignment, PSTypeName 'MsecAzureRoleAssignment'.
## NOTES
Needs BOTH an Az context (Reader on the subscriptions) and an msec session
(Directory.Read.All, or User/Group/Application.Read.All) - they do different halves of
the job.
Without the msec session the assignments still come back, with names
unresolved and a warning.

## RELATED LINKS
