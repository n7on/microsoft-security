#Requires -Module Pester
#
# Tests for Export-MsecDefenderDeviceReport.
#
# The shared writing machinery is exercised by the VM and disabled-account report tests. What
# is specific here is the vulnerability BAND, and the thing that must not be smoothed over:
#
#   Get-MsecDefenderDevice reports $null when the vulnerability export could not be read at
#   all, and 0 when it was read and the device had no findings. Those are different answers.
#   Folding the null into 'None' would report an unmeasured estate as a clean one - the only
#   reading here that is certainly wrong.

$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecDefenderDeviceReport' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant-1'; ClientId = 'client'; KeyVaultName = 'kv'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-dd-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'bands by vulnerability count, keeping unmeasured apart from zero' {
        $rows = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso' }) }
            }
            Mock Get-MsecDefenderDevice -MockWith {
                [pscustomobject]@{ DeviceName = 'clean';   VulnerabilityCount = 0;    CriticalCount = 0; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'few';     VulnerabilityCount = 7;    CriticalCount = 0; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'some';    VulnerabilityCount = 20;   CriticalCount = 1; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'many';    VulnerabilityCount = 40;   CriticalCount = 2; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'lots';    VulnerabilityCount = 80;   CriticalCount = 0; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'disaster'; VulnerabilityCount = 300; CriticalCount = 9; HealthStatus = 'Active' }
                # No licence / no permission: unknown, NOT clean.
                [pscustomobject]@{ DeviceName = 'unknown'; VulnerabilityCount = $null; CriticalCount = $null; HealthStatus = 'Active' }
            }
            Export-MsecDefenderDeviceReport -Path $Book -PassThru -WarningAction SilentlyContinue
        }

        $byName = @{}; foreach ($r in $rows) { $byName[$r.DeviceName] = $r }
        $byName['clean'].VulnerabilityBand    | Should -Be 'None'
        $byName['few'].VulnerabilityBand      | Should -Be '1 to 10'
        $byName['some'].VulnerabilityBand     | Should -Be '11 to 25'
        $byName['many'].VulnerabilityBand     | Should -Be '26 to 50'
        $byName['lots'].VulnerabilityBand     | Should -Be '51 to 100'
        $byName['disaster'].VulnerabilityBand | Should -Be 'Over 100'

        # The one that matters: unmeasured must never read as clean.
        $byName['unknown'].VulnerabilityBand | Should -Be 'Not assessed'
        $byName['unknown'].VulnerabilityBand | Should -Not -Be 'None'
    }

    It 'counts devices and critical-carrying devices separately per band' {
        $summary = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso' }) }
            }
            Mock Get-MsecDefenderDevice -MockWith {
                [pscustomobject]@{ DeviceName = 'a'; VulnerabilityCount = 300; CriticalCount = 5; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'b'; VulnerabilityCount = 250; CriticalCount = 1; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'c'; VulnerabilityCount = 200; CriticalCount = 0; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'd'; VulnerabilityCount = 0;   CriticalCount = 0; HealthStatus = 'Active' }
            }
            Export-MsecDefenderDeviceReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            @(Import-Excel -Path $Book -WorksheetName 'Summary')
        }

        # Every band present, so two tenants' charts stay comparable.
        @($summary).Count | Should -Be 7

        $over = $summary | Where-Object VulnerabilityBand -eq 'Over 100'
        $over.Devices      | Should -Be 3
        # Two of those three carry criticals - the second series, and the work order.
        $over.WithCritical | Should -Be 2

        ($summary | Where-Object VulnerabilityBand -eq 'None').Devices      | Should -Be 1
        ($summary | Where-Object VulnerabilityBand -eq 'None').WithCritical | Should -Be 0
        # Empty bands are 0, not the phantom 1 that @($null).Count gives.
        ($summary | Where-Object VulnerabilityBand -eq '1 to 10').Devices   | Should -Be 0
        (($summary | Measure-Object -Property Devices -Sum).Sum)            | Should -Be 4
    }

    It 'charts both series against the tenant, on a sheet named after it' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso Ltd' }) }
            }
            Mock Get-MsecDefenderDevice -MockWith {
                [pscustomobject]@{ DeviceName = 'a'; VulnerabilityCount = 300; CriticalCount = 5; HealthStatus = 'Active' }
            }
            Export-MsecDefenderDeviceReport -Path $Book -WarningAction SilentlyContinue | Out-Null
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $names = @($package.Workbook.Worksheets | ForEach-Object { $_.Name })
            $names[0] | Should -Be 'Dashboard'          # in front of the data
            $names | Should -Contain 'Contoso Ltd'      # tenant display name, not the GUID
            $names | Should -Contain 'Summary'

            $chart = $package.Workbook.Worksheets['Dashboard'].Drawings |
                Where-Object Name -eq 'chartContoso Ltd'
            @($chart.Series).Count | Should -Be 2
            @($chart.Series | ForEach-Object { $_.Header }) | Should -Be @('Devices', 'WithCritical')
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'sorts the unmeasured to the top, then the worst' {
        $order = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso' }) }
            }
            Mock Get-MsecDefenderDevice -MockWith {
                [pscustomobject]@{ DeviceName = 'clean';    VulnerabilityCount = 0;    CriticalCount = 0; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'bad-few';  VulnerabilityCount = 300;  CriticalCount = 1; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'bad-many'; VulnerabilityCount = 300;  CriticalCount = 9; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'unknown';  VulnerabilityCount = $null; CriticalCount = $null; HealthStatus = 'Active' }
            }
            @((Export-MsecDefenderDeviceReport -Path $Book -PassThru -WarningAction SilentlyContinue).DeviceName)
        }

        # What nobody has assessed first, then what is on fire, then the rest.
        $order | Should -Be @('unknown', 'bad-many', 'bad-few', 'clean')
    }

    It 'warns about unmeasured devices rather than letting them pass as clean' {
        $warnings = @()
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso' }) }
            }
            Mock Get-MsecDefenderDevice -MockWith {
                [pscustomobject]@{ DeviceName = 'a'; VulnerabilityCount = $null; CriticalCount = $null; HealthStatus = 'Active' }
                [pscustomobject]@{ DeviceName = 'b'; VulnerabilityCount = $null; CriticalCount = $null; HealthStatus = 'Active' }
            }
            Export-MsecDefenderDeviceReport -Path $Book
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        ($warnings -join ' ') | Should -Match "2 of 2 device"
        ($warnings -join ' ') | Should -Match 'rather than zero'
        ($warnings -join ' ') | Should -Match 'Vulnerability\.Read\.All'
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:MsecSession = $null
            { Export-MsecDefenderDeviceReport -Path $Book } | Should -Throw '*Connect-Msec*'
        }
    }
}
