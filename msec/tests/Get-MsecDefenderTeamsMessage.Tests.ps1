#Requires -Module Pester
#
# Tests for Get-MsecDefenderTeamsMessage. The function counts matching messages, then fetches
# them with recipients flattened out of a JSON array and URL info joined from a second table.
# The tests are built around what this command can get quietly wrong:
#
#   1. A leftouter join that misses returns an EMPTY PSCustomObject, not $null. [int] on it
#      throws and [bool] on it returns $true - so a missing IsExternalThread would read as
#      external and a message with no links would crash the projection.
#   2. Recipients are an array on ONE row per message, not one row per recipient like mail.
#      They must stay a string[] so -contains tests them exactly.
#   3. Filters must reach both queries, and the count query must NOT carry the mv-apply or the
#      join - it counts the same population by filtering the same raw columns.
#   4. -Subject and -ThreadName must use contains, not the token-based has.
#   5. Days must be capped at the 30-day hunting retention.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecDefenderTeamsMessage' {
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

    It 'survives a leftouter join miss, where the API returns an empty object rather than null' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Body.Query -match '\|\s*count\s*$') {
                    [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
                }
                else {
                    [pscustomobject]@{ Results = @([pscustomobject]@{
                        Timestamp = '2026-10-09T08:12:15Z'; ThreadType = 'chat'; ThreadName = 'Product Team'
                        # Exactly what Kusto hands back for a join that found nothing, and for a
                        # bool column that was absent: an empty object, NOT $null.
                        UrlCount = [pscustomobject]@{}; UrlDomains = [pscustomobject]@{}
                        IsExternalThread = [pscustomobject]@{}; IsOwnedThread = '1'
                        SenderEmailAddress = 'a@viedoc.com'
                        RecipientAddress = @('b@viedoc.com', 'c@viedoc.com')
                        LastEditedTime = [pscustomobject]@{}
                    }) }
                }
            }
            Get-MsecDefenderTeamsMessage -WarningAction SilentlyContinue
        }

        # No URL row found means zero links, not a crash.
        $row.UrlCount   | Should -Be 0
        $row.UrlCount   | Should -BeOfType [int]
        @($row.UrlDomains).Count | Should -Be 0
        # The one that matters most: [bool] on a non-null object is $true, which would mark an
        # internal thread as crossing the tenant boundary.
        $row.IsExternalThread | Should -BeFalse
        $row.IsOwnedThread    | Should -BeTrue
        $row.LastEditedTime   | Should -BeNullOrEmpty
    }

    It 'keeps recipients as a string[] on one row per message, so -contains tests them exactly' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Body.Query -match '\|\s*count\s*$') {
                    [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
                }
                else {
                    [pscustomobject]@{ Results = @([pscustomobject]@{
                        Timestamp = '2026-10-09T08:12:15Z'
                        RecipientAddress = @('bob.egner@viedoc.com', 'laura.oliver@viedoc.com', '')
                        UrlCount = 2; UrlDomains = @('teams.microsoft.com', '')
                    }) }
                }
            }
            Get-MsecDefenderTeamsMessage -WarningAction SilentlyContinue
        }

        # Empty entries dropped - make_list can emit one for a recipient with no SMTP address,
        # and a blank in the array makes `-contains ''` true for every message.
        @($row.RecipientAddress).Count | Should -Be 2
        $row.RecipientAddress | Should -Contain 'laura.oliver@viedoc.com'
        @($row.UrlDomains).Count | Should -Be 1

        # The flattening must happen in KQL, not by joining into a string: a substring match
        # would report 'anna@x' as a hit for 'joanna@x'.
        $row.RecipientAddress -is [array] | Should -BeTrue
    }

    It 'applies filters to both queries, and keeps the mv-apply and join out of the count' {
        $queries = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderTeamsMessage -Days 14 -ExternalOnly -ThreadType chat `
                -SenderType Anonymous -ThreatType Phish -WarningAction SilentlyContinue | Out-Null
            $script:Queries
        }

        @($queries).Count | Should -Be 2
        foreach ($q in $queries) {
            $q | Should -Match 'ago\(14d\)'
            $q | Should -Match 'IsExternalThread'
            $q | Should -Match 'ThreadType in~ \("chat"\)'
            $q | Should -Match 'SenderType in~ \("Anonymous"\)'
            $q | Should -Match 'ThreatTypes has_any \("Phish"\)'
        }

        # The count filters the same raw columns, so it needs neither the flatten nor the join -
        # and must not pay for them.
        @($queries)[0] | Should -Not -Match 'mv-apply'
        @($queries)[0] | Should -Not -Match 'MessageUrlInfo'
        @($queries)[1] | Should -Match 'mv-apply'
        @($queries)[1] | Should -Match 'MessageUrlInfo'
    }

    It 'matches recipients against the raw JSON array, since there is no recipient column' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderTeamsMessage -RecipientAddress 'anton@viedoc.com' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        $q | Should -Match 'tostring\(RecipientDetails\) contains "anton@viedoc\.com"'
    }

    It 'uses contains rather than the token-based has for -Subject and -ThreadName' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderTeamsMessage -Subject 'invoice' -ThreadName 'SMS Teknik' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        # `has` is token-based: 'SMS Teknik' as a thread name and 'Invoice-2451' as a subject
        # both fail it, and a hyphen is exactly where real names live.
        $q | Should -Match 'Subject contains "invoice"'
        $q | Should -Match 'ThreadName contains "SMS Teknik"'
        $q | Should -Not -Match 'Subject has'
        $q | Should -Not -Match 'ThreadName has'
    }

    It 'escapes a caller-supplied value instead of breaking the KQL' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderTeamsMessage -ThreadName 'say "hi"' -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        $q | Should -Match 'ThreadName contains "say \\"hi\\""'
    }

    It 'warns with both numbers when the result is truncated' {
        $warnings = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Body.Query -match '\|\s*count\s*$') {
                    [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1875 }) }
                }
                else { [pscustomobject]@{ Results = @() } }
            }
            Get-MsecDefenderTeamsMessage -MaxMessages 5 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }

        $t = $warnings | Where-Object { "$_" -match '1875' }
        $t | Should -Not -BeNullOrEmpty
        "$t" | Should -Match '\b5\b'
    }

    It 'sends no filter clause for a parameter that was not supplied' {
        $q = InModuleScope Msec {
            $script:Queries = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Queries.Add($Body.Query)
                [pscustomobject]@{ Results = @([pscustomobject]@{ Count = 1 }) }
            }
            Get-MsecDefenderTeamsMessage -WarningAction SilentlyContinue | Out-Null
            @($script:Queries)[0]
        }

        $q | Should -Not -Match 'ThreadType in~'
        $q | Should -Not -Match 'SenderType in~'
        $q | Should -Not -Match 'Subject contains'
        $q | Should -Not -Match 'IsExternalThread'
        $q | Should -Match 'ago\(7d\)'
    }

    It 'refuses a window longer than advanced hunting retains' {
        { Get-MsecDefenderTeamsMessage -Days 90 } | Should -Throw
    }
}
