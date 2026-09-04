function Get-MsecExcelHeader {
    <#
    .SYNOPSIS
        The column names already on a worksheet, or an empty array. Never throws.

    .DESCRIPTION
        Used by the measurements whose columns are DISCOVERED from the data, so that a column
        which existed on an earlier run can be carried forward deliberately rather than simply
        going missing. See the backfill in Export-MsecPostureReport for why that matters.

        Returns empty for every failure - no file, no sheet, unreadable - because every caller
        treats "no history" and "cannot read the history" the same way here: write what this
        run knows and let Add-MsecExcelRow handle the shape.

    .PARAMETER Path
        The .xlsx to read.

    .PARAMETER WorksheetName
        The worksheet whose header row is wanted.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $WorksheetName
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        $package = Open-ExcelPackage -Path $Path
        try {
            $worksheet = $package.Workbook.Worksheets[$WorksheetName]
            if (-not $worksheet -or -not $worksheet.Dimension) { return @() }
            return @(1..$worksheet.Dimension.Columns |
                        ForEach-Object { $worksheet.Cells[1, $_].Text } |
                        Where-Object { $_ })
        }
        finally { Close-ExcelPackage $package -NoSave }
    }
    catch {
        Write-Verbose "Could not read the header of '$WorksheetName' in '$Path': $($_.Exception.Message)"
        return @()
    }
}
