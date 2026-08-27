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

            # One per row band: every chart starts in column A, 30 rows below the last.
            $charts[0].From.Row | Should -Be 2
            for ($i = 0; $i -lt $charts.Count; $i++) {
                $charts[$i].From.Row    | Should -Be (2 + $i * 30)
                $charts[$i].From.Column | Should -Be 0
            }

            # A page break at the top of every band but the first, so each chart prints on
            # its own page - and no chart straddles one.
            for ($i = 1; $i -lt $charts.Count; $i++) {
                $worksheet.Row(2 + $i * 30).PageBreak | Should -BeTrue
                $charts[$i - 1].To.Row | Should -BeLessThan (2 + $i * 30)
            }
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
            $settings.PrintArea.Address | Should -Match '\$A\$1:\$P\$\d+'
        }
        finally { Close-ExcelPackage $package -NoSave }
    }
    It 'holds a slot for a measurement that has not succeeded yet' {
        # 'Email' has no sheet, so its chart cannot be drawn - but the one after it must
        # still land in its own slot rather than shuffling up into Email's place.
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

            # One chart per 30-row band, so slot 2 is row 2 + 2*30 = 62. If the gap had
            # collapsed, AzureSecureScore would sit at slot 1 (row 32) instead - and would
            # then move again the first time Email succeeded.
            ($dashboard.Drawings | Where-Object Name -eq 'chartAzureSecureScore').From.Row | Should -Be 62
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
