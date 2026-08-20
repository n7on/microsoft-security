---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecAdoServiceConnection

## SYNOPSIS
Lists every service connection (service endpoint) in an Azure DevOps
organization, projected to flat PowerShell rows with the full Graph
object preserved in Raw.

## SYNTAX

```
Get-MsecAdoServiceConnection [-Organization] <String> [[-Project] <String>] [<CommonParameters>]
```

## DESCRIPTION
Calls the Azure DevOps REST API:

    GET https://dev.azure.com/{org}/{project}/_apis/serviceendpoint/endpoints
        ?api-version=7.1-preview.4

Service connections are project-scoped in ADO, but commonly *shared*
across projects.
This function walks all projects in the org by default
and de-duplicates by endpoint Id, so each connection appears as one row
even if it's exposed to multiple projects.
The 'Projects' column lists
every project the connection is currently shared to.

See the examples for the audit-relevant questions the ADO portal makes painful.

## EXAMPLES

### EXAMPLE 1
```
# All service connections, sorted by what they connect to.
Get-MsecAdoServiceConnection -Organization 'contoso' |
    Sort-Object Type | Format-Table Name, Type, AuthScheme, IsShared
```

### EXAMPLE 2
```
# Connections to Azure subscriptions specifically: find forgotten ones, and audit
# the auth scheme - Service Principal vs Managed Identity vs Federated Workload
# Identity. A long-lived secret here is a standing key to a subscription.
Get-MsecAdoServiceConnection -Organization 'contoso' |
    Where-Object Type -eq 'azurerm' |
    Select-Object Name, AuthScheme, @{ n = 'SubId'; e = { $_.Raw.data.subscriptionId } },
                  CreatedByName, Projects
```

### EXAMPLE 3
```
# Highly shared connections - broad blast radius if one is compromised, because
# any pipeline in any of those projects can use it.
Get-MsecAdoServiceConnection -Organization 'contoso' |
    Where-Object { $_.Projects.Count -gt 3 } |
    Sort-Object { $_.Projects.Count } -Descending
```

## PARAMETERS

### -Organization
Azure DevOps organization name.
The bit before .visualstudio.com in
the legacy URL, or the path segment after dev.azure.com/ in the modern
URL.
E.g.
'contoso' for https://dev.azure.com/contoso.

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
Restrict to one project.
When omitted, walks every project in the org
(so the result is the org-wide unique list).

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES
The msec app's service principal must be added as a member of the ADO
organization with at least "Reader" permissions at the project-collection
level (or project-scoped reader on every project you want to query).
This is configured INSIDE Azure DevOps (Organization Settings \> Users),
NOT via Entra API permissions - so it's NOT something New-MsecApp can
provision.
A clearer error is raised on the typical 401/403.

Each row is a \[PSCustomObject\] with PSTypeName 'MsecAdoServiceConnection'.
Default Format-Table view: Name, Type, AuthScheme, IsShared - registered
in Msec.psm1.
Raw and other columns remain accessible via property
access or Format-List.

## RELATED LINKS
