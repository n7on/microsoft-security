function Assert-MsecAdminSession {
    <#
    .SYNOPSIS
        Throws a clear error unless Connect-MsecAdmin has established a live write session.

    .DESCRIPTION
        The app session from Connect-Msec is not a weaker version of this one - it is the wrong
        one. New-MsecApp consents only *.Read.All, so the Key Vault certificate has no write
        permission to fall back on, and a caller who has merely run Connect-Msec needs to be
        told that rather than sent into a 403 that names no scope.

        Also re-checks Get-MgContext, because $script:MsecAdminSession records that a sign-in
        HAPPENED, not that it still holds - Disconnect-MgGraph, a token expiry or another module
        calling Connect-MgGraph all leave the variable set and the connection gone.

    .PARAMETER Scope
        Delegated scopes the caller needs. Checked against what the tenant actually granted, so
        a missing consent is named here instead of arriving as an unexplained 403 mid-write.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $Scope
    )

    if (-not $script:MsecAdminSession) {
        throw ('No write session. Run Connect-MsecAdmin first. The app session from Connect-Msec cannot ' +
               'be used for this: New-MsecApp consents only *.Read.All permissions, so the certificate in ' +
               'Key Vault has no write access - writes run as you, not as the app.')
    }

    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        $script:MsecAdminSession = $null
        throw ('The write session recorded by Connect-MsecAdmin is no longer connected - Disconnect-MgGraph, ' +
               'an expired token or another module reconnecting Graph will do that. Run Connect-MsecAdmin again.')
    }

    if ($Scope) {
        $granted = @($script:MsecAdminSession.GrantedScope)
        $missing = @($Scope | Where-Object { $_ -notin $granted })
        if ($missing.Count) {
            throw ("The write session as $($script:MsecAdminSession.Account) does not hold: $($missing -join ', '). " +
                   "Reconnect with: Connect-MsecAdmin -Scope $($Scope -join ',')")
        }
    }
}
