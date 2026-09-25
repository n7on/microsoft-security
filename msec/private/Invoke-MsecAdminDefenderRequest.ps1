function Invoke-MsecAdminDefenderRequest {
    <#
    .SYNOPSIS
        Calls the Defender for Endpoint API as the signed-in Azure user - the write path for
        alert comments.

    .DESCRIPTION
        The third identity in the module, and it exists because a comment on an alert is not a
        Graph operation. Microsoft Graph has no writable comment on alerts_v2 at all; the
        Defender for Endpoint API does, and its docs are explicit that a comment may be
        submitted with or without updating any other property.

        That API will not take the Graph token from Connect-MsecAdmin - different audience - so
        this mints one from the Az context instead, exactly as Invoke-MsecKeyVaultSign and
        Connect-MsecTeams do. The token carries user_impersonation, so the write is bounded by
        the caller's own Defender role ('Alerts investigation') rather than by anything the app
        registration was consented. The app token is deliberately unreachable from here: msec's
        app holds Score/Machine/Vulnerability reads only and must not gain an alert write.

        Commercial-only, like its read-side counterpart Invoke-MsecDefenderRequest.

    .PARAMETER Path
        Path below the Defender API host, e.g. '/api/alerts/{id}'.

    .PARAMETER Method
        GET or PATCH. Defaults to GET for the verification read.

    .PARAMETER Body
        Hashtable sent as JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [ValidateSet('GET', 'PATCH')]
        [string] $Method = 'GET',

        [Parameter()]
        $Body
    )

    $base = if ($script:MsecSession -and $script:MsecSession.Endpoints -and
                $script:MsecSession.Endpoints.DefenderResource) {
        $script:MsecSession.Endpoints.DefenderResource
    }
    else {
        'https://api.securitycenter.microsoft.com'
    }

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw ('Commenting on an alert calls the Defender for Endpoint API, which needs a token for ' +
               "$base - the Connect-MsecAdmin Graph token has the wrong audience and cannot be reused. " +
               'Run Connect-AzAccount first; the comment is then written as you.')
    }

    try { $tokenInfo = Get-AzAccessToken -ResourceUrl $base -ErrorAction Stop }
    catch {
        throw ("Could not get a Defender API token for $base as the signed-in Azure user: $($_.Exception.Message)")
    }

    # Az.Accounts 5.x+ returns a SecureString - same shape as Invoke-MsecKeyVaultSign.
    $token = if ($tokenInfo.Token -is [securestring]) {
        $tokenInfo.Token | ConvertFrom-SecureString -AsPlainText
    }
    else {
        [string] $tokenInfo.Token
    }

    $params = @{
        Method      = $Method
        Uri         = $base + $Path
        Headers     = @{ Authorization = "Bearer $token" }
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params['ContentType'] = 'application/json'
        $params['Body'] = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 10) }
    }

    Invoke-RestMethod @params
}
