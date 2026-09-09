function Invoke-MsecDefenderRequest {
    <#
    .SYNOPSIS
        Calls the Microsoft Defender for Endpoint API using the session's app token;
        follows @odata.nextLink when -All is supplied.

    .DESCRIPTION
        Returns the deserialized response body. For collection endpoints, -All emits each
        page's .value items to the pipeline as one concatenated stream. Without -All the raw
        object is returned, which is what the single-value endpoints (/api/exposureScore,
        /api/configurationScore) want.

        Paging is not optional for the endpoints that matter here. /api/machines returns a
        page at a time, and the vulnerability assessment export is one row per device and
        software finding - tens of thousands of rows on a mid-sized estate. Reading only the
        first page would silently under-report, which on a vulnerability report is the worst
        possible failure: it looks like a clean answer.

    .PARAMETER Path
        Path below the Defender API host, e.g. '/api/machines'.

    .PARAMETER Method
        GET or POST. Defaults to GET.

    .PARAMETER All
        For GET collection endpoints: follow @odata.nextLink and emit .value items across
        every page.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [ValidateSet('GET', 'POST')]
        [string] $Method = 'GET',

        [Parameter()]
        [switch] $All
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

    $invokeParams = @{
        Method      = $Method
        Uri         = "$base$Path"
        Headers     = @{ Authorization = "Bearer $token" }
        ErrorAction = 'Stop'
    }

    if (-not $All) {
        return Invoke-RestMethod @invokeParams
    }

    # Paged collection: yield each page's .value items, follow @odata.nextLink.
    #
    # Progress is reported from the SECOND page onwards. The vulnerability export runs to
    # many pages on a real estate, and a caller blocked in here otherwise leaves whatever
    # status it set before the call frozen on screen, which reads as a hang. Suppressed for
    # single-page responses so ordinary calls stay silent, and given its own progress id so
    # it does not overwrite a caller's own bar.
    $progressId = 1731
    $page = 0
    $items = 0

    do {
        $response = Invoke-RestMethod @invokeParams
        $page++

        if ($null -ne $response.value) {
            $batch = @($response.value)
            $items += $batch.Count
            $batch
        }

        $next = $response.'@odata.nextLink'
        if ($next) {
            $invokeParams['Uri'] = $next
            # No total is available, so this is a live tally rather than a percentage. An
            # honest "still working, here is how much" beats a fabricated completion figure.
            Write-Progress -Id $progressId -Activity 'Paging Microsoft Defender for Endpoint' `
                -Status "$Path - $items item(s) after $page page(s)"
        }
    } while ($next)

    if ($page -gt 1) {
        Write-Progress -Id $progressId -Activity 'Paging Microsoft Defender for Endpoint' -Completed
    }
}
