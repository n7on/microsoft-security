---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# New-MsecDefenderIndicator

## SYNOPSIS
Creates a Defender for Endpoint indicator - allow, block or audit a certificate, file
hash, IP, domain or URL.
Runs as YOU, not as the msec app.

## SYNTAX

```
New-MsecDefenderIndicator [-Type] <String> [-Value] <String> [-Action] <String> [-Title] <String>
 [-Description] <String> [[-Severity] <String>] [[-ExpirationTime] <DateTime>] [[-DeviceGroup] <String[]>]
 [-GenerateAlert] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
RUNS AS THE SIGNED-IN USER, DELIBERATELY AND UNAVOIDABLY.
The indicator API has no
read-only permission: listing indicators requires Ti.ReadWrite, the same scope that
creates and deletes them.
Granting that to the msec app would mean a certificate in Key
Vault could allow-list arbitrary files and publishers across every onboarded device -
which is the ability to turn blocking off for malware of someone's choosing.
So this
takes a delegated token from your Az context instead, the same way Get-MsecSentinelRule
reads ARM, and the app keeps its read-only property.

AN ALLOW INDICATOR IS A HOLE IN EVERY CONTROL THAT HONOURS IT, NOT JUST THE ONE YOU HAD
IN MIND.
'Allowed' on a certificate exempts everything that certificate signs - now and
in future - from Microsoft Defender Antivirus and from every attack surface reduction
rule that honours certificate indicators, not only the rule that prompted it.
That is
usually the point, and it is still worth writing down: -Description is passed straight
through to the indicator and is the only place the reason survives.

CERTIFICATE INDICATORS MATCH LEAF CERTIFICATES ONLY.
Parents and children are not
included, so an indicator on a publisher's current signing certificate stops covering
anything they sign after they renew - while continuing to cover everything already
signed, because timestamped Authenticode signatures outlive the certificate.
The failure
is therefore silent and only affects new files.
Get-MsecDefenderCertificateUsage
-ExpiringWithinDays is how that is seen coming.

THE THUMBPRINT IS WHAT THE API WANTS, NOT A FILE.
The Defender portal's wizard asks for
a .CER upload and derives the thumbprint from it; the API takes the thumbprint directly.
Get-MsecDefenderCertificateUsage reports it as SignerHash, so the whole loop - notice a
new signing certificate, allow it - needs nothing downloaded or extracted.

IT REFUSES TO CREATE A DUPLICATE.
An identical type-and-value pair already present is
reported and left alone rather than added again, because the API accepts duplicates
happily and a second indicator for the same certificate is indistinguishable from the
first until somebody tries to remove one.

CONFIRMIMPACT IS HIGH.
This changes enforcement for every onboarded device in scope, so
a bare call prompts, and -WhatIf describes exactly what would be created.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderCertificateUsage -Signer anthropic -Issuer DigiCert |
    ForEach-Object {
        New-MsecDefenderIndicator -Type CertificateThumbprint -Value $_.SignerHash `
            -Action Allowed -Title "Anthropic code signing" `
            -Description "Claude is deployed on 95 devices across 8 install paths; ASR rules scid_2510 and scid_2517 block it. Work item 106897." -WhatIf
    }
```

The rotation loop, as a dry run.
Drop -WhatIf to create it.

### EXAMPLE 2
```
New-MsecDefenderIndicator -Type CertificateThumbprint `
    -Value 0d7581d2c51c59df686c3000c70bf543f9f6c6cb -Action Allowed `
    -Title 'Anthropic, PBC code signing' `
    -Description 'Allows Claude Desktop and Claude Code past ASR. Reviewed annually; see 106897.'
```

## PARAMETERS

### -Type
Indicator type.
'CertificateThumbprint' takes a SHA-1 thumbprint as -Value.

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

### -Value
The indicator value - thumbprint, hash, IP, domain or URL.
For CertificateThumbprint
this is 40 hexadecimal characters and is validated before anything is sent, because the
API accepts a malformed thumbprint without complaint and the indicator then silently
matches nothing.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Action
What Defender does on a match.
'Allowed' exempts; 'Block' and 'BlockAndRemediate'
enforce; 'Audit' records without acting.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Title
Short name, required by the API.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Description
Why this indicator exists.
Required here although the API treats it as optional - an
allow indicator with no recorded reason is indistinguishable from a mistake six months
later, and this is the only field that travels with it.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Severity
Informational, Low, Medium or High.
Defaults to Informational.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: Informational
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExpirationTime
When the indicator stops applying.
Omit for no expiry.

```yaml
Type: DateTime
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DeviceGroup
RBAC device group names to scope it to.
Omit to apply to every device.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -GenerateAlert
Raise an alert on match.
Meaningless for 'Allowed'.

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

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

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

### PSCustomObject describing the created indicator, PSTypeName 'MsecDefenderIndicator'.
## NOTES
Needs Connect-AzAccount and the Ti.ReadWrite permission on YOUR account - Security
Administrator or equivalent.
The msec app cannot do this and is not asked to.

## RELATED LINKS
