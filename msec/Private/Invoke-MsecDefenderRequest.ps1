function Invoke-MsecDefenderRequest {
    <#
    .SYNOPSIS
        Calls the Microsoft Defender for Endpoint API using the session's app token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [ValidateSet('GET', 'POST')]
        [string] $Method = 'GET'
    )

    # Defender for Endpoint (securitycenter) is commercial-only. In clouds where it has no
    # endpoint (e.g. retired in Azure China), fail clearly instead of hitting a dead host.
    # Fall back to the commercial host for sessions that predate endpoint resolution.
    $base = if ($script:MsecSession.Endpoints) {
        $script:MsecSession.Endpoints.DefenderResource
    }
    else {
        'https://api.securitycenter.microsoft.com'
    }
    if (-not $base) {
        throw "Microsoft Defender for Endpoint (securitycenter) API is not available in the '$($script:MsecSession.Endpoints.EnvironmentName)' cloud - Defender functions are commercial-only."
    }

    $token = Get-MsecAccessToken -Resource $base
    $uri = "$base$Path"

    Invoke-RestMethod -Method $Method -Uri $uri -ErrorAction Stop `
        -Headers @{ Authorization = "Bearer $token" }
}
