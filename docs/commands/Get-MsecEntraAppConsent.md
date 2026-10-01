---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraAppConsent

## SYNOPSIS
Which applications have been granted access to your tenant's data, what they can do,
and who agreed to it - one row per permission.

## SYNTAX

```
Get-MsecEntraAppConsent [[-PermissionType] <String[]>] [-HighRiskOnly] [-ThirdPartyOnly] [<CommonParameters>]
```

## DESCRIPTION
Get-MsecEntraAppCredential says which apps hold a key.
This says what those apps are
ALLOWED TO DO, which is the half that decides whether a key matters.
Illicit consent
is one of the most common routes into a Microsoft 365 tenant precisely because it needs
no password, survives a password reset, and leaves the attacker holding a token rather
than an account.

TWO DIFFERENT GRANTS, REPORTED TOGETHER.
  Delegated   - oauth2PermissionGrants.
The app acts AS A USER and is limited to what
                that user can reach.
ConsentType 'AllPrincipals' means an administrator
                consented on behalf of EVERYONE; 'Principal' means one user consented
                for themselves.
  Application - appRoleAssignments.
The app acts AS ITSELF, with no user and no user's
                limits.
Mail.Read here is every mailbox in the tenant, not one.
An Application grant is almost always the more serious of the two for the same
permission name, so PermissionType belongs in any review that sorts by risk.

ONE ROW PER PERMISSION, NOT PER GRANT.
A single delegated grant carries a whole
space-separated scope string; left whole it cannot be filtered or compared.
Split out,
'which apps can read mail' is one Where-Object.

APP ROLE ASSIGNMENTS ARE READ FROM THE RESOURCE SIDE, deliberately.
The obvious route -
expanding appRoleAssignments on each service principal - SILENTLY TRUNCATES at one page
and does not paginate: measured on one tenant it returned 203 assignments where the
resource-side read returned 410, and 20 of msec's own 24.
A security command that
under-reports permissions by half is worse than no command, so this one pays for ~200
extra calls and takes about half a minute.

ASSIGNMENTS TO USERS AND GROUPS ARE NOT CONSENT AND ARE EXCLUDED.
An app role assigned
to a user or a group says who may USE an app; only an assignment to a service principal
is an API permission the app holds over your data.
Mixing them would inflate every
count with something that answers a different question.

HIGH RISK IS A JUDGEMENT AND IS WRITTEN DOWN IN THE SOURCE, not inferred.
See
$highRisk below and argue with it - the three escalation permissions at the top of that
list let an app grant ITSELF more access, up to and including Global Administrator.

UNREADABLE IS NOT EMPTY.
A resource whose assignments cannot be read is reported as a
row saying so, rather than omitted - an app with permissions nobody could enumerate
must not read as an app with none.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraAppConsent -HighRiskOnly | Where-Object PermissionType -eq 'Application'
```

Apps that can act on the whole tenant without a user, holding a sensitive permission.

### EXAMPLE 2
```
Get-MsecEntraAppConsent -ThirdPartyOnly |
    Where-Object ConsentType -eq 'AllPrincipals'
```

Third-party apps an administrator consented to on behalf of every user.

### EXAMPLE 3
```
Get-MsecEntraAppConsent | Group-Object ClientDisplayName |
    Sort-Object Count -Descending | Select-Object -First 20
```

The apps holding the most permissions.

## PARAMETERS

### -PermissionType
Delegated, Application, or both.
Default is both.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: @('Delegated', 'Application')
Accept pipeline input: False
Accept wildcard characters: False
```

### -HighRiskOnly
Only permissions on the curated high-risk list.

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

### -ThirdPartyOnly
Exclude applications published by Microsoft.
Convenience for review, not a default:
a first-party app with a surprising permission is still worth seeing.

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

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
