function Invoke-MsecGraphRequest {
    <#
    .SYNOPSIS
        Calls the Microsoft Graph REST API using the session's app token; follows @odata.nextLink.

    .DESCRIPTION
        Returns the deserialized response body. For collection endpoints, when -All is supplied
        each page's .value items are emitted to the pipeline as a single concatenated stream.
        Without -All, the raw object (with .value and possibly @odata.nextLink) is returned.

        Retries throttling (429) and transient server errors (503, 504) up to 4 times,
        honouring Graph's Retry-After header where it is present and falling back to
        capped exponential backoff. Every other status - 403, 400, 404 - is rethrown
        immediately, since retrying cannot help and would only delay the message.

        This matters most for the callers that have no bulk endpoint available and must
        issue one request per object; without it, throttling arrives as a burst of failed
        reads that is easily mistaken for a missing permission.
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

    # Graph endpoint for the session's cloud (microsoftgraph.chinacloudapi.cn in China,
    # graph.microsoft.us in US Gov). Falls back to commercial for sessions that predate
    # endpoint resolution. The same value is both the token resource and the base URL.
    $base = if ($script:MsecSession.Endpoints -and $script:MsecSession.Endpoints.GraphResource) {
        $script:MsecSession.Endpoints.GraphResource
    }
    else {
        'https://graph.microsoft.com'
    }

    $token = Get-MsecAccessToken -Resource $base
    $headers = @{ Authorization = "Bearer $token" }

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

    # Graph throttles per app and per tenant, and answers with 429 plus a Retry-After
    # header saying how long to wait. Nothing here used to honour it, so any caller
    # making a burst of requests - notably the one-call-per-user loops, which have no
    # bulk endpoint to use instead - turned throttling into a wall of failed reads that
    # looked like a missing permission. 503 and 504 are retried on the same basis:
    # Graph's own guidance is that they are transient.
    #
    # Bounded, so a persistently throttled call still surfaces as an error rather than
    # hanging forever. Non-throttling errors (403, 400, 404) are rethrown untouched -
    # retrying those would only delay a message the caller needs now.
    $maxAttempts = 5

    $invoke = {
        param($Params)

        for ($attempt = 1; ; $attempt++) {
            try {
                return Invoke-RestMethod @Params
            }
            catch {
                $status = $null
                if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                    $status = [int] $_.Exception.Response.StatusCode
                }

                $throttled = ($status -in 429, 503, 504) -or
                             ($_.Exception.Message -match '\b(429|503|504)\b|Too Many Requests|Service Unavailable')

                if (-not $throttled -or $attempt -ge $maxAttempts) { throw }

                # Retry-After is authoritative when present; Graph sets it on 429. Fall
                # back to exponential backoff, capped so one bad call cannot stall a run
                # for minutes.
                $wait = 0
                try {
                    $retryAfter = $_.Exception.Response.Headers.RetryAfter
                    if ($retryAfter) {
                        if ($retryAfter.Delta) { $wait = [int] $retryAfter.Delta.TotalSeconds }
                        elseif ("$retryAfter" -match '^\d+$') { $wait = [int] "$retryAfter" }
                    }
                }
                catch {
                    # Header shapes vary by platform and exception type; backoff covers it.
                }
                if ($wait -le 0) { $wait = [Math]::Min(30, [Math]::Pow(2, $attempt)) }

                Write-Verbose "Microsoft Graph throttled this request (status $status). Waiting $wait s, then retry $attempt of $($maxAttempts - 1): $($Params.Uri)"
                Start-Sleep -Seconds $wait
            }
        }
    }

    if (-not $All) {
        return & $invoke $invokeParams
    }

    # Paged collection: yield each page's .value items, follow @odata.nextLink.
    #
    # Progress is reported from the SECOND page onwards. A caller blocked in here for
    # minutes - /auditLogs/signIns over a month is hundreds of pages - otherwise leaves
    # whatever status the caller set before the call frozen on screen, which reads as a
    # hang. Suppressed for single-page responses so ordinary calls stay silent, and given
    # its own progress id so it does not overwrite a caller's own bar.
    $progressId = 1729
    $page = 0
    $items = 0

    do {
        $response = & $invoke $invokeParams
        $page++

        if ($null -ne $response.value) {
            $batch = @($response.value)
            $items += $batch.Count
            $batch
        }

        $next = $response.'@odata.nextLink'
        if ($next) {
            $invokeParams['Uri'] = $next
            $invokeParams.Remove('Body') | Out-Null
            # No total is available - Graph does not return a count with nextLink - so
            # this is a live tally rather than a percentage. An honest "still working,
            # here is how much" beats a fabricated completion figure.
            Write-Progress -Id $progressId -Activity 'Paging Microsoft Graph' `
                -Status "$Path - $items item(s) after $page page(s)"
        }
    } while ($next)

    if ($page -gt 1) {
        Write-Progress -Id $progressId -Activity 'Paging Microsoft Graph' -Completed
    }
}
