#Requires -Module Pester
#
# Tests for Get-MsecDefenderIncidentStats. The function fires three independent
# Graph queries:
#   1. createdDateTime ge {start}                                  -> volume + severity + classification
#   2. lastUpdateDateTime ge {start} and status eq 'resolved'      -> MTTR
#   3. status eq 'active' or status eq 'inProgress'                -> backlog
# The mock differentiates by $Uri's $filter contents so each call returns its
# own canned response. Tests cover the bucketing, MTTR best-practice scoping
# (skip FalsePositive), backlog-includes-old behaviour, and the 403 rewrite.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecDefenderIncidentStats' {
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

    It 'buckets severity, classification, MTTR (skipping false positives), and backlog correctly' {
        $out = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }

            # ---- Query 1: created in window -> volume + severity + classification.
            # The URI is the raw (unencoded) string built by Invoke-MsecGraphRequest;
            # mock filters match against THAT, not its URL-encoded form.            ----
            Mock Invoke-RestMethod `
                -ParameterFilter { $Uri -match '/security/incidents' -and $Uri -match 'createdDateTime ge' -and $Uri -notmatch "status eq 'resolved'" } `
                -MockWith {
                    [pscustomobject]@{ value = @(
                        # Severity mix
                        [pscustomobject]@{ severity = 'high';          status = 'resolved';   classification = 'truePositive';                  createdDateTime = '2026-05-20T08:00:00Z'; lastUpdateDateTime = '2026-05-20T12:00:00Z' }
                        [pscustomobject]@{ severity = 'high';          status = 'active';     classification = $null;                           createdDateTime = '2026-05-22T08:00:00Z'; lastUpdateDateTime = '2026-05-22T08:00:00Z' }
                        [pscustomobject]@{ severity = 'medium';        status = 'resolved';   classification = 'falsePositive';                 createdDateTime = '2026-05-23T08:00:00Z'; lastUpdateDateTime = '2026-05-23T08:15:00Z' }
                        [pscustomobject]@{ severity = 'low';           status = 'resolved';   classification = 'benignPositive';                createdDateTime = '2026-05-24T08:00:00Z'; lastUpdateDateTime = '2026-05-24T20:00:00Z' }
                        [pscustomobject]@{ severity = 'informational'; status = 'resolved';   classification = 'informationalExpectedActivity'; createdDateTime = '2026-05-25T08:00:00Z'; lastUpdateDateTime = '2026-05-25T16:00:00Z' }
                    ) }
                }

            # ---- Query 2: resolved in window -> MTTR. Real-world this overlaps with
            # query 1 in a fresh tenant; here we use the same data shape but only
            # incidents with status=resolved. Includes a 90-day-old creation date
            # that resolved in window (to show MTTR over arbitrary creation time). ----
            Mock Invoke-RestMethod `
                -ParameterFilter { $Uri -match '/security/incidents' -and $Uri -match "status eq 'resolved'" } `
                -MockWith {
                    [pscustomobject]@{ value = @(
                        # 4 hours (TP)         -> 4
                        [pscustomobject]@{ classification = 'truePositive';                  createdDateTime = '2026-05-20T08:00:00Z'; lastUpdateDateTime = '2026-05-20T12:00:00Z' }
                        # 15 min (FP)          -> excluded from MTTR
                        [pscustomobject]@{ classification = 'falsePositive';                 createdDateTime = '2026-05-23T08:00:00Z'; lastUpdateDateTime = '2026-05-23T08:15:00Z' }
                        # 12 hours (BP)        -> 12
                        [pscustomobject]@{ classification = 'benignPositive';                createdDateTime = '2026-05-24T08:00:00Z'; lastUpdateDateTime = '2026-05-24T20:00:00Z' }
                        # 8 hours (informationalExpectedActivity treated as BP) -> 8
                        [pscustomobject]@{ classification = 'informationalExpectedActivity'; createdDateTime = '2026-05-25T08:00:00Z'; lastUpdateDateTime = '2026-05-25T16:00:00Z' }
                    ) }
                }

            # ---- Query 3: currently open (active OR inProgress), any age ----
            Mock Invoke-RestMethod `
                -ParameterFilter { $Uri -match '/security/incidents' -and $Uri -match "status eq 'active'" } `
                -MockWith {
                    [pscustomobject]@{ value = @(
                        # 5 days ago - recent
                        [pscustomobject]@{ status = 'active';     createdDateTime = (Get-Date).ToUniversalTime().AddDays(-5).ToString('o') }
                        # 90 days ago - old, but still open. This is the case the
                        # window-based view would MISS, and the reason backlog ignores -Days.
                        [pscustomobject]@{ status = 'inProgress'; createdDateTime = (Get-Date).ToUniversalTime().AddDays(-90).ToString('o') }
                    ) }
                }

            Get-MsecDefenderIncidentStats
        }

        # ---- Volume in window ----
        $out.TotalCreated   | Should -Be 5
        $out.High           | Should -Be 2
        $out.Medium         | Should -Be 1
        $out.Low            | Should -Be 1
        $out.Informational  | Should -Be 1

        # Classification: 1 TP, 1 FP, 2 BP (benign + informationalExpectedActivity), 1 unclassified
        $out.TruePositive   | Should -Be 1
        $out.FalsePositive  | Should -Be 1
        $out.BenignPositive | Should -Be 2
        $out.Unclassified   | Should -Be 1

        # ---- Resolution in window ----
        # Total resolved = 4 (all of query 2)
        $out.TotalResolvedInWindow | Should -Be 4
        # MTTR over TP+BP only: (4 + 12 + 8) / 3 = 8 hours
        # FalsePositive (15min = 0.25h) deliberately excluded.
        $out.MeanTimeToResolveHours   | Should -Be 8.0
        $out.MedianTimeToResolveHours | Should -Be 8.0
        # ...and the denominator is published, so a reader can see the average rests on
        # 3 of the 4 resolved incidents rather than all of them.
        $out.ResolvedClassifiedCount  | Should -Be 3

        # ---- Backlog ----
        $out.CurrentlyOpen     | Should -Be 2
        # Oldest open is ~90 days. Within tolerance of 1 day for clock drift.
        $out.OldestOpenAgeDays | Should -BeGreaterThan 89
        $out.OldestOpenAgeDays | Should -BeLessThan 91
    }

    It 'returns zero counts and null MTTR / OldestOpenAgeDays when no incidents are returned' {
        $out = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/security/incidents' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecDefenderIncidentStats
        }

        $out.TotalCreated              | Should -Be 0
        $out.High                      | Should -Be 0
        $out.TotalResolvedInWindow     | Should -Be 0
        $out.ResolvedClassifiedCount   | Should -Be 0
        $out.MeanTimeToResolveHours    | Should -BeNullOrEmpty
        $out.MedianTimeToResolveHours  | Should -BeNullOrEmpty
        $out.CurrentlyOpen             | Should -Be 0
        $out.OldestOpenAgeDays         | Should -BeNullOrEmpty
    }

    # The real-world case that made this field necessary: a team that resolves incidents
    # but never classifies them gets a null MTTR, which looks identical to a collection
    # failure. ResolvedClassifiedCount = 0 alongside TotalResolvedInWindow > 0 says
    # plainly "nothing qualified to be averaged".
    It 'publishes a zero classified count when incidents are resolved but never classified' {
        $out = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # Filters must be mutually exclusive - an overlapping generic mock shadows
            # the specific ones. Created in window: two incidents, both unclassified.
            Mock Invoke-RestMethod `
                -ParameterFilter { $Uri -match '/security/incidents' -and $Uri -match 'createdDateTime ge' -and $Uri -notmatch "status eq 'resolved'" } `
                -MockWith {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ severity = 'medium'; status = 'resolved'; classification = $null; createdDateTime = '2026-05-20T08:00:00Z'; lastUpdateDateTime = '2026-05-20T12:00:00Z' }
                        [pscustomobject]@{ severity = 'low';    status = 'resolved'; classification = $null; createdDateTime = '2026-05-21T08:00:00Z'; lastUpdateDateTime = '2026-05-22T08:00:00Z' }
                    ) }
                }
            # Resolved in window: the same two, closed with NO classification set.
            Mock Invoke-RestMethod `
                -ParameterFilter { $Uri -match '/security/incidents' -and $Uri -match "status eq 'resolved'" } `
                -MockWith {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ classification = $null; createdDateTime = '2026-05-20T08:00:00Z'; lastUpdateDateTime = '2026-05-20T12:00:00Z' }
                        [pscustomobject]@{ classification = $null; createdDateTime = '2026-05-21T08:00:00Z'; lastUpdateDateTime = '2026-05-22T08:00:00Z' }
                    ) }
                }
            Mock Invoke-RestMethod `
                -ParameterFilter { $Uri -match '/security/incidents' -and $Uri -match "status eq 'active'" } `
                -MockWith { [pscustomobject]@{ value = @() } }

            Get-MsecDefenderIncidentStats
        }

        # Work WAS done - two incidents resolved...
        $out.TotalResolvedInWindow    | Should -Be 2
        $out.Unclassified             | Should -Be 2
        # ...but none of it can be timed, and the count says so explicitly rather than
        # leaving a bare null that looks like a collection failure.
        $out.ResolvedClassifiedCount  | Should -Be 0 -Because 'nothing was classified, so nothing could be averaged'
        $out.MeanTimeToResolveHours   | Should -BeNullOrEmpty
        $out.MedianTimeToResolveHours | Should -BeNullOrEmpty
    }

    It 'rewrites a 403 to mention the missing SecurityIncident.Read.All permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/security/incidents' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecDefenderIncidentStats } |
                Should -Throw -ExpectedMessage '*SecurityIncident.Read.All*'
        }
    }
}
