#Requires -Module Pester
#
# Tests for Get-MsecAzureSecureScore. The function hits Defender for Cloud's ARM
# endpoints (management.azure.com/.../Microsoft.Security/secureScores) using the
# caller's Az.Accounts identity - so the mocks are at the Az cmdlet layer
# (Get-AzContext, Get-AzSubscription, Get-AzAccessToken) plus Invoke-RestMethod
# for the ARM calls themselves.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Get-MsecAzureSecureScore enumerates subscriptions through Get-MsecSubscriptionList, which
    # refreshes the completion cache. With Az mocked that would leave a folder of fake data in
    # the developer's real cache directory.
    $script:PrevCacheEnv = $env:MSEC_CACHE_DIR
    $env:MSEC_CACHE_DIR  = Join-Path ([System.IO.Path]::GetTempPath()) "msec-test-cache-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $env:MSEC_CACHE_DIR -Force | Out-Null
    $script:CacheDir = $env:MSEC_CACHE_DIR
}

AfterAll {
    if ($script:CacheDir -and (Test-Path -LiteralPath $script:CacheDir)) {
        Remove-Item -LiteralPath $script:CacheDir -Recurse -Force
    }
    $env:MSEC_CACHE_DIR = $script:PrevCacheEnv
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureSecureScore' {

    It 'returns one Overall row per subscription with correct percent (current / max * 100)' {
        $rows = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-A' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith {
                @(
                    [pscustomobject]@{ Id = 'sub-A'; Name = 'we-dev-sub'  }
                    [pscustomobject]@{ Id = 'sub-B'; Name = 'we-prod-sub' }
                )
            }
            Mock Get-AzAccessToken  -MockWith { [pscustomobject]@{ Token = 'mock-arm-token'; ExpiresOn = (Get-Date).AddHours(1) } }

            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscriptions/sub-A/.*/secureScores' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        name = 'ascScore'
                        properties = [pscustomobject]@{
                            displayName = 'ASC score'
                            score = [pscustomobject]@{ max = 58.0; current = 32.0; percentage = 0.5517 }
                            weight = 100
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscriptions/sub-B/.*/secureScores' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        name = 'ascScore'
                        properties = [pscustomobject]@{
                            displayName = 'ASC score'
                            score = [pscustomobject]@{ max = 50.0; current = 47.0; percentage = 0.94 }
                            weight = 100
                        }
                    }
                ) }
            }

            Get-MsecAzureSecureScore
        }

        $rows.Count | Should -Be 2

        $a = $rows | Where-Object SubscriptionId -eq 'sub-A'
        $a.SubscriptionName | Should -Be 'we-dev-sub'
        $a.ScoreType        | Should -Be 'Overall'
        $a.ScorePercent     | Should -Be 55.17       # 32 / 58 * 100, rounded to 2dp

        $b = $rows | Where-Object SubscriptionId -eq 'sub-B'
        $b.SubscriptionName | Should -Be 'we-prod-sub'
        $b.ScorePercent     | Should -Be 94.0
    }

    It '-IncludeControls emits one row per (subscription, control) in addition to Overall' {
        $rows = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-A' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-A'; Name = 'we-dev-sub' }) }
            Mock Get-AzAccessToken  -MockWith { [pscustomobject]@{ Token = 'mock-arm-token'; ExpiresOn = (Get-Date).AddHours(1) } }

            # Overall
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScores\?api-version' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        name = 'ascScore'
                        properties = [pscustomobject]@{
                            displayName = 'ASC score'
                            score = [pscustomobject]@{ max = 100.0; current = 72.0 }
                        }
                    }
                ) }
            }
            # Controls
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScoreControls\?api-version' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        properties = [pscustomobject]@{
                            displayName = 'Enable MFA'
                            score = [pscustomobject]@{ max = 10.0; current = 10.0 }
                        }
                    }
                    [pscustomobject]@{
                        properties = [pscustomobject]@{
                            displayName = 'Apply system updates'
                            score = [pscustomobject]@{ max = 10.0; current = 4.0 }
                        }
                    }
                    [pscustomobject]@{
                        # Edge case: control with no applicable assessments -> max=0
                        properties = [pscustomobject]@{
                            displayName = 'Custom recommendation (n/a)'
                            score = [pscustomobject]@{ max = 0.0; current = 0.0 }
                        }
                    }
                ) }
            }

            Get-MsecAzureSecureScore -IncludeControls
        }

        # 1 Overall + 3 controls = 4 rows
        $rows.Count                                     | Should -Be 4
        ($rows | Where-Object ScoreType -eq 'Overall').ScorePercent           | Should -Be 72.0
        ($rows | Where-Object ScoreType -eq 'Enable MFA').ScorePercent        | Should -Be 100.0
        ($rows | Where-Object ScoreType -eq 'Apply system updates').ScorePercent | Should -Be 40.0
        # max=0 control: ScorePercent must be $null (don't fake a 0 - it means "no data")
        ($rows | Where-Object ScoreType -eq 'Custom recommendation (n/a)').ScorePercent |
            Should -BeNullOrEmpty
    }

    It 'warns and skips a single failing subscription rather than aborting the whole batch' {
        $output = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-A' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith {
                @(
                    [pscustomobject]@{ Id = 'sub-A'; Name = 'reader-ok'  }   # works
                    [pscustomobject]@{ Id = 'sub-B'; Name = 'no-reader'  }   # 403
                    [pscustomobject]@{ Id = 'sub-C'; Name = 'reader-ok2' }   # works
                )
            }
            Mock Get-AzAccessToken  -MockWith { [pscustomobject]@{ Token = 'mock'; ExpiresOn = (Get-Date).AddHours(1) } }

            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscriptions/sub-B/' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscriptions/sub-[AC]/' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        name = 'ascScore'
                        properties = [pscustomobject]@{
                            displayName = 'ASC score'
                            score = [pscustomobject]@{ max = 50.0; current = 25.0 }
                        }
                    }
                ) }
            }

            # Capture warnings + rows in a single call - calling twice would run
            # the mocked Invoke-RestMethod twice and inflate the row count.
            $warnings = @()
            $rows = Get-MsecAzureSecureScore -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = $rows; Warnings = $warnings }
        }

        # 2 successful subs return rows, the failing one is skipped (no row, just warning).
        $output.Rows.Count | Should -Be 2
        $output.Rows.SubscriptionId | Should -Not -Contain 'sub-B'
        $output.Warnings.Count | Should -BeGreaterThan 0
        $output.Warnings[0] | Should -Match 'no-reader'
    }
}
