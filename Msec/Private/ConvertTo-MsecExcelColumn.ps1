function ConvertTo-MsecExcelColumn {
    <#
    .SYNOPSIS
        Zero-based column index to an Excel column letter: 0 -> A, 25 -> Z, 26 -> AA.

    .DESCRIPTION
        Written out rather than done with [char](65 + $Index), which is correct only for the
        first 26 columns and then silently produces punctuation - '[' for column 26 - giving
        a chart range that Excel accepts as text and renders as nothing. MfaCoverage already
        passes 26 columns, so this is a real boundary rather than a theoretical one.

    .PARAMETER Index
        Zero-based column index.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 16383)]
        [int] $Index
    )

    $n = $Index + 1
    $letters = ''
    while ($n -gt 0) {
        $remainder = ($n - 1) % 26
        $letters = [char](65 + $remainder) + $letters
        $n = [int](($n - $remainder) / 26)
    }
    return $letters
}
