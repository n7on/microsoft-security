#Requires -Module Pester
#
# Tests for Get-MsecSecureScoreRecommendation. The cases that matter are the ones where a
# plausible-looking implementation reports something false:
#   - 'on' arrives as the STRING "false", which is truthy. Enabled must be $false, not $true.
#   - A profile with no matching control score is NOT a control scoring zero. CurrentScore
#     must be $null for those, never 0.
#   - A scored control with no published profile is still returned, with a null Title, rather
#     than dropped.
#   - An Ignored control is not a completed one and must still be visible.
#   - Deprecated and completed controls are excluded by default - this is the
#     recommended-actions list, not an inventory.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecSecureScoreRecommendation' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }

            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScoreControlProfiles' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id='open';  title='Open action';  maxScore=10; controlCategory='Identity'
                                       rank=1; deprecated=$false; remediation='Do the thing'
                                       controlStateUpdates=[pscustomobject]@{ state='Default' } }
                    [pscustomobject]@{ id='done';  title='Finished';     maxScore=5;  controlCategory='Identity'
                                       rank=2; deprecated=$false
                                       controlStateUpdates=[pscustomobject]@{ state='Default' } }
                    [pscustomobject]@{ id='dep';   title='Retired';      maxScore=7;  controlCategory='Device'
                                       rank=3; deprecated=$true
                                       controlStateUpdates=[pscustomobject]@{ state='Default' } }
                    [pscustomobject]@{ id='ign';   title='Dismissed';    maxScore=9;  controlCategory='Device'
                                       rank=4; deprecated=$false
                                       controlStateUpdates=[pscustomobject]@{ state='Ignored'; updatedBy='someone' } }
                    [pscustomobject]@{ id='unlic'; title='Not licensed'; maxScore=4;  controlCategory='Apps'
                                       rank=5; deprecated=$false
                                       controlStateUpdates=[pscustomobject]@{ state='Default' } }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScores' -and $Uri -notmatch 'Profile' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        createdDateTime='2026-10-06T00:00:00Z'; currentScore=15; maxScore=35
                        controlScores=@(
                            [pscustomobject]@{ controlName='open'; controlCategory='Identity'; score=2; on='false'; scoreInPercentage=20 }
                            [pscustomobject]@{ controlName='done'; controlCategory='Identity'; score=5; on='true';  scoreInPercentage=100 }
                            [pscustomobject]@{ controlName='dep';  controlCategory='Device';   score=0; on='false' }
                            [pscustomobject]@{ controlName='ign';  controlCategory='Device';   score=0; on='false' }
                            [pscustomobject]@{ controlName='orphan'; controlCategory='Data';   score=3; on='true' })
                    }
                ) }
            }
        }
    }

    It 'treats the string "false" as $false, not as a truthy string' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation -IncludeCompleted | Where-Object ControlName -eq 'open'
        }
        $r.Enabled | Should -BeFalse
        $r.Enabled | Should -BeOfType [bool]
    }

    It 'returns a scored control that has no profile, with a null Title rather than dropping it' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation -IncludeCompleted | Where-Object ControlName -eq 'orphan'
        }
        $r | Should -Not -BeNullOrEmpty
        $r.Source | Should -Be 'ScoreOnly'
        $r.Title  | Should -BeNullOrEmpty
        # No profile means no maxScore, so points available is unknowable - not zero.
        $r.PointsAvailable | Should -BeNullOrEmpty
    }

    It 'gives a not-applicable control a NULL CurrentScore, never 0' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation -IncludeNotApplicable -IncludeCompleted |
                Where-Object ControlName -eq 'unlic'
        }
        $r.Source       | Should -Be 'ProfileOnly'
        $r.CurrentScore | Should -BeNullOrEmpty
        $r.CurrentScore | Should -Not -Be 0
    }

    It 'excludes not-applicable controls unless asked' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation -IncludeCompleted
        }
        @($r | Where-Object Source -eq 'ProfileOnly').Count | Should -Be 0
    }

    It 'excludes completed and deprecated controls by default' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation
        }
        @($r | Where-Object ControlName -eq 'done').Count | Should -Be 0
        @($r | Where-Object ControlName -eq 'dep').Count  | Should -Be 0
    }

    It 'keeps an Ignored control visible and carries who ignored it' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation | Where-Object ControlName -eq 'ign'
        }
        $r | Should -Not -BeNullOrEmpty
        $r.State          | Should -Be 'Ignored'
        $r.StateUpdatedBy | Should -Be 'someone'
        $r.PointsAvailable | Should -Be 9
    }

    It 'accepts a state the documentation does not list' {
        # ValidateSet would reject this; the live API returns AlternateMitigation.
        { InModuleScope Msec {
            Get-MsecSecureScoreRecommendation -State 'AlternateMitigation'
        } } | Should -Not -Throw
    }

    It 'computes PointsAvailable from the profile maxScore minus the achieved score' {
        $r = InModuleScope Msec {
            Get-MsecSecureScoreRecommendation | Where-Object ControlName -eq 'open'
        }
        $r.MaxScore        | Should -Be 10
        $r.CurrentScore    | Should -Be 2
        $r.PointsAvailable | Should -Be 8
    }
}
