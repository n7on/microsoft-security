function Resolve-MsecEvidenceSheet {
    <#
    .SYNOPSIS
        Works out which worksheet an evidence report would write to, and whether doing so
        would REPLACE data that is already there.

    .DESCRIPTION
        Shared by the overwrite prompt and by the writer itself, so the two cannot disagree
        about what is at stake. Asking the question in two places with two implementations is
        how a confirmation ends up guarding a different sheet than the one being overwritten.

        Three outcomes:
          new       - no file, or no sheet with this name. Nothing is at risk.
          replace   - a sheet with this name holding THIS owner's rows. Writing discards them.
          collision - a sheet with this name holding a DIFFERENT owner's rows, because two
                      owner names truncate to the same 31 characters. Writing lands on a
                      suffixed name instead, so nothing is lost and nothing is confirmed.

    .PARAMETER Path
        The .xlsx the report would write to.

    .PARAMETER OwnerName
        The subject the sheet is named after - a tenant or subscription name.

    .PARAMETER OwnerId
        That subject's id, which is what tells "this owner again" from "a different owner whose
        name truncates the same way".

    .PARAMETER OwnerColumn
        The column on the sheet holding OwnerId.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $OwnerName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $OwnerId,
        [Parameter(Mandatory)] [string] $OwnerColumn
    )

    $result = [pscustomobject]@{
        SheetName    = ConvertTo-MsecExcelSheetName -Name $OwnerName
        IsReplace    = $false
        RowCount     = 0
        CollectedUtc = $null
        CollidedWith = $null
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $existingSheets = @()
    $package = Open-ExcelPackage -Path $Path
    try { $existingSheets = @($package.Workbook.Worksheets | ForEach-Object { $_.Name }) }
    finally { Close-ExcelPackage $package -NoSave }

    if ($result.SheetName -notin $existingSheets) { return $result }

    $rows = @()
    try { $rows = @(Import-Excel -Path $Path -WorksheetName $result.SheetName -ErrorAction Stop) }
    catch { Write-Verbose "Could not read sheet '$($result.SheetName)': $($_.Exception.Message)" }

    $owner = if ($rows.Count) { [string] $rows[0].$OwnerColumn } else { $null }

    if ($owner -and $OwnerId -and $owner -ne $OwnerId) {
        # A different owner already holds this name. The writer will suffix ours instead, so
        # this is not an overwrite - there is nothing to confirm.
        $result.CollidedWith = $owner
        $result.SheetName    = ConvertTo-MsecExcelSheetName -Name $OwnerName -Existing $existingSheets
        return $result
    }

    # This owner's own sheet. Note the row count even when the read failed and returned none -
    # IsReplace is what matters, and an unreadable sheet is MORE reason to confirm, not less.
    $result.IsReplace    = $true
    $result.RowCount     = $rows.Count
    $result.CollectedUtc = if ($rows.Count) { [string] $rows[0].CollectedUtc } else { $null }

    return $result
}
