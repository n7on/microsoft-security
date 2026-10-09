#Requires -Module Pester
#
# Tests for Get-MsecPurviewActivity.
#
# Export-ActivityExplorerData has three ways of returning nothing without erroring, and every
# one of them was hit while this command was being written. The tests exist to keep each from
# reading as "there was no activity":
#
#   A WINDOW OF 30 DAYS RETURNS A WHOLLY EMPTY RESPONSE - no rows, no total, no result code and
#   no error. 29 days returns the lot. Measured: 29d = 143,952 events, 30d = silence.
#
#   THE FILTER TAKES THE ActivityId TOKEN. 'DLPRuleMatch' matches; 'DLP rule matched' - what the
#   portal and the Activity column both display - returns an empty result rather than an error.
#
#   ONE CALL IS ONE PAGE, NOT THE RESULT SET. Summarising page one of a 29,000-row week gives a
#   confident answer drawn from 17% of it.
#
# Plus two shape traps: PolicyName lives inside PolicyMatchInfo, so grouping by it on the raw
# output buckets everything under one blank key; and SensitivityLabel is a bare GUID.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # Compliance cmdlets do not exist without a live session; stubbed so Pester can mock them.
    function global:Export-ActivityExplorerData {
        [CmdletBinding()]
        param($StartTime, $EndTime, $OutputFormat, $PageSize, $PageCookie, $Filter1)
    }
    function global:Get-Label { }
}
AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
    Remove-Item 'function:global:Export-ActivityExplorerData' -ErrorAction SilentlyContinue
    Remove-Item 'function:global:Get-Label' -ErrorAction SilentlyContinue
}

