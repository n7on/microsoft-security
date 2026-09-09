function Get-MsecKeyVaultCertificate {
    <#
    .SYNOPSIS
        Every certificate in the accessible Key Vaults, with how long each has left - the
        certificate expiry inventory.

    .DESCRIPTION
        One row per certificate, across every vault the Az context can see, or a subset chosen
        by name or tag.

        CERTIFICATES ARE DATA-PLANE, SO RESOURCE GRAPH CANNOT SEE THEM. Every other Azure
        inventory in this module goes through Search-MsecAzureResourceGraph in one request;
        this one cannot. Resource Graph indexes the VAULT and nothing inside it -
        microsoft.keyvault/vaults/certificates returns no rows - so this walks the vaults with
        Az.KeyVault instead. That makes it the slowest command here, and the reason it takes
        -VaultName and -Tag: on a large estate you want to narrow it.

        A VAULT YOU CANNOT READ INTO IS NOT AN EMPTY VAULT, and telling them apart is the
        whole point of the Unreadable row. Listing vaults is a control-plane right (Reader);
        listing the certificates inside one is a data-plane right, granted separately through
        RBAC or an access policy. Having the first without the second is the NORMAL state for
        an auditor's account - so a vault that answers 403 emits a row saying so rather than
        contributing nothing, which would read as "this vault holds no certificates" and quietly
        shrink the inventory.

        EXPIRY IS BOTH AN OUTAGE AND A SECURITY QUESTION, the same as app registration
        credentials. An expired certificate breaks whatever presents it, usually at the worst
        moment; a very long-lived one is standing exposure if it leaks. DaysUntilExpiry answers
        the first and LifetimeDays the second.

        NO PRIVATE KEY IS READ. This lists metadata only - Get-AzKeyVaultCertificate returns
        the public certificate and its policy, never the key material.

    .PARAMETER VaultName
        Only these vaults, by name. Wildcards supported.

    .PARAMETER Tag
        Only vaults carrying this tag, as @{ Product = 'DNS' }. Matched case-insensitively on
        both key and value, because Azure treats tags that way and the Az cmdlets do not
        always.

    .PARAMETER ExpiringWithinDays
        Keep only certificates expiring within this many days. ALREADY-EXPIRED ones are always
        included, whatever the number: expired is strictly worse than expiring, and a window
        that hid them would answer the wrong question.

    .PARAMETER IncludeDisabled
        Include certificates whose current version is disabled. Excluded by default - a
        disabled certificate is not presented to anything, so its expiry is not an outage.

    .EXAMPLE
        Connect-AzAccount
        Get-MsecKeyVaultCertificate -Tag @{ Product = 'DNS' } | Sort-Object DaysUntilExpiry

    .EXAMPLE
        # The renewal list, worst first.
        Get-MsecKeyVaultCertificate -ExpiringWithinDays 60 |
            Sort-Object DaysUntilExpiry |
            Format-Table VaultName, Name, Subject, EndDateTime, DaysUntilExpiry, Issuer

    .EXAMPLE
        # Vaults the running identity cannot read into - fix these before trusting the count.
        Get-MsecKeyVaultCertificate | Where-Object Status -eq 'Unreadable'

    .OUTPUTS
        PSCustomObject per certificate, PSTypeName 'MsecKeyVaultCertificate'. A vault that
        could not be read emits one row with Status 'Unreadable'; an empty one, Status 'Empty'.

    .NOTES
        Uses your Az context, not the msec app session. Needs Reader on the vaults plus a
        data-plane grant - 'Key Vault Reader' (RBAC) or an access policy with certificate
        List/Get.

        SecretId is the URI the certificate's private material would be fetched from, which is
        what an App Service or Application Gateway binding references. It is a pointer, not the
        secret.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]] $VaultName,

        [hashtable] $Tag,

        [ValidateRange(0, 3650)]
        [int] $ExpiringWithinDays,

        [switch] $IncludeDisabled
    )

    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        throw 'Az.KeyVault is required for Get-MsecKeyVaultCertificate. Install with: Install-Module Az.KeyVault -Scope CurrentUser'
    }
    Import-Module Az.KeyVault -ErrorAction Stop

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount, then Select-MsecAzureContext to pick the subscription to report on.'
    }

    $hasWindow = $PSBoundParameters.ContainsKey('ExpiringWithinDays')

    # One clock for the run: reading UtcNow per certificate would let a long enumeration
    # measure early vaults against a different 'now' than late ones.
    $now = [DateTime]::UtcNow

    # The API's timestamps come back as DateTime already, but not always Kind=Utc - and a
    # Local-kind value compared against a UTC clock is off by the offset, which moves
    # DaysUntilExpiry by a whole day either side of midnight.
    $toUtc = {
        param($value)
        if (-not $value) { return $null }
        if ($value -is [datetime]) {
            if ($value.Kind -eq [DateTimeKind]::Unspecified) {
                return [DateTime]::SpecifyKind($value, [DateTimeKind]::Utc)
            }
            return $value.ToUniversalTime()
        }
        [datetime]::Parse([string] $value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }

    $vaults = @(Get-AzKeyVault -ErrorAction Stop)

    if ($VaultName) {
        $vaults = @($vaults | Where-Object {
            $name = $_.VaultName
            @($VaultName | Where-Object { $name -like $_ }).Count -gt 0
        })
    }

    if ($Tag) {
        # Case-insensitive on key AND value. Azure tags are case-insensitive; the Az objects
        # expose an ordinary hashtable that is not, so a vault tagged 'product=dns' would be
        # missed by -Tag @{ Product = 'DNS' } without this.
        $vaults = @($vaults | Where-Object {
            $vaultTags = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($key in @($_.Tags.Keys)) { $vaultTags[[string] $key] = [string] $_.Tags[$key] }

            $allMatch = $true
            foreach ($key in @($Tag.Keys)) {
                $value = $null
                if (-not $vaultTags.TryGetValue([string] $key, [ref] $value)) { $allMatch = $false; break }
                if ($value -ne [string] $Tag[$key]) { $allMatch = $false; break }
            }
            $allMatch
        })
    }

    if (-not $vaults.Count) {
        Write-Warning 'No Key Vaults matched. Check -VaultName / -Tag, and that the Az context is on the right subscription.'
        return
    }

    foreach ($vault in $vaults) {
        $common = [ordered]@{
            VaultName         = $vault.VaultName
            ResourceGroupName = $vault.ResourceGroupName
            Location          = $vault.Location
            VaultUri          = $vault.VaultUri
        }

        $certificates = $null
        try {
            $certificates = @(Get-AzKeyVaultCertificate -VaultName $vault.VaultName -ErrorAction Stop)
        }
        catch {
            # See the note in .DESCRIPTION: listing vaults and reading into them are different
            # rights, and having only the first is normal. This row is what stops that reading
            # as an empty vault.
            Write-Warning "Could not list the certificates in '$($vault.VaultName)', so it is reported as Unreadable rather than empty. The running identity needs a data-plane grant - 'Key Vault Reader' (RBAC) or an access policy with certificate List/Get. $($_.Exception.Message)"

            [PSCustomObject]($common + [ordered]@{
                PSTypeName      = 'MsecKeyVaultCertificate'
                Name            = $null
                Status          = 'Unreadable'
                Enabled         = $null
                Subject         = $null
                Issuer          = $null
                Thumbprint      = $null
                NotBefore       = $null
                EndDateTime     = $null
                DaysUntilExpiry = $null
                IsExpired       = $null
                LifetimeDays    = $null
                SecretId        = $null
                Id              = $null
            })
            continue
        }

        if (-not $certificates.Count) {
            # Genuinely empty, and said so rather than silently contributing nothing - the
            # difference from Unreadable above is the whole point.
            [PSCustomObject]($common + [ordered]@{
                PSTypeName      = 'MsecKeyVaultCertificate'
                Name            = $null
                Status          = 'Empty'
                Enabled         = $null
                Subject         = $null
                Issuer          = $null
                Thumbprint      = $null
                NotBefore       = $null
                EndDateTime     = $null
                DaysUntilExpiry = $null
                IsExpired       = $null
                LifetimeDays    = $null
                SecretId        = $null
                Id              = $null
            })
            continue
        }

        foreach ($listed in $certificates) {
            # The list call returns an identifier only; the subject, issuer and thumbprint
            # need the per-certificate GET. That makes this N+1 by necessity rather than by
            # oversight - there is no bulk form in the data plane.
            $certificate = $null
            try {
                $certificate = Get-AzKeyVaultCertificate -VaultName $vault.VaultName -Name $listed.Name -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not read certificate '$($listed.Name)' from '$($vault.VaultName)': $($_.Exception.Message)"
                continue
            }
            if (-not $certificate) { continue }

            $enabled = $certificate.Enabled
            if (-not $IncludeDisabled -and $enabled -eq $false) { continue }

            $start = & $toUtc $certificate.NotBefore
            $end   = & $toUtc $certificate.Expires

            $days      = if ($end) { [int][Math]::Floor(($end - $now).TotalDays) } else { $null }
            # From the timestamps, not the floored day count: a certificate with nine hours
            # left floors to 0, and 0 must not read as expired.
            $isExpired = if ($end) { $end -lt $now } else { $null }
            $lifetime  = if ($start -and $end) { [int][Math]::Round(($end - $start).TotalDays) } else { $null }

            if ($hasWindow -and $end) {
                # Expired survives any window - see .PARAMETER ExpiringWithinDays.
                if (-not $isExpired -and $days -gt $ExpiringWithinDays) { continue }
            }

            [PSCustomObject]($common + [ordered]@{
                PSTypeName      = 'MsecKeyVaultCertificate'
                Name            = $certificate.Name
                Status          = 'Present'
                Enabled         = $enabled
                Subject         = $certificate.Certificate.Subject
                Issuer          = $certificate.Certificate.Issuer
                Thumbprint      = $certificate.Thumbprint
                NotBefore       = $start
                EndDateTime     = $end
                DaysUntilExpiry = $days
                IsExpired       = $isExpired
                LifetimeDays    = $lifetime
                # The URI a binding references - a pointer, not the secret itself.
                SecretId        = $certificate.SecretId
                Id              = $certificate.Id
            })
        }
    }
}
