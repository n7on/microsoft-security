function Get-MsecDeviceSecureScore {
    <#
    .SYNOPSIS
        Per-snapshot percentage for Microsoft Secure Score controls in the Device category.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][ValidateRange(1, [int]::MaxValue)][int] $Top
    )
    Get-MsecSecureScoreCategoryData -Category 'Device' @PSBoundParameters
}
