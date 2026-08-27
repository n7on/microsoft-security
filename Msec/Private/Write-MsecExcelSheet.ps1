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

    $existing = @()
    if (Test-Path -LiteralPath $Path) {
        try { $existing = @(Import-Excel -Path $Path -WorksheetName $WorksheetName -ErrorAction Stop) }
        catch { Write-Verbose "No readable '$WorksheetName' sheet yet in '$Path': $($_.Exception.Message)" }
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
