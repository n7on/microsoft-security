---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Connect-Msec

## SYNOPSIS
Establishes a Microsoft Security session bound to a certificate in Azure Key Vault.

## SYNTAX

```
Connect-Msec [-KeyVaultName] <String> [[-CertificateName] <String>] [[-ClientId] <String>]
 [[-TenantId] <String>] [<CommonParameters>]
```

## DESCRIPTION
Use this once per PowerShell session before calling any Get-Msec* function.
It:
  1.
Requires you to be signed into Azure (Connect-AzAccount) - that's your *own*
     identity and is what Key Vault sees for RBAC and audit.
  2.
Reads the certificate's metadata from Key Vault.
New-MsecApp stamped the cert
     with two tags - AppId and TenantId - so the caller normally only needs the
     Key Vault and certificate names.
  3.
Stores tenant + client IDs, vault name, key name, and thumbprint in a
     module-scoped session.
  4.
Acquires the Graph and Defender tokens up front - each acquisition signs a
     fresh JWT client assertion inside Key Vault via Invoke-AzKeyVaultKeyOperation.
     The private key never leaves the vault.

Identity resolution order:
  ClientId  -\>  -ClientId param   -\>  AppId tag on the cert   -\>  error
  TenantId  -\>  -TenantId param   -\>  TenantId tag on the cert -\>  Get-AzContext tenant

Required Azure RBAC for the calling user (or group):
  - 'Key Vault Certificate User' on the vault (to read cert metadata + tags).
  - 'Key Vault Crypto User'      on the vault (to sign with the key).

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
Connect-Msec -KeyVaultName 'kv-mysec'
```

## PARAMETERS

### -KeyVaultName
The Azure Key Vault containing the certificate.

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

### -CertificateName
The name of the certificate in Key Vault.
Defaults to 'msec-app' (matches the
default used by New-MsecApp).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: Msec-app
Accept pipeline input: False
Accept wildcard characters: False
```

### -ClientId
Optional override.
App registration (client) ID.
Only needed if the cert was not
tagged by New-MsecApp.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -TenantId
Optional override.
Entra ID tenant ID.
Only needed if the cert was not tagged by
New-MsecApp AND the current Az context tenant is wrong.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES

## RELATED LINKS
