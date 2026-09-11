---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsVariableGroup

## SYNOPSIS
Variable groups across an Azure DevOps organization - what they hold, who they are shared
with, and whether any pipeline may use them.

## SYNTAX

```
Get-MsecAzureDevOpsVariableGroup [-Organization] <String> [-Project <String>] [-WithSecrets] [<CommonParameters>]
```

## DESCRIPTION
A variable group holds values that pipelines consume, and secret variables in it are
credentials by another name.
The question worth answering is not "does it contain
secrets" but "which pipelines can reach them" - a group marked available to ALL pipelines
in a project can be referenced by a pipeline someone writes this afternoon.

THE COMBINATION IS THE FINDING.
Secrets in a group, open to every pipeline, in a project
whose repositories require no reviewer, means anyone who can push can author a pipeline
that reads them.
Each of the three is unremarkable alone.
This command reports the first
two; Get-MsecAzureDevOpsRepository reports the third.

VALUES ARE NEVER RETURNED, AND SECRET VALUES ARE NOT AVAILABLE ANYWAY.
Azure DevOps does
not return secret values through this API.
Non-secret values are returned by the API and
are deliberately dropped here: this output goes into mailboxes and spreadsheets, and
pipeline variables carry connection strings and hostnames often enough that copying them
into a report is a poor default.
Variable NAMES are kept, because knowing a group holds
'AZURE_CLIENT_SECRET' is the point.

A KEY VAULT-BACKED GROUP IS A REFERENCE, NOT A COPY.
Its type is AzureKeyVault and the
secrets stay in the vault, fetched at run time through a service connection.
That moves
the question to the vault and the connection rather than removing it.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsVariableGroup -Organization 'contoso' -WithSecrets |
    Where-Object OpenToAllPipelines
```

### EXAMPLE 2
```
# Everything a pipeline author could reach without asking anyone.
Get-MsecAzureDevOpsVariableGroup -Organization 'contoso' |
    Where-Object OpenToAllPipelines |
    Sort-Object SecretCount -Descending
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

### -Project
Restrict to one project.
All projects by default.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WithSecrets
Only groups that hold at least one secret variable, or are backed by a Key Vault.

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

### PSCustomObject per variable group, PSTypeName 'MsecAzureDevOpsVariableGroup'.
## NOTES
Needs Connect-Msec and organization membership.
One call per project, plus one per group
for the pipeline authorization.

## RELATED LINKS
