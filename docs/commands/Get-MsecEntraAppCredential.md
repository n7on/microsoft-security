---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraAppCredential

## SYNOPSIS
Every client secret and certificate on the tenant's app registrations, with how
long each has left - the credential expiry inventory.

## SYNTAX

```
Get-MsecEntraAppCredential [[-ExpiringWithinDays] <Int32>] [-IncludeServicePrincipal] [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/applications and projects ONE ROW PER CREDENTIAL.
An
app registration with two secrets and a certificate is three rows, because the
credential is the thing that expires and the thing you have to rotate - rolling
them up per app would hide the one that lapses on Friday behind the two that are
good for a year.

THIS IS BOTH A SECURITY AND AN AVAILABILITY QUESTION.
An expired credential is an
outage: the app stops authenticating, usually at 3am, usually on the integration
nobody remembers owning.
A long-lived one is the security half - a secret minted
with a two-year lifetime is two years of standing access if it ever leaks, so
LifetimeDays is carried alongside the expiry rather than only the end date.

APP REGISTRATIONS ARE INVENTORIED COMPLETELY, INCLUDING THE ONES WITH NO
CREDENTIALS.
Those get a single row with CredentialType 'None' and null dates.
That is deliberate: an app with no secret at all is usually the GOOD state - it
has moved to federated credentials (workload identity) or is a pure public client -
and a report that silently omitted it could not tell you that, nor tell "no
credentials" apart from "app not returned".

SERVICE PRINCIPALS ARE NOT INVENTORIED THAT WAY, and are opt-in via
-IncludeServicePrincipal.
A tenant carries hundreds of Microsoft-owned service
principals holding no credentials whatever, so listing them all would bury the
rows that matter.
Only service principals that actually HOLD a credential are
returned.
They are worth asking for: a SAML app's token-signing certificate lives
here rather than on the app registration, and its expiry is a sign-in outage for
every user of that app.

Requires the 'Application.Read.All' application permission.
A clearer error is
raised on the typical 403.

Secret VALUES are never returned by Graph - only the metadata.
Nothing here can
leak a usable credential.

## EXAMPLES

### EXAMPLE 1
```
# The rotation list: what is already dead, worst first.
Get-MsecEntraAppCredential | Where-Object IsExpired | Sort-Object DaysUntilExpiry
```

### EXAMPLE 2
```
# The next 60 days, expired ones included.
Get-MsecEntraAppCredential -ExpiringWithinDays 60 | Sort-Object DaysUntilExpiry |
    Format-Table DisplayName, CredentialType, CredentialName, EndDateTime, DaysUntilExpiry
```

### EXAMPLE 3
```
# The security half rather than the outage half: secrets minted to last for years.
Get-MsecEntraAppCredential |
    Where-Object { $_.CredentialType -eq 'Secret' -and $_.LifetimeDays -gt 365 } |
    Sort-Object LifetimeDays -Descending
```

### EXAMPLE 4
```
# SAML sign-in outages waiting to happen.
Get-MsecEntraAppCredential -IncludeServicePrincipal |
    Where-Object { $_.ObjectType -eq 'ServicePrincipal' -and $_.CredentialUsage -eq 'Sign' } |
    Sort-Object DaysUntilExpiry
```

### EXAMPLE 5
```
# Apps that need no rotating at all, because they hold no secret.
Get-MsecEntraAppCredential | Where-Object CredentialType -eq 'None'
```

## PARAMETERS

### -ExpiringWithinDays
Keep only credentials that expire within this many days.
ALREADY-EXPIRED
credentials are always included, whatever the number: expired is strictly worse
than expiring, and a window that hid them would be answering the wrong question.

Apps with no credentials drop out under this filter - they have no expiry to fall
inside a window.
Omit the parameter for the full inventory.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeServicePrincipal
Also return credentials held on service principals - SAML token-signing
certificates in particular.
Only service principals holding at least one
credential are returned; see .DESCRIPTION.

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

### PSCustomObject per credential, PSTypeName 'MsecEntraAppCredential'. See .NOTES
### for the projection.
## NOTES
Needs Connect-Msec and the 'Application.Read.All' application permission, which
New-MsecApp already grants.

Projection (Graph field path -\> output property):
  displayName                       -\> DisplayName
  appId                             -\> AppId
  id                                -\> ObjectId
  \<which collection it came from\>   -\> ObjectType      ('Application' / 'ServicePrincipal')
  \<which array it came from\>        -\> CredentialType  ('Secret' / 'Certificate' / 'None')
  *Credentials\[\].displayName        -\> CredentialName
  *Credentials\[\].keyId              -\> KeyId
  keyCredentials\[\].usage            -\> CredentialUsage ('Verify' / 'Sign'; null for secrets)
  *Credentials\[\].startDateTime      -\> StartDateTime
  *Credentials\[\].endDateTime        -\> EndDateTime
  \<derived\>                         -\> DaysUntilExpiry, IsExpired, LifetimeDays
  signInAudience                    -\> SignInAudience  (null on service principals)
  createdDateTime                   -\> CreatedDateTime
  \<entire app / SP object verbatim\> -\> Raw

DaysUntilExpiry FLOORS, so a credential that lapsed two hours ago reads -1 rather
than 0.
IsExpired is the exact test and is computed from the timestamps, not from
the rounded number - so DaysUntilExpiry 0 means "expires later today", not
"expired".

Raw is the whole application or servicePrincipal object, not the credential - the
credential is a member of its passwordCredentials / keyCredentials array, findable
by KeyId.
Keeping the app means the row can still reach requiredResourceAccess
(what the app is allowed to do), which is what decides whether a leaked secret
would matter.

OWNERS ARE NOT RESOLVED.
"Who do I chase about this" is the field you most want,
and Graph only answers it per app - one extra call each, so a tenant with several
hundred registrations would pay several hundred round trips for it.
Look the
handful you actually care about up by ObjectId instead.

## RELATED LINKS
