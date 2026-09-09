#Requires -Module Pester
#
# Tests for Export-MsecVMNtpReport.
#
# The shared machinery - sheet naming, snapshot semantics, the Summary sheet, timestamps, the
# dashboard - is exercised by Export-MsecVMUpdateReport.Tests.ps1, since both commands are thin
# wrappers over Write-MsecVMEvidenceWorkbook. What is specific here is the verdict, and the one
# distinction that is easy to get wrong:
#
#   A Windows machine fallen back to Local CMOS Clock reports itself SYNCHRONISED - to its own
#   drifting hardware clock. That is not an unsynchronised machine, it is one pointed at
#   nothing, and the fix is different. Hence 'No time source' as its own verdict.

$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecVMNtpReport' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-ntp-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'separates a machine pointed at nothing from one that is simply not synchronised' {
        $rows = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'Contoso PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'good';    ResourceGroupName = 'rg'; Os = 'Linux';   Running = $true }
                [pscustomobject]@{ Name = 'cmos';    ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
                [pscustomobject]@{ Name = 'drifted'; ResourceGroupName = 'rg'; Os = 'Windows'; Running = $true }
                [pscustomobject]@{ Name = 'silent';  ResourceGroupName = 'rg'; Os = 'Linux';   Running = $true }
                [pscustomobject]@{ Name = 'stopped'; ResourceGroupName = 'rg'; Os = 'Linux';   Running = $false }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                switch ($Name) {
                    'good'    { [pscustomobject]@{ VmName = 'good'; Status = 'Succeeded'; Output = '{"Synchronized":true,"NtpEnabled":true,"Daemon":"systemd-timesyncd","Source":"time.cloudflare.com","Compliant":true,"TimeZone":"UTC","NowUtc":"2026-08-31T10:00:00Z"}' } }
                    # Reports itself synchronised, but to its own hardware clock: the script's
                    # Compliant rule requires a source, so this is NOT compliant.
                    'cmos'    { [pscustomobject]@{ VmName = 'cmos'; Status = 'Succeeded'; Output = '{"Synchronized":true,"NtpEnabled":true,"Daemon":"w32time","Source":"","Compliant":false,"TimeZone":"W. Europe","NowUtc":"2026-08-31T10:00:03Z"}' } }
                    'drifted' { [pscustomobject]@{ VmName = 'drifted'; Status = 'Succeeded'; Output = '{"Synchronized":false,"NtpEnabled":true,"Daemon":"w32time","Source":"time.windows.com","Compliant":false,"TimeZone":"UTC","NowUtc":"2026-08-31T09:47:12Z"}' } }
                    'silent'  { [pscustomobject]@{ VmName = 'silent'; Status = 'Failed'; Output = $null; Error = 'timed out' } }
                }
            }

            Export-MsecVMNtpReport -Path $Book -PassThru -WarningAction SilentlyContinue
        }

        @($rows).Count | Should -Be 5

        $byName = @{}; foreach ($r in $rows) { $byName[$r.VmName] = $r }
        $byName['good'].Assessment    | Should -Be 'Compliant'
        # Synchronised = true, yet not compliant: pointed at nothing.
        $byName['cmos'].Assessment    | Should -Be 'No time source'
        $byName['cmos'].Synchronized  | Should -BeTrue
        $byName['drifted'].Assessment | Should -Be 'Not synchronised'
        $byName['silent'].Assessment  | Should -Be 'No answer'
        $byName['stopped'].Assessment | Should -Be 'Not running'

        # The evidence a reviewer actually reads.
        $byName['good'].Source     | Should -Be 'time.cloudflare.com'
        $byName['good'].Daemon     | Should -Be 'systemd-timesyncd'
        # ConvertFrom-Json turns the ISO-8601 string into a real DateTime, which is what we
        # want in the cell - Excel can sort and format it. Asserted on the instant rather than
        # on the text, since the round-trip changes the rendering but not the value.
        ([datetime] $byName['drifted'].VmClockUtc).ToUniversalTime() |
            Should -Be ([datetime]'2026-08-31T09:47:12Z').ToUniversalTime()
    }

    It 'counts every verdict on the Summary sheet, including the empty ones' {
        $summary = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'a'; ResourceGroupName = 'rg'; Os = 'Linux'; Running = $true }
                [pscustomobject]@{ Name = 'b'; ResourceGroupName = 'rg'; Os = 'Linux'; Running = $true }
            }
            Mock Invoke-MsecAzureVMScript -MockWith {
                [pscustomobject]@{ VmName = $Name; Status = 'Succeeded'; Output = '{"Synchronized":true,"Source":"time.cloudflare.com","Compliant":true}' }
            }
            Export-MsecVMNtpReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            @(Import-Excel -Path $Book -WorksheetName 'Summary')
        }

        # All five categories present, so two runs' charts stay comparable.
        @($summary).Count | Should -Be 5
        ($summary | Where-Object Assessment -eq 'Compliant').VMs        | Should -Be 2
        ($summary | Where-Object Assessment -eq 'No time source').VMs   | Should -Be 0
        (($summary | Measure-Object -Property VMs -Sum).Sum)            | Should -Be 2
    }

    It 'runs ntp-status, not the update script' {
        $scriptName = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Name = 'PROD'; Id = 'sub-1' } }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ Name = 'a'; ResourceGroupName = 'rg'; Os = 'Linux'; Running = $true }
            }
            $captured = @{}
            Mock Invoke-MsecAzureVMScript -MockWith {
                $captured['ScriptName'] = $ScriptName
                [pscustomobject]@{ VmName = 'a'; Status = 'Succeeded'; Output = '{"Compliant":true,"Synchronized":true,"Source":"x"}' }
            }
            Export-MsecVMNtpReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            $captured['ScriptName']
        }

        $scriptName | Should -Be 'ntp-status'
    }

    It 'throws a clear error with no Azure context' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-AzContext -MockWith { $null }
            { Export-MsecVMNtpReport -Path $Book } | Should -Throw '*Connect-AzAccount*'
        }
    }
}