Describe 'Get-MsecPurviewActivity' {

    It 'refuses a window of 30 days or more, where the API returns silence rather than an error' {
        # 30 and 31 are refused by ValidateRange before any call is made - the API would answer
        # them with silence, which is worse than an error.
        { Get-MsecPurviewActivity -Days 30 } | Should -Throw
        { Get-MsecPurviewActivity -Days 31 } | Should -Throw

        # 29 is the measured ceiling and must be accepted.
        InModuleScope msec {
            Mock Get-Label -MockWith { @() }
            Mock Export-ActivityExplorerData -MockWith {
                [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 0
                                   ResultData = $null; WaterMark = $null; LastPage = $true }
            }
            { Get-MsecPurviewActivity -Days 29 } | Should -Not -Throw
        }
    }

    It 'throws on the empty-response failure mode instead of returning no rows' {
        InModuleScope msec {
            # Exactly what a 30-day window hands back: an object with every field unset. Row
            # count alone cannot tell this from a quiet window, so ResultCode is what is tested.
            Mock Export-ActivityExplorerData -MockWith { [pscustomobject]@{
                ResultCode = $null; TotalResultCount = $null; ResultData = $null
                WaterMark = $null; LastPage = $null } }
            Mock Get-Label -MockWith { @() }

            { Get-MsecPurviewActivity -Days 7 } | Should -Throw '*empty response*'
        }
    }

    It 'refuses the displayed activity name and names the token to use instead' {
        # The expensive one: passing this to the API returns an empty result, not an error.
        { Get-MsecPurviewActivity -Activity 'DLP rule matched' } |
            Should -Throw "*Use 'DLPRuleMatch' instead*"
        { Get-MsecPurviewActivity -Activity 'Label applied' } |
            Should -Throw "*Use 'LabelApplied' instead*"
    }

    It 'pages to the end rather than returning the first page' {
        $rows = InModuleScope msec {
            $script:Call = 0
            Mock Get-Label -MockWith { @() }
            Mock Export-ActivityExplorerData -MockWith {
                $script:Call++
                switch ($script:Call) {
                    1 { [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 3
                                           ResultData = (@([pscustomobject]@{ ActivityId = 'FileRead'; Happened = '2026-10-08T10:00:00Z' }) | ConvertTo-Json -AsArray)
                                           WaterMark = 'wm-1'; LastPage = $false } }
                    2 { [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 3
                                           ResultData = (@([pscustomobject]@{ ActivityId = 'FileRead'; Happened = '2026-10-08T11:00:00Z' }) | ConvertTo-Json -AsArray)
                                           WaterMark = 'wm-2'; LastPage = $false } }
                    default { [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 3
                                           ResultData = (@([pscustomobject]@{ ActivityId = 'FileRead'; Happened = '2026-10-08T12:00:00Z' }) | ConvertTo-Json -AsArray)
                                           WaterMark = $null; LastPage = $true } }
                }
            }
            @(Get-MsecPurviewActivity -Days 7 -WarningAction SilentlyContinue)
        }

        # Three pages, one row each. Stopping at page one would give 1 and look complete.
        $rows.Count | Should -Be 3
        Should -Invoke Export-ActivityExplorerData -ModuleName msec -Times 3 -Exactly
    }

    It 'warns when the pull falls materially short of the API total' {
        $w = InModuleScope msec {
            Mock Get-Label -MockWith { @() }
            Mock Export-ActivityExplorerData -MockWith {
                [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 29000
                                   ResultData = (@([pscustomobject]@{ ActivityId = 'FileRead' }) | ConvertTo-Json -AsArray)
                                   WaterMark = $null; LastPage = $true }
            }
            Get-MsecPurviewActivity -Days 7 -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            $wv
        }
        ($w | Where-Object { "$_" -match 'sample' }) | Should -Not -BeNullOrEmpty
        ($w | Where-Object { "$_" -match '29000' }) | Should -Not -BeNullOrEmpty
    }

    It 'does not warn when a small shortfall reflects events landing mid-pull' {
        $w = InModuleScope msec {
            Mock Get-Label -MockWith { @() }
            Mock Export-ActivityExplorerData -MockWith {
                # 2 short of 100 - ordinary drift, not a truncated pull.
                [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 100
                                   ResultData = ((1..98 | ForEach-Object { [pscustomobject]@{ ActivityId = 'FileRead' } }) | ConvertTo-Json -AsArray)
                                   WaterMark = $null; LastPage = $true }
            }
            Get-MsecPurviewActivity -Days 7 -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            $wv
        }
        $w | Should -BeNullOrEmpty
    }

    It 'flattens PolicyName and RuleName out of PolicyMatchInfo' {
        $row = InModuleScope msec {
            Mock Get-Label -MockWith { @() }
            Mock Export-ActivityExplorerData -MockWith {
                [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 1
                    ResultData = (@([pscustomobject]@{
                        ActivityId = 'DLPRuleMatch'; Activity = 'DLP rule matched'
                        Happened = '2026-10-08T21:51:59Z'; User = 'a@viedoc.com'; Workload = 'OneDrive'
                        PolicyMatchInfo = [pscustomobject]@{
                            PolicyName = 'DLP - GDPR'
                            RuleName   = 'Content detected GDPR - Block external sharing'
                            PolicyMode = 'Enable' }
                    }) | ConvertTo-Json -Depth 6 -AsArray)
                    WaterMark = $null; LastPage = $true }
            }
            Get-MsecPurviewActivity -Days 7 -WarningAction SilentlyContinue
        }

        # Grouping by PolicyName on the raw API output buckets every row under one blank key,
        # which reads as "no policy matched".
        $row.PolicyName | Should -Be 'DLP - GDPR'
        $row.RuleName   | Should -Be 'Content detected GDPR - Block external sharing'
        $row.PolicyMode | Should -Be 'Enable'
        $row.Happened   | Should -BeOfType [datetime]
        $row.PSObject.TypeNames | Should -Contain 'MsecPurviewActivity'
    }

    It 'resolves a label GUID to its name, and surfaces an unresolvable one rather than blanking it' {
        $rows = InModuleScope msec {
            Mock Get-Label -MockWith {
                @([pscustomobject]@{ Guid = '0746a447-2be0-405e-8efb-ecff871d0a53'; DisplayName = 'Confidential' })
            }
            Mock Export-ActivityExplorerData -MockWith {
                [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 3
                    ResultData = (@(
                        [pscustomobject]@{ ActivityId = 'LabelApplied'; SensitivityLabel = '0746a447-2be0-405e-8efb-ecff871d0a53' }
                        [pscustomobject]@{ ActivityId = 'LabelApplied'; SensitivityLabel = 'd145b07c-1216-434b-9d03-d664eda1f6a5' }
                        [pscustomobject]@{ ActivityId = 'FileRead';     SensitivityLabel = '' }
                    ) | ConvertTo-Json -Depth 6 -AsArray)
                    WaterMark = $null; LastPage = $true }
            }
            @(Get-MsecPurviewActivity -Days 7 -WarningAction SilentlyContinue)
        }

        $rows[0].SensitivityLabelName | Should -Be 'Confidential'
        # A label deleted since the event still appears in history. Blank would read as
        # "unlabelled", which is the opposite of what happened.
        $rows[1].SensitivityLabelName | Should -Match 'deleted or unknown'
        $rows[1].SensitivityLabelName | Should -Match 'd145b07c'
        # Genuinely unlabelled stays null.
        $rows[2].SensitivityLabelName | Should -BeNullOrEmpty
    }

    It 'passes the activity token through to the API filter' {
        $captured = InModuleScope msec {
            $script:Filter = $null
            Mock Get-Label -MockWith { @() }
            Mock Export-ActivityExplorerData -MockWith {
                $script:Filter = $Filter1
                [pscustomobject]@{ ResultCode = 'Success'; TotalResultCount = 0
                                   ResultData = $null; WaterMark = $null; LastPage = $true }
            }
            Get-MsecPurviewActivity -Days 7 -Activity DLPRuleMatch, LabelApplied -WarningAction SilentlyContinue | Out-Null
            $script:Filter
        }

        @($captured)[0] | Should -Be 'Activity'
        $captured | Should -Contain 'DLPRuleMatch'
        $captured | Should -Contain 'LabelApplied'
    }

    It 'gives a clear error when the compliance session exposes no Activity Explorer cmdlet' {
        InModuleScope msec {
            Mock Get-Command -ParameterFilter { $Name -eq 'Export-ActivityExplorerData' } -MockWith { $null }
            { Get-MsecPurviewActivity } | Should -Throw '*Connect-MsecPurview*'
        }
    }
}
