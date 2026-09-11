---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsEnvironment

## SYNOPSIS
Pipeline environments across an organization, the checks guarding them, and who approves
- one row per environment.

## SYNTAX

```
Get-MsecAzureDevOpsEnvironment [-Organization] <String> [-Project <String>] [-Unchecked] [<CommonParameters>]
```

## DESCRIPTION
An environment is what a pipeline deploys TO, and the checks on it are the last thing
between a pipeline run and production.
An environment with no approval check is a
deployment target nobody signs off: the pipeline reaches it unattended, whenever it runs.

NO CHECKS IS THE FINDING, and it is easy to miss because it looks like nothing.
An
environment that has never had a check configured returns an empty list, which is the
same shape as one whose checks could not be read - so those two are reported differently:
CheckCount 0 means none are configured, $null means the read failed.

AN APPROVAL WITH NO APPROVERS APPROVES NOTHING USEFUL.
Approvers are resolved to names
where the API gives them, and a check configured against a group is reported as that
group - who is IN the group is a separate question, answerable with
Get-MsecAzureDevOpsUser.

OPEN TO ALL PIPELINES applies here as it does to service connections and variable groups:
any pipeline in the project may deploy to the environment with no further authorization.
Combined with no approval check, that is a production target reachable by a pipeline
somebody writes this afternoon.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsEnvironment -Organization 'contoso' -Unchecked
```

### EXAMPLE 2
```
# Reachable by any pipeline, with nobody approving.
Get-MsecAzureDevOpsEnvironment -Organization 'contoso' |
    Where-Object { $_.OpenToAllPipelines -and -not $_.HasApproval }
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

### -Unchecked
Only environments with no checks configured at all.

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

### PSCustomObject per environment, PSTypeName 'MsecAzureDevOpsEnvironment'.
## NOTES
Needs Connect-Msec and organization membership.
One call per project to list
environments, then two per environment - the checks and the pipeline authorization.

## RELATED LINKS
