---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecGraphSdk

## SYNOPSIS
Signs the Microsoft.Graph PowerShell SDK in using the msec session's token, so
Get-Mg* commands run as the msec app without its private key ever leaving Key Vault.

## SYNTAX

```
Connect-MsecGraphSdk [[-MinimumMinutes] <Int32>] [-PassThru]
 [<CommonParameters>]
```

## DESCRIPTION
Hands Connect-MgGraph the access token Connect-MsecServiceSession already holds.
That
is the only handoff that preserves msec's central property: the certificate's private
key stays in Key Vault and signing happens there.

THE USUAL CERTIFICATE ROUTE CANNOT WORK HERE, and that is the point.
Connect-MgGraph -ClientId -TenantId -CertificateThumbprint needs the private key
present on the machine.
Anything that ships a PFX or a base64 certificate to a build
agent is putting the key somewhere it can be copied; this command exists so that is
never necessary.

THE TOKEN IS NOT REFRESHED.
Connect-MgGraph is given a static token, so the SDK cannot
renew it - unlike msec's own commands, which re-acquire as needed.
Tokens last about
an hour.
A script that runs longer must call this again; -MinimumMinutes is how a
long report asserts it has enough time before it starts rather than failing in the
middle.

APP-ONLY, NEVER DELEGATED.
There is no signed-in user, so anything /me-shaped fails by
design - Get-MgContext reports AppOnly.
And the SDK can only do what the app was
consented for: msec's roles are all *.Read.All, so every New-Mg*, Update-Mg* and
Remove-Mg* answers 403.
That is a guarantee rather than a limitation.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Connect-MsecGraphSdk
Get-MgUser -Top 5
```

### EXAMPLE 2
```
# A report that will run for half an hour, refusing to start without the headroom.
Connect-MsecGraphSdk -MinimumMinutes 30
Get-MgGroup -All | ForEach-Object { ... }
```

## PARAMETERS

### -MinimumMinutes
Fail unless the token has at least this long left.
Default 5.
A long-running report
should ask for the time it needs - a token with four minutes on it will connect
happily and then start failing partway through the run, which is far harder to
diagnose than a refusal up front.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 5
Accept pipeline input: False
Accept wildcard characters: False
```

### -PassThru
Emit the resulting Graph context.

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

### With -PassThru, the Microsoft.Graph authentication context.
## NOTES
Needs Connect-Msec first, and the Microsoft.Graph.Authentication module - which is NOT
a dependency of msec.
It is imported only when this command is called, so the module
installs and runs normally on a machine that has never heard of the Graph SDK.

The cloud is taken from the msec session, not assumed.
The SDK's environment names
differ from Azure's (China, not AzureChinaCloud), so they are matched on the Graph
endpoint itself rather than by name.

## RELATED LINKS
