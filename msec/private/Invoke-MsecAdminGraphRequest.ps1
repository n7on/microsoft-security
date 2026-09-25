function Invoke-MsecAdminGraphRequest {
    <#
    .SYNOPSIS
        Calls Microsoft Graph as the signed-in user from Connect-MsecAdmin - the write path.

    .DESCRIPTION
        The deliberate twin of Invoke-MsecGraphRequest, which is hard-wired to the app's
        certificate token and therefore read-only. Keeping them as two functions rather than a
        switch on one means a write cannot reach for the app's identity by passing the wrong
        argument: this one has no access to the app token at all, and calls through the
        Microsoft.Graph.Authentication session that Connect-MsecAdmin established.

        No paging and no throttle-retry, unlike its read-side twin. Writes are single-object
        calls made a handful at a time; retrying one automatically would re-send a state change
        whose first attempt may well have landed.

    .PARAMETER Path
        Graph path, e.g. /v1.0/security/alerts_v2/{id}.

    .PARAMETER Method
        Defaults to GET so the post-write re-read needs no argument.

    .PARAMETER Body
        Hashtable sent as JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method = 'GET',

        [Parameter()]
        $Body
    )

    Assert-MsecAdminSession

    $params = @{
        Method      = $Method
        Uri         = $Path
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params['Body'] = $Body
    }

    try {
        Invoke-MgGraphRequest @params
    }
    catch {
        # Graph's own text, not the bare status line - see Get-MsecGraphErrorMessage.
        throw (Get-MsecGraphErrorMessage $_)
    }
}
