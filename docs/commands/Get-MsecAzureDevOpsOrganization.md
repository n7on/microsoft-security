---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsOrganization

## SYNOPSIS
Every Azure DevOps organization connected to the Entra tenant, with its owner.

## SYNTAX

```
Get-MsecAzureDevOpsOrganization [[-TenantId] <String>]
 [<CommonParameters>]
```

## DESCRIPTION
Anyone in the tenant can create an Azure DevOps organization, and by default nothing
announces it.
The result is organizations nobody is reviewing: created for a trial or a
side project, owned by one person, holding repositories and service connections that no
governance process knows about.
Measured on a live tenant: 28 organizations, most of them
named after individuals.

THIS IS THE COMMAND THAT TELLS YOU WHAT TO POINT THE OTHERS AT.
Every other
Get-MsecAzureDevOps* command takes -Organization, and the answer is only as complete as
the list of organizations you thought to check.

THE ENDPOINT IS INTERNAL.
There is no documented REST API for enumerating a tenant's
organizations; this is the route behind the Azure DevOps organization list in the Entra
admin portal, and it returns CSV rather than JSON.
Microsoft can change or remove it
without notice.
If this starts returning nothing, that is the first thing to suspect -
which is why an empty result warns rather than reporting a tenant with no organizations.

THE OWNER IS THE ACCOUNTABLE PERSON, not necessarily an administrator.
It is whoever
created the organization or had ownership transferred to them, and it is the single most
useful column here: an organization whose owner has left the company is one nobody can
administer.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsOrganization | Sort-Object Owner
```

### EXAMPLE 2
```
# Organizations named after a person - usually personal, usually unreviewed.
Get-MsecAzureDevOpsOrganization |
    Where-Object { $_.Organization -notmatch '^(contoso|prod|shared)' }
```

### EXAMPLE 3
```
# Feed the whole estate through another command.
Get-MsecAzureDevOpsOrganization | ForEach-Object {
    Get-MsecAzureDevOpsOrganizationPolicy -Organization $_.Organization
}
```

## PARAMETERS

### -TenantId
The Entra tenant to enumerate.
Defaults to the tenant of the current msec session, which
is almost always what you want.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per organization, PSTypeName 'MsecAzureDevOpsOrganization'.
## NOTES
Needs Connect-Msec.
The app needs no membership in the organizations it lists - this is a
tenant-level query - but it does need to be able to acquire an Azure DevOps token, which
Connect-Msec handles.

## RELATED LINKS
