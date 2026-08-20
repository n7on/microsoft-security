#Requires -Module Pester
#
# Tests for Search-MsecLogAnalytics: the Kql/Law file convention, workspace resolution through
# Resource Graph and its two failure modes, and the invariants the bundled Law queries rely on.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Redirect the completion cache for the whole file. Every test here resolves a workspace,
    # which refreshes the cache - with Search-AzGraph mocked that would write MOCK data into the
    # developer's real cache.
    $script:PrevCacheEnv = $env:MSEC_CACHE_DIR
    $env:MSEC_CACHE_DIR  = Join-Path ([System.IO.Path]::GetTempPath()) "msec-test-cache-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $env:MSEC_CACHE_DIR -Force | Out-Null
    $script:CacheDir  = $env:MSEC_CACHE_DIR

    # Tenant-scoped now, so ask the module rather than assuming a flat layout - and mock the
    # context while asking. Get-MsecCachePath needs a tenant for the subfolder and THROWS
    # without one, which MSEC_CACHE_DIR does not satisfy: the tenant check comes first.
    #
    # A developer with an ambient `az login` never sees that. A CI runner has no context, so
    # this line threw in BeforeAll and Pester failed the whole CONTAINER - taking down all ten
    # tests in the file, including the four Kql ones that only read files off disk. 'tenant-1'
    # matches what every test below mocks, so setup and tests resolve the same cache folder.
    $script:CachePath = InModuleScope msec {
        Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-1' } } }
        Get-MsecCachePath -Name 'graph-loganalytics-all'
    }
}

AfterAll {
    if ($script:CacheDir -and (Test-Path -LiteralPath $script:CacheDir)) {
        Remove-Item -LiteralPath $script:CacheDir -Recurse -Force
    }
    $env:MSEC_CACHE_DIR = $script:PrevCacheEnv
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Search-MsecLogAnalytics' {
    BeforeEach {
        # Workspace resolution reads the cached workspace list, so a previous test's mocked
        # workspaces would be served to the next one from disk.
        Get-ChildItem -LiteralPath $script:CacheDir -Filter *.json -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    It 'loads the .kql by convention, resolves the workspace name, and passes the window as a timespan' {
        $result = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith {
                @([pscustomobject]@{ Name = 'ws-1'; ResourceGroupName = 'rg-a'
                                     SubscriptionId = 'sub-1'; CustomerId = 'cid-1'; Location = 'westeurope' })
            }
            $script:CapturedQuery = $null
            $script:CapturedId    = $null
            $script:CapturedSpan  = $null
            Mock Invoke-AzOperationalInsightsQuery -MockWith {
                $script:CapturedQuery = $Query
                $script:CapturedId    = $WorkspaceId
                $script:CapturedSpan  = $Timespan
                [pscustomobject]@{ Results = @([pscustomobject]@{ RuleId = '920230' }) }
            }

            $rows = Search-MsecLogAnalytics -Subject Waf -WorkspaceName ws-1 -Days 3
            $byDays = $script:CapturedSpan
            $null = Search-MsecLogAnalytics -Subject Waf -WorkspaceName ws-1 -Timespan 4:00
            [pscustomobject]@{ Rows = $rows; Query = $script:CapturedQuery; WorkspaceId = $script:CapturedId
                               ByDays = $byDays; ByTimespan = $script:CapturedSpan }
        }

        # The workspace NAME is resolved to its customerId - that GUID is what the API takes -
        # and the window is a server-side timespan, not a clause appended to the query.
        $result.WorkspaceId | Should -Be 'cid-1'
        $result.ByDays      | Should -Be ([TimeSpan]::FromDays(3))
        $result.ByTimespan  | Should -Be ([TimeSpan]::FromHours(4))
        $result.Query       | Should -Match 'ApplicationGatewayFirewallLog'
        $result.Rows[0].Workspace | Should -Be 'ws-1'
    }

    It 'lists the available workspaces when the name does not resolve' {
        # "Workspace not found" on its own sends you to the portal. With dozens of workspaces the
        # candidate list is the entire value of the error.
        InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith {
                @([pscustomobject]@{ Name = 'contoso-monitoring-log'; ResourceGroupName = 'rg-a'
                                     SubscriptionId = 'sub-1'; CustomerId = 'cid-1' },
                  [pscustomobject]@{ Name = 'contoso-sentinel-log'; ResourceGroupName = 'rg-b'
                                     SubscriptionId = 'sub-1'; CustomerId = 'cid-2' })
            }
            Mock Invoke-AzOperationalInsightsQuery -MockWith { [pscustomobject]@{ Results = @() } }

            { Search-MsecLogAnalytics -Subject Waf -WorkspaceName typo-log } |
                Should -Throw -ExpectedMessage '*Available: contoso-monitoring-log, contoso-sentinel-log*'
        }
    }

    It 'refuses to guess when a workspace name is ambiguous' {
        # Two workspaces of the same name in different resource groups is normal in a sharded
        # estate. Picking one silently would query the wrong data and look completely fine.
        InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith {
                @([pscustomobject]@{ Name = 'dup-log'; ResourceGroupName = 'rg-a'
                                     SubscriptionId = 'sub-1'; CustomerId = 'cid-1' },
                  [pscustomobject]@{ Name = 'dup-log'; ResourceGroupName = 'rg-b'
                                     SubscriptionId = 'sub-2'; CustomerId = 'cid-2' })
            }
            Mock Invoke-AzOperationalInsightsQuery -MockWith { [pscustomobject]@{ Results = @() } }

            { Search-MsecLogAnalytics -Subject Waf -WorkspaceName dup-log } | Should -Throw -ExpectedMessage '*ambiguous*'
            { Search-MsecLogAnalytics -Subject Waf -WorkspaceName dup-log -ResourceGroupName rg-b } | Should -Not -Throw
        }
    }

    It 'tab-completes -Subject and -Name from the Kql/Law tree' {
        $line = 'Search-MsecLogAnalytics -Subject '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'Waf'

        $line = 'Search-MsecLogAnalytics -Subject Waf -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'All'
        $names | Should -Contain 'TopRules'
    }
}

