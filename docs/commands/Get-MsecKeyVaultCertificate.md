---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecKeyVaultCertificate

## SYNOPSIS
Every certificate in the accessible Key Vaults, with how long each has left - the
certificate expiry inventory.

## SYNTAX

```
Get-MsecKeyVaultCertificate [[-VaultName] <String[]>] [[-Tag] <Hashtable>] [[-ExpiringWithinDays] <Int32>]
 [-IncludeDisabled] [<CommonParameters>]
```

## DESCRIPTION
One row per certificate, across every vault the Az context can see, or a subset chosen
by name or tag.

CERTIFICATES ARE DATA-PLANE, SO RESOURCE GRAPH CANNOT SEE THEM.
Every other Azure
inventory in this module goes through Search-MsecAzureResourceGraph in one request;
this one cannot.
Resource Graph indexes the VAULT and nothing inside it -
microsoft.keyvault/vaults/certificates returns no rows - so this walks the vaults with
Az.KeyVault instead.
That makes it the slowest command here, and the reason it takes
-VaultName and -Tag: on a large estate you want to narrow it.

A VAULT YOU CANNOT READ INTO IS NOT AN EMPTY VAULT, and telling them apart is the
whole point of the Unreadable row.
Listing vaults is a control-plane right (Reader);
listing the certificates inside one is a data-plane right, granted separately through
RBAC or an access policy.
Having the first without the second is the NORMAL state for
an auditor's account - so a vault that answers 403 emits a row saying so rather than
contributing nothing, which would read as "this vault holds no certificates" and quietly
shrink the inventory.

EXPIRY IS BOTH AN OUTAGE AND A SECURITY QUESTION, the same as app registration
credentials.
An expired certificate breaks whatever presents it, usually at the worst
moment; a very long-lived one is standing exposure if it leaks.
DaysUntilExpiry answers
the first and LifetimeDays the second.

NO PRIVATE KEY IS READ.
This lists metadata only - Get-AzKeyVaultCertificate returns
the public certificate and its policy, never the key material.

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
Get-MsecKeyVaultCertificate -Tag @{ Product = 'DNS' } | Sort-Object DaysUntilExpiry
```

### EXAMPLE 2
```
# The renewal list, worst first.
Get-MsecKeyVaultCertificate -ExpiringWithinDays 60 |
    Sort-Object DaysUntilExpiry |
    Format-Table VaultName, Name, Subject, EndDateTime, DaysUntilExpiry, Issuer
```

### EXAMPLE 3
```
# Vaults the running identity cannot read into - fix these before trusting the count.
Get-MsecKeyVaultCertificate | Where-Object Status -eq 'Unreadable'
```

## PARAMETERS

### -VaultName
Only these vaults, by name.
Wildcards supported.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Tag
Only vaults carrying this tag, as @{ Product = 'DNS' }.
Matched case-insensitively on
both key and value, because Azure treats tags that way and the Az cmdlets do not
always.

```yaml
Type: Hashtable
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExpiringWithinDays
Keep only certificates expiring within this many days.
ALREADY-EXPIRED ones are always
included, whatever the number: expired is strictly worse than expiring, and a window
that hid them would answer the wrong question.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeDisabled
Include certificates whose current version is disabled.
Excluded by default - a
disabled certificate is not presented to anything, so its expiry is not an outage.

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

### PSCustomObject per certificate, PSTypeName 'MsecKeyVaultCertificate'. A vault that
### could not be read emits one row with Status 'Unreadable'; an empty one, Status 'Empty'.
## NOTES
Uses your Az context, not the msec app session.
Needs Reader on the vaults plus a
data-plane grant - 'Key Vault Reader' (RBAC) or an access policy with certificate
List/Get.

SecretId is the URI the certificate's private material would be fetched from, which is
what an App Service or Application Gateway binding references.
It is a pointer, not the
secret.

## RELATED LINKS
