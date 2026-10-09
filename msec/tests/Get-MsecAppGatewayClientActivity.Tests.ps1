#Requires -Module Pester
#
# Tests for Get-MsecAppGatewayClientActivity.
#
# The command exists to stop two specific wrong answers:
#   - treating a 200 on a login page as a sign-in, which makes every crawler look like an
#     intruder
#   - reporting Authenticated = $false for a period where the only data is the hourly summary,
#     which has no HTTP method and therefore cannot answer the question at all
# Most of these cover those, plus refusing a malformed address before it becomes a quiet
# empty result.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecAppGatewayClientActivity' {
    BeforeEach {
        InModuleScope Msec {
            Mock Search-MsecAzureResourceGraph -MockWith {
                @([pscustomobject]@{ Name='prod-sentinel-log'; ResourceGroupName='siem'
                                     SubscriptionId='sub1'; CustomerId='11111111-1111-1111-1111-111111111111' })
            }
        }
    }

    It 'refuses a malformed address before querying, rather than returning an empty result' {
        $err = InModuleScope Msec {
            Mock Invoke-AzOperationalInsightsQuery -MockWith { throw 'must not be called' }
            try {
                Get-MsecAppGatewayClientActivity -ClientIp '79.137.138.24/32' -WorkspaceName 'prod-sentinel-log'
                $null
            } catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'not a valid IP address'
        # The reason this is an error and not a filter: a bad address matches nothing, and an
        # empty result reads as "this address did nothing".
        $err | Should -Match 'empty result rather than an error'
        InModuleScope Msec { Should -Invoke Invoke-AzOperationalInsightsQuery -Times 0 -Exactly }
    }

    It 'marks the OIDC completion points as authenticated and a login page as not' {
        $rows = InModuleScope Msec {
            Mock Invoke-AzOperationalInsightsQuery -MockWith {
                [pscustomobject]@{ Results = @(
                    [pscustomobject]@{ TimeGenerated='2026-09-27T19:00:00Z'; ClientIp='1.2.3.4'; Method='GET'
                                       Uri='/Account/Login'; Status=200; Host='idp'; Agent='Chrome'; Sent=100
                                       Requests=1; Grain='per-request'; Authenticated=$false }
                    [pscustomobject]@{ TimeGenerated='2026-09-27T19:05:00Z'; ClientIp='1.2.3.4'; Method='POST'
                                       Uri='/signin-oidc'; Status=302; Host='web'; Agent='Chrome'; Sent=200
                                       Requests=1; Grain='per-request'; Authenticated=$true }
                ) }
            }
            , @(Get-MsecAppGatewayClientActivity -ClientIp '1.2.3.4' -WorkspaceName 'prod-sentinel-log')
        }

        $login = $rows | Where-Object Uri -eq '/Account/Login'
        $oidc  = $rows | Where-Object Uri -eq '/signin-oidc'
        # A rendered login page is not a sign-in. Crawlers produce these constantly.
        $login.Authenticated | Should -BeFalse
        $oidc.Authenticated | Should -BeTrue
    }

    It 'reports Authenticated as null on summary rows, never false' {
        $row = InModuleScope Msec {
            Mock Invoke-AzOperationalInsightsQuery -MockWith {
                [pscustomobject]@{ Results = @(
                    [pscustomobject]@{ TimeGenerated='2026-10-07T18:00:00Z'; ClientIp='1.2.3.4'; Method=''
                                       Uri='["/Account/Login"]'; Status=0; Host='["idp"]'; Agent='["Chrome"]'
                                       Sent=5000; Requests=10; Grain='hourly-summary'; Authenticated=$null }
                ) }
            }
            Get-MsecAppGatewayClientActivity -ClientIp '1.2.3.4' -WorkspaceName 'prod-sentinel-log'
        }

        $row.Grain | Should -Be 'hourly-summary'
        # The summary has no HTTP method, so the question cannot be answered - and $false would
        # assert something that was never measured.
        $row.Authenticated | Should -BeNullOrEmpty
        # A zero status is 'not recorded', not 'HTTP 0'.
        $row.Status | Should -BeNullOrEmpty
    }

    It 'in -SummaryOnly, distinguishes "did not authenticate" from "could not tell"' {
        $out = InModuleScope Msec {
            Mock Invoke-AzOperationalInsightsQuery -MockWith {
                [pscustomobject]@{ Results = @(
                    # Per-request data exists and shows no authentication -> a real $false.
                    [pscustomobject]@{ TimeGenerated='2026-10-01T10:00:00Z'; ClientIp='1.1.1.1'; Method='GET'
                                       Uri='/robots.txt'; Status=404; Host='idp'; Agent='bot'; Sent=10
                                       Requests=1; Grain='per-request'; Authenticated=$false }
                    # Only summary data -> unknown, must not be reported as $false.
                    [pscustomobject]@{ TimeGenerated='2026-10-07T18:00:00Z'; ClientIp='2.2.2.2'; Method=''
                                       Uri='["/"]'; Status=0; Host='["web"]'; Agent='["x"]'; Sent=99
                                       Requests=7; Grain='hourly-summary'; Authenticated=$null }
                ) }
            }
            , @(Get-MsecAppGatewayClientActivity -ClientIp '1.1.1.1','2.2.2.2' -WorkspaceName 'prod-sentinel-log' -SummaryOnly)
        }

        ($out | Where-Object ClientIp -eq '1.1.1.1').Authenticated | Should -BeFalse
        ($out | Where-Object ClientIp -eq '2.2.2.2').Authenticated | Should -BeNullOrEmpty
        ($out | Where-Object ClientIp -eq '2.2.2.2').Requests | Should -Be 7
    }

    It 'warns on no activity, because a Basic-plan table also returns nothing' {
        $warning = InModuleScope Msec {
            Mock Invoke-AzOperationalInsightsQuery -MockWith { [pscustomobject]@{ Results = @() } }
            $w = @()
            Get-MsecAppGatewayClientActivity -ClientIp '1.2.3.4' -WorkspaceName 'prod-sentinel-log' `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }

        $warning | Should -Match 'NOT proof the address was never seen'
        $warning | Should -Match 'Basic-plan'
    }

    It 'lists the candidates when the workspace name is unknown' {
        $err = InModuleScope Msec {
            Mock Invoke-AzOperationalInsightsQuery -MockWith { throw 'must not be called' }
            try { Get-MsecAppGatewayClientActivity -ClientIp '1.2.3.4' -WorkspaceName 'nope'; $null }
            catch { "$($_.Exception.Message)" }
        }
        $err | Should -Match 'prod-sentinel-log'
    }
}
