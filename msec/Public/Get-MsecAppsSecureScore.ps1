function Get-MsecAppsSecureScore {
    <#
    .SYNOPSIS
        Per-snapshot percentage for Microsoft Secure Score controls in the Apps category.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][ValidateRange(1, [int]::MaxValue)][int] $Top
    )
    Get-MsecSecureScoreCategoryData -Category 'Apps' @PSBoundParameters
}
