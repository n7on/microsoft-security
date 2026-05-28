function Get-MsecDataSecureScore {
    <#
    .SYNOPSIS
        Per-snapshot percentage for Microsoft Secure Score controls in the Data category.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][ValidateRange(1, [int]::MaxValue)][int] $Top
    )
    Get-MsecSecureScoreCategoryData -Category 'Data' @PSBoundParameters
}
