#Requires -Module Pester
#
# Tests for Export-MsecPostureReport and the Excel append helper under it.
#
# The behaviour worth pinning down is what happens on the SECOND and THIRD run, because
# that is where this feature actually lives and where the obvious implementation is wrong:
#
#   * rows must accumulate, not overwrite, and the table's range must grow with them
#   * a changed column set must NOT be silently swallowed: Export-Excel -Append discards
#     properties that are not already columns, so drift has to be detected and the sheet
#     reshaped rather than quietly losing a field
#   * a measurement whose command throws must cost only its own row, not the whole run
#
# Charts live on a Dashboard sheet and use ORDINARY CELL RANGES. An earlier version used
# structured table references, which EPPlus stores and reads back happily - so it tested
# green - and which Excel then rendered as blank charts. Nothing here can catch that; only
# opening the file in Excel can. The ranges are refreshed in place as rows are appended.
#
# Skipped wholesale when ImportExcel is absent. Unlike the old Word report, ImportExcel is
# a real dependency of the command rather than an optional extra, so CI installing it is
# the intent - see .github/workflows/ci.yml.

# At FILE scope, not in BeforeAll. Pester 5 evaluates a Describe's -Skip: during discovery,
# which happens before any BeforeAll runs - so a flag set in BeforeAll is still $null when
# the decision is made, and every guarded block skips even where ImportExcel is installed.
$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Add-MsecExcelRow' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-posture-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'accumulates rows across runs and grows the table range with them' {
        # The table range is what a hand-drawn Excel chart binds to, so it growing is the
        # whole reason this writes tables rather than plain ranges.
        $result = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            foreach ($i in 1..3) {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = "2026-08-2$i 09:00:00"; SecureScorePercent = 60 + $i })
            }
        }

        $result | Should -Be @(1, 2, 3)

        $rows = @(Import-Excel -Path $script:Book -WorksheetName 'Scores')
        $rows.Count | Should -Be 3
        $rows[0].SecureScorePercent | Should -Be 61
        $rows[2].SecureScorePercent | Should -Be 63

        $package = Open-ExcelPackage -Path $script:Book
        try {
            # Header + 3 data rows.
            $package.Workbook.Worksheets['Scores'].Tables['tblScores'].Address.Address | Should -Be 'A1:B4'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'writes no chart on a data sheet - those all live on the Dashboard' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            foreach ($i in 1..3) {
                Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                    -Row ([pscustomobject]@{ RunUtc = "d$i"; Value = $i }) | Out-Null
            }
        }

        $package = Open-ExcelPackage -Path $script:Book
        try { @($package.Workbook.Worksheets['S'].Drawings).Count | Should -Be 0 }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'adds a new column for a property that appears later, without losing earlier rows' {
        # Export-Excel -Append maps onto the existing header and SILENTLY DISCARDS anything
        # not already a column - so a measurement gaining a field would never reach the
        # workbook. The helper must notice and reshape instead of appending.
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'a'; One = 1 }) | Out-Null
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'b'; One = 2; Two = 9 }) -WarningAction SilentlyContinue | Out-Null
        }

        $rows = @(Import-Excel -Path $script:Book -WorksheetName 'S')
        $rows.Count | Should -Be 2
        $rows[0].RunUtc | Should -Be 'a'
        $rows[0].Two    | Should -BeNullOrEmpty     # absent when that row was written
        $rows[1].Two    | Should -Be 9              # NOT silently dropped
    }

    It 'appends without reshaping when only the column ORDER differs' {
        # Export-Excel -Append maps onto the header by NAME, so a reorder needs no reshape -
        # and reshaping anyway would rewrite the sheet and discard manual formatting for no
        # reason. The drift check is therefore a set comparison, not an ordered one.
        $warned = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'm1'; PROD = 72; SANDBOX = 31 }) | Out-Null
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'm2'; SANDBOX = 33; PROD = 74 }) `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        @($warned).Count | Should -Be 0            # no reshape happened

        $rows = @(Import-Excel -Path $script:Book -WorksheetName 'S')
        $rows.Count | Should -Be 2
        $rows[1].PROD    | Should -Be 74           # by name, not by position
        $rows[1].SANDBOX | Should -Be 33
    }

    It 'refuses to replace a damaged workbook with a fresh one' {
        # THE OTHER WIPE. Export-Excel can CREATE the file, so it treats "cannot read this" and
        # "nothing here yet" identically - and a zero-byte file (a OneDrive placeholder that
        # never downloaded, a run killed mid-save) is indistinguishable from new. The old
        # behaviour replaced it with a workbook holding one sheet and one row, reported success,
        # and took every other tenant and every row ever collected with it.
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            foreach ($i in 1..4) {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = "day$i"; SecureScorePercent = 60 + $i }) | Out-Null
            }
        }
        (Get-Item $script:Book).Length | Should -BeGreaterThan 0

        # The file survives sync as an empty husk.
        Set-Content -Path $script:Book -Value '' -NoNewline

        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = 'day5'; SecureScorePercent = 65 })
            } | Should -Throw '*0 bytes*'
        }

        # Left exactly as found, so version history can still restore it.
        (Get-Item $script:Book).Length | Should -Be 0
    }

    It 'still creates a workbook that does not exist yet' {
        # The guard must not break a genuine first run.
        $fresh = Join-Path ([System.IO.Path]::GetTempPath()) "msec-new-$([guid]::NewGuid().Guid).xlsx"
        try {
            $count = InModuleScope Msec -Parameters @{ Book = $fresh } {
                param($Book)
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = 'day1'; SecureScorePercent = 61 })
            }
            $count | Should -Be 1
            Test-Path $fresh | Should -BeTrue
        }
        finally { Remove-Item $fresh -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to rewrite a sheet whose history it could not read back' {
        # THE WIPE THIS EXISTS FOR. A reshape rewrites the sheet with -ClearSheet, so whatever
        # was read back is the entire surviving record. An earlier version caught every read
        # failure and carried on with an empty history, which turned a transient lock - the
        # file open in Excel, a sync client mid-write - into the silent loss of every row ever
        # collected, reported only through Write-Verbose.
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            foreach ($i in 1..5) {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = "day$i"; SecureScorePercent = 60 + $i }) | Out-Null
            }
        }

        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Import-Excel -MockWith { throw 'The process cannot access the file because it is being used by another process.' }

            # A new column arrives, so this is a reshape - the destructive path.
            {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = 'day6'; SecureScorePercent = 66; ExposurePercent = 20 }) `
                    -WarningAction SilentlyContinue
            } | Should -Throw '*Refusing to rewrite*'
        }

        # The file is untouched: all five rows still there, and the new one was NOT written.
        $rows = @(Import-Excel -Path $script:Book -WorksheetName 'Scores')
        @($rows).Count | Should -Be 5
        @($rows | ForEach-Object { $_.RunUtc }) | Should -Not -Contain 'day6'
    }

    It 'still writes a sheet that genuinely has no rows yet' {
        # The other side of the guard: an absent or header-only sheet is a real "nothing to
        # preserve", and must not be turned into a refusal.
        $count = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                -Row ([pscustomobject]@{ RunUtc = 'day1'; SecureScorePercent = 61 })
        }
        $count | Should -Be 1
    }

    It 'warns when it reshapes, because that is the one case that discards manual changes' {
        $captured = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'a'; One = 1 }) | Out-Null
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'b'; One = 2; Two = 9 }) `
                -WarningVariable warned -WarningAction SilentlyContinue | Out-Null
            $warned
        }

        ($captured -join ' ') | Should -Match 'new: Two'
    }

    It 'styles the table Medium2 by default, and restyles an existing one on a later run' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'a'; Value = 1 }) | Out-Null
        }

        $package = Open-ExcelPackage -Path $script:Book
        try { $package.Workbook.Worksheets['S'].Tables['tblS'].StyleName | Should -Be 'TableStyleMedium2' }
        finally { Close-ExcelPackage $package -NoSave }

        # Passed on the append path too, so changing -TableStyle restyles what is already
        # there rather than leaving old sheets on the previous style.
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' -TableStyle 'Dark7' `
                -Row ([pscustomobject]@{ RunUtc = 'b'; Value = 2 }) | Out-Null
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $table = $package.Workbook.Worksheets['S'].Tables['tblS']
            $table.StyleName | Should -Be 'TableStyleDark7'
            $table.Address.Address | Should -Be 'A1:B3'   # and both rows are still there
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'flattens a collection-valued property instead of writing System.Object[]' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Add-MsecExcelRow -Path $Book -WorksheetName 'S' -TableName 'tblS' `
                -Row ([pscustomobject]@{ RunUtc = 'a'; TopFailingPolicies = @('Block legacy', 'Require MFA') }) | Out-Null
        }

        (Import-Excel -Path $script:Book -WorksheetName 'S').TopFailingPolicies |
            Should -Be 'Block legacy; Require MFA'
    }
}

Describe 'Add-MsecExcelDashboard' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-dash-$([guid]::NewGuid().Guid).xlsx"

        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            foreach ($i in 1..3) {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = "d$i"; SecureScorePercent = 60 + $i; ExposurePercent = 30 - $i }) | Out-Null
                Add-MsecExcelRow -Path $Book -WorksheetName 'AzureSecureScore' -TableName 'tblAzureSecureScore' `
                    -Row ([pscustomobject]@{ RunUtc = "d$i"; PROD = 40 + $i; SANDBOX = 20 + $i }) | Out-Null
            }
        }

        $script:Specs = @(
            [pscustomobject]@{ Sheet = 'Scores';           Table = 'tblScores';           XColumn = 'RunUtc'; Title = 'Scores'; Series = @('SecureScorePercent', 'ExposurePercent') }
            [pscustomobject]@{ Sheet = 'AzureSecureScore'; Table = 'tblAzureSecureScore'; XColumn = 'RunUtc'; Title = 'Azure';  Series = @('PROD', 'SANDBOX') }
        )
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'puts every chart on one Dashboard sheet, and that sheet first' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs -Heading 'Posture'
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $package.Workbook.Worksheets[1].Name | Should -Be 'Dashboard'

            $dashboard = $package.Workbook.Worksheets['Dashboard']
            @($dashboard.Drawings).Count | Should -Be 2
            $dashboard.Cells[1, 1].Value | Should -Be 'Posture'

            # ...and none left behind on the data sheets.
            @($package.Workbook.Worksheets['Scores'].Drawings).Count | Should -Be 0
            @($package.Workbook.Worksheets['AzureSecureScore'].Drawings).Count | Should -Be 0
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'points each series at an ordinary cell range on the data sheet' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $chart = $package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartAzureSecureScore' | Select-Object -First 1

            # NOT a structured table reference. Excel renders those blank in a chart, which
            # is the bug this replaced - and no unit test caught it, because EPPlus stores
            # and reads the string back happily either way.
            $chart.Series[0].Series | Should -Be 'AzureSecureScore!$B$2:$B$4'
            $chart.Series[0].XSeries | Should -Be 'AzureSecureScore!$A$2:$A$4'
            $chart.Series[0].Series | Should -Not -Match '\['
            $chart.Series[0].Header | Should -Be 'PROD'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'refreshes the ranges as rows are appended, without rebuilding the chart' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        # An edit made in Excel that must survive the refresh.
        $package = Open-ExcelPackage -Path $script:Book
        ($package.Workbook.Worksheets['Dashboard'].Drawings |
            Where-Object Name -eq 'chartScores').Title.Text = 'Renamed by the user'
        Close-ExcelPackage $package

        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            foreach ($i in 4..6) {
                Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                    -Row ([pscustomobject]@{ RunUtc = "d$i"; SecureScorePercent = 60 + $i; ExposurePercent = 30 - $i }) | Out-Null
            }
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $chart = $package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartScores' | Select-Object -First 1

            # 6 data rows now, so the ranges must reach row 7 - a stale chart would still
            # say $B$2:$B$4 and flat-line after the third point.
            $chart.Series[0].Series  | Should -Be 'Scores!$B$2:$B$7'
            $chart.Series[0].XSeries | Should -Be 'Scores!$A$2:$A$7'
            # ...and the edit survived, because the chart was refreshed rather than rebuilt.
            $chart.Title.Text | Should -Be 'Renamed by the user'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'sets no series colour, leaving the workbook theme to apply' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        # An explicit colour would be written into the chart XML as a solidFill on the
        # series line; leaving it out is what lets Excel's theme palette take over.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $script:Book))
        try {
            foreach ($entry in $zip.Entries | Where-Object FullName -like '*chart*.xml') {
                $reader = [System.IO.StreamReader]::new($entry.Open())
                $xml = $reader.ReadToEnd(); $reader.Close()
                $xml | Should -Not -Match 'srgbClr'
            }
        }
        finally { $zip.Dispose() }
    }

    It 'turns smoothing off so the line does not invent points between samples' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $chart = $package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartScores' | Select-Object -First 1
            $chart.Series[0].Smooth | Should -BeFalse
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'creates each chart once, leaving later edits alone' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        # Stand in for a human editing the chart in Excel.
        $package = Open-ExcelPackage -Path $script:Book
        ($package.Workbook.Worksheets['Dashboard'].Drawings |
            Where-Object Name -eq 'chartScores').Title.Text = 'Renamed by the user'
        Close-ExcelPackage $package

        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelRow -Path $Book -WorksheetName 'Scores' -TableName 'tblScores' `
                -Row ([pscustomobject]@{ RunUtc = 'd9'; SecureScorePercent = 99; ExposurePercent = 1 }) | Out-Null
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $dashboard = $package.Workbook.Worksheets['Dashboard']
            @($dashboard.Drawings).Count | Should -Be 2      # not duplicated
            ($dashboard.Drawings | Where-Object Name -eq 'chartScores').Title.Text |
                Should -Be 'Renamed by the user'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'stacks one chart per band, each starting on its own printed page' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $specs = foreach ($i in 0..4) {
                $name = "Slot$i"
                Add-MsecExcelRow -Path $Book -WorksheetName $name -TableName "tbl$name" `
                    -Row ([pscustomobject]@{ RunUtc = 'd1'; Value = 1 }) | Out-Null
                [pscustomobject]@{ Sheet = $name; Table = "tbl$name"; XColumn = 'RunUtc'
                                   Title = "chart $i"; Series = @('Value') }
            }
            Add-MsecExcelDashboard -Path $Book -Chart @($specs)
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $worksheet = $package.Workbook.Worksheets['Dashboard']
            $charts = @($worksheet.Drawings | Where-Object Name -like 'chartSlot*' |
                Sort-Object { $_.From.Row })

            $charts.Count | Should -Be 5

            # The band is derived from -ChartHeight, so it is read off the result rather than
            # hardcoded - otherwise every size change breaks this test for no reason.
            $charts[0].From.Row | Should -Be 2
            $band = $charts[1].From.Row - $charts[0].From.Row
            $band | Should -BeGreaterThan 0

            # One per row band: every chart starts in column A, one band below the last.
            for ($i = 0; $i -lt $charts.Count; $i++) {
                $charts[$i].From.Row    | Should -Be (2 + $i * $band)
                $charts[$i].From.Column | Should -Be 0
            }

            # A page break at the top of every band but the first, so each chart prints on
            # its own page - and no chart straddles one.
            for ($i = 1; $i -lt $charts.Count; $i++) {
                $worksheet.Row(2 + $i * $band).PageBreak | Should -BeTrue
                $charts[$i - 1].To.Row | Should -BeLessThan (2 + $i * $band)
            }
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'sizes charts to fit a Word page, and derives the print area from that width' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $worksheet = $package.Workbook.Worksheets['Dashboard']
            $chart = $worksheet.Drawings | Where-Object Name -eq 'chartScores' | Select-Object -First 1

            # Word pastes at true pixel size, and A4 portrait at standard margins gives about
            # 602 px of printable width. Anything wider has to be resized on every paste.
            $columnsSpanned = $chart.To.Column - $chart.From.Column
            $columnsSpanned | Should -BeLessOrEqual 10        # ~600 px at 64 px/column

            # The print area follows the chart width rather than being fixed wide, so
            # fit-to-one-page-wide scales the narrow band back up to fill the printed sheet.
            # ~600 px at 64 px per column plus one of slack, so about 11 columns - and in
            # any case far narrower than the 16 it took when charts were sized for Excel.
            $area = $package.Workbook.Worksheets['Dashboard'].PrinterSettings.PrintArea.Address
            $area | Should -Match '\$A\$1:\$[A-Z]+\$\d+'
            $lastColumn = [regex]::Match($area, ':\$([A-Z]+)\$').Groups[1].Value
            $lastColumn      | Should -Not -BeNullOrEmpty
            $lastColumn.Length | Should -Be 1                               # single letter, so < 27 columns
            [int][char]$lastColumn | Should -BeLessOrEqual ([int][char]'L')
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'honours an explicit chart size, and -Reset is what applies it to an existing sheet' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs -ChartWidth 600 -ChartHeight 370
            # Without -Reset the existing chart keeps its size: charts are created once.
            Add-MsecExcelDashboard -Path $Book -Chart $Specs -ChartWidth 1200 -ChartHeight 700
        }

        $package = Open-ExcelPackage -Path $script:Book
        $narrow = ($package.Workbook.Worksheets['Dashboard'].Drawings |
            Where-Object Name -eq 'chartScores')
        $narrowSpan = $narrow.To.Column - $narrow.From.Column
        Close-ExcelPackage $package -NoSave

        $narrowSpan | Should -BeLessOrEqual 10

        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs -ChartWidth 1200 -ChartHeight 700 -Reset
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $wide = ($package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartScores')
            ($wide.To.Column - $wide.From.Column) | Should -BeGreaterThan $narrowSpan
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'sets up the page so the charts actually come out in a PDF export' {
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $settings = $package.Workbook.Worksheets['Dashboard'].PrinterSettings

            $settings.Orientation | Should -Be 'Landscape'
            $settings.PaperSize   | Should -Be 'A4'
            $settings.FitToPage   | Should -BeTrue
            $settings.FitToWidth  | Should -Be 1
            # 0 = as many pages tall as needed. 1 would squeeze every chart onto one page.
            $settings.FitToHeight | Should -Be 0

            # Charts are drawings anchored to cells, so they print only if those cells are
            # inside the print area - without this the export is blank pages.
            $settings.PrintArea.Address | Should -Match '\$A\$1:\$[A-Z]+\$\d+'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }
    It 'repositions existing charts when a new measurement is inserted mid-list' {
        # This is how PolicyCompliance was added: not appended, but slotted in among the
        # existing specs. Every later slot shifts, and without repositioning the new chart is
        # drawn exactly on top of whichever chart already held that row - invisible, with
        # nothing to say it happened.
        $rows = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            foreach ($name in 'A', 'B', 'C', 'D') {
                Add-MsecExcelRow -Path $Book -WorksheetName $name -TableName "tbl$name" `
                    -Row ([pscustomobject]@{ RunUtc = 'd1'; Value = 1 }) | Out-Null
            }
            $spec = {
                param($sheet)
                [pscustomobject]@{ Sheet = $sheet; Table = "tbl$sheet"; XColumn = 'RunUtc'
                                   Title = $sheet; Series = @('Value') }
            }

            Add-MsecExcelDashboard -Path $Book -Chart @((& $spec 'A'), (& $spec 'B'), (& $spec 'C'))
            # 'D' inserted BEFORE 'C', so C's slot moves from 2 to 3.
            Add-MsecExcelDashboard -Path $Book -Chart @((& $spec 'A'), (& $spec 'B'), (& $spec 'D'), (& $spec 'C'))
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $charts = @($package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -like 'chart?')
            $positions = @($charts | ForEach-Object { $_.From.Row })

            $charts.Count | Should -Be 4
            @($positions | Sort-Object -Unique).Count | Should -Be 4    # no two stacked

            # C moved down a band to make room for D, rather than D landing on top of C.
            $band = ($charts | Where-Object Name -eq 'chartB').From.Row -
                    ($charts | Where-Object Name -eq 'chartA').From.Row
            ($charts | Where-Object Name -eq 'chartD').From.Row | Should -Be (2 + 2 * $band)
            ($charts | Where-Object Name -eq 'chartC').From.Row | Should -Be (2 + 3 * $band)
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'adds a series for a column that appeared after the chart was drawn' {
        # These sheets grow a column whenever the estate does - a new Azure subscription, a new
        # Secure Score category, a new policy initiative. Without this the column lands on the
        # data sheet while the chart silently keeps plotting only what existed the day it was
        # first drawn, so the report quietly under-reports the estate.
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs

            # A third subscription turns up.
            Add-MsecExcelRow -Path $Book -WorksheetName 'AzureSecureScore' -TableName 'tblAzureSecureScore' `
                -Row ([pscustomobject]@{ RunUtc = 'd4'; PROD = 44; SANDBOX = 24; NEWSUB = 10 }) -WarningAction SilentlyContinue | Out-Null

            $grown = @(
                $Specs[0]
                [pscustomobject]@{ Sheet = 'AzureSecureScore'; Table = 'tblAzureSecureScore'
                                   XColumn = 'RunUtc'; Title = 'Azure'; Series = @('PROD', 'SANDBOX', 'NEWSUB') }
            )
            Add-MsecExcelDashboard -Path $Book -Chart $grown
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $chart = $package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartAzureSecureScore'
            @($chart.Series | ForEach-Object { $_.Header }) | Should -Contain 'NEWSUB'
            @($chart.Series).Count | Should -Be 3

            # Every series spans the full row range, the newcomer included.
            foreach ($series in $chart.Series) {
                $series.Series | Should -Match '\$5$'
            }
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'keeps growing the range of a series this run did not produce' {
        # A subscription that dropped out of the Az context. Its column stays on the sheet
        # (Write-MsecExcelSheet takes the UNION, so history is never dropped), and its series
        # must keep spanning the sheet - otherwise the line stops dead at the row count it had
        # when it was last collected, which reads as the data ending rather than the
        # subscription leaving.
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs

            Add-MsecExcelRow -Path $Book -WorksheetName 'AzureSecureScore' -TableName 'tblAzureSecureScore' `
                -Row ([pscustomobject]@{ RunUtc = 'd4'; PROD = 44; SANDBOX = 24 }) | Out-Null

            # SANDBOX is gone from this run's spec, the way a vanished subscription would be.
            $shrunk = @(
                $Specs[0]
                [pscustomobject]@{ Sheet = 'AzureSecureScore'; Table = 'tblAzureSecureScore'
                                   XColumn = 'RunUtc'; Title = 'Azure'; Series = @('PROD') }
            )
            Add-MsecExcelDashboard -Path $Book -Chart $shrunk
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $chart = $package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartAzureSecureScore'
            # Not removed - the history it plots is still real.
            @($chart.Series | ForEach-Object { $_.Header }) | Should -Contain 'SANDBOX'

            $sandbox = $chart.Series | Where-Object Header -eq 'SANDBOX'
            $prod    = $chart.Series | Where-Object Header -eq 'PROD'
            $sandbox.Series | Should -Match '\$5$'
            $prod.Series    | Should -Match '\$5$'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'leaves no gap for a measurement that has not succeeded yet' {
        # 'Email' has no sheet, so its chart cannot be drawn - and it must cost NOTHING. The
        # earlier design reserved a slot for it, which on a workbook holding one measurement
        # meant the only chart sat several blank pages down the dashboard.
        $withGap = @(
            $script:Specs[0]
            [pscustomobject]@{ Sheet = 'Email'; Table = 'tblEmail'; XColumn = 'RunUtc'; Title = 'Email'; Series = @('Phishing') }
            $script:Specs[1]
        )

        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $withGap } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $dashboard = $package.Workbook.Worksheets['Dashboard']
            @($dashboard.Drawings).Count | Should -Be 2
            @($dashboard.Drawings | Where-Object Name -eq 'chartEmail').Count | Should -Be 0

            # Slot 1, not slot 2: AzureSecureScore sits directly under Scores, with Email's
            # empty place collapsed rather than printed as a blank page.
            $scores = ($dashboard.Drawings | Where-Object Name -eq 'chartScores').From.Row
            $azure  = ($dashboard.Drawings | Where-Object Name -eq 'chartAzureSecureScore').From.Row
            $scores | Should -Be 2

            # One band apart, whatever the band works out to.
            $gap = $azure - $scores
            $gap | Should -BeGreaterThan 0
            $gap | Should -BeLessThan 40      # one band, not two
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'pushes later charts down when a new measurement lands, without overlapping' {
        # The accepted cost of packing densely, pinned so it stays a one-off move rather than
        # turning into charts drawn on top of each other.
        $withGap = @(
            $script:Specs[0]
            [pscustomobject]@{ Sheet = 'Email'; Table = 'tblEmail'; XColumn = 'RunUtc'; Title = 'Email'; Series = @('Phishing') }
            $script:Specs[1]
        )

        $before = InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $withGap } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
            $p = Open-ExcelPackage -Path $Book
            $row = ($p.Workbook.Worksheets['Dashboard'].Drawings | Where-Object Name -eq 'chartAzureSecureScore').From.Row
            Close-ExcelPackage $p -NoSave
            $row
        }

        # Now Email succeeds for the first time, taking the slot between the two.
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $withGap } {
            param($Book, $Specs)
            Add-MsecExcelRow -Path $Book -WorksheetName 'Email' -TableName 'tblEmail' `
                -Row ([pscustomobject]@{ RunUtc = 'd1'; Phishing = 3 }) | Out-Null
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $drawings = $package.Workbook.Worksheets['Dashboard'].Drawings
            @($drawings).Count | Should -Be 3

            $rows = @($drawings | ForEach-Object { $_.From.Row })
            # Every chart on its own row - the failure this guards is two charts sharing one,
            # where the lower is invisible.
            @($rows | Select-Object -Unique).Count | Should -Be 3

            $scores = ($drawings | Where-Object Name -eq 'chartScores').From.Row
            $email  = ($drawings | Where-Object Name -eq 'chartEmail').From.Row
            $azure  = ($drawings | Where-Object Name -eq 'chartAzureSecureScore').From.Row

            # Canonical ORDER is still the caller's, even though spacing is not.
            $scores | Should -BeLessThan $email
            $email  | Should -BeLessThan $azure
            # And the newcomer pushed the last one down rather than landing on it.
            $azure  | Should -BeGreaterThan $before
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'repositions a chart whose columns were not discovered this run' {
        # The partial-run trap. A spec whose series are DISCOVERED from the data - one column
        # per subscription, per initiative, per Secure Score category - carries an EMPTY series
        # list on a run that did not collect that measurement. If an empty list made the whole
        # spec be skipped, the chart would keep the row it was drawn at while every slot around
        # it moved, and the next chart would be drawn straight on top of it.
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            Add-MsecExcelDashboard -Path $Book -Chart $Specs
        }

        # Displace it, the way inserting a new measurement ahead of it would.
        $package = Open-ExcelPackage -Path $script:Book
        ($package.Workbook.Worksheets['Dashboard'].Drawings |
            Where-Object Name -eq 'chartAzureSecureScore').SetPosition(500, 0, 0, 0)
        Close-ExcelPackage $package

        # Now a run that collected only Scores: the Azure spec knows no columns at all.
        InModuleScope Msec -Parameters @{ Book = $script:Book; Specs = $script:Specs } {
            param($Book, $Specs)
            $partial = @(
                $Specs[0]
                [pscustomobject]@{ Sheet = 'AzureSecureScore'; Table = 'tblAzureSecureScore'
                                   XColumn = 'RunUtc'; Title = 'Azure'; Series = @() }
            )
            Add-MsecExcelDashboard -Path $Book -Chart $partial
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $drawings = $package.Workbook.Worksheets['Dashboard'].Drawings
            $scores = ($drawings | Where-Object Name -eq 'chartScores').From.Row
            $azure  = ($drawings | Where-Object Name -eq 'chartAzureSecureScore').From.Row

            $azure | Should -Not -Be 500                 # back in its slot
            $azure | Should -BeGreaterThan $scores       # and below the chart before it

            # Its series are untouched: this run knew nothing about its columns, so it had
            # nothing to say about them.
            $series = $drawings | Where-Object Name -eq 'chartAzureSecureScore' |
                ForEach-Object { $_.Series } | ForEach-Object { $_.Header }
            @($series) | Should -Be @('PROD', 'SANDBOX')
        }
        finally { Close-ExcelPackage $package -NoSave }
    }
}

Describe 'Export-MsecPostureReport' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant-1'; ClientId = 'client'; KeyVaultName = 'kv'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-report-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'trims Secure Score to its newest snapshot rather than appending 90 days of history' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecSecureScore -MockWith {
                [pscustomobject]@{ ScoreType = 'Overall'; Date = [datetime]'2026-08-01'; ScorePercent = 50 }
                [pscustomobject]@{ ScoreType = 'Overall'; Date = [datetime]'2026-08-15'; ScorePercent = 55 }
                [pscustomobject]@{ ScoreType = 'Overall'; Date = [datetime]'2026-08-27'; ScorePercent = 61 }
                [pscustomobject]@{ ScoreType = 'Identity'; Date = [datetime]'2026-08-27'; ScorePercent = 70 }
            }
            Mock Get-MsecDefenderScoreExposure -MockWith { [pscustomobject]@{ ScorePercent = 29 } }
            Mock Get-MsecDefenderScoreDeviceConfiguration -MockWith { [pscustomobject]@{ Score = 412 } }

            Export-MsecPostureReport -Path $Book -Measurement Scores, SecureScoreByCategory `
                                     -WarningAction SilentlyContinue | Out-Null
        }

        $scores = @(Import-Excel -Path $script:Book -WorksheetName 'Scores')
        $scores.Count | Should -Be 1
        $scores[0].SecureScorePercent       | Should -Be 61      # newest, not 50 or 55
        $scores[0].ExposurePercent          | Should -Be 29
        $scores[0].DeviceConfigurationScore | Should -Be 412
        $scores[0].TenantId                 | Should -Be 'tenant-1'

        (Import-Excel -Path $script:Book -WorksheetName 'SecureScoreByCategory').Identity | Should -Be 70
    }

    It 'gives Azure Secure Score one column per subscription, not a tenant-wide average' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureSecureScore -MockWith {
                [pscustomobject]@{ ScoreType = 'Overall'; SubscriptionId = 'aaaaaaaa-1111-2222-3333-444444444444'; SubscriptionName = 'PROD';    ScorePercent = 72 }
                [pscustomobject]@{ ScoreType = 'Overall'; SubscriptionId = 'bbbbbbbb-1111-2222-3333-444444444444'; SubscriptionName = 'SANDBOX'; ScorePercent = 31 }
                # A control-level row, which must not become a column of its own.
                [pscustomobject]@{ ScoreType = 'EnableMFA'; SubscriptionId = 'aaaaaaaa-1111-2222-3333-444444444444'; SubscriptionName = 'PROD'; ScorePercent = 90 }
            }

            Export-MsecPostureReport -Path $Book -Measurement AzureSecureScore -WarningAction SilentlyContinue | Out-Null
        }

        $azure = @(Import-Excel -Path $script:Book -WorksheetName 'AzureSecureScore')
        $azure.Count | Should -Be 1
        $azure[0].PROD    | Should -Be 72
        $azure[0].SANDBOX | Should -Be 31
        # Averaging 72 and 31 to 51.5 would describe neither subscription.
        $azure[0].PSObject.Properties.Name | Should -Not -Contain 'AzureSecureScorePercent'
        $azure[0].PSObject.Properties.Name | Should -Not -Contain 'EnableMFA'
    }

    It 'disambiguates two subscriptions that share a name instead of losing one' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureSecureScore -MockWith {
                [pscustomobject]@{ ScoreType = 'Overall'; SubscriptionId = 'aaaaaaaa-1111-2222-3333-444444444444'; SubscriptionName = 'Cloud Subscription'; ScorePercent = 40 }
                [pscustomobject]@{ ScoreType = 'Overall'; SubscriptionId = 'bbbbbbbb-1111-2222-3333-444444444444'; SubscriptionName = 'Cloud Subscription'; ScorePercent = 80 }
            }
            Export-MsecPostureReport -Path $Book -Measurement AzureSecureScore -WarningAction SilentlyContinue | Out-Null
        }

        $azure = @(Import-Excel -Path $script:Book -WorksheetName 'AzureSecureScore')
        $columns = @($azure[0].PSObject.Properties.Name)

        # Both survive: the second is suffixed with the leading octet of its id.
        $azure[0].'Cloud Subscription' | Should -Be 40
        ($columns | Where-Object { $_ -like 'Cloud Subscription*' }).Count | Should -Be 2
        $columns | Should -Contain 'Cloud Subscription (bbbbbbbb)'
    }

    It 'passes -Subscription through to Get-MsecAzureSecureScore as resolved ids' {
        $seen = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Resolve-MsecSubscription -MockWith { @('aaaaaaaa-1111-2222-3333-444444444444') }
            $captured = @{}
            Mock Get-MsecAzureSecureScore -MockWith {
                $captured['Ids'] = $SubscriptionId
                [pscustomobject]@{ ScoreType = 'Overall'; SubscriptionId = 'aaaaaaaa-1111-2222-3333-444444444444'; SubscriptionName = 'PROD'; ScorePercent = 72 }
            }

            Export-MsecPostureReport -Path $Book -Measurement AzureSecureScore `
                                     -Subscription 'PROD' -WarningAction SilentlyContinue | Out-Null
            $captured
        }

        $seen['Ids'] | Should -Be @('aaaaaaaa-1111-2222-3333-444444444444')
    }

    It 'fails loudly on an unresolvable subscription rather than logging it as unavailable' {
        # A typo in a subscription name must not read as "Azure Secure Score was not
        # licensed on this tenant", which is what a per-measurement catch would make of it.
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Resolve-MsecSubscription -MockWith { throw "No subscription matched 'PRDO'." }

            { Export-MsecPostureReport -Path $Book -Measurement AzureSecureScore -Subscription 'PRDO' } |
                Should -Throw "*PRDO*"
        }
    }

    It 'appends one row per run, so three runs leave three rows' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:Pct = 60
            Mock Get-MsecSecureScore -MockWith {
                $script:Pct += 2
                [pscustomobject]@{ ScoreType = 'Overall'; Date = [datetime]'2026-08-27'; ScorePercent = $script:Pct }
            }
            Mock Get-MsecDefenderScoreExposure -MockWith { }
            Mock Get-MsecDefenderScoreDeviceConfiguration -MockWith { }

            1..3 | ForEach-Object {
                Export-MsecPostureReport -Path $Book -Measurement Scores -WarningAction SilentlyContinue
            }
        }

        $scores = @(Import-Excel -Path $script:Book -WorksheetName 'Scores')
        $scores.Count | Should -Be 3
        $scores.SecureScorePercent | Should -Be @(62, 64, 66)
    }

    It 'keeps going when one measurement throws, and records it in RunLog' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecSecureScore -MockWith {
                [pscustomobject]@{ ScoreType = 'Overall'; Date = [datetime]'2026-08-27'; ScorePercent = 61 }
            }
            Mock Get-MsecDefenderScoreExposure -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            Mock Get-MsecDefenderScoreDeviceConfiguration -MockWith { }
            Mock Get-MsecDefenderIncidentStats -MockWith { throw 'no Defender licence' }

            Export-MsecPostureReport -Path $Book -Measurement Scores, Incidents `
                                     -WarningAction SilentlyContinue | Out-Null
        }

        # The score row still landed, minus the exposure figure.
        $scores = @(Import-Excel -Path $script:Book -WorksheetName 'Scores')
        $scores.Count | Should -Be 1
        $scores[0].SecureScorePercent | Should -Be 61
        $scores[0].ExposurePercent    | Should -BeNullOrEmpty

        # The failed measurement contributed NO row rather than a fabricated zero.
        { Import-Excel -Path $script:Book -WorksheetName 'Incidents' -ErrorAction Stop } | Should -Throw

        $log = @(Import-Excel -Path $script:Book -WorksheetName 'RunLog')
        ($log | Where-Object Source -eq 'Get-MsecDefenderScoreExposure').Status | Should -Be 'Failed'
        ($log | Where-Object Source -eq 'Get-MsecDefenderIncidentStats').Message | Should -Match 'licence'
        ($log | Where-Object Source -eq 'Get-MsecSecureScore').Status | Should -Be 'Succeeded'
    }

    It 'skips policy compliance when the Az context is on a different tenant' {
        # The multi-tenant loop this report invites: Connect-Msec per tenant, export per
        # tenant. Connect-Msec does not move the Az context, so without this guard tenant B's
        # workbook gets tenant A's policy numbers - plausible, wrong, and in a compliance report.
        $result = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'other-tenant' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith { throw 'must not be called' }

            Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        ($result -join ' ') | Should -Match 'WRONG TENANT'
        ($result -join ' ') | Should -Match 'Select-MsecAzureContext'

        # No sheet at all - a gap in the chart, not a wrong number.
        { Import-Excel -Path $script:Book -WorksheetName 'PolicyCompliance' -ErrorAction Stop } | Should -Throw

        # ...and the reason is recorded, so a missing column is explainable months later.
        $log = @(Import-Excel -Path $script:Book -WorksheetName 'RunLog')
        ($log | Where-Object Source -like '*Policy/Compliance*').Status | Should -Be 'Skipped'
    }

    It 'collects policy compliance when the Az context matches the session tenant' {
        $columns = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            # Same tenant as the session set up in BeforeEach.
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Initiative = 'NIS2'; CompliantResources = 8; Resources = 10 }
            }
            Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance -WarningAction SilentlyContinue | Out-Null
            @((Import-Excel -Path $Book -WorksheetName 'PolicyCompliance')[0].PSObject.Properties.Name)
        }

        $columns | Should -Contain 'NIS2'
    }

    It 'weights policy compliance by resources rather than averaging the percentages' {
        $row = InModuleScope Msec {
            # Matches the session tenant, so the wrong-tenant guard lets it through.
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                # Same initiative in two subscriptions of very different size.
                [pscustomobject]@{ Initiative = 'CIS Benchmark'; SubscriptionName = 'PROD'
                                   CompliantResources = 100; Resources = 400 }   # 25%
                [pscustomobject]@{ Initiative = 'CIS Benchmark'; SubscriptionName = 'SANDBOX'
                                   CompliantResources = 4;   Resources = 4 }     # 100%
            }
            @(Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance `
                -PassThru -WarningAction SilentlyContinue)[0].Row
        } -Parameters @{ Book = $script:Book }

        # 104 compliant of 404 graded = 25.74%.
        # Averaging the two percentages would give 62.5 - a number matching neither
        # subscription, and one that a four-resource sandbox can swing at will.
        $row.'CIS Benchmark' | Should -Be 25.74
    }

    It 'orders initiative columns by how much of the estate they grade' {
        $columns = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            # Matches the session tenant, so the wrong-tenant guard lets it through.
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Initiative = 'Small';  CompliantResources = 1;  Resources = 2 }
                [pscustomobject]@{ Initiative = 'Broad';  CompliantResources = 50; Resources = 900 }
                [pscustomobject]@{ Initiative = 'Medium'; CompliantResources = 10; Resources = 40 }
                # Grades nothing, so it is not a column at all - an empty line on the chart
                # says less than no line.
                [pscustomobject]@{ Initiative = 'Unused'; CompliantResources = 0;  Resources = 0 }
            }
            Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance -WarningAction SilentlyContinue | Out-Null
            @((Import-Excel -Path $Book -WorksheetName 'PolicyCompliance')[0].PSObject.Properties.Name)
        }

        # Widest coverage leftmost, so the first chart series is the one grading most.
        $initiatives = @($columns | Where-Object { $_ -notin 'RunUtc', 'TenantId' })
        $initiatives | Should -Be @('Broad', 'Medium', 'Small')
        $initiatives | Should -Not -Contain 'Unused'
    }

    It 'filters initiatives by wildcard' {
        $columns = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            # Matches the session tenant, so the wrong-tenant guard lets it through.
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Initiative = 'CIS Benchmark v2';   CompliantResources = 5; Resources = 10 }
                [pscustomobject]@{ Initiative = 'Tagging standards';  CompliantResources = 5; Resources = 10 }
            }
            Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance `
                -PolicyInitiative '*Benchmark*' -WarningAction SilentlyContinue | Out-Null
            @((Import-Excel -Path $Book -WorksheetName 'PolicyCompliance')[0].PSObject.Properties.Name)
        }

        $columns | Should -Contain 'CIS Benchmark v2'
        $columns | Should -Not -Contain 'Tagging standards'
    }

    It 'warns per pattern that matched nothing, and names what was actually in scope' {
        # Three standards asked for, two assigned. Silently returning two columns would read
        # as "SOC 2 has no data" rather than "SOC 2 is not assigned, or is called something
        # else here".
        $warnings = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            # Matches the session tenant, so the wrong-tenant guard lets it through.
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Initiative = 'ISO 27001:2013'; CompliantResources = 5; Resources = 10 }
                [pscustomobject]@{ Initiative = 'NIS2';           CompliantResources = 8; Resources = 10 }
            }
            Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance `
                -PolicyInitiative '*NIS2*', '*SOC*', '*27001*' `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        $text = $warnings -join ' '
        $text | Should -Match "No policy initiative matches '\*SOC\*'"
        $text | Should -Match 'ISO 27001:2013'          # says what IS there
        $text | Should -Not -Match "matches '\*NIS2\*'"  # the two that hit stay quiet
        $text | Should -Not -Match "matches '\*27001\*'"

        # ...and the two that matched still produce their columns.
        $columns = @((Import-Excel -Path $script:Book -WorksheetName 'PolicyCompliance')[0].PSObject.Properties.Name)
        $columns | Should -Contain 'NIS2'
        $columns | Should -Contain 'ISO 27001:2013'
    }

    It 'warns rather than silently drawing an unreadable chart when many initiatives are in scope' {
        $warnings = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            # Matches the session tenant, so the wrong-tenant guard lets it through.
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                1..10 | ForEach-Object {
                    [pscustomobject]@{ Initiative = "Initiative $_"; CompliantResources = 1; Resources = 2 }
                }
            }
            Export-MsecPostureReport -Path $Book -Measurement PolicyCompliance `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        ($warnings -join ' ') | Should -Match '10 policy initiatives'
        ($warnings -join ' ') | Should -Match '-PolicyInitiative'
    }

    It 'aggregates Intune compliance from the per-device rows' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecIntuneDevice -MockWith {
                [pscustomobject]@{ Id = 'a'; ComplianceState = 'compliant';     IsEncrypted = $true }
                [pscustomobject]@{ Id = 'b'; ComplianceState = 'compliant';     IsEncrypted = $true }
                [pscustomobject]@{ Id = 'c'; ComplianceState = 'noncompliant';  IsEncrypted = $false }
                [pscustomobject]@{ Id = 'd'; ComplianceState = 'inGracePeriod'; IsEncrypted = $true }
            }
            Export-MsecPostureReport -Path $Book -Measurement DeviceCompliance -WarningAction SilentlyContinue | Out-Null
        }

        $devices = @(Import-Excel -Path $script:Book -WorksheetName 'DeviceCompliance')
        $devices[0].TotalDevices  | Should -Be 4
        $devices[0].Compliant     | Should -Be 2
        $devices[0].Noncompliant  | Should -Be 1
        $devices[0].InGracePeriod | Should -Be 1
        $devices[0].Encrypted     | Should -Be 3
        # Out of ALL enrolled devices - counting the grace-period one out of the denominator
        # would flatter the number exactly where it matters.
        $devices[0].CompliantPercent | Should -Be 50
    }

    It 'counts privileged people, not privileged assignments' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraRoleHolder -MockWith {
                # One person, three roles. Counting rows would call this three administrators.
                [pscustomobject]@{ EffectiveId = 'u1'; EffectiveType = 'user'; RoleName = 'Global Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                [pscustomobject]@{ EffectiveId = 'u1'; EffectiveType = 'user'; RoleName = 'Security Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                [pscustomobject]@{ EffectiveId = 'u1'; EffectiveType = 'user'; RoleName = 'Exchange Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                # A second, genuinely different person.
                [pscustomobject]@{ EffectiveId = 'u2'; EffectiveType = 'user'; RoleName = 'Global Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                # Holds a role, but not a privileged one - in AllRoleAssignments and nothing else.
                [pscustomobject]@{ EffectiveId = 'u3'; EffectiveType = 'user'; RoleName = 'Message Center Reader'
                                   IsHighlyPrivileged = $false; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
            }
            Export-MsecPostureReport -Path $Book -Measurement PrivilegedAccess -WarningAction SilentlyContinue | Out-Null
        }

        $row = @(Import-Excel -Path $script:Book -WorksheetName 'PrivilegedAccess')[0]
        $row.StandingPrivileged | Should -Be 2   # people, not the 4 privileged rows
        $row.GlobalAdminHolders | Should -Be 2
        # Both totals are still carried, so the ratio between them stays checkable.
        $row.PrivilegedAssignments | Should -Be 4
        $row.AllRoleAssignments    | Should -Be 5
    }

    It 'splits standing privilege from PIM-eligible, counting someone with both in each' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraRoleHolder -MockWith {
                [pscustomobject]@{ EffectiveId = 'u1'; EffectiveType = 'user'; RoleName = 'Global Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                # Same person, also eligible. Standing access they never have to activate for
                # plus an eligible assignment is a real state, and belongs in both counts.
                [pscustomobject]@{ EffectiveId = 'u1'; EffectiveType = 'user'; RoleName = 'Security Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Eligible'; AccountEnabled = $true; IsResolved = $true }
                [pscustomobject]@{ EffectiveId = 'u2'; EffectiveType = 'user'; RoleName = 'Security Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Eligible'; AccountEnabled = $true; IsResolved = $true }
            }
            Export-MsecPostureReport -Path $Book -Measurement PrivilegedAccess -WarningAction SilentlyContinue | Out-Null
        }

        $row = @(Import-Excel -Path $script:Book -WorksheetName 'PrivilegedAccess')[0]
        $row.StandingPrivileged | Should -Be 1
        $row.EligiblePrivileged | Should -Be 2
    }

    It 'separates the holders no MFA or PIM policy covers' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraRoleHolder -MockWith {
                [pscustomobject]@{ EffectiveId = 'u1'; EffectiveType = 'user'; UserType = 'Member'; RoleName = 'Global Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                [pscustomobject]@{ EffectiveId = 'g1'; EffectiveType = 'user'; UserType = 'Guest'; RoleName = 'Global Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                [pscustomobject]@{ EffectiveId = 'sp1'; EffectiveType = 'servicePrincipal'; RoleName = 'Application Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $true; IsResolved = $true }
                # Cannot sign in today, but the assignment survives the account being re-enabled.
                [pscustomobject]@{ EffectiveId = 'u2'; EffectiveType = 'user'; UserType = 'Member'; RoleName = 'Security Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; AccountEnabled = $false; IsResolved = $true }
                # Graph would not name this one - privilege nobody is reviewing.
                [pscustomobject]@{ EffectiveId = 'x1'; EffectiveType = 'unknown'; RoleName = 'Security Administrator'
                                   IsHighlyPrivileged = $true; AssignmentType = 'Active'; IsResolved = $false }
            }
            Export-MsecPostureReport -Path $Book -Measurement PrivilegedAccess -WarningAction SilentlyContinue | Out-Null
        }

        $row = @(Import-Excel -Path $script:Book -WorksheetName 'PrivilegedAccess')[0]
        $row.PrivilegedGuests            | Should -Be 1
        $row.PrivilegedServicePrincipals | Should -Be 1
        $row.PrivilegedDisabled          | Should -Be 1
        $row.UnresolvedHolders           | Should -Be 1
    }

    It 'contributes no row rather than a row of zeroes when role holders cannot be read' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraRoleHolder -MockWith { throw 'Forbidden' }
            Export-MsecPostureReport -Path $Book -Measurement PrivilegedAccess -WarningAction SilentlyContinue | Out-Null
        }

        # A fabricated zero would read as 'no administrators', which is the one conclusion
        # a failed read must never support. The gap in the chart is the honest answer.
        @(Open-ExcelPackage -Path $script:Book | ForEach-Object { $_.Workbook.Worksheets.Name }) |
            Should -Not -Contain 'PrivilegedAccess'
        @(Import-Excel -Path $script:Book -WorksheetName 'RunLog')[0].Source | Should -Be 'Get-MsecEntraRoleHolder'
    }

    It 'writes a Target column and plots it, only on the sheets named' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraMfaRegistrationStats -MockWith {
                [pscustomobject]@{ TotalUsers = 100; MfaCapable = 87; MfaCapablePercent = 87 }
            }
            Mock Get-MsecDefenderIncidentStats -MockWith {
                [pscustomobject]@{ TotalCreated = 12; High = 1; Medium = 4; Low = 7; Informational = 0 }
            }
            Export-MsecPostureReport -Path $Book -Measurement MfaCoverage, Incidents `
                -Target @{ MfaCoverage = 95 } -WarningAction SilentlyContinue | Out-Null
        }

        # The named sheet carries the constant, which is what Excel draws as a flat line.
        (Import-Excel -Path $script:Book -WorksheetName 'MfaCoverage').Target | Should -Be 95

        # The sheet NOT named is untouched - no column, so no extra series and no clutter.
        @((Import-Excel -Path $script:Book -WorksheetName 'Incidents')[0].PSObject.Properties.Name) |
            Should -Not -Contain 'Target'

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $dashboard = $package.Workbook.Worksheets['Dashboard']
            $mfa = $dashboard.Drawings | Where-Object Name -eq 'chartMfaCoverage'
            $incidents = $dashboard.Drawings | Where-Object Name -eq 'chartIncidents'

            # Target is LAST, so it takes the final theme colour and reads as an annotation.
            @($mfa.Series)[-1].Header | Should -Be 'Target'
            @($incidents.Series | ForEach-Object { $_.Header }) | Should -Not -Contain 'Target'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'records a raised target as a step rather than rewriting the earlier rows' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraMfaRegistrationStats -MockWith {
                [pscustomobject]@{ TotalUsers = 100; MfaCapable = 87; MfaCapablePercent = 87 }
            }
            Export-MsecPostureReport -Path $Book -Measurement MfaCoverage -Target @{ MfaCoverage = 90 } -WarningAction SilentlyContinue | Out-Null
            Export-MsecPostureReport -Path $Book -Measurement MfaCoverage -Target @{ MfaCoverage = 95 } -WarningAction SilentlyContinue | Out-Null
        }

        # Stored per row, so "we moved the bar" is visible in the chart. A single stored
        # constant would have silently restated the old months at the new target.
        @((Import-Excel -Path $script:Book -WorksheetName 'MfaCoverage').Target) | Should -Be @(90, 95)
    }

    It 'warns when -Target names a sheet that does not exist' {
        $warnings = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraMfaRegistrationStats -MockWith {
                [pscustomobject]@{ TotalUsers = 100; MfaCapablePercent = 87 }
            }
            Export-MsecPostureReport -Path $Book -Measurement MfaCoverage `
                -Target @{ MfaCoverge = 95 } `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        # A typo would otherwise be a target that silently never appears.
        ($warnings -join ' ') | Should -Match "'MfaCoverge'"
        ($warnings -join ' ') | Should -Match 'MfaCoverage'      # names the real ones
    }

    It 'honours -WhatIf without creating the workbook' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecSecureScore -MockWith {
                [pscustomobject]@{ ScoreType = 'Overall'; Date = [datetime]'2026-08-27'; ScorePercent = 61 }
            }
            Mock Get-MsecDefenderScoreExposure -MockWith { }
            Mock Get-MsecDefenderScoreDeviceConfiguration -MockWith { }

            Export-MsecPostureReport -Path $Book -Measurement Scores -WhatIf -WarningAction SilentlyContinue
        }

        Test-Path $script:Book | Should -BeFalse
    }

    It 'records the look-back window alongside the counts it describes' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecDefenderIncidentStats -MockWith {
                [pscustomobject]@{ TotalCreated = 12; High = 1; Medium = 4; Low = 7; Informational = 0; CurrentlyOpen = 3 }
            }
            Export-MsecPostureReport -Path $Book -Measurement Incidents -Days 7 -WarningAction SilentlyContinue | Out-Null
        }

        $incidents = @(Import-Excel -Path $script:Book -WorksheetName 'Incidents')
        $incidents[0].WindowDays   | Should -Be 7
        $incidents[0].TotalCreated | Should -Be 12
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Export-MsecPostureReport -Path './nope.xlsx' } | Should -Throw '*Connect-Msec*'
        }
    }
}
