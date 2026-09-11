function Get-MsecAzureDevOpsEnvironment {
    <#
    .SYNOPSIS
        Pipeline environments across an organization, the checks guarding them, and who approves
        - one row per environment.

    .DESCRIPTION
        An environment is what a pipeline deploys TO, and the checks on it are the last thing
        between a pipeline run and production. An environment with no approval check is a
        deployment target nobody signs off: the pipeline reaches it unattended, whenever it runs.

        NO CHECKS IS THE FINDING, and it is easy to miss because it looks like nothing. An
        environment that has never had a check configured returns an empty list, which is the
        same shape as one whose checks could not be read - so those two are reported differently:
        CheckCount 0 means none are configured, $null means the read failed.

        AN APPROVAL WITH NO APPROVERS APPROVES NOTHING USEFUL. Approvers are resolved to names
        where the API gives them, and a check configured against a group is reported as that
        group - who is IN the group is a separate question, answerable with
        Get-MsecAzureDevOpsUser.

        OPEN TO ALL PIPELINES applies here as it does to service connections and variable groups:
        any pipeline in the project may deploy to the environment with no further authorization.
        Combined with no approval check, that is a production target reachable by a pipeline
        somebody writes this afternoon.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER Project
        Restrict to one project. All projects by default.

    .PARAMETER Unchecked
        Only environments with no checks configured at all.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsEnvironment -Organization 'contoso' -Unchecked

    .EXAMPLE
        # Reachable by any pipeline, with nobody approving.
        Get-MsecAzureDevOpsEnvironment -Organization 'contoso' |
            Where-Object { $_.OpenToAllPipelines -and -not $_.HasApproval }

    .OUTPUTS
        PSCustomObject per environment, PSTypeName 'MsecAzureDevOpsEnvironment'.

    .NOTES
        Needs Connect-Msec and organization membership. One call per project to list
        environments, then two per environment - the checks and the pipeline authorization.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [string] $Project,

        [switch] $Unchecked
    )

    Assert-MsecSession

    $projects = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                      -HostName 'dev.azure.com' -ApiVersion '7.1' -Path '_apis/projects' -All)
    if ($Project) {
        $projects = @($projects | Where-Object { $_.name -eq $Project })
        if (-not $projects.Count) { throw "No project named '$Project' in '$Organization'." }
    }
    if (-not $projects.Count) {
        Write-Warning "No projects returned for '$Organization'. That is 'nothing was read', not 'no projects'."
        return
    }

    $unreadable = [System.Collections.Generic.List[string]]::new()

    foreach ($proj in $projects) {
        $environments = @()
        try {
            $environments = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                                  -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                                  -Path "$($proj.id)/_apis/distributedtask/environments")
        }
        catch {
            $unreadable.Add($proj.name)
            Write-Verbose "Could not read environments in '$($proj.name)': $($_.Exception.Message)"
            continue
        }

        foreach ($environment in $environments) {
            $checks = $null
            try {
                $checks = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                                -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                                -Path "$($proj.id)/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$($environment.id)&`$expand=settings")
            }
            catch { Write-Verbose "Could not read checks for environment '$($environment.name)': $($_.Exception.Message)" }

            $approvals = @($checks | Where-Object { $_.type.name -eq 'Approval' })
            # The API nests approvers under settings; a check configured against a group reports
            # the group, which is the honest answer - who is in it is a separate question.
            $approvers = @($approvals | ForEach-Object { $_.settings.approvers.displayName } | Where-Object { $_ } | Sort-Object -Unique)

            $open = $null; $authorized = $null; $openedBy = $null; $openedOn = $null
            try {
                $perms = Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                             -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                             -Path "$($proj.id)/_apis/pipelines/pipelinePermissions/environment/$($environment.id)"
                $open       = [bool] $perms.allPipelines.authorized
                $authorized = @($perms.pipelines).Count
                $openedBy   = $perms.allPipelines.authorizedBy.displayName
                $openedOn   = $perms.allPipelines.authorizedOn
            }
            catch { Write-Verbose "Could not read pipeline permissions for environment '$($environment.name)': $($_.Exception.Message)" }

            $row = [PSCustomObject]@{
                PSTypeName    = 'MsecAzureDevOpsEnvironment'
                Organization  = $Organization
                Project       = $proj.name
                Environment   = $environment.name
                # 0 means no checks are configured. $null means the read failed - a deployment
                # target nobody looked at must not read as one nobody guards.
                CheckCount    = if ($null -eq $checks) { $null } else { $checks.Count }
                Checks        = if ($null -eq $checks) { $null } else { (@($checks | ForEach-Object { $_.type.name }) | Sort-Object -Unique) -join ', ' }
                HasApproval   = if ($null -eq $checks) { $null } else { $approvals.Count -gt 0 }
                # An approval with nobody named on it is a gate that cannot be satisfied by
                # anyone in particular.
                ApproverCount = if ($null -eq $checks) { $null } else { $approvers.Count }
                Approvers     = if ($null -eq $checks) { $null } else { $approvers -join '; ' }

                OpenToAllPipelines      = $open
                AuthorizedPipelineCount = $authorized
                OpenedBy                = $openedBy
                OpenedOn                = $openedOn

                LastModifiedBy = $environment.lastModifiedBy.displayName
                LastModifiedOn = $environment.lastModifiedOn
                CreatedBy      = $environment.createdBy.displayName
                Id             = $environment.id
            }

            # $null is not evidence of being unchecked.
            if ($Unchecked -and $row.CheckCount -ne 0) { continue }
            $row
        }
    }

    if ($unreadable.Count) {
        $shown = ($unreadable | Select-Object -First 5) -join ', '
        $more  = if ($unreadable.Count -gt 5) { " and $($unreadable.Count - 5) more" } else { '' }
        Write-Warning "$($unreadable.Count) project(s) refused their environments: $shown$more. Those are NOT in this output - treat them as unread, not as projects without deployment targets."
    }
}
