function Invoke-MsecAzureDevOpsRequest {
    <#
        One place for the three things every Azure DevOps call in this module has to get right:
        the token, the continuation header, and what a 401 actually means.

        PAGINATION IS THE REASON THIS EXISTS. The ADO graph APIs return a page and put the
        cursor in an X-MS-CONTINUATION-TOKEN RESPONSE HEADER - not in the body, where every
        other API in this module keeps it. Code that reads only $response.value gets the first
        page, no error, and no indication there was more. In an access review that is the worst
        possible failure: the users who are missing look exactly like users who do not exist.

        401/403 here almost never means the Entra token is wrong. It means the msec app is not
        a member of the ADO organization, which is granted INSIDE Azure DevOps and cannot be
        fixed by New-MsecApp, so the message says so rather than pointing at API permissions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Organization,

        # Everything after the organization, e.g. '_apis/graph/users'. May carry its own query
        # string - 'memberships/{d}?direction=up' - and the api-version is appended correctly
        # either way.
        [Parameter(Mandatory)]
        [string] $Path,

        # The graph/identity APIs live on vssps, the rest on dev.azure.com. NOT named $Host:
        # that is an automatic variable, and assigning it silently breaks Write-Host.
        [string] $HostName = 'vssps.dev.azure.com',

        [string] $ApiVersion = '7.1-preview.1',

        # Follow the continuation header to the end. Off by default so a single-object call
        # (one group, one user) does not pay for a loop it cannot use.
        [switch] $All
    )

    # ADO is a separate Entra resource - 499b84ac-1321-427f-aa17-267ca6975798 is Microsoft's
    # well-known Azure DevOps app ID. Get-MsecAccessToken appends /.default itself, so pass the
    # bare resource identifier (NOT '.../.default' - that produces a malformed
    # '.../default/.default' scope and Entra 400s).
    try {
        $token = Get-MsecAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798'
    }
    catch {
        throw "Could not acquire an Entra token for Azure DevOps. This is a token-request failure (Entra-side), NOT an ADO membership failure. Check the msec app's certificate is still valid and that Connect-Msec succeeded. Original error: $($_.Exception.Message)"
    }

    $headers = @{ Authorization = "Bearer $token" }
    $separator = if ($Path -match '\?') { '&' } else { '?' }
    $results = [System.Collections.Generic.List[object]]::new()
    $continuation = $null
    $page = 0

    do {
        $uri = "https://$HostName/$Organization/$Path$separator" + "api-version=$ApiVersion"
        if ($continuation) { $uri += "&continuationToken=$([uri]::EscapeDataString($continuation))" }

        # Invoke-WebRequest, not Invoke-RestMethod, because the continuation cursor arrives in a
        # HEADER. Invoke-RestMethod only surfaces headers through -ResponseHeadersVariable, an
        # out-variable side effect - which cannot be produced by a mock, so the paging loop
        # would be untestable and this is the one part that must not be got wrong.
        try {
            $web = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
            $response = if ($web.Content) { $web.Content | ConvertFrom-Json } else { $null }
            $responseHeaders = $web.Headers
        }
        catch {
            $detail = $_.Exception.Message
            if ($detail -match '401|403|Unauthorized|Forbidden') {
                # DELIBERATELY DOES NOT NAME A CAUSE. Two different things produce a 403 here -
                # the app not being an organization member at all, and the app being a member
                # without the permission this particular resource needs - and the response does
                # not distinguish them. Asserting the first sent readers to check a membership
                # that was already in place while the real gap was a namespace permission.
                #
                # Callers that know which permission their resource needs say so themselves.
                throw "Forbidden calling '$Path' in organization '$Organization'. Either the msec app is not a member of the organization (Organization Settings > Users > Add, Basic access), or it is a member without the permission this resource requires - Azure DevOps returns the same 403 for both, and neither is granted through Entra, so New-MsecApp cannot do it. Original error: $detail"
            }
            throw "Azure DevOps request failed for '$Path' in '$Organization': $detail"
        }

        if ($null -ne $response -and $response.PSObject.Properties.Name -contains 'value') {
            $results.AddRange(@($response.value))
        }
        elseif ($null -ne $response) {
            $results.Add($response)
        }

        $continuation = $null
        if ($responseHeaders -and $responseHeaders['X-MS-ContinuationToken']) {
            $continuation = @($responseHeaders['X-MS-ContinuationToken'])[0]
        }
        $page++
    } while ($All -and $continuation)

    if ($page -gt 1) { Write-Verbose "Read $page page(s) from '$Path' in '$Organization'." }

    # A guard against a server that keeps handing back the same cursor: without -All we stop
    # after one page anyway, and the caller sees a short answer rather than a hung shell.
    if (-not $All -and $continuation) {
        Write-Verbose "'$Path' has more pages; call with -All to read them."
    }

    # NOT ', $results.ToArray()'. The unary comma emits the array as a SINGLE object, so a
    # caller writing @(Invoke-MsecAzureDevOpsRequest ...) - which every caller does - gets a
    # one-element collection holding an array, and an EMPTY result counts as one. Downstream
    # that turns "no users" into one nameless user and skips the empty-response warning
    # entirely. Emitting the elements is what callers expect.
    $results.ToArray()
}
