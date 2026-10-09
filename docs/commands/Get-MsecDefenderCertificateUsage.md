---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderCertificateUsage

## SYNOPSIS
Code-signing certificates actually in use on the fleet, with their validity window, how
many devices carry files signed by each, and how long each has left.

## SYNTAX

```
Get-MsecDefenderCertificateUsage [[-Signer] <String>] [[-Issuer] <String>] [[-ExpiringWithinDays] <Int32>]
 [-TrustedOnly] [[-Days] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
Reads DeviceFileCertificateInfo through advanced hunting and groups it by signing
certificate rather than by file, so the question becomes "whose code are we running, and
on what trust" instead of "what is this binary".

SIGNERHASH IS THE WINDOWS THUMBPRINT, AND IS THE JOIN TO DEFENDER INDICATORS.
The SHA-1
over the certificate's DER bytes is what Windows calls the thumbprint, what Defender
reports as SignerHash, and what New-MsecDefenderIndicator takes as -Value for a
CertificateThumbprint indicator.
Verified both ways on one tenant: the value Defender
reported and the SHA-1 computed from the vendor's own installer were identical.
That
equality is the reason this command is useful rather than merely interesting - the
thumbprint needed to allow or block a publisher is in the output, so nothing has to be
downloaded, unpacked, or extracted from a binary.

A CERTIFICATE EXPIRY IS A ROTATION, AND A ROTATION BREAKS INDICATORS.
Only LEAF
certificates can be used in a Defender indicator; parents and children are not included.
So when a publisher renews, everything they sign afterwards carries a new thumbprint that
existing indicators do not match - while the old indicator keeps working for everything
already signed, because timestamped Authenticode signatures stay valid past expiry.
The
gap is therefore silent and one-directional: old files keep working, new ones stop.
DaysUntilExpiry is how far away that is, and it is why this command sorts by it.

TRUST IS REPORTED, NOT FILTERED ON.
An untrusted or self-signed certificate running on
managed devices is a finding, not noise to be hidden, so IsTrusted is a column and
everything is returned by default.
-TrustedOnly is there for when you are specifically
building an allowlist and want to be sure you are not about to allow something the
platform already distrusts.

THE WINDOW IS THE HUNTING WINDOW, WHICH IS NOT THE SAME AS "IN USE".
Advanced hunting
retains 30 days and measured as little as 7 on one tenant.
A certificate absent from
this output has not been seen signing a file that ran recently; it has not necessarily
been retired.
The window actually returned is reported on the verbose stream.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderCertificateUsage -Signer anthropic
```

Every Anthropic signing certificate seen on the fleet.
SignerHash is the value to hand
to New-MsecDefenderIndicator.

### EXAMPLE 2
```
Get-MsecDefenderCertificateUsage -ExpiringWithinDays 60 |
    Sort-Object DaysUntilExpiry |
    Format-Table Signer, DaysUntilExpiry, Devices, SignerHash
```

Publishers about to rotate.
Any certificate here that an indicator depends on needs a
replacement indicator when the new one appears.

### EXAMPLE 3
```
Get-MsecDefenderCertificateUsage | Where-Object { -not $_.IsTrusted }
```

Untrusted or self-signed code running on managed devices.

### EXAMPLE 4
```
# The rotation check, run daily against a list of thumbprints already approved.
$approved = Get-Content ./approved-thumbprints.txt
Get-MsecDefenderCertificateUsage -Signer anthropic |
    Where-Object { $_.SignerHash -notin $approved }
```

Rows mean a new signing certificate has landed and an indicator needs adding.
Keeping
the approved list in version control makes it the exception register as well as the
comparison set.

## PARAMETERS

### -Signer
Substring match on the signing subject, case-insensitive.
'anthropic', 'microsoft'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Issuer
Substring match on the issuing CA.
Useful for separating platform signing identities
from Authenticode ones - an Apple 'Developer ID Certification Authority' certificate is
not usable in a Defender indicator, which is Windows-only.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExpiringWithinDays
Only certificates expiring within this many days.
The rotation warning.

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

### -TrustedOnly
Only certificates the platform reports as trusted.

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

### -Days
Hunting window to search.
Default 30, which is the retention ceiling - asking for more
cannot find more.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per certificate, PSTypeName 'MsecDefenderCertificateUsage'.
## NOTES
Needs 'ThreatHunting.Read.All', which New-MsecApp already grants - this runs as the app.

## RELATED LINKS
