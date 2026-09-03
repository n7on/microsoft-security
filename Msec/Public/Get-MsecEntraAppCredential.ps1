function Get-MsecEntraAppCredential {
    <#
    .SYNOPSIS
        Every client secret and certificate on the tenant's app registrations, with how
        long each has left - the credential expiry inventory.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/applications and projects ONE ROW PER CREDENTIAL. An
        app registration with two secrets and a certificate is three rows, because the
        credential is the thing that expires and the thing you have to rotate - rolling
        them up per app would hide the one that lapses on Friday behind the two that are
        good for a year.

        THIS IS BOTH A SECURITY AND AN AVAILABILITY QUESTION. An expired credential is an
        outage: the app stops authenticating, usually at 3am, usually on the integration
        nobody remembers owning. A long-lived one is the security half - a secret minted
        with a two-year lifetime is two years of standing access if it ever leaks, so
        LifetimeDays is carried alongside the expiry rather than only the end date.

        APP REGISTRATIONS ARE INVENTORIED COMPLETELY, INCLUDING THE ONES WITH NO
        CREDENTIALS. Those get a single row with CredentialType 'None' and null dates.
        That is deliberate: an app with no secret at all is usually the GOOD state - it
        has moved to federated credentials (workload identity) or is a pure public client -
        and a report that silently omitted it could not tell you that, nor tell "no
        credentials" apart from "app not returned".

        SERVICE PRINCIPALS ARE NOT INVENTORIED THAT WAY, and are opt-in via
        -IncludeServicePrincipal. A tenant carries hundreds of Microsoft-owned service
        principals holding no credentials whatever, so listing them all would bury the
        rows that matter. Only service principals that actually HOLD a credential are
        returned. They are worth asking for: a SAML app's token-signing certificate lives
        here rather than on the app registration, and its expiry is a sign-in outage for
        every user of that app.

        Requires the 'Application.Read.All' application permission. A clearer error is
        raised on the typical 403.

        Secret VALUES are never returned by Graph - only the metadata. Nothing here can
        leak a usable credential.

    .PARAMETER ExpiringWithinDays
        Keep only credentials that expire within this many days. ALREADY-EXPIRED
        credentials are always included, whatever the number: expired is strictly worse
        than expiring, and a window that hid them would be answering the wrong question.

        Apps with no credentials drop out under this filter - they have no expiry to fall
        inside a window. Omit the parameter for the full inventory.

    .PARAMETER IncludeServicePrincipal
        Also return credentials held on service principals - SAML token-signing
        certificates in particular. Only service principals holding at least one
        credential are returned; see .DESCRIPTION.

    .EXAMPLE
        # The rotation list: what is already dead, worst first.
        Get-MsecEntraAppCredential | Where-Object IsExpired | Sort-Object DaysUntilExpiry

    .EXAMPLE
        # The next 60 days, expired ones included.
        Get-MsecEntraAppCredential -ExpiringWithinDays 60 | Sort-Object DaysUntilExpiry |
            Format-Table DisplayName, CredentialType, CredentialName, EndDateTime, DaysUntilExpiry

    .EXAMPLE
        # The security half rather than the outage half: secrets minted to last for years.
        Get-MsecEntraAppCredential |
            Where-Object { $_.CredentialType -eq 'Secret' -and $_.LifetimeDays -gt 365 } |
            Sort-Object LifetimeDays -Descending

    .EXAMPLE
        # SAML sign-in outages waiting to happen.
        Get-MsecEntraAppCredential -IncludeServicePrincipal |
            Where-Object { $_.ObjectType -eq 'ServicePrincipal' -and $_.CredentialUsage -eq 'Sign' } |
            Sort-Object DaysUntilExpiry

    .EXAMPLE
        # Apps that need no rotating at all, because they hold no secret.
        Get-MsecEntraAppCredential | Where-Object CredentialType -eq 'None'

    .OUTPUTS
        PSCustomObject per credential, PSTypeName 'MsecEntraAppCredential'. See .NOTES
        for the projection.

    .NOTES
        Needs Connect-Msec and the 'Application.Read.All' application permission, which
        New-MsecApp already grants.

        Projection (Graph field path -> output property):
          displayName                       -> DisplayName
          appId                             -> AppId
          id                                -> ObjectId
          <which collection it came from>   -> ObjectType      ('Application' / 'ServicePrincipal')
          <which array it came from>        -> CredentialType  ('Secret' / 'Certificate' / 'None')
          *Credentials[].displayName        -> CredentialName
          *Credentials[].keyId              -> KeyId
          keyCredentials[].usage            -> CredentialUsage ('Verify' / 'Sign'; null for secrets)
          *Credentials[].startDateTime      -> StartDateTime
          *Credentials[].endDateTime        -> EndDateTime
          <derived>                         -> DaysUntilExpiry, IsExpired, LifetimeDays
          signInAudience                    -> SignInAudience  (null on service principals)
          createdDateTime                   -> CreatedDateTime
          <entire app / SP object verbatim> -> Raw

        DaysUntilExpiry FLOORS, so a credential that lapsed two hours ago reads -1 rather
        than 0. IsExpired is the exact test and is computed from the timestamps, not from
        the rounded number - so DaysUntilExpiry 0 means "expires later today", not
        "expired".

        Raw is the whole application or servicePrincipal object, not the credential - the
        credential is a member of its passwordCredentials / keyCredentials array, findable
        by KeyId. Keeping the app means the row can still reach requiredResourceAccess
        (what the app is allowed to do), which is what decides whether a leaked secret
        would matter.

        OWNERS ARE NOT RESOLVED. "Who do I chase about this" is the field you most want,
        and Graph only answers it per app - one extra call each, so a tenant with several
        hundred registrations would pay several hundred round trips for it. Look the
        handful you actually care about up by ObjectId instead.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(0, 3650)]
        [int] $ExpiringWithinDays,

        [switch] $IncludeServicePrincipal
    )

    Assert-MsecSession

    # One clock for the whole run. Reading UtcNow per credential would let a long
    # enumeration produce rows measured against slightly different "now"s, which is
    # exactly the kind of drift that makes two runs disagree for no reason.
    $now = [DateTime]::UtcNow
    $hasWindow = $PSBoundParameters.ContainsKey('ExpiringWithinDays')

    # EVERY TIMESTAMP IS FORCED TO UTC BEFORE IT IS COMPARED. A plain [datetime] cast of
    # Graph's '2026-09-01T08:00:00Z' returns Kind=Local - the right instant, expressed in
    # local wall-clock - and comparing that against [DateTime]::UtcNow, which is a naive
    # UTC number, silently shifts every result by the local offset. In Stockholm that is
    # one or two hours: enough to report a credential that lapsed at 23:30 as still valid,
    # and enough to move DaysUntilExpiry by a whole day either side of midnight.
    #
    # AssumeUniversal covers the case where Graph omits the trailing Z, which would
    # otherwise be read as local and shifted the other way.
    $toUtc = {
        param($value)
        if (-not $value) { return $null }
        if ($value -is [datetime]) { return $value.ToUniversalTime() }
        [datetime]::Parse([string] $value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }

    $get = {
        param($Path, $Endpoint, $Permission)
        try {
            @(Invoke-MsecGraphRequest -Path $Path -All)
        }
        catch {
            $detail = $_.Exception.Message
            if ($detail -match '403|Forbidden|Authorization_RequestDenied') {
                throw "Forbidden when calling $Endpoint. The msec app needs the '$Permission' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $detail"
            }
            throw
        }
    }

    $select = 'id,appId,displayName,createdDateTime,signInAudience,passwordCredentials,keyCredentials'
    $applications = & $get "/v1.0/applications?`$select=$select" '/applications' 'Application.Read.All'

    $servicePrincipals = @()
    if ($IncludeServicePrincipal) {
        # No signInAudience on a service principal - it is a property of the registration,
        # not of the tenant-local object - so it is left out of the $select rather than
        # asked for and silently returned null.
        $spSelect = 'id,appId,displayName,createdDateTime,passwordCredentials,keyCredentials'
        $servicePrincipals = & $get "/v1.0/servicePrincipals?`$select=$spSelect" '/servicePrincipals' 'Application.Read.All'
    }

    $emit = {
        param($Object, $ObjectType)

        $secrets      = @($Object.passwordCredentials | Where-Object { $_ })
        $certificates = @($Object.keyCredentials      | Where-Object { $_ })

        $credentials = @(
            foreach ($c in $secrets)      { [pscustomobject]@{ Type = 'Secret';      Cred = $c } }
            foreach ($c in $certificates) { [pscustomobject]@{ Type = 'Certificate'; Cred = $c } }
        )

        # An app registration with nothing on it is still a fact worth reporting - usually
        # a good one. A service principal with nothing on it is one of the hundreds
        # Microsoft owns, and reporting those would bury everything else.
        if (-not $credentials.Count) {
            if ($ObjectType -ne 'Application') { return }

            [PSCustomObject]@{
                PSTypeName      = 'MsecEntraAppCredential'
                DisplayName     = $Object.displayName
                AppId           = $Object.appId
                ObjectId        = $Object.id
                ObjectType      = $ObjectType
                CredentialType  = 'None'
                CredentialName  = $null
                KeyId           = $null
                CredentialUsage = $null
                StartDateTime   = $null
                EndDateTime     = $null
                DaysUntilExpiry = $null
                IsExpired       = $null
                LifetimeDays    = $null
                SignInAudience  = $Object.signInAudience
                CreatedDateTime = & $toUtc $Object.createdDateTime
                Raw             = $Object
            }
            return
        }

        foreach ($entry in $credentials) {
            $c = $entry.Cred

            $start = & $toUtc $c.startDateTime
            $end   = & $toUtc $c.endDateTime

            # IsExpired from the timestamps, not from the floored day count - otherwise a
            # credential with nine hours left (DaysUntilExpiry 0) would read as expired.
            $days      = if ($end) { [int][Math]::Floor(($end - $now).TotalDays) } else { $null }
            $isExpired = if ($end) { $end -lt $now } else { $null }
            $lifetime  = if ($start -and $end) { [int][Math]::Round(($end - $start).TotalDays) } else { $null }

            [PSCustomObject]@{
                PSTypeName      = 'MsecEntraAppCredential'
                DisplayName     = $Object.displayName
                AppId           = $Object.appId
                ObjectId        = $Object.id
                ObjectType      = $ObjectType
                CredentialType  = $entry.Type
                CredentialName  = $c.displayName
                KeyId           = $c.keyId
                # Only certificates carry a usage - 'Sign' is a SAML token-signing cert,
                # 'Verify' is one used to authenticate as the app.
                CredentialUsage = if ($entry.Type -eq 'Certificate') { $c.usage } else { $null }
                StartDateTime   = $start
                EndDateTime     = $end
                DaysUntilExpiry = $days
                IsExpired       = $isExpired
                LifetimeDays    = $lifetime
                SignInAudience  = $Object.signInAudience
                CreatedDateTime = & $toUtc $Object.createdDateTime
                Raw             = $Object
            }
        }
    }

    $rows = @(
        foreach ($a in $applications)      { & $emit $a 'Application' }
        foreach ($s in $servicePrincipals) { & $emit $s 'ServicePrincipal' }
    )

    if ($hasWindow) {
        # Expired ones survive any window. A credential that lapsed last month is not less
        # urgent than one lapsing next week, so a filter that dropped it would be reporting
        # the opposite of the truth.
        $rows = @($rows | Where-Object {
            $null -ne $_.DaysUntilExpiry -and ($_.IsExpired -or $_.DaysUntilExpiry -le $ExpiringWithinDays)
        })
    }

    $rows
}
