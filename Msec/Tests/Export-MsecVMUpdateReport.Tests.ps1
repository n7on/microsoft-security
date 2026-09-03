#Requires -Module Pester
#
# Tests for Export-MsecVMUpdateReport and the worksheet-name sanitiser under it.
#
# This is an EVIDENCE document, not a trend: one row per VM, a fresh file per run, nothing
# appended. So the things worth pinning down are about what the table shows a reviewer:
#
#   * every VM appears, including the ones that could not be reached - evidence that quietly
#     omits the machines it failed on is not evidence
#   * the four assessments stay distinct, because they need different follow-up: Up to date,
#     Stale, No update history, No answer
#   * unparseable output is No answer, never a clean machine
#   * a sheet written twice is REPLACED, since a snapshot has nothing to accumulate
#   * two subscriptions truncating to the same 31 characters must not share a sheet

$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-MsecExcelSheetName' {
    It 'passes a legal name through untouched' {
        InModuleScope Msec {
            ConvertTo-MsecExcelSheetName -Name 'Contoso PROD' | Should -Be 'Contoso PROD'
        }
    }

    It 'strips the characters Excel refuses, and collapses the gap' {
        InModuleScope Msec {
            # Replaced with a space rather than removed, so 'A/B' does not become 'AB'.
            ConvertTo-MsecExcelSheetName -Name 'Contoso: PROD / EU' | Should -Be 'Contoso PROD EU'
            ConvertTo-MsecExcelSheetName -Name 'a[b]c*d?e\f' | Should -Be 'a b c d e f'
        }
    }

    It 'truncates to 31 characters, which is Excel s hard limit' {
        InModuleScope Msec {
            $long = 'Viedoc Production Subscription Northern Europe'
            $name = ConvertTo-MsecExcelSheetName -Name $long
            $name.Length | Should -BeLessOrEqual 31
            $long | Should -BeLike "$name*"
        }
    }

    It 'disambiguates two names that truncate to the same thing' {
        InModuleScope Msec {
            $a = ConvertTo-MsecExcelSheetName -Name 'Contoso Production Platform EU'
            $b = ConvertTo-MsecExcelSheetName -Name 'Contoso Production Platform US' -Existing @($a)

            # Without this the second subscription would overwrite the first's evidence.
            $b | Should -Not -Be $a
            $b.Length | Should -BeLessOrEqual 31
        }
    }

    It 'handles empty and the reserved name' {
        InModuleScope Msec {
            ConvertTo-MsecExcelSheetName -Name ''        | Should -Be 'Subscription'
            ConvertTo-MsecExcelSheetName -Name '   '     | Should -Be 'Subscription'
            ConvertTo-MsecExcelSheetName -Name 'History' | Should -Not -Be 'History'
        }
    }
}

