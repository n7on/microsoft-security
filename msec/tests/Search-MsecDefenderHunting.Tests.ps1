#Requires -Module Pester
#
# Tests for Search-MsecDefenderHunting.
#
# The things worth pinning are the ones that make a hunting result trustworthy rather than
# merely present:
#
#   The window goes to the API as its own timespan, so the .kql files carry no ago() - one file
#   serves every window, and nothing silently intersects with what the caller asked for.
#
#   A BARE INTEGER -Timespan is TICKS. -Timespan 7 means 700 nanoseconds, so the query returns
#   nothing and reads as "there was nothing to find" - the single most dangerous way for a
#   security query to be wrong.
#
#   A table belonging to an un-onboarded product FAILS TO RESOLVE rather than returning zero
#   rows. Translating that into a plain sentence is the point: "0 results" and "this product is
#   not installed" must never look alike.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Search-MsecDefenderHunting' {

    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'refuses without a session' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Search-MsecDefenderHunting -Subject Alert } | Should -Throw '*Connect-Msec*'
        }
    }

    It 'sends the bundled file and a whole-day ISO window' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:captured = $Body
                @{ results = @(); schema = @() }
            }
            $null = Search-MsecDefenderHunting -Subject SignIn -Name Failed -Days 3
            $script:captured
        }

        $sent['Timespan'] | Should -Be 'P3D'
        $sent['Query']    | Should -Match 'AADSignInEventsBeta'
        $sent['Query']    | Should -Match 'ErrorCode != 0'
    }

    It 'defaults to seven days' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:captured = $Body; @{ results = @() } }
            $null = Search-MsecDefenderHunting -Subject Alert
            $script:captured
        }
        $sent['Timespan'] | Should -Be 'P7D'
    }

    It 'converts a sub-day -Timespan to hours and minutes' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:captured = $Body; @{ results = @() } }
            $null = Search-MsecDefenderHunting -Subject Alert -Timespan 04:30:00
            $script:captured
        }
        $sent['Timespan'] | Should -Be 'PT4H30M'
    }

    It 'refuses a bare-integer -Timespan, which PowerShell reads as ticks' {
        { Search-MsecDefenderHunting -Subject Alert -Timespan 7 } |
            Should -Throw '*read as TICKS*'
    }

    It 'refuses a window past the stores retention' {
        { Search-MsecDefenderHunting -Subject Alert -Days 90 } | Should -Throw
    }

    It 'runs literal KQL without touching the bundled files' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:captured = $Body; @{ results = @() } }
            $null = Search-MsecDefenderHunting -Query 'DeviceInfo | take 1' -Days 1
            $script:captured
        }
        $sent['Query'] | Should -Be 'DeviceInfo | take 1'
    }

    It 'names a missing .kql rather than running something else' {
        { Search-MsecDefenderHunting -Subject SignIn -Name NoSuchQuery } |
            Should -Throw '*NoSuchQuery.kql*'
    }

    It 'translates an unresolved table into "not onboarded", not zero rows' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                throw "Failed to resolve table or column expression named 'CloudAppEvents'"
            }
            { Search-MsecDefenderHunting -Query 'CloudAppEvents | count' } |
                Should -Throw '*not onboarded or not licensed*'
        }
    }

    It 'emits one object per result row' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @{ results = @(@{ Severity = 'High'; n = '83' }, @{ Severity = 'Low'; n = '126' }) }
            }
            @(Search-MsecDefenderHunting -Query 'AlertInfo | count')
        }
        $rows.Count       | Should -Be 2
        $rows[0].Severity | Should -Be 'High'
    }
}

Describe 'kql/Hunting bundled queries' {
    BeforeAll {
        $script:HuntRoot = Join-Path (Get-Module msec).ModuleBase 'kql/Hunting'
        $script:HuntFiles = @(Get-ChildItem -LiteralPath $script:HuntRoot -Filter *.kql -File -Recurse)
    }

    It 'carries no time filter - the window belongs to -Days' {
        # Same rule as kql/Law: the window is a server-side parameter, and one baked into a file
        # is invisible at the call site and intersects silently with what was asked for.
        $offenders = $script:HuntFiles | ForEach-Object {
            $code = ((Get-Content -LiteralPath $_.FullName) | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            if ($code -match '\bago\s*\(' -or $code -match 'Timestamp\s*[<>]') { $_.Name }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'gives every subject an All.kql, which is the default -Name' {
        foreach ($dir in Get-ChildItem -LiteralPath $script:HuntRoot -Directory) {
            (Join-Path $dir.FullName 'All.kql') | Should -Exist
        }
    }

    It 'collapses DeviceInfo to one row per device' {
        # DeviceInfo writes a row per device per day. Without arg_max a "device count" counts
        # observations instead, inflating silently with the length of the window.
        $q = Get-Content -LiteralPath (Join-Path $script:HuntRoot 'Device/All.kql') -Raw
        $q | Should -Match 'arg_max\(Timestamp, \*\) by DeviceId'
    }

    It 'says in the file that the vulnerability snapshot ignores the window' {
        # DeviceTvmSoftwareVulnerabilities has no Timestamp column, so -Days cannot apply. The
        # caller has to be told, or an unchanged row count across windows looks like a bug.
        $q = Get-Content -LiteralPath (Join-Path $script:HuntRoot 'Vulnerability/All.kql') -Raw
        $q | Should -Match 'NO Timestamp'
    }
}
