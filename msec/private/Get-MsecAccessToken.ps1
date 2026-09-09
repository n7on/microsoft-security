function Get-MsecAccessToken {
    <#
    .SYNOPSIS
        Returns a cached or freshly acquired bearer token for the given Entra resource.

    .DESCRIPTION
        Looks up $script:MsecSession.Tokens[$Resource]; if present and not within 60s of expiry,
        returns it. Otherwise builds a JWT client assertion signed by Key Vault (the private
        key never leaves the vault) and exchanges it at the v2.0 /token endpoint for the
        resource's /.default scope.
    #>
    [CmdletBinding()]
    param(
        # The API resource, e.g. 'https://graph.microsoft.com' or 'https://api.securitycenter.microsoft.com'.
        [Parameter(Mandatory)]
        [string] $Resource
    )

    Assert-MsecSession
    $session = $script:MsecSession

    $cached = $session.Tokens[$Resource]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddSeconds(60)) {
        return $cached.Token
    }

    # AAD login authority for the session's cloud. Falls back to commercial when the
    # session predates endpoint resolution (older Connect-Msec, or unit-test sessions).
    $authority = if ($session.Endpoints -and $session.Endpoints.AadAuthority) {
        $session.Endpoints.AadAuthority
    }
    else {
        'https://login.microsoftonline.com'
    }

    Write-Verbose "Acquiring access token for $Resource via $authority"
    $assertion = New-MsecClientAssertion `
        -TenantId        $session.TenantId `
        -ClientId        $session.ClientId `
        -VaultName       $session.KeyVaultName `
        -KeyName         $session.KeyName `
        -ThumbprintBytes $session.ThumbprintBytes `
        -Authority       $authority

    $response = Invoke-RestMethod -Method Post -ErrorAction Stop `
        -Uri "$authority/$($session.TenantId)/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            client_id             = $session.ClientId
            scope                 = "$Resource/.default"
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $assertion
            grant_type            = 'client_credentials'
        }

    $session.Tokens[$Resource] = @{
        Token     = $response.access_token
        ExpiresOn = [DateTimeOffset]::UtcNow.AddSeconds([int]$response.expires_in)
    }

    $response.access_token
}
