#Requires -Module Pester
#
# Tests for Get-MsecScoreSummary. Verifies:
#   1. The 'Overall' row comes first.
#   2. Per-category percentages are normalised by control max scores (not VM count).
#   3. Defender API rows (Exposure, DeviceConfiguration) have blank
#      previous-month / diff because the API gives a single point-in-time score.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecScoreSummary' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId        = 'tenant'
                ClientId        = 'client'
                KeyVaultName    = 'kv-test'
                KeyName         = 'msec-app'
                ThumbprintBytes = $Thumb
                Tokens          = @{}
            }
        }
    }

    It 'returns Overall first then categories, with correct today / prev-month / diff' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScoreControlProfiles' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'ctrl_id1';  maxScore = 30; controlCategory = 'Identity' }
                    [pscustomobject]@{ id = 'ctrl_id2';  maxScore = 20; controlCategory = 'Identity' }
                    [pscustomobject]@{ id = 'ctrl_dev1'; maxScore = 50; controlCategory = 'Device' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScores' -and $Uri -notmatch 'Profile' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        createdDateTime = '2026-05-27'; currentScore = 65; maxScore = 100
                        controlScores = @(
                            [pscustomobject]@{ controlName = 'ctrl_id1';  controlCategory = 'Identity'; score = 30 }
                            [pscustomobject]@{ controlName = 'ctrl_id2';  controlCategory = 'Identity'; score = 10 }
                            [pscustomobject]@{ controlName = 'ctrl_dev1'; controlCategory = 'Device';   score = 25 })
                    }
                    [pscustomobject]@{
                        createdDateTime = '2026-04-27'; currentScore = 70; maxScore = 100
                        controlScores = @(
                            [pscustomobject]@{ controlName = 'ctrl_id1';  controlCategory = 'Identity'; score = 20 }
                            [pscustomobject]@{ controlName = 'ctrl_id2';  controlCategory = 'Identity'; score = 10 }
                            [pscustomobject]@{ controlName = 'ctrl_dev1'; controlCategory = 'Device';   score = 40 })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/api/exposureScore' }      -MockWith { [pscustomobject]@{ score = 33.49 } }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/api/configurationScore' } -MockWith { [pscustomobject]@{ score = 88 } }

            Get-MsecScoreSummary
        }

        $rows[0].ScoreType            | Should -Be 'Overall'
        $rows[0].TodayPercent         | Should -Be 65
        $rows[0].PreviousMonthPercent | Should -Be 70
        $rows[0].DiffPercent          | Should -Be -5

        $identity = $rows | Where-Object ScoreType -eq 'Identity'
        $identity.TodayPercent         | Should -Be 80
        $identity.PreviousMonthPercent | Should -Be 60
        $identity.DiffPercent          | Should -Be 20

        $device = $rows | Where-Object ScoreType -eq 'Device'
        $device.TodayPercent         | Should -Be 50
        $device.PreviousMonthPercent | Should -Be 80
        $device.DiffPercent          | Should -Be -30

        $exposure = $rows | Where-Object ScoreType -eq 'Exposure'
        $exposure.TodayPercent         | Should -Be 33.49
        $exposure.PreviousMonthPercent | Should -BeNullOrEmpty
        $exposure.DiffPercent          | Should -BeNullOrEmpty

        # DeviceConfiguration is intentionally excluded - the Defender API returns raw points
        # with no maximum, so it can't be normalized to a comparable percentage.
        ($rows | Where-Object ScoreType -eq 'DeviceConfiguration') | Should -BeNullOrEmpty
    }
}
