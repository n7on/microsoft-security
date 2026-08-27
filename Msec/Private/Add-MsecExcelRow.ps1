function Add-MsecExcelRow {
    <#
    .SYNOPSIS
        Appends one row to a worksheet's Excel table.

    .DESCRIPTION
        Data only - charts live on the Dashboard sheet and are built once by
        Add-MsecExcelDashboard. That separation is the point: after a sheet exists, this does
        nothing but append rows, so the charts (and anything you changed about them in Excel)
        are never touched.

        The charts use ordinary cell ranges, which are pinned to the row count they were
        written with, so Add-MsecExcelDashboard refreshes those ranges in place after this
        has appended. It refreshes only the ranges - never the chart - which is why the two
        are separate functions.

        SCHEMA DRIFT IS DETECTED, NOT ABSORBED
        --------------------------------------
        Export-Excel -Append maps values onto the EXISTING header and silently discards any
        property that is not already a column. That is a quiet data-loss bug waiting to
        happen: add a field to a measurement and it would never reach the workbook, with
        nothing said. So the row's columns are compared against the header first, and a
        mismatch takes the slow path - rewrite the sheet with the new column - with a
        warning saying so. Normal runs never take that path.

    .PARAMETER Path
        The .xlsx file. Created if it does not exist.

    .PARAMETER WorksheetName
        Sheet to append to. Created, with its table, if absent.

    .PARAMETER Row
        One object. Its properties become the columns on first write.

    .PARAMETER TableName
        Excel table name. Must not change once a sheet exists.

    .PARAMETER TableStyle
        An EPPlus TableStyles name - Light1-21, Medium1-28 or Dark1-11. Passed on the append
        path as well as on create, so changing it restyles an existing table on the next run
        rather than only applying to new sheets.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $WorksheetName,
        [Parameter(Mandatory)] [object] $Row,
        [Parameter(Mandatory)] [string] $TableName,

        # Typed as [string], not as [OfficeOpenXml.Table.TableStyles]. That enum only exists
        # once ImportExcel has been imported, and a parameter's type is resolved when the
        # function is DEFINED - so naming it here would break `Import-Module Msec` on any
        # machine without ImportExcel installed, which is every machine that never runs the
        # posture report. Validated by the cast in Export-MsecPostureReport instead.
        [string] $TableStyle = 'Medium2'
    )

    # A collection would land in the cell as 'System.Object[]'. These do occur -
    # AdminsNotMfaCapableUpn and TopFailingPolicies are both arrays.
    $flat = [ordered]@{}
    foreach ($property in $Row.PSObject.Properties) {
        $value = $property.Value
        if ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
            $value = (@($value) | ForEach-Object { "$_" }) -join '; '
        }
        $flat[$property.Name] = $value
    }
    $flatRow = [pscustomobject] $flat
    $rowColumns = @($flat.Keys)

    # Existing header, if any. A missing file and a missing sheet both mean "create".
    $existingHeader = $null
    if (Test-Path -LiteralPath $Path) {
        $package = Open-ExcelPackage -Path $Path
        try {
            $worksheet = $package.Workbook.Worksheets[$WorksheetName]
            if ($worksheet -and $worksheet.Dimension) {
                $existingHeader = @(
                    1..$worksheet.Dimension.Columns | ForEach-Object { $worksheet.Cells[1, $_].Text }
                ) | Where-Object { $_ }
            }
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    if ($existingHeader) {
        # Compared as a SET, not as an ordered sequence. Export-Excel -Append maps values onto
        # the header BY NAME, so a row whose properties come back in a different order still
        # lands in the right columns - checking order too would force a needless sheet
        # rewrite, and a rewrite is the one thing here that discards manual formatting.
        #
        # What -Append does not survive is a column it has never seen: it drops that property
        # silently, which is the whole reason this wrapper exists.
        $same = -not (Compare-Object $existingHeader $rowColumns)

        if ($same) {
            $flatRow | Export-Excel -Path $Path -WorksheetName $WorksheetName -Append `
                              -TableName $TableName -TableStyle $TableStyle
            return (Get-MsecExcelRowCount -Path $Path -WorksheetName $WorksheetName)
        }

        $added = @($rowColumns | Where-Object { $_ -notin $existingHeader })
        Write-Warning ("Sheet '$WorksheetName' has a different column set than this run produced" +
            $(if ($added.Count) { " (new: $($added -join ', '))" } else { '' }) +
            '. Rewriting the sheet to take the new shape - any manual formatting on it will be lost, though the dashboard charts are untouched. This happens only when a measurement changes shape.')

        return (Write-MsecExcelSheet -Path $Path -WorksheetName $WorksheetName `
                    -TableName $TableName -NewRow $flatRow -TableStyle $TableStyle)
    }

    # First write for this sheet.
    return (Write-MsecExcelSheet -Path $Path -WorksheetName $WorksheetName `
                -TableName $TableName -NewRow $flatRow -TableStyle $TableStyle)
}
