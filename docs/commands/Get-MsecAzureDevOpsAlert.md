---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsAlert

## SYNOPSIS
Advanced Security alerts across an Azure DevOps organization - secret, dependency and
code scanning findings - as one row per alert.

## SYNTAX

```
Get-MsecAzureDevOpsAlert [-Organization] <String> [-State <String>] [-AlertType <String[]>] [<CommonParameters>]
```

## DESCRIPTION
What the Security Overview page shows, as objects.
Secret scanning finds credentials
committed to source; the alert is a live exposure, not a code-quality opinion.

THERE IS NO ORGANIZATION-WIDE ALERTS ENDPOINT.
Confirmed by enumerating the Advanced
Security service's own routes: every alerts route is
{project}/_apis/alert/repositories/{repository}/alerts.
The portal's org-level view
aggregates client-side, and so does this - one call per enabled repository.

THE REPOSITORY LIST COMES FROM ENABLEMENT, NOT FROM THE GIT API, and that is deliberate.
_apis/git/repositories returns only what the caller can see - measured on a live
organization, an app saw 95 repositories where a person with a PAT saw 220 - and it
returns them with a 200, so the shortfall is invisible.
_apis/management/enablement is
ORGANIZATION-scoped, lists every repository with Advanced Security switched on, and is
readable by an org member.
The git call is used only to put names to ids; a repository
whose name cannot be resolved is still queried and reported by id.

A REPOSITORY THAT CANNOT BE READ FAILS LOUDLY.
Alerts return 403, never an empty list,
so unreadable repositories are counted and named rather than passing as clean.
That is
the property that makes this command trustworthy where a service-connection inventory
was not.

THE SECRET ITSELF IS NOT RETURNED.
The API includes a truncatedSecret field holding a
fragment of the credential it found.
This command drops it: the output of a security
report ends up in mailboxes and spreadsheets, and a partial credential in a spreadsheet
is a second exposure.
Title carries the secret TYPE, which is what triage needs.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsAlert -Organization 'contoso' |
    Format-Table Project, Repository, Severity, AlertType, Title, AgeDays
```

### EXAMPLE 2
```
# The ones to act on first: live credentials, high confidence, oldest first.
Get-MsecAzureDevOpsAlert -Organization 'contoso' |
    Where-Object { $_.AlertType -eq 'secret' -and $_.Confidence -eq 'high' } |
    Sort-Object AgeDays -Descending
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

### -State
Filter by alert state.
Default 'active' - the alerts that still matter.
'all' includes
fixed and dismissed ones.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: Active
Accept pipeline input: False
Accept wildcard characters: False
```

### -AlertType
Filter by kind: secret, dependency, code.
All kinds by default.

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

### PSCustomObject per alert, PSTypeName 'MsecAzureDevOpsAlert'.
## NOTES
Needs Connect-Msec, and the msec app must be a member of the ADO organization AND hold
Advanced Security alert read.
Organization membership alone is not enough - the alerts
call returns 403 while enablement and repository listing succeed.

One call per enabled repository, so this is slow on a large organization: 87 enabled
repositories on the tenant it was built against.

## RELATED LINKS
