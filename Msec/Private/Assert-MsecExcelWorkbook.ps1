function Assert-MsecExcelWorkbook {
    <#
    .SYNOPSIS
        Throws if $Path exists but is not a readable Excel workbook - so a damaged file is
        never silently replaced by a fresh one.

    .DESCRIPTION
        Both writers here can CREATE the workbook, which is what makes a damaged file
        dangerous: Export-Excel treats "cannot read this" and "there is nothing here yet" the
        same way, and writes a new workbook holding only the current run. Every sheet in it -
        every tenant, every subscription, every row ever collected - is gone, and the write
        reports success.

        The case that actually happens is a zero-byte file: a OneDrive placeholder that never
        materialised, a sync interrupted mid-write, a previous run killed while saving. The
        file exists, so nothing treats it as new; it has no workbook in it, so nothing finds
        anything to preserve.

        A file that does not exist is fine and returns quietly - that is a genuine first run.

    .PARAMETER Path
        The .xlsx to check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -eq 0) {
        throw "'$Path' exists but is empty (0 bytes), so it is not a workbook this can add to. Writing would replace it with a new file containing only this run, discarding whatever the original held. Nothing has been written. This is usually a OneDrive placeholder that never downloaded, or a run killed mid-save - restore the file from version history, or delete it deliberately to start fresh."
    }

    $worksheets = 0
    try {
        $package = Open-ExcelPackage -Path $Path
        try { $worksheets = @($package.Workbook.Worksheets).Count }
        finally { Close-ExcelPackage $package -NoSave }
    }
    catch {
        throw "'$Path' exists but could not be opened as an Excel workbook, so writing would replace it with a new file and discard whatever it held. Nothing has been written. Original error: $($_.Exception.Message)"
    }

    if ($worksheets -eq 0) {
        throw "'$Path' exists but contains no worksheets, so it is not a workbook this can add to. Writing would replace it and discard whatever the original held. Nothing has been written. Restore it from version history, or delete it deliberately to start fresh."
    }
}
