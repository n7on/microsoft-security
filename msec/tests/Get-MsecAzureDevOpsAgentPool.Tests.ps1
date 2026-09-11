#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsAgentPool.
#
# The distinction that matters most here is unread versus empty. A hosted pool has no enumerable
# agents and reports 0; a pool whose agents could not be read reports $null. Reporting both as 0
# would say "this pool has no agents" about a pool nobody managed to look inside.
#
# The other is that versions and operating systems are reported as DISTINCT LISTS. A live pool
# held agent versions 2.213.2, 3.244.1 and 4.264.2 at once - an average or a maximum would have
# hidden the 2.x agent, which is the one worth finding.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsAgentPool' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:New-Pool {
                param([int] $Id = 1, [string] $Name = 'Pool', [switch] $Hosted, [switch] $AutoProvision)
                [pscustomobject]@{ id = $Id; name = $Name; isHosted = [bool]$Hosted
                                   autoProvision = [bool]$AutoProvision; autoUpdate = $true }
            }
            function script:New-Agent {
                param(
                    [string] $Name, [string] $Version, [string] $Status = 'online',
                    [bool] $Enabled = $true, [string] $Os = 'Ubuntu 22.04', [int] $OfflineDays = 0
                )
                [pscustomobject]@{
                    name = $Name; version = $Version; status = $Status; enabled = $Enabled
                    osDescription = $Os
                    statusChangedOn = if ($OfflineDays) { [datetime]::UtcNow.AddDays(-$OfflineDays) } else { [datetime]::UtcNow }
                }
            }
            # The fixtures live in MODULE scope, not in this function's parameters. Pester
            # evaluates a -MockWith body later and in its own scope, where a dot-sourced
            # function's parameters are not reachable - the mock then returned an empty agent
            # list and every count read as 0, which looked like a bug in the command.
            function script:Set-PoolMock {
                param($Pools, $Agents = @(), $Roles = $null, [switch] $AgentsFail, $Projects = @(), $Queues = @(), $OpenQueues = @())
                $script:MockPools      = $Pools
                $script:MockProjects   = $Projects
                $script:MockQueues     = $Queues
                $script:MockOpenQueues = @($OpenQueues)
                $script:MockAgents     = $Agents
                $script:MockRoles      = $Roles
                $script:MockAgentsFail = [bool] $AgentsFail
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/projects') { return $script:MockProjects }
                    if ($Path -match '/_apis/distributedtask/queues$') {
                        $projectId = ($Path -split '/')[0]
                        return @($script:MockQueues | Where-Object { $_.projectId -eq $projectId })
                    }
                    if ($Path -match '/pipelinePermissions/queue/(\d+)$') {
                        $queueId = [int] $Matches[1]
                        if ($script:MockOpenQueues -contains $queueId) {
                            return [pscustomobject]@{ allPipelines = [pscustomobject]@{ authorized = $true } }
                        }
                        # The field is omitted when the setting is off - absence is 'not open'.
                        return [pscustomobject]@{ pipelines = @() }
                    }
                    if ($Path -eq '_apis/distributedtask/pools') { return $script:MockPools }
                    if ($Path -match '/agents$') {
                        if ($script:MockAgentsFail) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        return $script:MockAgents
                    }
                    if ($Path -match 'agentqueuerole') {
                        if ($null -eq $script:MockRoles) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        return $script:MockRoles
                    }
                    return @()
                }
            }
        }
    }

    It 'lists agent versions and operating systems distinctly' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool -Name 'Default') -Agents @(
                (New-Agent -Name 'a' -Version '2.213.2' -Os 'Windows 10.0.14393')
                (New-Agent -Name 'b' -Version '4.264.2' -Os 'Windows 10.0.19045')
                (New-Agent -Name 'c' -Version '4.264.2' -Os 'Windows 10.0.19045'))
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
        }

        # Both versions present, deduplicated. A maximum would have shown only 4.264.2 and hidden
        # the agent two majors behind.
        $rows.AgentVersions | Should -Be '2.213.2, 4.264.2'
        $rows.AgentOperatingSystems | Should -Match '10.0.14393'
        $rows.AgentCount | Should -Be 3
    }

    It 'separates offline-but-enabled from disabled' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool) -Agents @(
                (New-Agent -Name 'up'      -Version '5.0' -Status 'online')
                (New-Agent -Name 'away'    -Version '5.0' -Status 'offline' -Enabled $true)
                (New-Agent -Name 'retired' -Version '5.0' -Status 'offline' -Enabled $false))
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
        }

        # An offline agent that is still enabled will rejoin and take jobs; a disabled one will
        # not. Counting them together would blur a machine that is coming back with one that is
        # gone.
        $rows.AgentsOnline         | Should -Be 1
        $rows.AgentsOfflineEnabled | Should -Be 1
        $rows.AgentsDisabled       | Should -Be 1
    }

    It 'reports how long the most absent enabled agent has been gone' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool) -Agents @(
                (New-Agent -Name 'here'  -Version '5.0' -Status 'online')
                (New-Agent -Name 'gone'  -Version '2.1' -Status 'offline' -Enabled $true  -OfflineDays 309)
                (New-Agent -Name 'older' -Version '2.1' -Status 'offline' -Enabled $true  -OfflineDays 731)
                # Absent even longer, but disabled - it will not come back, so it must not count.
                (New-Agent -Name 'off'   -Version '2.1' -Status 'offline' -Enabled $false -OfflineDays 2000))
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
        }

        # Measured live: 731 days on one organization, 2261 on another pool. A count of offline
        # agents does not convey that; the age does.
        $rows.LongestOfflineDays | Should -Be 731
        # And it is a whole number - Measure-Object -Maximum returns a double, which rendered as
        # 731.000 in a table.
        $rows.LongestOfflineDays | Should -BeOfType [int]
    }
    It 'reports $null for agents it could not read, not 0' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool) -AgentsFail
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        $rows.AgentCount    | Should -BeNullOrEmpty
        $rows.AgentVersions | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'could not read agents'
    }

    It 'does not ask a hosted pool for agents' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool -Name 'Azure Pipelines' -Hosted)
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
            Should -Invoke Invoke-MsecAzureDevOpsRequest -Times 0 -Exactly -ParameterFilter { $Path -match '/agents$' }
        }

        # A hosted pool has no enumerable agents - 0 is the answer, and asking is a wasted call
        # and a confusing 404.
        $rows.AgentCount | Should -Be 0
        $rows.IsHosted   | Should -BeTrue
    }



    It 'maps which projects can queue work on a pool' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool -Id 7 -Name 'Shared') -Agents @() `
                -Projects @(
                    [pscustomobject]@{ id = 'p1'; name = 'Alpha' }
                    [pscustomobject]@{ id = 'p2'; name = 'Beta' }
                    [pscustomobject]@{ id = 'p3'; name = 'Gamma' }) `
                -Queues @(
                    [pscustomobject]@{ id = 11; projectId = 'p1'; pool = [pscustomobject]@{ id = 7 } }
                    [pscustomobject]@{ id = 12; projectId = 'p2'; pool = [pscustomobject]@{ id = 7 } })
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso' -IncludeExposure
        }

        # AutoProvision says future projects will get the pool; this says which have it now -
        # measured live, three self-hosted pools were reachable from all 36 projects.
        $rows.ProjectCount | Should -Be 2
        $rows.Projects     | Should -Be 'Alpha; Beta'
    }

    It 'names only the projects where any pipeline may use the pool' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool -Id 7 -Name 'Shared') -Agents @() `
                -Projects @(
                    [pscustomobject]@{ id = 'p1'; name = 'Alpha' }
                    [pscustomobject]@{ id = 'p2'; name = 'Beta' }) `
                -Queues @(
                    [pscustomobject]@{ id = 11; projectId = 'p1'; pool = [pscustomobject]@{ id = 7 } }
                    [pscustomobject]@{ id = 12; projectId = 'p2'; pool = [pscustomobject]@{ id = 7 } }) `
                -OpenQueues @(12)
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso' -IncludeExposure
        }

        # Reachable from both, but only Beta lets any pipeline use it without approval.
        $rows.ProjectCount       | Should -Be 2
        $rows.OpenInProjects | Should -Be 'Beta'
    }

    It 'leaves the exposure columns $null when not asked for' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @(New-Pool) -Agents @()
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
        }

        # $null is "not collected". 0 would claim the pool is reachable from no project at all.
        $rows.ProjectCount | Should -BeNullOrEmpty
        $rows.Projects     | Should -BeNullOrEmpty
    }
    It 'filters to self-hosted pools when asked' {
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @((New-Pool -Id 1 -Name 'Hosted' -Hosted), (New-Pool -Id 2 -Name 'Ours')) -Agents @()
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso' -SelfHostedOnly
        }

        @($rows).Count | Should -Be 1
        $rows.Pool     | Should -Be 'Ours'
    }

    It 'warns rather than returning nothing when no pool is readable' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-PoolMock -Pools @()
            Get-MsecAzureDevOpsAgentPool -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'nothing was read'
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsAgentPool -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
