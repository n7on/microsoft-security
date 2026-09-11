---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsPipelineSetting

## SYNOPSIS
Project-level pipeline security settings - fork protection, job authorization scope,
settable variables, shell argument sanitising - one row per project.

## SYNTAX

```
Get-MsecAzureDevOpsPipelineSetting [-Organization] <String> [-Project <String>] [<CommonParameters>]
```

## DESCRIPTION
These are the switches that decide what a pipeline is allowed to do, set once per project
and rarely revisited.
They are not visible from a pipeline definition, so a repository can
look well governed while the project it lives in allows a fork's build to read its
secrets.

THE FORK SETTINGS ARE THE ONES TO READ FIRST, and they only make sense together.
A fork
of a public repository is code from someone outside the organization.
If builds of forks
are enabled AND secrets are not withheld from them, a pull request from a stranger runs
with your credentials.
BuildsEnabledForForks being false makes the rest moot - which is
why they are reported as separate columns rather than a single verdict.

JOB AUTHORIZATION SCOPE decides whether a pipeline's token can reach other projects.
Limited to the current project is the safer setting; unlimited means a compromised
pipeline in a sandbox project can act across the organization.

SETTABLE VARIABLES AT QUEUE TIME let whoever starts a run override variables the pipeline
defined.
Restricting it is what stops a run-time override changing what the pipeline does.

UNRECOGNISED SETTINGS ARE NAMED, NOT DROPPED.
Azure DevOps adds settings to this endpoint
and a column-per-known-key report silently loses them, so anything this command has not
been taught appears in OtherSettings with its value.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso' |
    Format-Table Project, BuildsEnabledForForks, SecretsWithheldFromForks, JobAuthScopeLimited
```

### EXAMPLE 2
```
# The combination that lets an outsider's pull request run with your credentials.
Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso' |
    Where-Object { $_.BuildsEnabledForForks -and -not $_.SecretsWithheldFromForks }
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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per project, PSTypeName 'MsecAzureDevOpsPipelineSetting'.
## NOTES
Needs Connect-Msec and organization membership.
One call per project.

## RELATED LINKS