Describe '-WorkspaceName completion' {
    It 'completes from the cached workspace query' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:CachePath) -Force | Out-Null
        Set-Content -LiteralPath $script:CachePath -Encoding utf8 -Value (@{
            UpdatedUtc = '2026-01-01T00:00:00Z'
            Items      = @(
                @{ Name = 'contoso-sentinel-log';   ResourceGroupName = 'rg-sec'; Location = 'westeurope' }
                @{ Name = 'contoso-monitoring-log'; ResourceGroupName = 'rg-mon'; Location = 'francecentral' }
            )
        } | ConvertTo-Json -Depth 4)

        $line = 'Search-MsecLogAnalytics -Subject Waf -WorkspaceName contoso-m'
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'contoso-monitoring-log'
        $names | Should -Not -Contain 'contoso-sentinel-log'
    }

    It 'refreshes the cache even when the workspace name does not resolve' {
        # The first attempt at a half-remembered name is exactly when you most need completion to
        # start working. Enumerating BEFORE matching is what makes the retry tab-completable.
        $cached = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith {
                @([pscustomobject]@{ Name = 'newly-discovered-log'; ResourceGroupName = 'rg-x'
                                     SubscriptionId = 'sub-1'; CustomerId = 'cid-9' })
            }
            Mock Invoke-AzOperationalInsightsQuery -MockWith { [pscustomobject]@{ Results = @() } }

            try { Search-MsecLogAnalytics -Subject Waf -WorkspaceName nope } catch { }
            Read-MsecCache -Name 'graph-loganalytics-all'
        }

        $cached.Name | Should -Contain 'newly-discovered-log'
    }
}

