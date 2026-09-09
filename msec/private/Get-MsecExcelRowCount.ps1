function Get-MsecExcelRowCount {
    <#
    .SYNOPSIS
        Data rows (excluding the header) on a worksheet, or 0 if it is not there.

    .DESCRIPTION
        Read from the sheet's dimension rather than by counting what Import-Excel returns,
        so it costs one open instead of deserialising every row just to length it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $WorksheetName
    )

    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    $package = Open-ExcelPackage -Path $Path
    try {
        $worksheet = $package.Workbook.Worksheets[$WorksheetName]
        if (-not $worksheet -or -not $worksheet.Dimension) { return 0 }
        return [Math]::Max(0, $worksheet.Dimension.Rows - 1)
    }
    finally { Close-ExcelPackage $package -NoSave }
}
