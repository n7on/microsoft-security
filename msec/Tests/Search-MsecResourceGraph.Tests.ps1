#Requires -Module Pester
#
# Tests for Search-MsecResourceGraph. Verifies the KQL-file convention, the
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

Describe 'Search-MsecResourceGraph' {
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

            $rows = Search-MsecResourceGraph -ResourceType VM
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
            Search-MsecResourceGraph -ResourceType VM
        }

        # We should see two rows, with the actual VM properties accessible for filtering.
        $rows.Count                                    | Should -Be 2
        ($rows | Where-Object Os -eq 'Linux').Name     | Should -Be 'lin-1'
        # SkipToken / Data must not leak through as row properties.
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'SkipToken'
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'Data'
    }

    It 'throws a clear error when the named .kql file does not exist' {
        InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'sub-1' }) }
            Mock Search-AzGraph -MockWith { @() }
            { Search-MsecResourceGraph -ResourceType VM -Name 'NoSuchQuery' } |
                Should -Throw -ExpectedMessage 'KQL query file not found:*'
        }
    }

    # Tab-completion tests go through PowerShell's real completion entry point
    # (TabExpansion2), NOT InModuleScope + & $scriptblock - the latter passed even when the
    # completer was actually broken because it ran the scriptblock with module $script:
    # scope available, whereas the real completion engine does not. These tests would
    # catch a regression to module-scoped state usage in the completer scriptblock.
    It 'tab completion for -ResourceType returns folders containing .kql files' {
        $line = 'Search-MsecResourceGraph -ResourceType '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'VM'
    }

    It 'tab completion for -Name returns the .kql file basenames in the chosen ResourceType folder' {
        $line = 'Search-MsecResourceGraph -ResourceType VM -Name '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'All'
    }

    It 'pipes cleanly through Where-Object into Invoke-MsecVMScript' {
        # End-to-end: ARG-shaped rows -> Where-Object -> runner. Validates that
        # Search-MsecResourceGraph's output (Name + ResourceGroupName) binds correctly to the runner.
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

            Search-MsecResourceGraph -ResourceType VM |
                Where-Object Os -eq Linux |
                Invoke-MsecVMScript -Os Linux -ScriptName os-info -TimeoutSeconds 0 |
                Out-Null
            ,$script:CapturedVmNames
        }

        $captured.Count | Should -Be 1
        $captured[0]    | Should -Be 'lin-1'
    }
}
