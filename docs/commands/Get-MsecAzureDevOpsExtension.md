---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsExtension

## SYNOPSIS
Marketplace extensions installed in an Azure DevOps organization, with the access each
one holds - one row per extension.

## SYNTAX

```
Get-MsecAzureDevOpsExtension [-Organization] <String> [-ThirdPartyOnly]
 [<CommonParameters>]
```

## DESCRIPTION
An extension is third-party code running inside your organization with delegated access
to it.
The scopes it was granted at install time are permanent until someone uninstalls
it, they apply organization-wide, and nothing prompts anyone to review them again.

A publisher with \`vso.serviceendpoint_manage\` can read and rewrite service connections;
one with \`vso.code_manage\` can rewrite repositories.
Those are not hypothetical
permissions - they are what the extension already has.

ACCESS IS DERIVED FROM THE SCOPE SUFFIXES, and that derivation is this command's
judgement rather than something the API states:

    Manage   any *_manage scope - full control of that resource type
    Write    any *_write or *_execute scope - can change things or run code
    Read     read-only scopes
    None     no scopes declared

The raw Scopes are always returned alongside it, because the grouping is a convenience
and the scope list is the fact.

MICROSOFT-PUBLISHED IS NOT THE SAME AS SAFE, but it is the line most reviews draw first,
so IsMicrosoftPublisher is a column rather than a filter.
Judging the publisher is the
reader's job.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsExtension -Organization 'contoso' |
    Sort-Object Access, Publisher | Format-Table Publisher, ExtensionName, Access, Scopes
```

### EXAMPLE 2
```
# Third-party code that can rewrite service connections or repositories.
Get-MsecAzureDevOpsExtension -Organization 'contoso' -ThirdPartyOnly |
    Where-Object { $_.Access -in 'Manage', 'Write' }
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

### -ThirdPartyOnly
Exclude extensions published by Microsoft.
On a real organization 43 of 50 were
Microsoft-published, and the remainder is where a review usually starts.

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

### PSCustomObject per extension, PSTypeName 'MsecAzureDevOpsExtension'.
## NOTES
Needs Connect-Msec and organization membership.
No extra permission: the extension
management API is readable by any member, unlike repositories and service connections.

Extensions are installed per ORGANIZATION, so there is no project dimension here.

## RELATED LINKS
