---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsSecureFile

## SYNOPSIS
Secure files stored in an Azure DevOps organization - certificates, keystores and signing
material - and which pipelines may use them.

## SYNTAX

```
Get-MsecAzureDevOpsSecureFile [-Organization] <String> [-Project <String>]
 [<CommonParameters>]
```

## DESCRIPTION
A secure file is a file a pipeline needs but nobody wants in source control: a signing
certificate, a keystore, a provisioning profile, a private key.
Azure DevOps stores it
encrypted and hands it to authorised pipelines at run time.

THE CONTENTS ARE NEVER FETCHED.
There is a download endpoint and this command does not
call it - the point is an inventory of what exists and who can reach it, and a report
that downloads private keys to produce that inventory would be worse than no report.

THE FILE NAME IS THE ONLY CLUE TO WHAT IT HOLDS, so Kind is derived from the extension
and is a guess, clearly labelled as one.
A .pfx is a certificate and probably carries a
private key; a .key could be anything.
The name is always returned so the guess can be
checked.

AGE MATTERS MORE HERE THAN ELSEWHERE.
Signing certificates expire, and a secure file
uploaded four years ago that no pipeline has been authorised against since is either
expired or forgotten.
Neither is visible from the file itself.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsSecureFile -Organization 'contoso'
```

### EXAMPLE 2
```
# Certificates and keystores any pipeline could use.
Get-MsecAzureDevOpsSecureFile -Organization 'contoso' |
    Where-Object { $_.Kind -eq 'Certificate' -and $_.OpenToAllPipelines }
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

### PSCustomObject per secure file, PSTypeName 'MsecAzureDevOpsSecureFile'.
## NOTES
Needs Connect-Msec and organization membership.
One call per project, plus one per file
for the pipeline authorization.

## RELATED LINKS
