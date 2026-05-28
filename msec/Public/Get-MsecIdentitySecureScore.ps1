function Get-MsecIdentitySecureScore {
    <#
    .SYNOPSIS
        Per-snapshot percentage for Microsoft Secure Score controls in the Identity category.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][ValidateRange(1, [int]::MaxValue)][int] $Top
    )
    Get-MsecSecureScoreCategoryData -Category 'Identity' @PSBoundParameters
}
