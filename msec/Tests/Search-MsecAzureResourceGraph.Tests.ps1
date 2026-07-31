#Requires -Module Pester
#
# Tests for Search-MsecAzureResourceGraph. Verifies the KQL-file convention, the
# Az.ResourceGraph response unwrap, error handling for missing query files, and
# the tab-completion pathway (which has caught real bugs that InModuleScope
# would miss because it inherits the module's $script: state).

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Search-MsecAzureResourceGraph' {
    It 'loads KQL/Graph/VM/All.kql by convention and shuttles it to Search-AzGraph unchanged' {
        $result = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        $rows = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        $sub = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-current' } } }
            Mock Get-AzSubscription -MockWith { throw 'should not enumerate all subscriptions with -CurrentSubscription' }
            $script:CapturedSub = $null
            Mock Search-AzGraph -MockWith { $script:CapturedSub = $Subscription; @() }

            $null = Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription
            , $script:CapturedSub
        }
        $sub | Should -Be @('sub-current')
    }

    It 'throws when -CurrentSubscription and -SubscriptionId are both supplied' {
        InModuleScope msec {
            Mock Get-AzContext  -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-1' } } }
            Mock Search-AzGraph -MockWith { @() }
            { Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription -SubscriptionId 'sub-2' } |
                Should -Throw -ExpectedMessage '*either -CurrentSubscription or -SubscriptionId*'
        }
    }

    It 'throws a clear error when the named .kql file does not exist' {
        InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        $captured = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
        }
    }

    It 'follows the skip token and returns every page, not just the first 1000 rows' {
        # KeyVault/NetworkRules is over 1100 rows on a mid-sized tenant, so single-page
        # behaviour silently dropped real findings off the end of a security report.
        $rows = InModuleScope msec {
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
        $token = InModuleScope msec {
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
        $result = InModuleScope msec {
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

        $result.Rows.Count     | Should -Be 3
        $result.Warnings.Count | Should -Be 1
        $result.Warnings[0]    | Should -Match 'INCOMPLETE'
    }

    It 'makes exactly one call when the response is a bare row array with no token' {
        $calls = InModuleScope msec {
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

Describe 'KQL/Graph/KeyVault' {
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
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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

Describe 'KQL/Graph/Storage' {
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
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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

Describe 'KQL/Graph/NSG' {
    It 'tab-completes NSG and both of its query names' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'NSG'

        $line = 'Search-MsecAzureResourceGraph -ResourceType NSG -Name '
        $names = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $names | Should -Contain 'All'
        $names | Should -Contain 'SecurityRules'
    }

    It 'SecurityRules.kql projects the columns the old Get-ViedocAzNetworkGroupSecurityRules printed' {
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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

Describe 'KQL/Graph/MySQL' {
    It 'tab-completes MySQL as a ResourceType' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType '
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain 'MySQL'
    }

    It 'All.kql classifies the network access model' {
        # NetworkMode is the whole point of this query: Resource Graph cannot reach a
        # flexible server's firewall rules (no child type is projected), so the access model
        # is the closest thing to an exposure answer that KQL alone can give.
        $query = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
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

Describe 'Bundled KQL files' {
    # Resource Graph accepts `let` for scalars only - a tabular `let` (the natural way to
    # name a lookup subquery) fails server-side with ParserFailure, which you only find out
    # by running it against a real tenant. Inline such lookups into join()/union() instead.
    It 'uses no tabular let statements, which Resource Graph cannot parse' {
        $kqlRoot = Join-Path (Get-Module msec).ModuleBase 'KQL'
        $offenders = Get-ChildItem -LiteralPath $kqlRoot -Filter *.kql -File -Recurse |
            Where-Object {
                # let <name> = <TableOrExpr> ... | ...  (pipe on the same or a later line)
                (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^\s*let\s+\w+\s*=\s*\w+\s*(\r?\n\s*)*\|'
            } |
            ForEach-Object { $_.FullName }

        $offenders | Should -BeNullOrEmpty
    }
}
