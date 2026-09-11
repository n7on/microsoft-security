function Get-MsecAzureDevOpsAgentPool {
    <#
    .SYNOPSIS
        Agent pools in an Azure DevOps organization, with what runs in them - one row per pool.

    .DESCRIPTION
        A self-hosted agent executes pipeline code on a machine you own, as whatever account the
        agent service runs under. Anyone who can queue a pipeline against the pool can run code
        there. That makes pool membership a permission question and the agents themselves an
        estate question - what they are, how old, and whether they are still reachable.

        MICROSOFT-HOSTED POOLS ARE DISPOSABLE; SELF-HOSTED ONES ARE NOT. A hosted agent is a
        fresh VM per job. A self-hosted agent keeps its disk, its credentials and whatever the
        last job left behind, so a compromised pipeline persists there.

        AUTOPROVISION MEANS EVERY NEW PROJECT GETS THE POOL. It is how a pool intended for one
        team ends up reachable from projects nobody associated with it.

        AGENT VERSIONS AND OPERATING SYSTEMS ARE REPORTED AS DISTINCT LISTS, not summarised. A
        pool where most agents are current and one is three major versions behind is the case
        worth seeing, and an average or a maximum would hide exactly that agent.

        AN OFFLINE AGENT THAT IS STILL ENABLED IS NOT DECOMMISSIONED. It is a machine that will
        rejoin and start taking jobs the moment it comes back, which is a different thing from
        one that was removed. LongestOfflineDays says how long the most absent of them has been
        gone - measured on a live organization, two years, on an agent two major versions behind.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER SelfHostedOnly
        Only pools running on your own machines.


    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsAgentPool -Organization 'contoso' -SelfHostedOnly

    .EXAMPLE
        # Pools reachable from every project, running on machines you own.
        Get-MsecAzureDevOpsAgentPool -Organization 'contoso' |
            Where-Object { -not $_.IsHosted -and $_.AutoProvision }

    .OUTPUTS
        PSCustomObject per pool, PSTypeName 'MsecAzureDevOpsAgentPool'.

    .NOTES
        Needs Connect-Msec and organization membership. Everything here is readable by any
        member, including -IncludeExposure.

        THERE IS DELIBERATELY NO ROLE-ASSIGNMENT COLUMN. Reading distributedtask.agentqueuerole
        was not enabled by 'View' or by 'Use' on the DistributedTask namespace - both were
        granted at the organization root against a live organization and the read still returned
        403. The only remaining candidate is 'AdministerPermissions', the right to CHANGE
        permissions, which this module has no business holding to display four counts.

        The question those counts would answer - who can put work on this pool - is answered by
        -IncludeExposure instead: which projects have a queue for it, and whether any pipeline in
        those projects may use it without approval. That needs no extra permission.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [switch] $SelfHostedOnly,


        # Which projects can queue work on each pool, and whether any pipeline in those projects
        # may do so without approval.
        #
        # OPT-IN and the most expensive thing here: one call per project to list queues, plus one
        # per queue belonging to a pool being reported. AutoProvision answers "will FUTURE
        # projects get this pool"; this answers "which ones have it NOW", which is the question
        # an access review actually asks.
        [switch] $IncludeExposure
    )

    Assert-MsecSession

    $pools = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                   -HostName 'dev.azure.com' -ApiVersion '7.1' -Path '_apis/distributedtask/pools' -All)

    if (-not $pools.Count) {
        Write-Warning "No agent pools returned for '$Organization'. That is 'nothing was read', not 'none exist' - every organization has the Microsoft-hosted pools."
        return
    }

    # poolId -> @{ Projects = @(names); OpenProjects = @(names) }. Built once, before the pool
    # loop, because queues are addressed per PROJECT and the pool is the thing we report on.

    $exposure = @{}
    if ($IncludeExposure) {
        $projects = @()
        try { $projects = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' -ApiVersion '7.1' -Path '_apis/projects' -All) }
        catch { Write-Warning "Could not list projects, so exposure columns are `$null: $($_.Exception.Message)" }

        foreach ($proj in $projects) {
            $queues = @()
            try {
                $queues = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' `
                                -ApiVersion '7.1-preview.1' -Path "$($proj.id)/_apis/distributedtask/queues")
            }
            catch {
                # Named: a project whose queues could not be read is a project whose exposure is
                # unknown, not a project with none.
                Write-Warning "Could not read queues in project '$($proj.name)', so its pools may under-report exposure: $($_.Exception.Message)"
                continue
            }

            foreach ($queue in $queues) {
                $poolId = [string] $queue.pool.id
                if (-not $poolId) { continue }
                if (-not $exposure.ContainsKey($poolId)) {
                    $exposure[$poolId] = @{ Projects = [System.Collections.Generic.List[string]]::new()
                                            OpenProjects = [System.Collections.Generic.List[string]]::new() }
                }
                $exposure[$poolId].Projects.Add($proj.name)

                try {
                    $perms = Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' `
                                 -ApiVersion '7.1-preview.1' -Path "$($proj.id)/_apis/pipelines/pipelinePermissions/queue/$($queue.id)"
                    # The field is omitted unless the setting is on, so absence is 'not open'.
                    if ([bool] $perms.allPipelines.authorized) { $exposure[$poolId].OpenProjects.Add($proj.name) }
                }
                catch { Write-Verbose "Could not read pipeline permissions for queue $($queue.id) in '$($proj.name)': $($_.Exception.Message)" }
            }
        }
    }

    foreach ($pool in $pools) {
        if ($SelfHostedOnly -and $pool.isHosted) { continue }

        # Hosted pools have no enumerable agents; asking is a wasted call and a confusing 404.
        $agents = @()
        $agentsRead = $false
        if (-not $pool.isHosted) {
            try {
                $agents = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                                -HostName 'dev.azure.com' -ApiVersion '7.1' `
                                -Path "_apis/distributedtask/pools/$($pool.id)/agents")
                $agentsRead = $true
            }
            catch {
                # Left unread rather than reported as an empty pool.
                Write-Warning "Could not read agents in pool '$($pool.name)', so its agent columns are `$null: $($_.Exception.Message)"
            }
        }
        else { $agentsRead = $true }


        [PSCustomObject]@{
            PSTypeName         = 'MsecAzureDevOpsAgentPool'
            Organization       = $Organization
            Pool               = $pool.name
            IsHosted           = [bool] $pool.isHosted
            # Every new project gets this pool without anyone asking for it.
            AutoProvision      = [bool] $pool.autoProvision
            AutoUpdate         = [bool] $pool.autoUpdate

            AgentCount         = if ($agentsRead) { $agents.Count } else { $null }
            AgentsOnline       = if ($agentsRead) { @($agents | Where-Object { $_.status -eq 'online' }).Count } else { $null }
            # Enabled but offline: not decommissioned, just not here right now.
            AgentsOfflineEnabled = if ($agentsRead) { @($agents | Where-Object { $_.status -ne 'online' -and $_.enabled }).Count } else { $null }
            AgentsDisabled     = if ($agentsRead) { @($agents | Where-Object { -not $_.enabled }).Count } else { $null }
            # How long the longest-absent enabled agent has been gone. An agent offline for two
            # years and still enabled is registered infrastructure that will rejoin and start
            # taking jobs the moment its machine powers on - on whatever agent version and
            # operating system it was left at. A count of offline agents does not convey that;
            # the age does.
            LongestOfflineDays = if ($agentsRead) {
                $away = @($agents | Where-Object { $_.status -ne 'online' -and $_.enabled -and $_.statusChangedOn })
                # [int] on the RESULT too: Measure-Object -Maximum returns a double, so the column
                # rendered as 731.000 rather than 731.
                if ($away.Count) { [int] ($away | ForEach-Object { ([datetime]::UtcNow - [datetime] $_.statusChangedOn).TotalDays } | Measure-Object -Maximum).Maximum } else { $null }
            } else { $null }
            # Distinct, not summarised - one agent far behind the others is the finding.
            AgentVersions      = if ($agentsRead -and $agents.Count) { (@($agents.version) | Sort-Object -Unique) -join ', ' } elseif ($agentsRead) { '' } else { $null }
            AgentOperatingSystems = if ($agentsRead -and $agents.Count) { (@($agents.osDescription) | Sort-Object -Unique) -join '; ' } elseif ($agentsRead) { '' } else { $null }

            # Projects that can queue work on this pool today. $null when not collected.
            ProjectCount       = if ($IncludeExposure) { @($exposure[[string] $pool.id].Projects).Count } else { $null }
            Projects           = if ($IncludeExposure) { (@($exposure[[string] $pool.id].Projects) | Sort-Object -Unique) -join '; ' } else { $null }
            # The PROJECTS in which any pipeline may use this pool with no further approval -
            # named rather than counted, because which project matters. A boolean would say
            OpenInProjects     = if ($IncludeExposure) { (@($exposure[[string] $pool.id].OpenProjects) | Sort-Object -Unique) -join '; ' } else { $null }

            PoolType           = $pool.poolType
            Owner              = $pool.owner.displayName
            CreatedOn          = $pool.createdOn


            PoolId             = $pool.id
        }
    }

}
