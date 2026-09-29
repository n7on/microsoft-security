---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Grant-MsecAzureDevOpsPermission

## SYNOPSIS
Grants an Azure DevOps permission to an identity or group, at organization or project
scope.
Runs as YOU - one-time setup, not something the app can do for itself.

## SYNTAX

```
Grant-MsecAzureDevOpsPermission [-Organization] <String> [[-Identity] <String>] [[-Permission] <String[]>]
 [[-RoleName] <String>] [[-RoleScope] <String>] [[-Namespace] <String>] [[-Scope] <String>]
 [[-Project] <String>] [-ListPermissions] [-ListRoles] [-Revoke] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Some things msec needs cannot be granted through Entra.
New-MsecApp handles API
permissions and directory roles; Azure DevOps keeps its own permission system, and an
app that is a member of the organization still reads nothing until permissions are set
INSIDE Azure DevOps.
This is the other half.

IT RUNS AS YOU, NOT AS THE APP, and that is not a detail.
The app is usually the
GRANTEE, and an identity that could grant itself permissions would make the whole
exercise circular.
Managing permissions in Azure DevOps needs Project Collection
Administrator or equivalent, which a person has and the app should not.

NO PERSONAL ACCESS TOKEN.
An earlier version of this took a PAT.
It does not need one:
the security namespace, access control list and identity APIs all accept an ordinary
Entra token for the Azure DevOps resource, which was verified against all three before
the PAT was removed.
A PAT is a long-lived credential, and asking people to create one
for a setup task is worse than using the sign-in they already have.

AZURE DEVOPS HAS TWO PERMISSION SYSTEMS AND THEY ARE NOT INTERCHANGEABLE.

  -Permission  classic security namespaces, granted as ACL bits on a hierarchical token.
               Repositories and Advanced Security live here.
  -RoleName    role assignments (Reader / User / Administrator) on a resource scope.
               Pipeline resources - service connections, agent pools, variable groups,
               secure files - live here, and have no organization root.

Picking the wrong one fails SILENTLY: an allow on the ServiceEndpoints namespace is
accepted, stored, reported back by the ACL API, and confers nothing at all.
Verified the
hard way.

NOTHING IS HARDCODED.
The namespace id and the permission bit are resolved by NAME at
run time from the security namespace metadata, so a renumbered bit fails loudly instead
of silently granting a different permission.
The bit for 'view alerts' happens to be
65536 today; that is a fact about one organization on one date, not something to rely on.

THE ROOT TOKEN IS NAMESPACE-SPECIFIC AND HAS NO TRAILING SLASH.
Git Repositories is
'repoV2'; 'repoV2/' returns 400 "The request is invalid" for the same body.
That one
character is the difference between granting once for the whole organization and
granting once per project, and it cost an afternoon to find.
Namespaces this command has
not been proven against are refused rather than guessed at.

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
Grant-MsecAzureDevOpsPermission -Organization contoso -ListPermissions
```

### EXAMPLE 2
```
Grant-MsecAzureDevOpsPermission -Organization contoso -Identity 'Security Reporting Readers' `
    -Permission ViewAdvSecAlerts -Scope Organization -WhatIf
```

Shows what would change.
Drop -WhatIf to write it.

### EXAMPLE 3
```
# Service connections use ROLES, not namespace bits.
Grant-MsecAzureDevOpsPermission -Organization contoso -Identity 'Security Reporting Readers' `
    -RoleName Reader -Scope Project
```

## PARAMETERS

### -Organization
Azure DevOps organization name: the path segment after dev.azure.com/.

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

### -Identity
Who to grant to - a group or an app, by display name.
A GROUP is usually right: the
permission is then granted once and membership becomes the control.

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

### -Permission
Permission names as the namespace defines them, e.g.
ViewAdvSecAlerts.
Run with
-ListPermissions to see them.

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

### -RoleName
Role assignment instead of a namespace ACL - Reader, User or Administrator.
Use this for
pipeline resources; see the note above on the two systems.

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

### -RoleScope
The roles scope.
distributedtask.serviceendpointrole is service connections.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: Distributedtask.serviceendpointrole
Accept pipeline input: False
Accept wildcard characters: False
```

### -Namespace
Security namespace name, for -Permission.
Case-sensitive.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: Git Repositories
Accept pipeline input: False
Accept wildcard characters: False
```

### -Scope
Organization or Project.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: Organization
Accept pipeline input: False
Accept wildcard characters: False
```

### -Project
Limit to one project by name.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ListPermissions
Emit the permission names and bits in the namespace, and stop.
Reads only.

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

### -ListRoles
Emit the role assignments that exist on the scope, and stop.
Reads only.
Use it when a
grant reports "already" and nothing changed - it shows what is actually there rather
than what a match against one identity implies.

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

### -Revoke
Take the permission away instead of granting it.
Working out which permission an API
actually checks tends to leave grants behind that turned out not to enable anything,
and those should not just be left in place.

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

### One PSCustomObject per target describing what was found and what was done.
## NOTES
Needs an Az sign-in (Connect-AzAccount) as someone who can manage Azure DevOps
permissions - Project Collection Administrator or equivalent.
It does NOT need
Connect-Msec: this grants the app its access, so it runs before the app has any.

## RELATED LINKS
