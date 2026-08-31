function Add-MsecExcelDashboard {
    <#
    .SYNOPSIS
        Builds the Dashboard sheet - every chart in the workbook, on one page, in front of
        the data sheets - and keeps each chart's ranges covering the rows added since.

    .DESCRIPTION
        WHY PLAIN CELL RANGES AND NOT STRUCTURED TABLE REFERENCES
        ---------------------------------------------------------
        An earlier version pointed each series at the table by structured reference -
        'Scores'!tblScores[SecureScorePercent] - on the theory that Excel would then grow the
        series with the table and the chart would never need touching again. EPPlus stores
        that string happily and reads it back, so it tested green. In Excel the charts came
        out BLANK: the value reference does not resolve, so there is nothing to plot.

        So the series use ordinary ranges - Scores!$B$2:$B$5 - which is the form EPPlus and
        ImportExcel both emit natively and the form Excel unambiguously understands.

        The cost of ordinary ranges is that they are pinned to the row count they were
        written with, so they must be refreshed as rows are appended. This does NOT rebuild
        the chart to do that. A chart that already exists keeps its title, position, size,
        colours and any other edit made in Excel; only the range strings on its existing
        series are rewritten. Add a series or restyle one in Excel and that survives too -
        the only thing overwritten is the span of rows each series covers, which has to move
        or the chart stops keeping up.

        Slot positions come from the caller's canonical ordering rather than from what
        happens to exist yet, so a measurement that failed on the first run and succeeded on
        the second still lands in its own place rather than shuffling the others along.

    .PARAMETER Path
        The .xlsx file. Must already have the data sheets written.

    .PARAMETER Chart
        Ordered chart specs. Each needs Sheet, Table, Title, Series and XColumn. A spec whose
        sheet does not exist yet is skipped and picked up on a later run.

    .PARAMETER Heading
        Text for the title cell above the charts.

    .PARAMETER WorksheetName
        Dashboard sheet name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Chart,

        [int]    $ChartWidth  = 600,
        [int]    $ChartHeight = 370,
        [switch] $Reset,
        [string] $Heading,
        [string] $WorksheetName = 'Dashboard'
    )

    # ---- page geometry ---------------------------------------------------------------------
    #
    # THE BINDING CONSTRAINT IS WORD, NOT EXCEL. Copy a chart out of Excel and paste it into a
    # document and it arrives at its true pixel size, with no scaling - so it has to fit the
    # target page as drawn. At 96 DPI and Word's default 2.54 cm margins:
    #
    #   A4 portrait   21.0 cm - 5.08 = 15.9 cm  ~  602 px
    #   A4 landscape  29.7 cm - 5.08 = 24.6 cm  ~  930 px
    #
    # Sizing for Excel's own landscape page (about 1045 px) therefore produces a chart too
    # wide for Word in EITHER orientation, which has to be dragged smaller by hand on every
    # paste. The default is sized for the tighter of the two - portrait - so a pasted chart
    # fits any document without being touched.
    #
    # Printing from Excel does not suffer for it: the print area below is derived from the
    # chart width, so fit-to-one-page-wide scales that narrow band UP to fill the sheet.
    # Small in the file, full width on the page, exact size in Word.
    $chartWidth  = $ChartWidth
    $chartHeight = $ChartHeight

    # Rows are 20 px by default, so a band is the chart's height in rows plus a gap. The band
    # is where the page breaks go, so it decides pagination.
    $band     = [int][Math]::Ceiling($chartHeight / 20) + 4
    $firstRow = 2      # below the heading in A1

    # Columns are 64 px by default. One column of slack so the chart never touches the edge
    # of the print area.
    $printColumns = [int][Math]::Ceiling($chartWidth / 64) + 1
    $printLastCol = ConvertTo-MsecExcelColumn -Index ($printColumns - 1)

    $package = Open-ExcelPackage -Path $Path
    try {
        # Charts are created once and then only range-refreshed, so a size change cannot reach
        # a chart that already exists. -Reset drops the sheet so the whole thing is rebuilt at
        # the current geometry - the only way to reshape a dashboard built by an earlier
        # version, and the reason it is a switch rather than the default: it discards every
        # manual edit on that sheet along with the old sizes.
        $dashboard = $package.Workbook.Worksheets[$WorksheetName]
        if ($dashboard -and $Reset) {
            $package.Workbook.Worksheets.Delete($WorksheetName)
            $dashboard = $null
        }

        $created = $false
        if (-not $dashboard) {
            $dashboard = $package.Workbook.Worksheets.Add($WorksheetName)
            $created = $true
        }

        if ($Heading) {
            $dashboard.Cells[1, 1].Value = $Heading
            $dashboard.Cells[1, 1].Style.Font.Bold = $true
            $dashboard.Cells[1, 1].Style.Font.Size = 14
        }

        # Page setup that is a matter of taste is written ONCE, when the sheet is created, so
        # switching to A3 or portrait in Excel is not undone on the next run. The print area
        # and the page breaks are different - they have to track how many charts there are -
        # and so are rewritten below every time.
        if ($created) {
            $dashboard.PrinterSettings.Orientation         = [OfficeOpenXml.eOrientation]::Landscape
            $dashboard.PrinterSettings.PaperSize            = [OfficeOpenXml.ePaperSize]::A4
            $dashboard.PrinterSettings.LeftMargin           = 0.4
            $dashboard.PrinterSettings.RightMargin          = 0.4
            $dashboard.PrinterSettings.TopMargin            = 0.4
            $dashboard.PrinterSettings.BottomMargin         = 0.4
            $dashboard.PrinterSettings.HorizontalCentered   = $true
            $dashboard.PrinterSettings.FitToPage            = $true
            $dashboard.PrinterSettings.FitToWidth           = 1
            # 0 means "as many pages tall as it takes". Setting 1 here would squeeze every
            # chart onto a single page, which is the opposite of one chart per page.
            $dashboard.PrinterSettings.FitToHeight          = 0
        }

        for ($slot = 0; $slot -lt $Chart.Count; $slot++) {
            $spec = $Chart[$slot]
            $chartName = "chart$($spec.Sheet)"

            # No data sheet yet - that measurement has never succeeded. Skipped rather than
            # drawn empty, and its slot is held so the layout does not shift when it arrives.
            $dataSheet = $package.Workbook.Worksheets[$spec.Sheet]
            if (-not $dataSheet -or -not $dataSheet.Dimension) { continue }

            # Header row of the data sheet, so each series name can be mapped to its column.
            $headers = @(1..$dataSheet.Dimension.Columns | ForEach-Object { $dataSheet.Cells[1, $_].Text })
            $lastRow = $dataSheet.Dimension.Rows
            if ($lastRow -lt 2) { continue }     # header only; nothing to plot yet

            $xIndex = [array]::IndexOf($headers, $spec.XColumn)
            if ($xIndex -lt 0) { continue }
            $xLetter = ConvertTo-MsecExcelColumn -Index $xIndex
            $xRange = "$($spec.Sheet)!`$$xLetter`$2:`$$xLetter`$$lastRow"

            $plot = [ordered]@{}
            foreach ($name in @($spec.Series | Where-Object { $_ })) {
                $index = [array]::IndexOf($headers, $name)
                if ($index -lt 0) { continue }
                $letter = ConvertTo-MsecExcelColumn -Index $index
                $plot[$name] = "$($spec.Sheet)!`$$letter`$2:`$$letter`$$lastRow"
            }
            if (-not $plot.Count) { continue }

            $existing = $dashboard.Drawings | Where-Object Name -eq $chartName | Select-Object -First 1

            if ($existing) {
                # REFRESH ONLY THE RANGES. Everything else about the chart is the reader's -
                # title, colours, size, position, series they added themselves - and stays.
                foreach ($series in $existing.Series) {
                    if ($plot.Contains($series.Header)) {
                        $series.Series = $plot[$series.Header]
                        $series.XSeries = $xRange
                    }
                }

                # POSITION IS OWNED BY THE LAYOUT, not by the reader, so it is reasserted
                # every run. Without this, adding a measurement anywhere but the end of the
                # canonical list shifts every later slot while the charts already drawn stay
                # put - and the new chart lands exactly on top of an existing one. That is
                # not a cosmetic misalignment: the chart underneath simply cannot be seen.
                #
                # Everything else about the chart is still the reader's - title, colours,
                # size, series added by hand. Only where it sits is not, because where it
                # sits is what the page breaks are aligned to.
                $existing.SetPosition($firstRow + ($slot * $band), 0, 0, 0)
                continue
            }

            $type = if ($spec.ChartType) { $spec.ChartType } else { 'Line' }
            $drawing = $dashboard.Drawings.AddChart($chartName, [OfficeOpenXml.Drawing.Chart.eChartType]::$type)
            $drawing.Title.Text = $spec.Title

            # One chart per band, stacked down column A. The band is also the page break
            # interval, so each chart starts at the top of its own printed page.
            $drawing.SetPosition($firstRow + ($slot * $band), 0, 0, 0)
            $drawing.SetSize($chartWidth, $chartHeight)

            foreach ($name in $plot.Keys) {
                $series = $drawing.Series.Add($plot[$name], $xRange)
                $series.Header = $name

                # The only two properties set, and neither is styling:
                #   Smooth off - a smoothed line invents values between two monthly samples,
                #                which on a compliance trend reads as movement that never
                #                happened.
                #   Markers on - with a handful of points, the dots show where a real sample
                #                sits as opposed to interpolation between them.
                # Colour and width are left to Excel's theme.
                $series.Smooth = $false
                $series.Marker = [OfficeOpenXml.Drawing.Chart.eMarkerStyle]::Circle
            }
        }

        # ---- pagination ----------------------------------------------------------------------
        #
        # A page break at the top of every band but the first, so each chart prints - and
        # exports to PDF - on its own page. Driven by the number of SLOTS rather than by the
        # charts that exist, so a measurement that has not succeeded yet leaves a blank page
        # rather than shifting every later chart onto the wrong one.
        for ($slot = 1; $slot -lt $Chart.Count; $slot++) {
            $dashboard.Row($firstRow + ($slot * $band)).PageBreak = $true
        }

        # Print area has to cover the charts. They are drawings anchored to cells, so Excel
        # prints them only if the cells they sit over are inside it; without this the export
        # comes out as blank pages.
        #
        # Derived from the chart width rather than fixed, so a narrow chart still fills the
        # printed page: fit-to-one-page-wide scales this band up to the sheet width.
        $lastRow = $firstRow + ($Chart.Count * $band)
        $dashboard.PrinterSettings.PrintArea = $dashboard.Cells["A1:$printLastCol$lastRow"]

        # In front of the data sheets, so the workbook opens on the charts.
        $package.Workbook.Worksheets.MoveToStart($WorksheetName)

        Close-ExcelPackage $package
    }
    catch {
        Close-ExcelPackage $package -NoSave
        throw
    }
}
