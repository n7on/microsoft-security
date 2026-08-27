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

        [string] $Heading,
        [string] $WorksheetName = 'Dashboard'
    )

    # ---- page geometry ---------------------------------------------------------------------
    #
    # One chart per printed page, sized for A4 landscape.
    #
    # A4 landscape is 11.69 x 8.27 in. At 0.4 in margins the printable area is 10.89 x 7.47 in,
    # which at 96 DPI is about 1045 x 717 px. A 960 x 560 chart therefore fits without Excel
    # having to scale it down, and leaves room for the heading on the first page.
    #
    # 560 px is 28 rows at the default 20 px row height, so a 30-row band holds one chart with
    # a gap. The band is what the page breaks are placed on, so it decides pagination.
    $chartWidth  = 960
    $chartHeight = 560
    $band        = 30
    $firstRow    = 2      # below the heading in A1

    $package = Open-ExcelPackage -Path $Path
    try {
        $dashboard = $package.Workbook.Worksheets[$WorksheetName]
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
        # 960 px is 15 columns at the default 64 px width, so column P gives a column of
        # slack. The last row is the bottom of the final band.
        $lastRow = $firstRow + ($Chart.Count * $band)
        $dashboard.PrinterSettings.PrintArea = $dashboard.Cells["A1:P$lastRow"]

        # In front of the data sheets, so the workbook opens on the charts.
        $package.Workbook.Worksheets.MoveToStart($WorksheetName)

        Close-ExcelPackage $package
    }
    catch {
        Close-ExcelPackage $package -NoSave
        throw
    }
}
