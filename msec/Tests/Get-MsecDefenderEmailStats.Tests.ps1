#Requires -Module Pester
#
# Tests for Get-MsecDefenderEmailStats. The function POSTs a KQL aggregation to
# Microsoft Graph's /security/runHuntingQuery and projects the single result row
# into a flat summary with percentages. Tests cover:
#   1. The KQL body sent to the API filters Inbound + the right time window.
#   2. Counts come through verbatim; percentages are computed correctly.
#   3. Zero-result responses don't blow up; everything zeroes out.
#   4. A 403 is rewritten to mention ThreatHunting.Read.All.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecDefenderEmailStats' {
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

    It 'sends a KQL POST that filters Inbound + the requested -Days window, and computes percentages' {
        $captured = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            $script:CapturedBody = $null
            $script:CapturedMethod = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/security/runHuntingQuery' } -MockWith {
                $script:CapturedBody   = $Body
                $script:CapturedMethod = $Method
                [pscustomobject]@{
                    Schema  = @()
                    Results = @(
                        [pscustomobject]@{
                            Total     = 1000
                            Delivered = 850
                            Junked    = 100
                            Blocked   = 40
                            Replaced  = 10
                            Phishing  = 25
                            Spam      = 75
                            Malware   = 5
                        }
                    )
                }
            }

            $out = Get-MsecDefenderEmailStats -Days 30
            [pscustomobject]@{ Out = $out; Body = $script:CapturedBody; Method = $script:CapturedMethod }
        }

        # Method + KQL shape. Body is the JSON-encoded payload, so the patterns
        # use \w-friendly fragments rather than full literals with quotes (which
        # would be backslash-escaped in the encoded form).
        $captured.Method | Should -Be 'POST'
        $captured.Body   | Should -Match 'EmailEvents'
        $captured.Body   | Should -Match 'ago\(30d\)'              # window flowed through from -Days
        $captured.Body   | Should -Match 'EmailDirection.*Inbound' # direction filter applied
        $captured.Body   | Should -Match 'ThreatTypes.*Phish'      # threat-type filter applied
        # And NOT outbound - direction filter is hard-coded to Inbound.
        $captured.Body   | Should -Not -Match 'Outbound'

        # Raw counts pass through.
        $captured.Out.Total     | Should -Be 1000
        $captured.Out.Delivered | Should -Be 850
        $captured.Out.Junked    | Should -Be 100
        $captured.Out.Blocked   | Should -Be 40
        $captured.Out.Replaced  | Should -Be 10
        $captured.Out.Phishing  | Should -Be 25
        $captured.Out.Spam      | Should -Be 75
        $captured.Out.Malware   | Should -Be 5

        # Percentages: each / Total * 100, rounded to 2dp.
        $captured.Out.DeliveredPercent | Should -Be 85.0
        $captured.Out.JunkedPercent    | Should -Be 10.0
        $captured.Out.BlockedPercent   | Should -Be 4.0
        $captured.Out.PhishingPercent  | Should -Be 2.5
        $captured.Out.SpamPercent      | Should -Be 7.5
        $captured.Out.MalwarePercent   | Should -Be 0.5
    }

    It 'returns all-zero counts (no division-by-zero) when the API returns no rows' {
        $out = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/security/runHuntingQuery' } -MockWith {
                [pscustomobject]@{ Schema = @(); Results = @() }
            }

            Get-MsecDefenderEmailStats
        }

        $out.Total            | Should -Be 0
        $out.Phishing         | Should -Be 0
        # All percentages should be 0.0, not NaN / divide-by-zero / null.
        $out.PhishingPercent  | Should -Be 0.0
        $out.DeliveredPercent | Should -Be 0.0
    }

    It 'rewrites a 403 to mention the missing ThreatHunting.Read.All permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/security/runHuntingQuery' } -MockWith {
                # Mimic Invoke-RestMethod's HttpResponseException for a 403.
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecDefenderEmailStats } |
                Should -Throw -ExpectedMessage '*ThreatHunting.Read.All*'
        }
    }
}