Describe 'Export-MsecVMUpdateReport' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-vm-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'writes one row per VM, including the ones that gave no answer' {
        $rows = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'Contoso PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'fresh';   ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true;  Location = 'westeurope' }
                [pscustomobject]@{ Name = 'stale';   ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true;  Location = 'westeurope' }
                [pscustomobject]@{ Name = 'silent';  ResourceGroupName = 'rg'; Os = 'Linux';   Running = $true;  Location = 'westeurope' }
                [pscustomobject]@{ Name = 'nohist';  ResourceGroupName = 'rg'; Os = 'Linux';   Running = $true;  Location = 'westeurope' }
                [pscustomobject]@{ Name = 'stopped'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $false; Location = 'westeurope' }
            }
            # One result per call: the command pipes VMs in, so Pester invokes the mock per VM.
            Mock Invoke-MsecAzureVMScript -MockWith {
                switch ($Name) {
                    'fresh'  { [pscustomobject]@{ VmName = 'fresh';  Status = 'Succeeded'; Output = '{"DaysSinceUpdate":3,"SecurityPending":0,"RebootRequired":false}' } }
                    'stale'  { [pscustomobject]@{ VmName = 'stale';  Status = 'Succeeded'; Output = '{"DaysSinceUpdate":90,"SecurityPending":7,"RebootRequired":true}' } }
                    'silent' { [pscustomobject]@{ VmName = 'silent'; Status = 'Failed';    Output = $null; Error = 'timed out' } }
                    'nohist' { [pscustomobject]@{ VmName = 'nohist'; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":null,"SecurityPending":2}' } }
                }
            }

            Export-MsecVMUpdateReport -Path $Book -PassThru -WarningAction SilentlyContinue
        }

        # Five VMs in the subscription, five rows - the stopped one was never attempted and is
        # still on the sheet. Leaving it out would be evidence with a hole in it.
        @($rows).Count | Should -Be 5

        $byName = @{}; foreach ($r in $rows) { $byName[$r.VmName] = $r }
        $byName['fresh'].Assessment   | Should -Be 'Up to date'
        $byName['stale'].Assessment   | Should -Be 'Stale'
        $byName['silent'].Assessment  | Should -Be 'No answer'
        $byName['nohist'].Assessment  | Should -Be 'No update history'
        $byName['stopped'].Assessment | Should -Be 'Not running'

        # The reason travels with the row, so a reviewer does not have to ask.
        $byName['silent'].Error | Should -Be 'timed out'
        $byName['stale'].SecurityPending | Should -Be 7
        $byName['stale'].RebootRequired  | Should -BeTrue

        # And it is all on the sheet, not just in the pipeline.
        @(Import-Excel -Path $script:Book -WorksheetName 'Contoso PROD').Count | Should -Be 5
    }

    It 'orders the rows worst first, with the unassessed at the TOP' {
        $names = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'a'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
                [pscustomobject]@{ Name = 'b'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
                [pscustomobject]@{ Name = 'c'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                switch ($Name) {
                    'a' { [pscustomobject]@{ VmName = 'a'; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":10}' } }
                    'b' { [pscustomobject]@{ VmName = 'b'; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":200}' } }
                    'c' { [pscustomobject]@{ VmName = 'c'; Status = 'Failed'; Output = $null } }
                }
            }
            @((Export-MsecVMUpdateReport -Path $Book -PassThru -WarningAction SilentlyContinue).VmName)
        }

        # Ordered by assessment severity: No answer, then Stale, then Up to date. On an
        # evidence table the machines nobody could assess are what a reviewer is hunting for,
        # so they belong at the top rather than buried under a long list of healthy ones.
        #
        # This was the other way round when the chart plotted days per VM and a null must not
        # lead. The chart now counts per assessment, so that constraint is gone.
        $names | Should -Be @('c', 'b', 'a')
    }

    It 'treats unparseable output as no answer rather than as a clean machine' {
        $row = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'vm1'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                # Azure returns only the last 4096 bytes of stdout; a clipped JSON object
                # arrives as an unparseable string. Zeros would read as a patched machine.
                [pscustomobject]@{ VmName = 'vm1'; Status = 'Succeeded'; Output = '{"DaysSince' }
            }
            @(Export-MsecVMUpdateReport -Path $Book -PassThru -WarningAction SilentlyContinue)[0]
        }

        $row.Assessment      | Should -Be 'No answer'
        $row.DaysSinceUpdate | Should -BeNullOrEmpty
    }

    It 'replaces the sheet when the same subscription is written again' {
        $counts = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'PROD'; Id = 'sub-1' } }
            }
            $script:VmCount = 3
            Mock Search-MsecAzureResourceGraph -MockWith {
                1..$script:VmCount | ForEach-Object {
                    [pscustomobject]@{ Name = "vm$_"; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
                }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                [pscustomobject]@{ VmName = $Name; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":5}' }
            }

            Export-MsecVMUpdateReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            $first = @(Import-Excel -Path $Book -WorksheetName 'PROD').Count

            # A VM was decommissioned between collections.
            $script:VmCount = 2
            Export-MsecVMUpdateReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            $second = @(Import-Excel -Path $Book -WorksheetName 'PROD').Count

            @($first, $second)
        }

        # Replaced, not appended: a snapshot of two VMs must not still show the third.
        $counts | Should -Be @(3, 2)
    }

    It 'gives each subscription its own sheet and its own chart in one document' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:Sub = 'PROD'
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = $script:Sub; Id = "sub-$($script:Sub)" } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'vm1'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                [pscustomobject]@{ VmName = 'vm1'; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":5}' }
            }

            foreach ($name in 'PROD', 'TEST', 'DEV') {
                $script:Sub = $name
                Export-MsecVMUpdateReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            }
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $names = @($package.Workbook.Worksheets | ForEach-Object { $_.Name })
            foreach ($name in 'PROD', 'TEST', 'DEV') { $names | Should -Contain $name }
            $names[0] | Should -Be 'Dashboard'

            $dashboard = $package.Workbook.Worksheets['Dashboard']
            @($dashboard.Drawings).Count | Should -Be 3

            # Each chart counts VMs per assessment and reads only its own block of the shared
            # Summary sheet - three subscriptions, five rows each, so PROD is rows 2-6.
            $chart = $dashboard.Drawings | Where-Object Name -eq 'chartPROD'
            $chart.Series[0].Header  | Should -Be 'VMs'
            $chart.Series[0].XSeries | Should -Match 'Summary!'
            $chart.Series[0].Series  | Should -Match 'Summary!'

            # Blocks must not overlap, or one subscription's chart shows another's numbers.
            $ranges = @($dashboard.Drawings | ForEach-Object { $_.Series[0].Series })
            @($ranges | Sort-Object -Unique).Count | Should -Be 3

            # No two charts stacked.
            @(@($dashboard.Drawings | ForEach-Object { $_.From.Row }) | Sort-Object -Unique).Count | Should -Be 3
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'counts every assessment, including the ones with no VMs in them' {
        $summary = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'a'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
                [pscustomobject]@{ Name = 'b'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                [pscustomobject]@{ VmName = $Name; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":5}' }
            }
            Export-MsecVMUpdateReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            @(Import-Excel -Path $Book -WorksheetName 'Summary')
        }

        # All five states present, so the chart has a stable set of categories run to run.
        @($summary).Count | Should -Be 5

        # PowerShell wraps $null into a ONE-element array, so @($counts[$absent]).Count is 1 -
        # which made a two-VM subscription sum to five, with a phantom machine under every
        # empty state.
        ($summary | Where-Object Assessment -eq 'Up to date').VMs | Should -Be 2
        ($summary | Where-Object Assessment -eq 'Stale').VMs      | Should -Be 0
        ($summary | Where-Object Assessment -eq 'No answer').VMs  | Should -Be 0
        (($summary | Measure-Object -Property VMs -Sum).Sum)      | Should -Be 2
    }
    It 'timestamps every sheet, and dates the heading by span not by the last run' {
        $result = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:Sub = 'PROD'
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = $script:Sub; Id = "sub-$($script:Sub)" } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'vm1'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                [pscustomobject]@{ VmName = 'vm1'; Status = 'Succeeded'; Output = '{"DaysSinceUpdate":5}' }
            }

            Export-MsecVMUpdateReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 1        # so the two runs carry different clocks
            $script:Sub = 'TEST'
            Export-MsecVMUpdateReport -Path $Book -WarningAction SilentlyContinue | Out-Null

            $package = Open-ExcelPackage -Path $Book
            $heading = $package.Workbook.Worksheets['Dashboard'].Cells[1, 1].Value
            Close-ExcelPackage $package -NoSave
            $heading
        }

        # Every VM row is stamped...
        (Import-Excel -Path $script:Book -WorksheetName 'PROD').CollectedUtc | Should -Not -BeNullOrEmpty

        # ...and so is the Summary, per subscription block rather than per file. Without this
        # the sheet driving the charts carried no date at all.
        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        $prod = @($summary | Where-Object Subscription -eq 'PROD')
        $test = @($summary | Where-Object Subscription -eq 'TEST')
        $prod[0].CollectedUtc | Should -Not -BeNullOrEmpty
        # The two runs happened at different times, and the sheet says so rather than
        # restating PROD's scan with TEST's clock.
        $prod[0].CollectedUtc | Should -Not -Be $test[0].CollectedUtc

        # The heading reports the span, not just the last run.
        $result | Should -Match 'collected .* to .* UTC'
    }

    It 'throws a clear error with no Azure context' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith { $null }
            { Export-MsecVMUpdateReport -Path $Book } | Should -Throw '*Connect-AzAccount*'
        }
    }
}
