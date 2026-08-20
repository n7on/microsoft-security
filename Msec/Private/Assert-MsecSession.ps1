function Assert-MsecSession {
    <#
    .SYNOPSIS
        Throws a clear error if Connect-Msec has not been called.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:MsecSession) {
        throw 'Not connected. Run Connect-Msec first.'
    }
}
