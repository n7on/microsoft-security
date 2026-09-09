function Write-MsecEvidenceWorkbook {
    <#
    .SYNOPSIS
        Writes a snapshot evidence workbook: one sheet of rows per owner, a shared Summary
        counting them by category, and a chart per owner.

    .DESCRIPTION
        The half every evidence report has in common. Collecting the rows is the report's own
        business - VMs answering a Run-Command, users read from Graph - but once the rows
        exist, what happens to them is identical, and it is the fiddly half: worksheet naming
        under Excel's 31-character limit, telling a re-run apart from a name collision,
        replace-rather-than-append, the shared Summary block, per-block timestamps, and the
        dashboard.

        Two bugs were found in that machinery while it lived in one report. Keeping a second
        copy would have meant finding them twice.

        AN "OWNER" is whatever a sheet is per: a subscription for the VM reports, a tenant for
        the directory ones. It supplies the sheet name and, through -OwnerColumn, the value
        that tells this subscription's own sheet apart from a different one whose name happens
        to truncate the same way.

        -Count IS AN ORDERED MAP of Summary column name to a predicate over a row. One entry
        gives one bar per category; two give two, which is how a chart shows both a total and
        the subset that matters - accounts per age bucket, and how many of those still hold a
        licence.

        CATEGORIES COME FROM -CategoryOrder, VERBATIM, so every category appears each run even
        at zero. One that vanished when nothing was in it would make two runs' charts
        incomparable, which on evidence is worse than an empty bar.

    .PARAMETER Path
        The .xlsx to write. Added to rather than replaced, so several owners can share a file.

    .PARAMETER OwnerName
        Names the sheet, e.g. a subscription or tenant name. Sanitised to Excel's rules.

    .PARAMETER OwnerId
        Stable id for the owner, used to tell a re-run from a truncation collision.

    .PARAMETER OwnerColumn
        The column on the rows holding OwnerId, e.g. 'SubscriptionId' or 'TenantId'.

    .PARAMETER Row
        The evidence rows. Written as given; sort before calling.

    .PARAMETER CategoryProperty
        Property holding each row's category, e.g. 'Assessment'.

    .PARAMETER CategoryOrder
        Every category, ordered as the chart should read them.

    .PARAMETER Count
        Ordered map of Summary column name to a predicate scriptblock evaluated per row with
        $_ bound. Each becomes a chart series.

    .PARAMETER Heading
        Dashboard heading. The collection span is appended.

    .PARAMETER ChartTitlePrefix
        Prefix for each chart's title; the owner name is appended.

    .PARAMETER CollectedUtc
        Collection timestamp, stamped on the Summary block for this owner.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $OwnerName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $OwnerId,
        [Parameter(Mandatory)] [string] $OwnerColumn,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Row,
        [Parameter(Mandatory)] [string] $CategoryProperty,
        [Parameter(Mandatory)] [string[]] $CategoryOrder,
        [Parameter(Mandatory)] $Count,
        [Parameter(Mandatory)] [string] $Heading,
        [Parameter(Mandatory)] [string] $ChartTitlePrefix,
        [Parameter(Mandatory)] [string] $CollectedUtc,

        # The Summary sheet's own column headers. Defaulted generically but always passed, so
        # an evidence sheet reads 'Subscription' and 'Assessment' rather than 'Owner' and
        # 'Category' - a reviewer should not have to translate.
        [string] $OwnerLabel    = 'Owner',
        [string] $CategoryLabel = 'Category',

        [string] $TableStyle  = 'Medium2',
        [int]    $ChartWidth  = 600,
        [int]    $ChartHeight = 370
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    # An existing sheet with our name is this owner's own - replaced, not collided with. A
    # genuine collision is two DIFFERENT owners whose names truncate to the same 31 characters,
    # told apart by the id already on the sheet.
    #
    # Resolved by the same function the overwrite prompt uses, so the sheet the caller was
    # asked about is necessarily the sheet that gets written.
    $sheet = Resolve-MsecEvidenceSheet -Path $Path -OwnerName $OwnerName -OwnerId $OwnerId -OwnerColumn $OwnerColumn
    $sheetName = $sheet.SheetName

    if ($sheet.CollidedWith) {
        Write-Warning "'$OwnerName' truncates to a worksheet name already used by $($sheet.CollidedWith), so this one is on '$sheetName' instead."
    }

    $tableName = 'tbl' + ($sheetName -replace '[^A-Za-z0-9]', '')
    if ($tableName -eq 'tbl') { $tableName = 'tblEvidence' }

    $written = Write-MsecExcelTable -Path $Path -WorksheetName $sheetName -Row $Row `
                                    -TableName $tableName -TableStyle $TableStyle

    # ---- summary ------------------------------------------------------------------------------

    $summary = @()
    if (Test-Path -LiteralPath $Path) {
        try { $summary = @(Import-Excel -Path $Path -WorksheetName 'Summary' -ErrorAction Stop) }
        catch { Write-Verbose "No Summary sheet yet: $($_.Exception.Message)" }
    }

    # This owner's block is rebuilt; everyone else's carried over untouched.
    $summary = @($summary | Where-Object { $_.$OwnerLabel -ne $OwnerName })

    foreach ($category in $CategoryOrder) {
        $inCategory = @($Row | Where-Object { $_.$CategoryProperty -eq $category })

        $block = [ordered]@{ $OwnerLabel = $OwnerName; $CategoryLabel = $category }
        foreach ($column in $Count.Keys) {
            $predicate = $Count[$column]
            # Counted with Where-Object rather than by indexing a Group-Object hashtable:
            # PowerShell wraps $null into a ONE-element array, so an absent key counts as 1 -
            # a phantom row under every empty category.
            $block[$column] = @($inCategory | Where-Object $predicate).Count
        }
        # Per BLOCK, not per document: owners are scanned in separate runs, so one timestamp
        # for the file would date a Monday scan with Friday's clock. Last, so the chart's
        # column letters do not move when a count column is added.
        $block['CollectedUtc'] = $CollectedUtc

        $summary += [pscustomobject] $block
    }

    $summary = @($summary |
        Sort-Object $OwnerLabel, @{ Expression = { [array]::IndexOf($CategoryOrder, $_.$CategoryLabel) } })

    Write-MsecExcelTable -Path $Path -WorksheetName 'Summary' -Row $summary `
                         -TableName 'tblSummary' -TableStyle $TableStyle | Out-Null

    # ---- dashboard ---------------------------------------------------------------------------

    $chartSpec = foreach ($name in @($summary.$OwnerLabel | Select-Object -Unique)) {
        $indexes = @(0..($summary.Count - 1) | Where-Object { $summary[$_].$OwnerLabel -eq $name })
        if (-not $indexes.Count) { continue }

        [pscustomobject]@{
            Sheet     = 'Summary'
            Table     = 'tblSummary'
            XColumn   = $CategoryLabel
            Title     = "$ChartTitlePrefix - $name"
            Series    = @($Count.Keys)
            # +2: row 1 is the header, and the index is zero-based.
            RowStart  = $indexes[0] + 2
            RowEnd    = $indexes[-1] + 2
            # Columns, not a line: unrelated categories, and a line joining them would imply a
            # progression that does not exist.
            ChartType = 'ColumnClustered'
            # Named for the OWNER though the data is on Summary, so each keeps its own chart
            # and its own slot as owners are added.
            ChartName = "chart$name"
        }
    }

    # The heading reports the SPAN rather than this run's clock, because owners are scanned
    # separately and one timestamp would date every sheet by whichever ran last.
    $collected = @($summary.CollectedUtc | Where-Object { $_ } | Sort-Object -Unique)
    $fullHeading = if ($collected.Count -gt 1) {
        "$Heading - collected $($collected[0]) to $($collected[-1]) UTC"
    }
    else {
        "$Heading - collected $($collected[0]) UTC"
    }

    Add-MsecExcelDashboard -Path $Path -Heading $fullHeading `
        -ChartWidth $ChartWidth -ChartHeight $ChartHeight -Chart @($chartSpec)

    return $written
}
