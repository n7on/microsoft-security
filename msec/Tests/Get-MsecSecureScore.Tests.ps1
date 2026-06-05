#Requires -Module Pester
#
# Tests for Get-MsecSecureScore (the consolidated function). Verifies:
#   - Default call: emits Overall + every category present in the snapshot.
#   - -Category Overall:    skips the profile fetch entirely, emits only Overall rows.
#   - -Category Identity:   emits only the Identity rows, but still pulls profiles
#                           because per-category math requires the maxScore map.
#   - -Top N:               passes through to the Graph $top query param.
#   - Per-category percentages are computed from (sum-achieved / sum-max) where
#     the max comes from secureScoreControlProfiles, not from the snapshot.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecSecureScore' {
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

    It 'no -Category: emits one Overall row plus one row per category, per snapshot' {
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
                        createdDateTime = '2026-06-01T00:00:00Z'; currentScore = 65; maxScore = 100
                        controlScores = @(
                            [pscustomobject]@{ controlName = 'ctrl_id1';  controlCategory = 'Identity'; score = 30 }
                            [pscustomobject]@{ controlName = 'ctrl_id2';  controlCategory = 'Identity'; score = 10 }
                            [pscustomobject]@{ controlName = 'ctrl_dev1'; controlCategory = 'Device';   score = 25 })
                    }
                ) }
            }

            Get-MsecSecureScore
        }

        # One snapshot -> Overall + Identity + Device = 3 rows.
        $rows.Count | Should -Be 3

        $overall = $rows | Where-Object ScoreType -eq 'Overall'
        $overall.ScorePercent | Should -Be 65   # 65 / 100

        $identity = $rows | Where-Object ScoreType -eq 'Identity'
        # achieved = 30+10 = 40; max = 30+20 = 50 -> 80%
        $identity.ScorePercent | Should -Be 80

        $device = $rows | Where-Object ScoreType -eq 'Device'
        # achieved = 25; max = 50 -> 50%
        $device.ScorePercent | Should -Be 50
    }

    It '-Category Overall skips the profile fetch and returns only the Overall rows' {
        $result = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # If this mock fires, we've done unnecessary work for -Category Overall.
            $script:ProfileHits = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScoreControlProfiles' } -MockWith {
                $script:ProfileHits++
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScores' -and $Uri -notmatch 'Profile' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ createdDateTime = '2026-06-01T00:00:00Z'; currentScore = 81; maxScore = 100; controlScores = @() }
                    [pscustomobject]@{ createdDateTime = '2026-05-01T00:00:00Z'; currentScore = 75; maxScore = 100; controlScores = @() }
                ) }
            }

            $rows = Get-MsecSecureScore -Category Overall
            [pscustomobject]@{ Rows = $rows; ProfileHits = $script:ProfileHits }
        }

        $result.Rows.Count             | Should -Be 2
        ($result.Rows.ScoreType -join ',') | Should -Be 'Overall,Overall'
        $result.Rows[0].ScorePercent   | Should -Be 81
        $result.Rows[1].ScorePercent   | Should -Be 75

        # The key perf claim: -Category Overall does NOT load profile maxima.
        $result.ProfileHits | Should -Be 0
    }

    It '-Category Identity emits only Identity rows but still computes from the profile maxima' {
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
                        createdDateTime = '2026-06-01T00:00:00Z'; currentScore = 65; maxScore = 100
                        controlScores = @(
                            [pscustomobject]@{ controlName = 'ctrl_id1';  controlCategory = 'Identity'; score = 30 }
                            [pscustomobject]@{ controlName = 'ctrl_id2';  controlCategory = 'Identity'; score = 10 }
                            [pscustomobject]@{ controlName = 'ctrl_dev1'; controlCategory = 'Device';   score = 25 })
                    }
                ) }
            }

            Get-MsecSecureScore -Category Identity
        }

        $rows.Count            | Should -Be 1
        $rows[0].ScoreType     | Should -Be 'Identity'
        $rows[0].ScorePercent  | Should -Be 80   # (30 + 10) / (30 + 20)
    }

    It '-Top N passes through to the Graph $top query parameter' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScoreControlProfiles' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            $script:CapturedScoreUri = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScores' -and $Uri -notmatch 'Profile' } -MockWith {
                $script:CapturedScoreUri = $Uri
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ createdDateTime = '2026-06-01T00:00:00Z'; currentScore = 80; maxScore = 100; controlScores = @() }
                ) }
            }

            Get-MsecSecureScore -Top 1 | Out-Null

            $script:CapturedScoreUri | Should -Match '\$top=1$'
        }
    }
}
