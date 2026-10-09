#Requires -Module Pester
#
# Tests for Get-MsecDefenderEmail. The function counts matching messages first, then fetches the
# newest MaxMessages of them with the sending country resolved as a column. The tests are built
# around the ways this command could hand back a confident wrong answer:
#
#   1. Truncation must warn with BOTH numbers - filtering happens downstream, so a truncated
#      fetch filtered to one country looks complete and is not.
#   2. The count query and the row query must share one filter, or the count describes a
#      different population from the rows.
#   3. -Direction and -ThreatsOnly must reach the KQL; 'All' must NOT emit a direction filter.
#   4. IPv6 and missing-IP rows must survive into the output with an explicit SenderCountry
#      rather than a blank that a -eq filter would silently swallow.
#   5. Days must be capped at the 30-day hunting retention rather than silently returning less
#      than asked for.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecDefenderEmail' {
    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId        = 'tenant'
                ClientId        = 'client'
                KeyVaultName    = 'kv-test'
                KeyName         = 'msec-app'
                ThumbprintBytes = [byte[]](1..20)
                Tokens          = @{}
            }
        }
    }

    It 'warns with the matching total and the returned count when the result is truncated' {
        $warnings = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Body.Query -match '\|\s*count\s*$') {
                    [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 41237 }) }
                }
                else { [pscustomobject]@{ Results = @() } }
            }

            Get-MsecDefenderEmail -Days 30 -MaxMessages 5000 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        $trunc = $warnings | Where-Object { "$_" -match '41237' }
        $trunc | Should -Not -BeNullOrEmpty
        "$trunc" | Should -Match '5000'
        # The part that matters: downstream filtering is over the subset, not the window.
        "$trunc" | Should -Match 'downstream'
    }

    It 'does not warn when everything matching was returned' {
        $warnings = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Body.Query -match '\|\s*count\s*$') {
                    [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 12 }) }
                }
                else { [pscustomobject]@{ Results = @() } }
            }

            Get-MsecDefenderEmail -MaxMessages 5000 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        $warnings | Should -BeNullOrEmpty
    }

    It 'applies the SAME filter to the count query and the row query' {
        $queries = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }

            Get-MsecDefenderEmail -Days 14 -Direction Inbound -ThreatsOnly -WarningAction SilentlyContinue | Out-Null
            $script:Queries
        }

        @($queries).Count | Should -Be 2
        foreach ($q in $queries) {
            # A count over a different population than the rows is worse than no count at all.
            $q | Should -Match 'ago\(14d\)'
            $q | Should -Match 'EmailDirection == "Inbound"'
            $q | Should -Match 'isnotempty\(ThreatTypes\)'
        }
    }

    It 'emits no direction filter at all for -Direction All' {
        $queries = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }

            Get-MsecDefenderEmail -WarningAction SilentlyContinue | Out-Null
            $script:Queries
        }

        foreach ($q in $queries) {
            $q | Should -Not -Match 'EmailDirection =='
        }
        # ...but direction is still projected, so the caller can filter on it in PowerShell.
        @($queries)[1] | Should -Match 'EmailDirection'
    }

    It 'keeps IPv6 and no-IP messages in the output with an explicit SenderCountry' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Body.Query -match '\|\s*count\s*$') {
                    [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 2 }) }
                }
                else {
                    [pscustomobject]@{ Results = @(
                        [pscustomobject]@{
                            Timestamp = '2026-10-08T10:00:00Z'; EmailDirection = 'Inbound'
                            SenderCountry = '(IPv6 - not geolocated)'; SenderIPv4 = ''
                            SenderIPv6 = '2a00:1450::1'; SenderFromAddress = 'a@example.com'
                            RecipientEmailAddress = 'anton@viedoc.com'; Subject = 'v6'
                            NetworkMessageId = 'nm-1'
                        }
                        [pscustomobject]@{
                            Timestamp = '2026-10-08T09:00:00Z'; EmailDirection = 'IntraOrg'
                            SenderCountry = '(no sender IP)'; SenderIPv4 = ''; SenderIPv6 = ''
                            SenderFromAddress = 'b@viedoc.com'; RecipientEmailAddress = 'anton@viedoc.com'
                            Subject = 'internal'; NetworkMessageId = 'nm-2'
                        }
                    ) }
                }
            }

            Get-MsecDefenderEmail -WarningAction SilentlyContinue
        }

        @($rows).Count | Should -Be 2
        # Not blank. A blank would be swallowed by `Where-Object SenderCountry -eq 'Israel'`
        # exactly like a real miss, which is the confusion the explicit bucket prevents.
        $rows[0].SenderCountry | Should -Be '(IPv6 - not geolocated)'
        $rows[1].SenderCountry | Should -Be '(no sender IP)'
        $rows[0].Timestamp     | Should -BeOfType [datetime]
        $rows[0].PSObject.TypeNames | Should -Contain 'MsecDefenderEmail'
    }

    It 'refuses a window longer than advanced hunting retains' {
        # Accepting -Days 90 and returning 30 days of mail would be the quiet wrong answer.
        { Get-MsecDefenderEmail -Days 90 } | Should -Throw
    }

    It 'applies every filter parameter server-side, in BOTH the count and the row query' {
        $queries = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }

            Get-MsecDefenderEmail -Days 14 -Direction Inbound -SenderCountry 'Israel' `
                -RecipientAddress 'anton@viedoc.com' -DeliveryLocation 'Inbox' `
                -ThreatType Phish -WarningAction SilentlyContinue | Out-Null
            $script:Queries
        }

        @($queries).Count | Should -Be 2
        foreach ($q in $queries) {
            # A count over a different population than the rows is worse than no count at all.
            $q | Should -Match 'ago\(14d\)'
            $q | Should -Match 'EmailDirection == "Inbound"'
            $q | Should -Match 'SenderCountry in~ \("Israel"\)'
            $q | Should -Match 'RecipientEmailAddress in~ \("anton@viedoc.com"\)'
            $q | Should -Match 'LatestDeliveryLocation in~ \("Inbox"\)'
            $q | Should -Match 'ThreatTypes has_any \("Phish"\)'
            # SenderCountry is computed, so the extend must precede the where in both.
            $q.IndexOf('extend SenderCountry') | Should -BeLessThan $q.IndexOf('SenderCountry in~')
        }
    }

    It 'matches a sender domain against BOTH the header From and the envelope MailFrom' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderEmail -SenderDomain 'example.com' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        # Relayed mail carries different values in the two. Matching one would quietly miss it.
        $q | Should -Match 'SenderFromDomain in~ \("example\.com"\)'
        $q | Should -Match 'SenderMailFromDomain in~ \("example\.com"\)'
        $q | Should -Match '\bor\b'
    }

    It 'uses contains for -Subject, not has, so a hyphenated subject still matches' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderEmail -Subject 'invoice', 'payment' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        # `has` is token-based: it finds "Invoice" in "Invoice due" and NOT in "Invoice-2451".
        $q | Should -Match 'Subject contains "invoice"'
        $q | Should -Match 'Subject contains "payment"'
        $q | Should -Not -Match 'Subject has'
    }

    It 'escapes quotes and backslashes in a caller-supplied value instead of breaking the KQL' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderEmail -Subject 'say "hi"' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        # An unescaped quote would terminate the string literal and change what the query means.
        $q | Should -Match 'Subject contains "say \\"hi\\""'
    }

    It 'sends no filter clause for a parameter that was not supplied' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderEmail -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        $q | Should -Not -Match 'EmailDirection =='
        $q | Should -Not -Match 'SenderCountry in~'
        $q | Should -Not -Match 'RecipientEmailAddress in~'
        $q | Should -Not -Match 'Subject contains'
        $q | Should -Not -Match 'ThreatTypes has_any'
        # The window is the one filter that is never optional.
        $q | Should -Match 'ago\(7d\)'
    }

    It 'can ask for the unplaceable buckets by name' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderEmail -SenderCountry '(IPv6 - not geolocated)' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        # The messages that belong to no country must be reachable, not just visible.
        $q | Should -Match 'SenderCountry in~ \("\(IPv6 - not geolocated\)"\)'
    }
}
