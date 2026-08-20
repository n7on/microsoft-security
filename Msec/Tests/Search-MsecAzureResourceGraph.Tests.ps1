#Requires -Module Pester
#
# Tests for Search-MsecAzureResourceGraph. Verifies the .kql-file convention, the
# Az.ResourceGraph response unwrap, error handling for missing query files, and
# the tab-completion pathway (which has caught real bugs that InModuleScope
# would miss because it inherits the module's $script: state).

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Redirect the completion cache for the whole file. An unscoped Search-MsecAzureResourceGraph
    # enumerates subscriptions and refreshes the cache, and with Get-AzSubscription mocked that
    # writes MOCK data - which lands in the developer's real cache and leaves -Subscription
    # completing to 'sub-1'. There is a guard test in MsecCompletionCache.Tests.ps1 that fails if
    # a test file which can trigger a cache write forgets this.
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
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Search-MsecAzureResourceGraph' {
    BeforeEach {
        # Results are cached by default, so the same query run in two tests would serve the
        # first test's mocked rows to the second and the second's mock would look like it had
        # no effect. Start every test cache-cold. (Pester rejects BeforeEach at file root, so
        # this lives in each Describe that re-runs a query.)
        Get-ChildItem -LiteralPath $script:CacheDir -Filter *.json -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    It 'loads Kql/Graph/VM/All.kql by convention and shuttles it to Search-AzGraph unchanged' {
        $result = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith {
                $script:CapturedQuery = $Query
                @(
                    [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a'; Os = 'Linux' }
                )
            }

            $rows = Search-MsecAzureResourceGraph -ResourceType VM
            [pscustomobject]@{ Rows = $rows; Query = $script:CapturedQuery }
        }

        # The query that hit Search-AzGraph is exactly what's in the .kql file -
        # no filter clauses appended.
        $result.Query | Should -Match "type =~ 'microsoft.compute/virtualmachines'"
        $result.Query | Should -Match 'project Name\s*=\s*name'
        $result.Query | Should -Not -Match 'Os =~'           # no in-query filtering anymore
        $result.Query | Should -Not -Match 'Running =='
        $result.Query | Should -Not -Match "ResourceGroupName =~"

        $result.Rows.Count | Should -Be 1
        $result.Rows[0].Name | Should -Be 'lin-1'
    }

    It 'unwraps Search-AzGraph response objects that have a .Data array' {
        # Reproduces what Az.ResourceGraph returns on some installs: ONE object with
        # .SkipToken (string) + .Data (array of rows). Without unwrapping, downstream
        # Where-Object can only filter on 'SkipToken' / 'Data' - useless.
        $rows = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith {
                [pscustomobject]@{
                    SkipToken = ''
                    Data      = @(
                        [pscustomobject]@{ Name = 'lin-1'; Os = 'Linux';   Running = $true }
                        [pscustomobject]@{ Name = 'win-1'; Os = 'Windows'; Running = $true }
                    )
                }
            }
            Search-MsecAzureResourceGraph -ResourceType VM
        }

        # We should see two rows, with the actual VM properties accessible for filtering.
        $rows.Count                                    | Should -Be 2
        ($rows | Where-Object Os -eq 'Linux').Name     | Should -Be 'lin-1'
        # SkipToken / Data must not leak through as row properties.
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'SkipToken'
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'Data'
    }

    It '-CurrentSubscription scopes the query to just the active context subscription' {
        # Must NOT enumerate every accessible sub - it should pass only the current one
        # to Search-AzGraph.
        $sub = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-current' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { throw 'should not enumerate all subscriptions with -CurrentSubscription' }
            $script:CapturedSub = $null
            Mock Search-AzGraph -MockWith { $script:CapturedSub = $Subscription; @() }

            $null = Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription
            , $script:CapturedSub
        }
        $sub | Should -Be @('sub-current')
    }

    It 'resolves -Subscription by name, passes an id straight through, and refuses an ambiguous name' {
        # Names are what people remember, but they are not unique - this estate has three
        # subscriptions called 'Cloud Subscription'. An id must therefore still work, and an
        # ambiguous name must fail with the candidates rather than pick one.
        $captured = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 't1' } } }
            Mock Get-AzSubscription -MockWith {
                @([pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'Contoso-Prod'; TenantId = 't1' },
                  [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; Name = 'Shared-Name'; TenantId = 't1' },
                  [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; Name = 'Shared-Name'; TenantId = 't2' })
            }
            $script:CapturedSub = $null
            Mock Search-AzGraph -MockWith { $script:CapturedSub = $Subscription; @() }

            $null = Search-MsecAzureResourceGraph -ResourceType VM -Subscription 'Contoso-Prod'
            $byName = $script:CapturedSub
            # A GUID needs no lookup at all, so this must not depend on enumeration succeeding.
            $null = Search-MsecAzureResourceGraph -ResourceType VM -Subscription '99999999-9999-9999-9999-999999999999'
            [pscustomobject]@{ ByName = $byName; ById = $script:CapturedSub }
        }

        $captured.ByName | Should -Be @('11111111-1111-1111-1111-111111111111')
        $captured.ById   | Should -Be @('99999999-9999-9999-9999-999999999999')

        InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 't1' } } }
            Mock Get-AzSubscription -MockWith {
                @([pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; Name = 'Shared-Name'; TenantId = 't1' },
                  [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; Name = 'Shared-Name'; TenantId = 't2' })
            }
            Mock Search-AzGraph -MockWith { @() }
            { Search-MsecAzureResourceGraph -ResourceType VM -Subscription 'Shared-Name' } |
                Should -Throw -ExpectedMessage '*ambiguous*'
            { Search-MsecAzureResourceGraph -ResourceType VM -Subscription 'No-Such-Sub' } |
                Should -Throw -ExpectedMessage '*not found. Available: Shared-Name*'
        }
    }

    It 'reuses a cached result, honours -NoCache, and never crosses subscription scopes' {
        # Caching is on by default. The scope label is what keeps that safe: a result gathered
        # for one subscription must never be served to an unscoped call, which would report a
        # fraction of the estate as all of it.
        $calls = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1'; Name = 'Contoso-Prod'; TenantId = 'tenant-1' }) }
            $script:Calls = 0
            Mock Search-AzGraph -MockWith { $script:Calls++; @([pscustomobject]@{ Name = 'vm-1' }) }

            $null = Search-MsecAzureResourceGraph -ResourceType VM              # live
            $first = $script:Calls
            $null = Search-MsecAzureResourceGraph -ResourceType VM              # cached
            $second = $script:Calls
            $null = Search-MsecAzureResourceGraph -ResourceType VM -NoCache     # forced live
            $third = $script:Calls
            $null = Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription  # different scope
            [pscustomobject]@{ First = $first; Second = $second; Third = $third; Scoped = $script:Calls }
        }

        $calls.First  | Should -Be 1   # first call queries Azure
        $calls.Second | Should -Be 1   # second is served from cache
        $calls.Third  | Should -Be 2   # -NoCache goes back to Azure
        $calls.Scoped | Should -Be 3   # a different scope must not reuse the unscoped result
    }

    It 'throws when -CurrentSubscription and -Subscription are both supplied' {
        InModuleScope Msec {
            Mock Get-AzContext  -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Search-AzGraph -MockWith { @() }
            { Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription -Subscription 'sub-2' } |
                Should -Throw -ExpectedMessage '*either -CurrentSubscription or -Subscription*'
        }
    }

    It 'throws a clear error when the named .kql file does not exist' {
        InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith { @() }
            { Search-MsecAzureResourceGraph -ResourceType VM -Name 'NoSuchQuery' } |
                Should -Throw -ExpectedMessage 'KQL query file not found:*'
        }
    }

    # Tab-completion tests go through PowerShell's real completion entry point
    # (TabExpansion2), NOT InModuleScope + & $scriptblock - the latter passed even when the
    # completer was actually broken because it ran the scriptblock with module $script:
    # scope available, whereas the real completion engine does not. These tests would
    # catch a regression to module-scoped state usage in the completer scriptblock.
    It 'tab completion for -ResourceType returns folders containing .kql files' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'VM'
    }

    It 'tab completion for -Name returns the .kql file basenames in the chosen ResourceType folder' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType VM -Name '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'All'
    }

    It 'pipes cleanly through Where-Object into Invoke-MsecAzureVMScript' {
        # End-to-end: ARG-shaped rows -> Where-Object -> runner. Validates that
        # Search-MsecAzureResourceGraph's output (Name + ResourceGroupName) binds correctly to the runner.
        $captured = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith {
                @(
                    [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a'; Os = 'Linux';   Running = $true }
                    [pscustomobject]@{ Name = 'win-1'; ResourceGroupName = 'rg-a'; Os = 'Windows'; Running = $true }
                )
            }
            $script:CapturedVmNames = @()
            Mock Invoke-AzVMRunCommand -MockWith {
                $script:CapturedVmNames += $Name
                [pscustomobject]@{ Status = 'Succeeded'; Value = @() }
            }

            Search-MsecAzureResourceGraph -ResourceType VM |
                Where-Object Os -eq Linux |
                Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info -TimeoutSeconds 0 |
                Out-Null
            ,$script:CapturedVmNames
        }

        $captured.Count | Should -Be 1
        $captured[0]    | Should -Be 'lin-1'
    }
}

