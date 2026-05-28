function Disconnect-Msec {
    <#
    .SYNOPSIS
        Clears the Microsoft Security session (cached tokens and key/vault references).
    #>
    [CmdletBinding()]
    param()

    $script:MsecSession = $null
    Write-Verbose 'Msec session cleared.'
}
