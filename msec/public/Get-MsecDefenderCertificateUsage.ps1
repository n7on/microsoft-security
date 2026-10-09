function Get-MsecDefenderCertificateUsage {
    <#
    .SYNOPSIS
        Code-signing certificates actually in use on the fleet, with their validity window, how
        many devices carry files signed by each, and how long each has left.

    .DESCRIPTION
        Reads DeviceFileCertificateInfo through advanced hunting and groups it by signing
        certificate rather than by file, so the question becomes "whose code are we running, and
        on what trust" instead of "what is this binary".

        SIGNERHASH IS THE WINDOWS THUMBPRINT, AND IS THE JOIN TO DEFENDER INDICATORS. The SHA-1
        over the certificate's DER bytes is what Windows calls the thumbprint, what Defender
        reports as SignerHash, and what New-MsecDefenderIndicator takes as -Value for a
        CertificateThumbprint indicator. Verified both ways on one tenant: the value Defender
        reported and the SHA-1 computed from the vendor's own installer were identical. That
        equality is the reason this command is useful rather than merely interesting - the
        thumbprint needed to allow or block a publisher is in the output, so nothing has to be
        downloaded, unpacked, or extracted from a binary.

        A CERTIFICATE EXPIRY IS A ROTATION, AND A ROTATION BREAKS INDICATORS. Only LEAF
        certificates can be used in a Defender indicator; parents and children are not included.
        So when a publisher renews, everything they sign afterwards carries a new thumbprint that
        existing indicators do not match - while the old indicator keeps working for everything
        already signed, because timestamped Authenticode signatures stay valid past expiry. The
        gap is therefore silent and one-directional: old files keep working, new ones stop.
        DaysUntilExpiry is how far away that is, and it is why this command sorts by it.

        TRUST IS REPORTED, NOT FILTERED ON. An untrusted or self-signed certificate running on
        managed devices is a finding, not noise to be hidden, so IsTrusted is a column and
        everything is returned by default. -TrustedOnly is there for when you are specifically
        building an allowlist and want to be sure you are not about to allow something the
        platform already distrusts.

        THE WINDOW IS THE HUNTING WINDOW, WHICH IS NOT THE SAME AS "IN USE". Advanced hunting
        retains 30 days and measured as little as 7 on one tenant. A certificate absent from
        this output has not been seen signing a file that ran recently; it has not necessarily
        been retired. The window actually returned is reported on the verbose stream.

    .PARAMETER Signer
        Substring match on the signing subject, case-insensitive. 'anthropic', 'microsoft'.

    .PARAMETER Issuer
        Substring match on the issuing CA. Useful for separating platform signing identities
        from Authenticode ones - an Apple 'Developer ID Certification Authority' certificate is
        not usable in a Defender indicator, which is Windows-only.

    .PARAMETER ExpiringWithinDays
        Only certificates expiring within this many days. The rotation warning.

    .PARAMETER TrustedOnly
        Only certificates the platform reports as trusted.

    .PARAMETER Days
        Hunting window to search. Default 30, which is the retention ceiling - asking for more
        cannot find more.

    .EXAMPLE
        Get-MsecDefenderCertificateUsage -Signer anthropic

        Every Anthropic signing certificate seen on the fleet. SignerHash is the value to hand
        to New-MsecDefenderIndicator.

    .EXAMPLE
        Get-MsecDefenderCertificateUsage -ExpiringWithinDays 60 |
            Sort-Object DaysUntilExpiry |
            Format-Table Signer, DaysUntilExpiry, Devices, SignerHash

        Publishers about to rotate. Any certificate here that an indicator depends on needs a
        replacement indicator when the new one appears.

    .EXAMPLE
        Get-MsecDefenderCertificateUsage | Where-Object { -not $_.IsTrusted }

        Untrusted or self-signed code running on managed devices.

    .EXAMPLE
        # The rotation check, run daily against a list of thumbprints already approved.
        $approved = Get-Content ./approved-thumbprints.txt
        Get-MsecDefenderCertificateUsage -Signer anthropic |
            Where-Object { $_.SignerHash -notin $approved }

        Rows mean a new signing certificate has landed and an indicator needs adding. Keeping
        the approved list in version control makes it the exception register as well as the
        comparison set.

    .OUTPUTS
        PSCustomObject per certificate, PSTypeName 'MsecDefenderCertificateUsage'.

    .NOTES
        Needs 'ThreatHunting.Read.All', which New-MsecApp already grants - this runs as the app.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Signer,

        [string] $Issuer,

        [int] $ExpiringWithinDays,

        [switch] $TrustedOnly,

        [ValidateRange(1, 30)]
        [int] $Days = 30
    )

    Assert-MsecSession

    $query = @"
