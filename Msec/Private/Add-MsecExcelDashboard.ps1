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

        Charts are PACKED DENSELY in the caller's canonical order. The order is the caller's;
        the spacing is not. A spec that has never produced a row takes no space at all, so a
        workbook holding one measurement gets one chart at the top rather than one chart
        several blank pages down. The trade is that a measurement succeeding for the first
        time pushes every later chart down one page - once, and never back.

    .PARAMETER Path
        The .xlsx file. Must already have the data sheets written.

    .PARAMETER Chart
        Ordered chart specs. Each needs Sheet, Table, Title, Series and XColumn. A spec whose
        sheet does not exist yet is skipped - it contributes no chart and no blank space - and
        is picked up on a later run.

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

        # CHARTS ARE PACKED DENSELY, IN CANONICAL ORDER. The caller's list fixes the ORDER
        # charts appear in; it does not reserve a slot for each entry. A measurement that has
        # never produced a row contributes no chart and takes no space, so a workbook holding
        # only one measurement gets one chart at the top rather than one chart four blank
        # pages down.
        #
        # The cost, accepted deliberately: when a measurement succeeds for the FIRST time,
        # every chart after it moves down one page. That is a one-way, one-off move - a data
        # sheet never loses its rows, so a chart that exists keeps existing and the layout only
        # ever settles further. Position is reasserted every run anyway (see below), so this
        # adds no new instability; it only makes the existing kind more visible. Blank pages
        # between charts are the worse cost, because they are permanent rather than one-off.
        $slot = 0
        foreach ($spec in $Chart) {

            # Normally one chart per sheet, so the sheet names it. A spec may override that,
            # which is what several charts reading different BLOCKS of one shared sheet need -
            # without it they would all derive the same name and only the first would exist.
            $chartName = if ($spec.ChartName) { [string] $spec.ChartName } else { "chart$($spec.Sheet)" }

            $existing = $dashboard.Drawings | Where-Object Name -eq $chartName | Select-Object -First 1

            # Work out what this spec can plot, if anything. A missing data sheet is not an
            # error - that measurement has simply never succeeded.
            $plot   = [ordered]@{}
            $xRange = $null

            $dataSheet = $package.Workbook.Worksheets[$spec.Sheet]
            if ($dataSheet -and $dataSheet.Dimension) {
                # Header row of the data sheet, so each series name can be mapped to its column.
                $headers = @(1..$dataSheet.Dimension.Columns | ForEach-Object { $dataSheet.Cells[1, $_].Text })
                $lastRow = $dataSheet.Dimension.Rows

                # A spec may pin the rows it plots. Used where one sheet holds several blocks -
                # a summary table with a section per subscription - and each chart must read
                # only its own, rather than the whole sheet.
                $firstDataRow = if ($spec.RowStart) { [int] $spec.RowStart } else { 2 }
                if ($spec.RowEnd) { $lastRow = [Math]::Min([int] $spec.RowEnd, $lastRow) }

                $xIndex = [array]::IndexOf($headers, $spec.XColumn)

                # $lastRow -lt $firstDataRow covers the header-only sheet as well as an
                # out-of-range RowStart: either way there is nothing to plot yet.
                if ($xIndex -ge 0 -and $lastRow -ge $firstDataRow) {
                    $xLetter = ConvertTo-MsecExcelColumn -Index $xIndex
                    $xRange = "$($spec.Sheet)!`$$xLetter`$$firstDataRow`:`$$xLetter`$$lastRow"

                    foreach ($name in @($spec.Series | Where-Object { $_ })) {
                        $index = [array]::IndexOf($headers, $name)
                        if ($index -lt 0) { continue }
                        $letter = ConvertTo-MsecExcelColumn -Index $index
                        $plot[$name] = "$($spec.Sheet)!`$$letter`$$firstDataRow`:`$$letter`$$lastRow"
                    }
                }
            }

            # Nothing drawn and nothing to draw: contributes no chart, and therefore no slot
            # and no blank page. An EXISTING chart always takes its slot even when this run has
            # nothing to say about it - otherwise it would keep the position it was drawn at
            # while the charts around it packed up past it, and end up underneath one of them.
            if (-not $existing -and -not $plot.Count) { continue }

            if ($existing) {
                # REFRESH ONLY THE RANGES. Everything else about the chart is the reader's -
                # title, colours, size, series they added themselves - and stays.
                if ($plot.Count) {
                    foreach ($series in $existing.Series) {
                        if ($plot.Contains($series.Header)) {
                            $series.Series = $plot[$series.Header]
                            $series.XSeries = $xRange
                        }
                    }
                }

                # POSITION IS OWNED BY THE LAYOUT, not by the reader, so it is reasserted
                # every run. Without this, a chart that already existed would keep the row it
                # was drawn at while the ones around it moved - and the chart taking its place
                # would be drawn straight on top of it. That is not a cosmetic misalignment:
                # the chart underneath simply cannot be seen.
                #
                # Everything else about the chart is still the reader's - title, colours,
                # size, series added by hand. Only where it sits is not, because where it
                # sits is what the page breaks are aligned to.
                $existing.SetPosition($firstRow + ($slot * $band), 0, 0, 0)
                $slot++
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

                # LINE SERIES ONLY. Smooth and Marker live on ExcelLineChartSerie; a column
                # chart's series is an ExcelBarChartSerie and has neither, so setting them
                # unconditionally throws the moment a spec asks for anything but a line.
                # Tested by property rather than by chart type, so a future type is handled
                # by whether it actually supports these rather than by a list to keep in sync.
                #
                # Neither is styling:
                #   Smooth off - a smoothed line invents values between two monthly samples,
                #                which on a trend reads as movement that never happened.
                #   Markers on - with a handful of points, the dots show where a real sample
                #                sits as opposed to interpolation between them.
                # Colour and width are left to Excel's theme.
                $properties = $series.PSObject.Properties.Name
                if ($properties -contains 'Smooth') { $series.Smooth = $false }
                if ($properties -contains 'Marker') {
                    $series.Marker = [OfficeOpenXml.Drawing.Chart.eMarkerStyle]::Circle
                }
            }

            $slot++
        }

        # How many charts actually landed. Pagination and the print area follow THIS rather
        # than the length of the spec list - sizing them to the list would put the page breaks
        # where charts are not, and leave a print area of empty pages hanging off the bottom.
        $placed = $slot

        # ---- pagination ----------------------------------------------------------------------
        #
        # A page break at the top of every band but the first, so each chart prints - and
        # exports to PDF - on its own page.
        for ($i = 1; $i -lt $placed; $i++) {
            $dashboard.Row($firstRow + ($i * $band)).PageBreak = $true
        }

        # Print area has to cover the charts. They are drawings anchored to cells, so Excel
        # prints them only if the cells they sit over are inside it; without this the export
        # comes out as blank pages.
        #
        # Derived from the chart width rather than fixed, so a narrow chart still fills the
        # printed page: fit-to-one-page-wide scales this band up to the sheet width.
        $lastRow = $firstRow + ($placed * $band)
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
