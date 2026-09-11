---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsRepository

## SYNOPSIS
Every Git repository in an Azure DevOps organization with the protections on its default
branch - reviewers, build validation, secret push protection, Advanced Security.

## SYNTAX

```
Get-MsecAzureDevOpsRepository [-Organization] <String> [-Project <String>] [-Unprotected] [<CommonParameters>]
```

## DESCRIPTION
The question this answers is "which repositories can be changed without anyone looking".
A repository whose default branch has no blocking policy accepts a direct push to main;
one whose minimum-reviewer policy counts the author's own vote accepts a self-approved
pull request, which is the same thing with more steps.

POLICIES ARE FETCHED ONCE PER PROJECT, not once per repository.
The policy configuration
endpoint is project-scoped and returns every policy for every repository in one call, so
a few dozen calls cover hundreds of repositories.

A POLICY ONLY COUNTS IF IT IS ENABLED AND BLOCKING.
Azure DevOps lets a policy be
configured, enabled, and non-blocking - it shows in the pull request as advice and stops
nothing.
Reporting that as protection would overstate the posture, so the Require*
columns mean "enabled AND blocking" and PolicyCount reports everything found.

SCOPE IS RESOLVED, NOT ASSUMED.
A policy can be scoped to one repository or to every
repository in the project (a null repository id), and to an exact branch, a prefix, or
the whole repository (an empty ref).
All four are matched against the default branch,
because a project-wide policy protects a repository just as well as a per-repository one.

THIS COMMAND IS ONLY AS COMPLETE AS THE APP'S READ ACCESS.
Azure DevOps returns the
repositories the caller can see, with a 200 - it does not say what it withheld.
An app
without Read on the Git Repositories namespace silently sees a subset.
See the notes.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsRepository -Organization 'contoso' |
    Format-Table Project, Repository, DefaultBranch, MinimumReviewers, RequireBuildValidation
```

### EXAMPLE 2
```
# Repositories anyone can push to unreviewed.
Get-MsecAzureDevOpsRepository -Organization 'contoso' -Unprotected |
    Sort-Object Project, Repository
```

### EXAMPLE 3
```
# Protected on paper only: a reviewer policy the author can satisfy alone.
Get-MsecAzureDevOpsRepository -Organization 'contoso' |
    Where-Object { $_.MinimumReviewers -ge 1 -and $_.SelfApprovalAllowed }
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

### -Unprotected
Only repositories whose default branch requires NO REVIEWER - the ones a change can
reach main through without anyone else looking.

Deliberately not "no blocking policy at all": on a real organization every repository
had at least one, because a single project-wide secrets-scanning rule applies to all of
them.
By that measure nothing was ever unprotected, which is true and useless.
The
reviewer requirement is the control that decides whether a human sees the change.

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

### PSCustomObject per repository, PSTypeName 'MsecAzureDevOpsRepository'.
## NOTES
Needs Connect-Msec, and the msec app must be a member of the ADO organization with Read
on the Git Repositories namespace.
Without it the organization returns only the
repositories the app happens to see and says nothing about the rest - measured on a live
organization, 95 of 220.
Grant it once for the whole organization:

    ./tools/Grant-MsecAzureDevOpsPermission.ps1 -Organization \<org\> \`
        -Identity \<group\> -Permission GenericRead -Scope Organization -Pat $pat -Apply

## RELATED LINKS
