#Requires -Module Pester
#
# Tests for Export-MsecEntraDisabledUserReport.
#
# The shared writing machinery is exercised by the VM report tests. What is specific here is
# the age bucket, and the thing that is easy to get wrong:
#
#   An account whose disable event has aged out of the audit log carries a BRACKET, not a date.
#   The bracket can still place it in a bucket when both ends fall inside one - 'at least 30, at
#   most 60' is squarely 30-to-90 - but where it straddles a boundary the honest answer is
#   Unknown. What it must never be is 'Under 30 days': anything the audit log cannot see is
#   OLDER than the window, never newer.

$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecEntraDisabledUserReport' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant-1'; ClientId = 'client'; KeyVaultName = 'kv'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-du-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'buckets by age, and never calls an unknown duration recent' {
        $rows = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 'tenant-1'; displayName = 'Contoso' }) }
            }
            Mock Get-MsecEntraDisabledUser -MockWith {
                [pscustomobject]@{ UserPrincipalName = 'recent@x.com';  DisabledDays = 5;    LicenseCount = 0 }
                [pscustomobject]@{ UserPrincipalName = 'twomonth@x.com'; DisabledDays = 60;   LicenseCount = 2 }
                [pscustomobject]@{ UserPrincipalName = 'halfyear@x.com'; DisabledDays = 200;  LicenseCount = 0 }
                [pscustomobject]@{ UserPrincipalName = 'ancient@x.com';  DisabledDays = 900;  LicenseCount = 1 }
                # Beyond retention, and the bracket lands wholly inside one bucket.
                [pscustomobject]@{ UserPrincipalName = 'bracketed@x.com'; DisabledDays = $null
                                   DisabledAtLeastDays = 30; DisabledAtMostDays = 60; LicenseCount = 0 }
                # Beyond retention, and the bracket straddles a boundary - genuinely unknown.
                [pscustomobject]@{ UserPrincipalName = 'vague@x.com'; DisabledDays = $null
                                   DisabledAtLeastDays = 30; DisabledAtMostDays = 400; LicenseCount = 3 }
                # Beyond retention with no successful sign-in at all: no upper bound either.
                [pscustomobject]@{ UserPrincipalName = 'silent@x.com'; DisabledDays = $null
                                   DisabledAtLeastDays = 30; DisabledAtMostDays = $null; LicenseCount = 0 }
            }

            Export-MsecEntraDisabledUserReport -Path $Book -PassThru -WarningAction SilentlyContinue
        }

        $byUpn = @{}; foreach ($r in $rows) { $byUpn[$r.UserPrincipalName] = $r }
        $byUpn['recent@x.com'].DisabledFor    | Should -Be 'Under 30 days'
        $byUpn['twomonth@x.com'].DisabledFor  | Should -Be '30 to 90 days'
        $byUpn['halfyear@x.com'].DisabledFor  | Should -Be '90 to 365 days'
        $byUpn['ancient@x.com'].DisabledFor   | Should -Be 'Over 365 days'

        # The bracket places it when both ends agree...
        $byUpn['bracketed@x.com'].DisabledFor | Should -Be '30 to 90 days'
        # ...and does not when it straddles.
        $byUpn['vague@x.com'].DisabledFor     | Should -Be 'Unknown'
        $byUpn['silent@x.com'].DisabledFor    | Should -Be 'Unknown'

        # The one reading that is certainly wrong: nothing beyond the audit window can be
        # newer than it.
        foreach ($upn in 'bracketed@x.com', 'vague@x.com', 'silent@x.com') {
            $byUpn[$upn].DisabledFor | Should -Not -Be 'Under 30 days'
        }
    }

    It 'counts accounts and licensed accounts separately per bucket' {
        $summary = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso' }) }
            }
            Mock Get-MsecEntraDisabledUser -MockWith {
                [pscustomobject]@{ UserPrincipalName = 'a@x.com'; DisabledDays = 400; LicenseCount = 2 }
                [pscustomobject]@{ UserPrincipalName = 'b@x.com'; DisabledDays = 500; LicenseCount = 1 }
                [pscustomobject]@{ UserPrincipalName = 'c@x.com'; DisabledDays = 600; LicenseCount = 0 }
                [pscustomobject]@{ UserPrincipalName = 'd@x.com'; DisabledDays = 10;  LicenseCount = 0 }
            }
            Export-MsecEntraDisabledUserReport -Path $Book -WarningAction SilentlyContinue | Out-Null
            @(Import-Excel -Path $Book -WorksheetName 'Summary')
        }

        # Every bucket present, so two runs' charts stay comparable.
        @($summary).Count | Should -Be 5
        ($summary | Where-Object DisabledFor -eq 'Over 365 days').Accounts | Should -Be 3
        # Two of those three still cost money - the second series, and the finding.
        ($summary | Where-Object DisabledFor -eq 'Over 365 days').Licensed | Should -Be 2
        ($summary | Where-Object DisabledFor -eq 'Under 30 days').Accounts | Should -Be 1
        ($summary | Where-Object DisabledFor -eq 'Under 30 days').Licensed | Should -Be 0
        # Empty buckets are 0, not the phantom 1 that @($null).Count gives.
        ($summary | Where-Object DisabledFor -eq '30 to 90 days').Accounts | Should -Be 0
        (($summary | Measure-Object -Property Accounts -Sum).Sum)          | Should -Be 4
    }

    It 'charts both series against the tenant, on a sheet named after it' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso Ltd' }) }
            }
            Mock Get-MsecEntraDisabledUser -MockWith {
                [pscustomobject]@{ UserPrincipalName = 'a@x.com'; DisabledDays = 400; LicenseCount = 2 }
            }
            Export-MsecEntraDisabledUserReport -Path $Book -WarningAction SilentlyContinue | Out-Null
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
            @($chart.Series | ForEach-Object { $_.Header }) | Should -Be @('Accounts', 'Licensed')
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'falls back to the tenant id when the display name cannot be read' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Forbidden' }
            Mock Get-MsecEntraDisabledUser -MockWith {
                [pscustomobject]@{ UserPrincipalName = 'a@x.com'; DisabledDays = 10; LicenseCount = 0 }
            }
            Export-MsecEntraDisabledUserReport -Path $Book -WarningAction SilentlyContinue | Out-Null
        }

        # Ugly but unambiguous, and the report still lands.
        @(Open-ExcelPackage -Path $script:Book | ForEach-Object { $_.Workbook.Worksheets.Name }) |
            Should -Contain 'tenant-1'
    }

    It 'sorts the expensive, long-dead accounts to the top' {
        $order = InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso' }) }
            }
            Mock Get-MsecEntraDisabledUser -MockWith {
                [pscustomobject]@{ UserPrincipalName = 'fresh@x.com';    DisabledDays = 5;   LicenseCount = 5 }
                [pscustomobject]@{ UserPrincipalName = 'old-free@x.com'; DisabledDays = 900; LicenseCount = 0 }
                [pscustomobject]@{ UserPrincipalName = 'old-paid@x.com'; DisabledDays = 900; LicenseCount = 3 }
            }
            @((Export-MsecEntraDisabledUserReport -Path $Book -PassThru -WarningAction SilentlyContinue).UserPrincipalName)
        }

        # Oldest bucket first; within it, the ones still costing money ahead of the free ones.
        $order | Should -Be @('old-paid@x.com', 'old-free@x.com', 'fresh@x.com')
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:MsecSession = $null
            { Export-MsecEntraDisabledUserReport -Path $Book } | Should -Throw '*Connect-Msec*'
        }
    }
}
