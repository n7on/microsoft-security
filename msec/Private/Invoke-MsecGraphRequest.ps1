function Invoke-MsecGraphRequest {
    <#
    .SYNOPSIS
        Calls the Microsoft Graph REST API using the session's app token; follows @odata.nextLink.

    .DESCRIPTION
        Returns the deserialized response body. For collection endpoints, when -All is supplied
        each page's .value items are emitted to the pipeline as a single concatenated stream.
        Without -All, the raw object (with .value and possibly @odata.nextLink) is returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method = 'GET',

        [Parameter()]
        $Body,

        [Parameter()]
        [string] $ContentType = 'application/json',

        # For GET collection endpoints: follow @odata.nextLink and emit .value items across pages.
        [Parameter()]
        [switch] $All
    )

    $token = Get-MsecAccessToken -Resource 'https://graph.microsoft.com'
    $headers = @{ Authorization = "Bearer $token" }

    $base = 'https://graph.microsoft.com'
    $uri  = if ($Path -like 'https://*') { $Path } else { $base + $Path }

    $invokeParams = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $invokeParams['ContentType'] = $ContentType
        $invokeParams['Body'] = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 20) }
    }

    if (-not $All) {
        return Invoke-RestMethod @invokeParams
    }

    # Paged collection: yield each page's .value items, follow @odata.nextLink.
    do {
        $response = Invoke-RestMethod @invokeParams
        if ($null -ne $response.value) { $response.value }
        $next = $response.'@odata.nextLink'
        if ($next) { $invokeParams['Uri'] = $next; $invokeParams.Remove('Body') | Out-Null }
    } while ($next)
}
