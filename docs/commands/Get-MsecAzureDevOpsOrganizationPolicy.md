---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsOrganizationPolicy

## SYNOPSIS
The organization-wide Azure DevOps security policies - guest access, OAuth and SSH
authentication, public projects, who may invite users - as one row per policy.

## SYNTAX

```
Get-MsecAzureDevOpsOrganizationPolicy [-Organization] <String>
 [<CommonParameters>]
```

## DESCRIPTION
Calls the Azure DevOps REST API:

    GET https://dev.azure.com/{org}/_apis/organizationpolicy/policies

These are the ORGANIZATION's ceiling, the same role the SharePoint tenant settings and
the Teams Global policy play: a well-governed project inside an organization that allows
third-party OAuth apps and alternate credentials is still exposed, and reviewing
projects or pipelines one at a time never surfaces it.

There are only about a dozen of these and every one of them is a security control, so
unlike Get-MsecTeamsPolicy there is no projection to argue with - all of them are
returned.
Category groups them for reading.

IsExplicit MATTERS AS MUCH AS THE VALUE.
A policy nobody ever set reports its default,
and the API says so separately; a default that happens to be safe today is not a
decision anyone made, and it is not guaranteed to stay safe.
So the row carries both
the effective value and whether it was set on purpose, rather than flattening the two
into one column that reads as deliberate configuration.

THE APP'S ACCESS IS GRANTED INSIDE AZURE DEVOPS, NOT IN ENTRA.
New-MsecApp cannot
provision it - see the notes.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
```

### EXAMPLE 2
```
# The ones that widen who can reach the organization.
Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
    Where-Object Category -eq 'Access' |
    Format-Table Setting, Value, IsExplicit
```

### EXAMPLE 3
```
# Everything still sitting on its default, i.e. never decided.
Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
    Where-Object { -not $_.IsExplicit }
```

## PARAMETERS

### -Organization
Azure DevOps organization name: the path segment after dev.azure.com/, e.g.
'contoso'
for https://dev.azure.com/contoso.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per policy, PSTypeName 'MsecAzureDevOpsOrganizationPolicy'.
## NOTES
Needs Connect-Msec, and the msec app's service principal must be a member of the ADO
organization with at least Reader at the project-collection level.
That is configured
INSIDE Azure DevOps (Organization Settings \> Users \> Add), NOT through Entra API
permissions - so New-MsecApp cannot grant it, and the usual 401/403 is turned into an
error that says exactly this.

Reading these policies additionally needs the app to be able to see organization
settings, which project-scoped Reader does not cover.
If the call 401s while
Get-MsecAzureDevOpsServiceConnection works, that is the difference.

## RELATED LINKS
