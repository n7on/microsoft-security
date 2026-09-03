function Write-MsecExcelTable {
    <#
    .SYNOPSIS
        Writes a set of rows to a worksheet as an Excel table, replacing whatever was there.

    .DESCRIPTION
        The counterpart to Add-MsecExcelRow. That one APPENDS one row per run to build a time
        series; this one REPLACES the sheet with the rows it is given.

        Which is right depends on what the workbook is. A posture report accumulates - the
        history is the point. An evidence document is a snapshot of one moment, and a fresh
        file per run, so there is nothing to accumulate and nothing to drift: no header
        comparison, no reshape warning, no range to refresh afterwards.

        Rows are written exactly as given, in the order given, so the caller controls what the
        reader sees first - and, since a chart plots the column in sheet order, what the chart
        reads left to right.

    .PARAMETER Path
        The .xlsx file. Created if it does not exist. An existing file is added to, not
        replaced, so several subscriptions can each write their own sheet into one document.

    .PARAMETER WorksheetName
        Sheet to write. Replaced if it already exists.

    .PARAMETER Row
        The rows. Their properties become the columns.

    .PARAMETER TableName
        Excel table name, unique within the workbook.

    .PARAMETER TableStyle
        An EPPlus TableStyles name - Light1-21, Medium1-28 or Dark1-11.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $WorksheetName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Row,
        [Parameter(Mandatory)] [string] $TableName,

        [string] $TableStyle = 'Medium2'
    )

    if (-not $Row.Count) {
        Write-Verbose "No rows for '$WorksheetName'; nothing written."
        return 0
    }

    # A collection in a cell would render as 'System.Object[]', so it is joined - same
    # treatment Add-MsecExcelRow gives it.
    $flat = foreach ($item in $Row) {
        $ordered = [ordered]@{}
        foreach ($property in $item.PSObject.Properties) {
            $value = $property.Value
            if ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
                $value = (@($value) | ForEach-Object { "$_" }) -join '; '
            }
            $ordered[$property.Name] = $value
        }
        [pscustomobject] $ordered
    }

    $headers = @($flat[0].PSObject.Properties.Name)

    $package = $flat | Export-Excel -Path $Path -WorksheetName $WorksheetName -ClearSheet `
                                   -TableName $TableName -TableStyle $TableStyle -PassThru
    try {
        $worksheet = $package.Workbook.Worksheets[$WorksheetName]

        # Widths by hand rather than -AutoSize, which needs libgdiplus and warns on a stock
        # macOS or Linux box.
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $worksheet.Column($i + 1).Width = [Math]::Min(40, [Math]::Max(12, $headers[$i].Length + 3))
        }
        $worksheet.View.FreezePanes(2, 1)

        Close-ExcelPackage $package
    }
    catch {
        Close-ExcelPackage $package -NoSave
        throw
    }

    return $flat.Count
}
