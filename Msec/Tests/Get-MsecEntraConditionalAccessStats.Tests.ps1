#Requires -Module Pester
#
# Tests for Get-MsecEntraConditionalAccessStats. The function is a thin
# aggregation over Get-MsecEntraConditionalAccessSignInLog - we mock that
# function inside the module scope so the test doesn't need to mock the Graph
# layer, just feed canned sign-in events and verify the math.
# Coverage:
#   - CA-status counts and percentages (success / failure / notApplied)
#   - UniqueUsers de-dupes by UPN
#   - Risk-level counts (high / medium)
#   - ReportOnlyWouldBlock counts reportOnlyFailure + reportOnlyInterrupted
#   - TopFailingPolicies aggregates AppliedPolicies[].result == 'failure'
#   - Empty result returns zero counts and 0.0 percentages (no divide-by-zero)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraConditionalAccessStats' {

    It 'aggregates volume / CA outcomes / risk / report-only / top failing policies correctly' {
        $stats = InModuleScope msec {
            # Mock the SignInLog so the inner call returns a small, deterministic set.
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith {
                @(
                    # 6 sign-ins total: 3 success, 2 failure, 1 notApplied
                    [pscustomobject]@{
                        UserPrincipalName = 'alice@x'; ConditionalAccessStatus = 'success'
                        RiskLevelDuringSignIn = 'none'
                        AppliedPolicies = @(
                            [pscustomobject]@{ displayName = 'P1: Require MFA'; result = 'success' }
                        )
                    }
                    [pscustomobject]@{
                        UserPrincipalName = 'alice@x'; ConditionalAccessStatus = 'success'
                        RiskLevelDuringSignIn = 'none'
                        AppliedPolicies = @(
                            [pscustomobject]@{ displayName = 'P1: Require MFA'; result = 'success' }
                            # A report-only policy that WOULD have blocked this sign-in
                            [pscustomobject]@{ displayName = 'P3: Geo Block (RO)'; result = 'reportOnlyFailure' }
                        )
                    }
                    [pscustomobject]@{
                        UserPrincipalName = 'bob@x'; ConditionalAccessStatus = 'success'
                        RiskLevelDuringSignIn = 'medium'
                        AppliedPolicies = @()
                    }
                    [pscustomobject]@{
                        UserPrincipalName = 'attacker@external'; ConditionalAccessStatus = 'failure'
                        RiskLevelDuringSignIn = 'high'
                        AppliedPolicies = @(
                            [pscustomobject]@{ displayName = 'P1: Require MFA';  result = 'failure' }
                            [pscustomobject]@{ displayName = 'P2: Block Legacy'; result = 'failure' }
                        )
                    }
                    [pscustomobject]@{
                        UserPrincipalName = 'attacker@external'; ConditionalAccessStatus = 'failure'
                        RiskLevelDuringSignIn = 'high'
                        AppliedPolicies = @(
                            [pscustomobject]@{ displayName = 'P1: Require MFA'; result = 'failure' }
                        )
                    }
                    [pscustomobject]@{
                        UserPrincipalName = 'service@x'; ConditionalAccessStatus = 'notApplied'
                        RiskLevelDuringSignIn = 'none'
                        AppliedPolicies = @()
                    }
                )
            }

            Get-MsecEntraConditionalAccessStats -Days 7
        }

        # Volume
        $stats.TotalSignIns | Should -Be 6
        $stats.UniqueUsers  | Should -Be 4              # alice + bob + attacker + service

        # CA outcomes
        $stats.CaSuccess        | Should -Be 3
        $stats.CaFailure        | Should -Be 2
        $stats.CaNotApplied     | Should -Be 1
        $stats.CaSuccessPercent | Should -Be 50.0       # 3 / 6
        $stats.CaFailurePercent | Should -Be 33.33      # 2 / 6, rounded to 2dp

        # Risk
        $stats.HighRiskSignIns   | Should -Be 2
        $stats.MediumRiskSignIns | Should -Be 1

        # Report-only would-block - one event triggered reportOnlyFailure on P3
        $stats.ReportOnlyWouldBlock | Should -Be 1

        # Top failing policies (aggregated across all events):
        # P1 failed 2 times, P2 failed 1 time. P3 was reportOnly - NOT in this list.
        ($stats.TopFailingPolicies | Where Name -eq 'P1: Require MFA').Count  | Should -Be 2
        ($stats.TopFailingPolicies | Where Name -eq 'P2: Block Legacy').Count | Should -Be 1
        $stats.TopFailingPolicies.Name | Should -Not -Contain 'P3: Geo Block (RO)'
    }

    It 'returns zero counts and 0.0 percentages when the sign-in log is empty (no divide-by-zero)' {
        $stats = InModuleScope msec {
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith { @() }
            Get-MsecEntraConditionalAccessStats
        }

        $stats.TotalSignIns           | Should -Be 0
        $stats.CaSuccess              | Should -Be 0
        $stats.CaSuccessPercent       | Should -Be 0.0
        $stats.CaFailurePercent       | Should -Be 0.0
        $stats.ReportOnlyWouldBlock   | Should -Be 0
        $stats.TopFailingPolicies     | Should -BeNullOrEmpty
        # Date columns still populated.
        $stats.StartDate | Should -Not -BeNullOrEmpty
        $stats.EndDate   | Should -Not -BeNullOrEmpty
    }

    It 'has -Days with the same bounds as the SignInLog function (1..30)' {
        $param = (Get-Command Get-MsecEntraConditionalAccessStats).Parameters['Days']
        $range = $param.Attributes |
            Where-Object { $_.TypeId.Name -eq 'ValidateRangeAttribute' } |
            Select-Object -First 1
        $range.MinRange | Should -Be 1
        $range.MaxRange | Should -Be 30
    }
}
