function Get-MsecInfrastructureSecureScore {
    <#
    .SYNOPSIS
        Per-snapshot percentage for Microsoft Secure Score controls in the Infrastructure category.

    .DESCRIPTION
        Not all tenants have Infrastructure controls (only those onboarded to Defender for Cloud /
        Azure infrastructure); this returns nothing if none are present.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][ValidateRange(1, [int]::MaxValue)][int] $Top
    )
    Get-MsecSecureScoreCategoryData -Category 'Infrastructure' @PSBoundParameters
}