DeviceFileCertificateInfo
| where Timestamp > ago(${Days}d)
| where isnotempty(Signer)
| summarize Files = dcount(SHA1), Devices = dcount(DeviceId),
            FirstSeen = min(Timestamp), LastSeen = max(Timestamp),
            IsTrusted = max(todouble(IsTrusted)),
            IsRootSignerMicrosoft = max(todouble(IsRootSignerMicrosoft))
          by Signer, Issuer, SignerHash, IssuerHash, CertificateSerialNumber,
             CertificateCreationTime, CertificateExpirationTime
| order by Devices desc
"@

    $rows = @(Search-MsecDefenderHunting -Query $query)
    if (-not $rows.Count) {
        Write-Warning "No certificate records returned for the last $Days day(s). DeviceFileCertificateInfo is populated by file events, so an empty result can also mean advanced hunting holds less history than was asked for - it is NOT evidence that nothing is signed."
        return
    }

    $seen = @($rows | ForEach-Object { if ($_.FirstSeen) { [datetime] $_.FirstSeen } }) | Sort-Object
    if ($seen.Count) {
        Write-Verbose "Asked for $Days day(s); $($rows.Count) certificate(s) across a window starting $($seen[0].ToString('u'))."
    }

    $now = (Get-Date).ToUniversalTime()

    foreach ($r in $rows) {
        if ($Signer -and "$($r.Signer)" -notmatch [regex]::Escape($Signer)) { continue }
        if ($Issuer -and "$($r.Issuer)" -notmatch [regex]::Escape($Issuer)) { continue }

        # Defender returns these as sbyte 0/1 through the OData surface, and max() above makes
        # them doubles. Compared against 1 rather than cast to [bool], because [bool] on the
        # STRING "0" is $true - the same trap as Secure Score's 'on' field being the text
        # "false", which reported every control as enabled until it was caught.
        $trusted = ($null -ne $r.IsTrusted) -and ([double] $r.IsTrusted -eq 1)
        if ($TrustedOnly -and -not $trusted) { continue }

        $validTo = if ($r.CertificateExpirationTime) { [datetime] $r.CertificateExpirationTime } else { $null }
        # $null, never a large number, when the certificate carries no expiry in the record.
        # A missing expiry sorted alongside real ones would put "unknown" at the safe end.
        $daysLeft = if ($validTo) { [math]::Round(($validTo.ToUniversalTime() - $now).TotalDays, 1) } else { $null }

        if ($PSBoundParameters.ContainsKey('ExpiringWithinDays')) {
            if ($null -eq $daysLeft -or $daysLeft -gt $ExpiringWithinDays) { continue }
        }

        [PSCustomObject]@{
            PSTypeName            = 'MsecDefenderCertificateUsage'
            Signer                = [string] $r.Signer
            Issuer                = [string] $r.Issuer
            # The Windows thumbprint. Hand this straight to New-MsecDefenderIndicator.
            SignerHash            = [string] $r.SignerHash
            IssuerHash            = [string] $r.IssuerHash
            SerialNumber          = [string] $r.CertificateSerialNumber
            ValidFrom             = if ($r.CertificateCreationTime) { [datetime] $r.CertificateCreationTime } else { $null }
            ValidTo               = $validTo
            DaysUntilExpiry       = $daysLeft
            Expired               = if ($null -eq $daysLeft) { $null } else { $daysLeft -lt 0 }
            Devices               = [int] $r.Devices
            Files                 = [int] $r.Files
            IsTrusted             = $trusted
            IsRootSignerMicrosoft = ($null -ne $r.IsRootSignerMicrosoft) -and ([double] $r.IsRootSignerMicrosoft -eq 1)
            FirstSeen             = if ($r.FirstSeen) { [datetime] $r.FirstSeen } else { $null }
            LastSeen              = if ($r.LastSeen) { [datetime] $r.LastSeen } else { $null }
            Raw                   = $r
        }
    }
}
