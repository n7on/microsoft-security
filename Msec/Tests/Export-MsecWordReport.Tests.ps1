#Requires -Module Pester
#
# Tests for Export-MsecWordReport. Verifies the shape-detection dispatch:
#   - VMScript-shaped rows -> per-VM page with Courier New output.
#   - Anything else -> a flat Word table with auto-detected columns.
# The whole file is skipped if PSWriteOffice isn't available (it's an optional
# dep, not declared in msec's RequiredModules).

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecWordReport' -Skip:($null -eq (Get-Module -ListAvailable PSWriteOffice)) {
    It 'detects VMScript-shaped input and produces the per-VM page layout in Courier New' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "msec-report-$([guid]::NewGuid().Guid).docx"
        $unzip = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)

        try {
            $rows = @(
                [pscustomobject]@{
                    VmName='lin-1'; ResourceGroupName='rg-a'; Os='Linux'
                    ScriptName='ntp-status'; Status='Succeeded'
                    Output="hostname:  web-test`nNTP service: active"
                    Error=$null; DurationSeconds=31.6
                }
                [pscustomobject]@{
                    VmName='win-1'; ResourceGroupName='rg-a'; Os='Windows'
                    ScriptName='ntp-status'; Status='Succeeded'
                    Output='W32Time: Running'
                    Error=$null; DurationSeconds=12.4
                }
            )
            $result = $rows | Export-MsecWordReport `
                -Path $tmp -Title 'NTP evidence' -Subtitle 'ISO 27001 A.8.17'

            $result.Exists                | Should -BeTrue
            ($result.Length -gt 0)        | Should -BeTrue

            Expand-Archive -Path $tmp -DestinationPath $unzip
            $xml = Get-Content (Join-Path $unzip 'word/document.xml') -Raw
            $xml | Should -Match 'NTP evidence'
            $xml | Should -Match 'ISO 27001 A.8.17'
            $xml | Should -Match 'lin-1'
            $xml | Should -Match 'win-1'
            $xml | Should -Match 'hostname:  web-test'
            $xml | Should -Match 'W32Time: Running'
            $xml | Should -Match 'Courier New'   # monospace styling applied to script output
        }
        finally {
            Remove-Item -LiteralPath $tmp   -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $unzip -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to a Word table for any other shape and includes every column + cell value' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "msec-report-generic-$([guid]::NewGuid().Guid).docx"
        $unzip = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)

        try {
            # Deliberately NOT VMScript-shaped: no VmName/ScriptName/Output. This is
            # the kind of row you'd get from Get-MsecSecureScore or a hand-built
            # tabular result.
            $rows = @(
                [pscustomobject]@{ Date='2026-04-01'; Score=72; Diff=+3 }
                [pscustomobject]@{ Date='2026-05-01'; Score=78; Diff=+6 }
                [pscustomobject]@{ Date='2026-06-01'; Score=81; Diff=+3 }
            )
            $result = $rows | Export-MsecWordReport -Path $tmp -Title 'Secure Score Trend'

            $result.Exists         | Should -BeTrue
            ($result.Length -gt 0) | Should -BeTrue

            Expand-Archive -Path $tmp -DestinationPath $unzip
            $xml = Get-Content (Join-Path $unzip 'word/document.xml') -Raw

            # Cover-page strings.
            $xml | Should -Match 'Secure Score Trend'
            $xml | Should -Match 'Total rows: 3'

            # Headers + a sample of cell values from every row prove the table contains
            # the data (rather than e.g. silently dropping rows when not VMScript-shaped).
            $xml | Should -Match 'Date'
            $xml | Should -Match 'Score'
            $xml | Should -Match 'Diff'
            $xml | Should -Match '2026-04-01'
            $xml | Should -Match '2026-05-01'
            $xml | Should -Match '2026-06-01'
            $xml | Should -Match '<w:t[^>]*>72</w:t>'
            $xml | Should -Match '<w:t[^>]*>81</w:t>'

            # And specifically NOT the VMScript layout - no Courier-styled paragraphs
            # leaked through.
            $xml | Should -Not -Match 'Courier New'
        }
        finally {
            Remove-Item -LiteralPath $tmp   -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $unzip -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits a warning and produces no file when nothing is piped' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "msec-report-empty-$([guid]::NewGuid().Guid).docx"
        @() | Export-MsecWordReport -Path $tmp -WarningAction SilentlyContinue
        (Test-Path -LiteralPath $tmp) | Should -BeFalse
    }
}