Describe 'Search-MsecAzureResourceGraph pagination' {
    BeforeEach {
        # Every test here runs VM/All; without clearing, the second onwards would be served the
        # first one's cached rows instead of exercising its own paging mock.
        Get-ChildItem -LiteralPath $script:CacheDir -Filter *.json -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
        InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
        }
    }

    It 'follows the skip token and returns every page, not just the first 1000 rows' {
        # KeyVault/NetworkRules is over 1100 rows on a mid-sized tenant, so single-page
        # behaviour silently dropped real findings off the end of a security report.
        $rows = InModuleScope Msec {
            $script:Calls = 0
            Mock Search-AzGraph -MockWith {
                $script:Calls++
                if ($script:Calls -eq 1) {
                    [pscustomobject]@{ SkipToken = 'tok-1'; Data = @([pscustomobject]@{ Name = 'page1' }) }
                }
                else {
                    [pscustomobject]@{ SkipToken = ''; Data = @([pscustomobject]@{ Name = 'page2' }) }
                }
            }
            Search-MsecAzureResourceGraph -ResourceType VM
        }

        $rows.Count  | Should -Be 2
        $rows[0].Name | Should -Be 'page1'
        $rows[1].Name | Should -Be 'page2'
        # SkipToken must not leak through as a row property.
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'SkipToken'
    }

    It 'passes the previous page token back to Search-AzGraph' {
        $token = InModuleScope Msec {
            $script:Calls = 0
            $script:SeenToken = $null
            Mock Search-AzGraph -MockWith {
                $script:Calls++
                if ($script:Calls -eq 1) {
                    [pscustomobject]@{ SkipToken = 'tok-1'; Data = @([pscustomobject]@{ Name = 'a' }) }
                }
                else {
                    $script:SeenToken = $SkipToken
                    [pscustomobject]@{ SkipToken = ''; Data = @() }
                }
            }
            $null = Search-MsecAzureResourceGraph -ResourceType VM
            $script:SeenToken
        }
        $token | Should -Be 'tok-1'
    }

    It 'stops at -MaxRows with a warning rather than truncating silently' {
        # An under-reported security query is indistinguishable from a clean one, so the
        # ceiling must be loud. The mock never stops handing out tokens.
        $result = InModuleScope Msec {
            Mock Search-AzGraph -MockWith {
                [pscustomobject]@{
                    SkipToken = 'always-more'
                    Data      = @([pscustomobject]@{ Name = 'x' }, [pscustomobject]@{ Name = 'y' })
                }
            }
            $rows = Search-MsecAzureResourceGraph -ResourceType VM -MaxRows 3 `
                        -WarningVariable w -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($w) }
        }

        $result.Rows.Count | Should -Be 3
        # Filtered, not counted outright: the point is that truncation is reported ONCE and
        # not per page, which is a claim about this command's warnings only. Counting every
        # warning in the variable also counts Az.Accounts' version-upgrade advisory, which
        # has nothing to do with paging and is not present on every machine.
        @($result.Warnings | Where-Object { $_ -match 'INCOMPLETE' }).Count | Should -Be 1
    }

    It 'makes exactly one call when the response is a bare row array with no token' {
        $calls = InModuleScope Msec {
            $script:Calls = 0
            Mock Search-AzGraph -MockWith {
                $script:Calls++
                @([pscustomobject]@{ Name = 'only' })
            }
            $null = Search-MsecAzureResourceGraph -ResourceType VM
            $script:Calls
        }
        $calls | Should -Be 1
    }
}

Describe 'Kql/Graph/KeyVault' {
    It 'tab-completes KeyVault and both of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'KeyVault'

        $line = 'Search-MsecAzureResourceGraph -ResourceType KeyVault -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'All'
        $names | Should -Contain 'NetworkRules'
    }

    It 'All.kql treats a missing networkAcls block as open, not unknown' {
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $null = Search-MsecAzureResourceGraph -ResourceType KeyVault
            $script:CapturedQuery
        }

        $query | Should -Match "type =~ 'microsoft.keyvault/vaults'"
        # A vault with no firewall reports an EMPTY defaultAction and behaves as Allow.
        # Both halves of that test must be present or the open vaults hide.
        $query | Should -Match "isempty\(DefaultAction\) or DefaultAction =~ 'Allow'"
        foreach ($state in 'PrivateOnly', 'OpenToAllNetworks', 'Restricted') {
            $query | Should -Match "'$state'"
        }
        # Absent publicNetworkAccess means Enabled - defaulting it the other way would
        # report public vaults as private.
        $query | Should -Match "isempty\(PublicNetworkAccess\), 'Enabled'"
    }

    It 'NetworkRules.kql covers ip rules, vnet rules and vaults with neither' {
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $null = Search-MsecAzureResourceGraph -ResourceType KeyVault -Name NetworkRules
            $script:CapturedQuery
        }

        foreach ($ruleType in 'IPv4', 'VirtualNetwork', 'None') {
            $query | Should -Match "RuleType = '$ruleType'"
        }
        # mv-expand drops vaults whose rule arrays are empty, so the third leg is what keeps
        # an unconfigured vault - the whole point of the report - in the results.
        $query | Should -Match 'array_length\(properties\.networkAcls\.ipRules\), 0\) == 0'
        # An allow-list only enforces when the default is Deny AND the door is open.
        $query | Should -Match "Effective = \(DefaultAction =~ 'Deny'\) and \(PublicNetworkAccess =~ 'Enabled'\)"
    }
}

Describe 'Kql/Graph/Storage' {
    It 'tab-completes Storage and both of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'Storage'

        $line = 'Search-MsecAzureResourceGraph -ResourceType Storage -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'All'
        $names | Should -Contain 'NetworkRules'
    }

    It 'All.kql defaults the three absent-means-permissive properties the permissive way' {
        # allowBlobPublicAccess, allowSharedKeyAccess and minimumTlsVersion are routinely
        # ABSENT rather than set, and absent means permissive for all three. Coalescing them
        # to false / TLS1_2 would silently under-report exposure - the failure mode that
        # makes a security report worse than no report.
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $null = Search-MsecAzureResourceGraph -ResourceType Storage
            $script:CapturedQuery
        }

        $query | Should -Match "type =~ 'microsoft.storage/storageaccounts'"
        $query | Should -Match 'BlobPublicAccessAllowed = coalesce\(tobool\(properties\.allowBlobPublicAccess\), true\)'
        $query | Should -Match 'SharedKeyAccessAllowed  = coalesce\(tobool\(properties\.allowSharedKeyAccess\), true\)'
        $query | Should -Match "'TLS1_0', tostring\(properties\.minimumTlsVersion\)"
        foreach ($state in 'PrivateOnly', 'SecuredByPerimeter', 'OpenToAllNetworks', 'Restricted') {
            $query | Should -Match "'$state'"
        }
    }

    It 'NetworkRules.kql covers all four rule kinds plus accounts with none' {
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $null = Search-MsecAzureResourceGraph -ResourceType Storage -Name NetworkRules
            $script:CapturedQuery
        }

        foreach ($ruleType in 'IPv4', 'IPv6', 'VirtualNetwork', 'ResourceAccess', 'None') {
            $query | Should -Match "RuleType = '$ruleType'"
        }
        # The None leg must test ALL FOUR arrays. Omitting one would drop every account whose
        # only rules are of that kind from the "no rules" bucket AND leave it uncounted.
        foreach ($array in 'ipRules', 'ipv6Rules', 'virtualNetworkRules', 'resourceAccessRules') {
            $query | Should -Match "array_length\(properties\.networkAcls\.$array\), 0\) == 0"
        }
        $query | Should -Match "Effective = \(DefaultAction =~ 'Deny'\) and \(PublicNetworkAccess =~ 'Enabled'\)"
    }
}

Describe 'Kql/Graph/NSG' {
    It 'tab-completes NSG and both of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'NSG'

        $line = 'Search-MsecAzureResourceGraph -ResourceType NSG -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'All'
        $names | Should -Contain 'SecurityRules'
    }

    It 'SecurityRules.kql projects every column the old script produced, plus IsDefault, and fan-out is per-rule' {
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }

            $null = Search-MsecAzureResourceGraph -ResourceType NSG -Name SecurityRules
            $script:CapturedQuery
        }

        $query | Should -Match "type =~ 'microsoft.network/networksecuritygroups'"
        # One row per rule, not per NSG.
        $query | Should -Match 'mv-expand Rule = Rules'
        # Every column the script it replaces produced, plus IsDefault.
        foreach ($column in 'NsgName', 'AppliedToType', 'AppliedToName', 'RuleName', 'Direction',
                            'Priority', 'Access', 'Protocol', 'Source', 'SourcePort', 'Destination',
                            'DestinationPort', 'IsDefault', 'SubscriptionName') {
            $query | Should -Match "\b$column\b"
        }
        # All three ways an NSG can be referenced must be covered, or an NSG that is in use
        # is reported as an orphan. NICs alone - what the old script walked - is not enough:
        # a subnet-bound NSG has no NICs, and a Uniform scale set's instance NICs are child
        # resources that never appear in ARG's networkinterfaces table.
        $query | Should -Match 'microsoft.network/networkinterfaces'
        $query | Should -Match "AppliedToType = 'Subnet'"
        $query | Should -Match 'microsoft.compute/virtualmachinescalesets'
        $query | Should -Match "AppliedToType = 'VMSS'"
        # The attachment lookup must NOT be collapsed into one label per NSG: the fan-out is
        # what keeps AppliedToType / AppliedToName scalar and groupable.
        $query | Should -Not -Match 'summarize\s+AppliedTo'
    }

    It 'All.kql flags NSGs that are attached to nothing' {
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }

            $null = Search-MsecAzureResourceGraph -ResourceType NSG
            $script:CapturedQuery
        }

        $query | Should -Match "type =~ 'microsoft.network/networksecuritygroups'"
        # VmssCount must be part of the sum. An NSG used only by a Uniform scale set has
        # SubnetCount = NicCount = 0 and would otherwise be reported as safe to delete.
        $query | Should -Match 'Attached\s*=\s*\(SubnetCount \+ NicCount \+ VmssCount\) > 0'
        $query | Should -Match 'microsoft.compute/virtualmachinescalesets'
    }
}

Describe 'Kql/Graph/MySQL' {
    It 'tab-completes MySQL as a ResourceType' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'MySQL'
    }

    It 'All.kql classifies the network access model' {
        # NetworkMode is the whole point of this query: Resource Graph cannot reach a
        # flexible server's firewall rules (no child type is projected), so the access model
        # is the closest thing to an exposure answer that KQL alone can give.
        $query = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $null = Search-MsecAzureResourceGraph -ResourceType MySQL
            $script:CapturedQuery
        }

        $query | Should -Match "type =~ 'microsoft.dbformysql/flexibleservers'"
        foreach ($mode in 'VNetIntegrated', 'PrivateEndpoint', 'Public', 'Isolated') {
            $query | Should -Match "'$mode'"
        }
        $query | Should -Match '\bPublicNetworkAccess\b'
    }
}

Describe 'Kql/Graph/AppGateway' {
    BeforeAll {
        $script:AppGwQueries = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $captured = @{}
            foreach ($queryName in 'All', 'Sites', 'Backends') {
                $null = Search-MsecAzureResourceGraph -ResourceType AppGateway -Name $queryName
                $captured[$queryName] = $script:CapturedQuery
            }
            $captured
        }
    }

    It 'tab-completes AppGateway and all three of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'AppGateway'

        $line = 'Search-MsecAzureResourceGraph -ResourceType AppGateway -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        foreach ($queryName in 'All', 'Sites', 'Backends') { $names | Should -Contain $queryName }
    }

    It 'All.kql reads both places a gateway WAF can live, and tests the tier with contains' {
        # A WAF_v2 gateway keeps its WAF in a separate policy and leaves the inline block absent;
        # a v1 does the opposite. Reading one and not the other reports "no WAF" on a protected
        # estate. And 'WAF_v2' is a single term to `has` - the underscore is not a separator - so
        # `Tier has 'WAF'` is false on every v2 gateway and misclassifies the lot.
        $query = $AppGwQueries['All']
        $query | Should -Match 'properties\.webApplicationFirewallConfiguration'
        $query | Should -Match 'microsoft\.network/applicationgatewaywebapplicationfirewallpolicies'
        $query | Should -Match "Tier !contains 'WAF'"
        foreach ($source in 'Policy', 'PolicyUnresolved', 'InlineConfig', 'NotWafSku', 'None') {
            $query | Should -Match "'$source'"
        }
    }

    It 'Sites.kql resolves the three-level WAF precedence a listener is subject to' {
        # Listener policy beats gateway policy beats the legacy inline config. Reading only the
        # gateway level silently mis-reports every listener that overrides it.
        $query = $AppGwQueries['Sites']
        $query | Should -Match 'LP\.firewallPolicy\.id'
        $query | Should -Match 'GwProps\.firewallPolicy\.id'
        foreach ($source in 'ListenerPolicy', 'GatewayPolicy', 'GatewayInlineConfig') {
            $query | Should -Match "'$source'"
        }
    }
}

Describe 'Kql/Graph/Waf' {
    BeforeAll {
        $script:WafQueries = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $captured = @{}
            foreach ($queryName in 'All', 'ManagedRules', 'Exclusions', 'CustomRules') {
                $null = Search-MsecAzureResourceGraph -ResourceType Waf -Name $queryName
                $captured[$queryName] = $script:CapturedQuery
            }
            $captured
        }
    }

    It 'tab-completes Waf and all four of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'Waf'

        $line = 'Search-MsecAzureResourceGraph -ResourceType Waf -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        foreach ($queryName in 'All', 'ManagedRules', 'Exclusions', 'CustomRules') { $names | Should -Contain $queryName }
    }

    It 'covers the legacy inline WAF block, not just policy resources' {
        # A v1 gateway keeps its WAF on the gateway itself. Querying only the policy type reports
        # a v1 estate as having no WAF, no disabled rule groups and no exclusions - the gaps read
        # as a clean configuration. Custom rules are the exception: v1 WAF has no such concept.
        foreach ($queryName in 'All', 'ManagedRules', 'Exclusions') {
            $WafQueries[$queryName] | Should -Match 'properties\.webApplicationFirewallConfiguration'
            $WafQueries[$queryName] | Should -Match "'GatewayInlineConfig'"
        }
        $WafQueries['CustomRules'] | Should -Not -Match 'webApplicationFirewallConfiguration'
    }

    It 'keeps the rows an empty array would otherwise erase' {
        # mv-expand drops a row whose array is empty, and every one of these absences is a
        # finding: a rule set with no overrides, an exclusion scoped to nothing (the widest kind
        # there is), a policy with no custom rules.
        $WafQueries['ManagedRules'] | Should -Match 'mv-expand Rs = iff\(coalesce\(array_length'
        $WafQueries['ManagedRules'] | Should -Match "'RuleSetDefaults'"
        $WafQueries['Exclusions']   | Should -Match "'AllManagedRules'"
        $WafQueries['CustomRules']  | Should -Match 'array_length\(PolicyProps\.customRules\), 0\) == 0'
    }
}

Describe 'Kql/Graph/Resource' {
    BeforeAll {
        $script:ResQueries = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith { $script:CapturedQuery = $Query; @() }
            $captured = @{}
            foreach ($queryName in 'All', 'Inventory') {
                $null = Search-MsecAzureResourceGraph -ResourceType Resource -Name $queryName
                $captured[$queryName] = $script:CapturedQuery
            }
            $captured
        }
    }

    It 'tab-completes Resource and both of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'Resource'

        $line = 'Search-MsecAzureResourceGraph -ResourceType Resource -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'All'
        $names | Should -Contain 'Inventory'
    }

    It 'shares a byte-identical classification map between the two queries' {
        # Resource Graph cannot share an expression across .kql files, so the map is duplicated.
        # Duplicated and DIVERGED would mean the type view and the resource view disagree about
        # what is PaaS, which is worse than either being wrong on its own.
        $begin = '>>> BEGIN CLASSIFICATION MAP'
        $end   = '>>> END CLASSIFICATION MAP'
        $blocks = foreach ($queryName in 'All', 'Inventory') {
            $q = $ResQueries[$queryName]
            $q.Substring($q.IndexOf($begin), $q.IndexOf($end) - $q.IndexOf($begin) + $end.Length)
        }
        $blocks[0] | Should -BeExactly $blocks[1]
    }

    It 'never guesses, and puts exact-type overrides ahead of the provider defaults' {
        # case() takes the first match: if the microsoft.network default came first it would
        # swallow the overrides beneath it and DNS zones, Front Door, Firewall and Bastion would
        # all report as IaaS. An unmapped type must surface rather than be absorbed.
        $query = $ResQueries['All']
        $query | Should -Match "'Unclassified\|Unknown'"
        $query.IndexOf("'microsoft.network/dnszones'") |
            Should -BeLessThan $query.IndexOf("Provider == 'microsoft.network',")
    }
}

Describe 'Bundled KQL files' {
    # Resource Graph accepts `let` for scalars only - a tabular `let` (the natural way to
    # name a lookup subquery) fails server-side with ParserFailure, which you only find out
    # by running it against a real tenant. Inline such lookups into join()/union() instead.
    It 'uses no tabular let statements, which Resource Graph cannot parse' {
        $kqlRoot = Join-Path (Get-Module Msec).ModuleBase 'Kql'
        $offenders = Get-ChildItem -LiteralPath $kqlRoot -Filter *.kql -File -Recurse |
            Where-Object {
                # let <name> = <TableOrExpr> ... | ...  (pipe on the same or a later line)
                (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^\s*let\s+\w+\s*=\s*\w+\s*(\r?\n\s*)*\|'
            } |
            ForEach-Object { $_.FullName }

        $offenders | Should -BeNullOrEmpty
    }

    It 'every mv-expand in the AppGateway and Waf queries sets an explicit limit' {
        # Resource Graph's default mv-expand RowLimit is 128. An Application Gateway v2 allows
        # 200 listeners and 400 routing rules, and a DRS 2.1 policy can carry more overrides
        # than that, so the default silently truncates - and an under-reported security query
        # looks exactly like a clean one.
        #
        # Scoped to these two folders deliberately: the older queries predate this rule and
        # tightening them is a separate change with its own risk.
        $kqlRoot = Join-Path (Get-Module Msec).ModuleBase 'Kql/Graph'
        $offenders = 'AppGateway', 'Waf' | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $kqlRoot $_) -Filter *.kql -File
        } | ForEach-Object {
            $file = $_
            # Strip comments, then split into pipeline statements: an mv-expand over a
            # multi-line array_concat() or iff() carries its limit on a continuation line, so a
            # line-by-line check reports false offenders.
            $code = ((Get-Content -LiteralPath $file.FullName) |
                Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            ($code -split '(?m)^\s*\|') |
                Where-Object { $_ -match '^\s*mv-expand' -and $_ -notmatch 'limit\s+\d+' } |
                ForEach-Object { "$($file.Name): $(($_ -replace '\s+', ' ').Trim())" }
        }

        $offenders | Should -BeNullOrEmpty
    }

    It 'every extract_all pattern has a capture group' {
        # Resource Graph rejects a group-less extract_all pattern at PARSE time with
        # Functions_ArgumentRegexMatchingGroupCountInvalid, so a pattern used only to count
        # matches fails the entire query rather than returning an empty array.
        $kqlRoot = Join-Path (Get-Module Msec).ModuleBase 'Kql'
        $offenders = Get-ChildItem -LiteralPath $kqlRoot -Filter *.kql -File -Recurse |
            ForEach-Object {
                $file = $_
                $raw = Get-Content -LiteralPath $file.FullName -Raw
                [regex]::Matches($raw, "extract_all\(@'((?:[^']|'')*)'") |
                    Where-Object { $_.Groups[1].Value -notmatch '(?<!\\)\((?!\?)' } |
                    ForEach-Object { "$($file.Name): $($_.Groups[1].Value)" }
            }

        $offenders | Should -BeNullOrEmpty
    }
}
