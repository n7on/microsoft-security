function Write-MsecExcelSheet {
    <#
    .SYNOPSIS
        Writes a data worksheet from scratch - table and formatting - carrying over any rows
        already there. Used to create a sheet, and to reshape one whose columns changed.

    .DESCRIPTION
        Data only. Charts live on the Dashboard sheet and are built by Add-MsecExcelDashboard,
        so nothing here creates or destroys one - which is what allows a reshape of the data
        to leave the charts alone. It does clear the DATA sheet, so anything added to that
        sheet by hand is lost on a reshape; the Dashboard is untouched either way.

        Called on the first write to a sheet, and again only if a measurement's column set
        changes. Every run in between is a plain append via Add-MsecExcelRow.

    .PARAMETER NewRow
        The row to add. Existing rows are read first and preserved, with the union of old
        and new columns as the header.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $WorksheetName,
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [object] $NewRow,

        [string] $TableStyle = 'Medium2'
    )

    # A damaged workbook must never be silently replaced by a fresh one.
    Assert-MsecExcelWorkbook -Path $Path

    # THE HISTORY IS READ BEFORE IT IS OVERWRITTEN, AND A FAILED READ MUST NOT LOOK LIKE AN
    # EMPTY ONE. This function rewrites the sheet with -ClearSheet, so whatever is in $existing
    # is the entire surviving record. An earlier version caught every read failure and carried
    # on with an empty $existing, which turned a transient lock - a sync client mid-write, the
    # file open in Excel - into the silent loss of every row ever collected, reported only
    # through Write-Verbose.
    #
    # So the row count is taken from the package FIRST, which is what makes "there is nothing
    # to preserve" distinguishable from "I could not read what is there". Only the first is
    # allowed to proceed.
    $existing = @()
    $existingRows = 0

    if (Test-Path -LiteralPath $Path) {
        $package = Open-ExcelPackage -Path $Path
        try {
            $worksheet = $package.Workbook.Worksheets[$WorksheetName]
            # Row 1 is the header, so anything at or below 1 means no data yet.
            if ($worksheet -and $worksheet.Dimension) {
                $existingRows = [Math]::Max(0, $worksheet.Dimension.Rows - 1)
            }
        }
        finally { Close-ExcelPackage $package -NoSave }

        if ($existingRows -gt 0) {
            try { $existing = @(Import-Excel -Path $Path -WorksheetName $WorksheetName -ErrorAction Stop) }
            catch {
                throw "Refusing to rewrite worksheet '$WorksheetName' in '$Path': it holds $existingRows data row(s) that could not be read back, and rewriting now would discard them. The file has NOT been modified. This is usually the file being open in Excel or mid-sync; close it and run again. Original error: $($_.Exception.Message)"
            }

            # Read back fewer rows than the sheet holds and the difference would be dropped on
            # the rewrite just as silently. Refusing is recoverable; a truncated history is not.
            if ($existing.Count -lt $existingRows) {
                throw "Refusing to rewrite worksheet '$WorksheetName' in '$Path': it holds $existingRows data row(s) but only $($existing.Count) could be read back, so rewriting would discard the rest. The file has NOT been modified."
            }
        }
        else {
            Write-Verbose "No data rows in '$WorksheetName' yet in '$Path' - writing it fresh."
        }
    }

    $all = @($existing) + @($NewRow)

    # Union of columns, existing order preserved so a reshape never reorders history.
    $headers = [System.Collections.Generic.List[string]]::new()
    foreach ($object in $all) {
        foreach ($name in $object.PSObject.Properties.Name) {
            if (-not $headers.Contains($name)) { [void] $headers.Add($name) }
        }
    }
    $shaped = foreach ($object in $all) {
        $ordered = [ordered]@{}
        foreach ($header in $headers) { $ordered[$header] = $object.$header }
        [pscustomobject] $ordered
    }

    $package = $shaped | Export-Excel -Path $Path -WorksheetName $WorksheetName -ClearSheet `
                                      -TableName $TableName -TableStyle $TableStyle -PassThru
    try {
        $worksheet = $package.Workbook.Worksheets[$WorksheetName]

        # Widths by hand rather than -AutoSize: AutoSize needs libgdiplus, which is absent
        # on a stock macOS or Linux box and warns on every call there.
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

    return @($shaped).Count
}
