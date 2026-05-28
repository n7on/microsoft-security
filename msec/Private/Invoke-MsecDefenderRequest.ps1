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

    $token = Get-MsecAccessToken -Resource 'https://api.securitycenter.microsoft.com'
    $uri = "https://api.securitycenter.microsoft.com$Path"

    Invoke-RestMethod -Method $Method -Uri $uri -ErrorAction Stop `
        -Headers @{ Authorization = "Bearer $token" }
}