Describe 'Kql/Law bundled queries' {
    BeforeAll {
        $script:LawRoot = Join-Path (Get-Module msec).ModuleBase 'Kql/Law'
    }

    It 'carries no time filter - the window belongs to -Days' {
        # -Days is passed to the API as a server-side timespan. A window baked into a file is
        # invisible at the call site and silently intersects with the one the caller asked for.
        $offenders = Get-ChildItem -LiteralPath $script:LawRoot -Filter *.kql -File -Recurse | ForEach-Object {
            $code = ((Get-Content -LiteralPath $_.FullName) | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            if ($code -match 'TimeGenerated\s*[<>]' -or $code -match '\bago\s*\(') { $_.Name }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'reads both App Gateway log modes and the GUID-suffixed transaction id' {
        # A per-gateway diagnostic setting decides whether firewall logs land in AzureDiagnostics
        # or AGWFirewallLogs; reading one means a setting change silently empties the report.
        # And AzureDiagnostics suffixes dynamic columns by TYPE - transactionId is a guid, so _g.
        # Reading _s returns nothing without erroring, which made dcount(TransactionId) report
        # exactly 1 on every row: a per-request count that was silently always one.
        foreach ($name in 'All', 'TopRules') {
            $q = Get-Content -LiteralPath (Join-Path $script:LawRoot "Waf/$name.kql") -Raw
            $q | Should -Match 'union isfuzzy=true'
            $q | Should -Match 'AGWFirewallLogs'
            $q | Should -Match "Category == 'ApplicationGatewayFirewallLog'"
            $q | Should -Match "column_ifexists\('transactionId_g'"
            $q | Should -Not -Match "column_ifexists\('transactionId_s'"
        }
    }

    It 'makes the VM overview resilient to a missing table but keeps the single-table variants strict' {
        # Kql/Law/VM/All is a cross-signal roster over a mixed estate, so a Linux-only workspace
        # (no Event/SecurityEvent) or a Windows-only one (no Syslog) must NOT fail the whole query -
        # that is what union isfuzzy=true buys. The per-signal variants target one table each and
        # deliberately do the opposite: no isfuzzy, so an absent table errors naming it rather than
        # lying with a blank result.
        $all = Get-Content -LiteralPath (Join-Path $script:LawRoot 'VM/All.kql') -Raw
        $all | Should -Match 'union isfuzzy=true'
        foreach ($table in 'Heartbeat', 'Event', 'Syslog', 'SecurityEvent') {
            $all | Should -Match $table
        }

        $singles = @{ Heartbeat = 'Heartbeat'; WindowsEvents = 'Event'
                      Syslog = 'Syslog'; SecurityEvents = 'SecurityEvent' }
        foreach ($name in $singles.Keys) {
            $path = Join-Path $script:LawRoot "VM/$name.kql"
            # Comments talk ABOUT isfuzzy; the query code must not USE it. Strip comment lines the
            # same way the "no time filter" test does before asserting.
            $code = ((Get-Content -LiteralPath $path) | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            $code | Should -Not -Match 'isfuzzy'
            $code | Should -Match $singles[$name]
        }
    }

    It 'shares a byte-identical normalization block between the two Waf queries' {
        # Duplicated because Log Analytics cannot share a fragment across files. Duplicated and
        # DIVERGED would mean Action and RuleId mean different things in the two views.
        $begin = '>>> BEGIN WAF LOG NORMALIZATION'
        $end   = '>>> END WAF LOG NORMALIZATION'
        $blocks = foreach ($name in 'All', 'TopRules') {
            $q = (Get-Content -LiteralPath (Join-Path $script:LawRoot "Waf/$name.kql") -Raw) -replace "`r`n", "`n"
            $q.Substring($q.IndexOf($begin), $q.IndexOf($end) - $q.IndexOf($begin) + $end.Length)
        }
        $blocks[0] | Should -BeExactly $blocks[1]
    }
}
