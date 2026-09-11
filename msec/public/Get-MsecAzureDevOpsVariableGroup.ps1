function Get-MsecAzureDevOpsVariableGroup {
    <#
    .SYNOPSIS
        Variable groups across an Azure DevOps organization - what they hold, who they are shared
        with, and whether any pipeline may use them.

    .DESCRIPTION
        A variable group holds values that pipelines consume, and secret variables in it are
        credentials by another name. The question worth answering is not "does it contain
        secrets" but "which pipelines can reach them" - a group marked available to ALL pipelines
        in a project can be referenced by a pipeline someone writes this afternoon.

        THE COMBINATION IS THE FINDING. Secrets in a group, open to every pipeline, in a project
        whose repositories require no reviewer, means anyone who can push can author a pipeline
        that reads them. Each of the three is unremarkable alone. This command reports the first
        two; Get-MsecAzureDevOpsRepository reports the third.

        VALUES ARE NEVER RETURNED, AND SECRET VALUES ARE NOT AVAILABLE ANYWAY. Azure DevOps does
        not return secret values through this API. Non-secret values are returned by the API and
        are deliberately dropped here: this output goes into mailboxes and spreadsheets, and
        pipeline variables carry connection strings and hostnames often enough that copying them
        into a report is a poor default. Variable NAMES are kept, because knowing a group holds
        'AZURE_CLIENT_SECRET' is the point.

        A KEY VAULT-BACKED GROUP IS A REFERENCE, NOT A COPY. Its type is AzureKeyVault and the
        secrets stay in the vault, fetched at run time through a service connection. That moves
        the question to the vault and the connection rather than removing it.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER Project
        Restrict to one project. All projects by default.

    .PARAMETER WithSecrets
        Only groups that hold at least one secret variable, or are backed by a Key Vault.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsVariableGroup -Organization 'contoso' -WithSecrets |
            Where-Object OpenToAllPipelines

    .EXAMPLE
        # Everything a pipeline author could reach without asking anyone.
        Get-MsecAzureDevOpsVariableGroup -Organization 'contoso' |
            Where-Object OpenToAllPipelines |
            Sort-Object SecretCount -Descending

    .OUTPUTS
        PSCustomObject per variable group, PSTypeName 'MsecAzureDevOpsVariableGroup'.

    .NOTES
        Needs Connect-Msec and organization membership. One call per project, plus one per group
        for the pipeline authorization.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [string] $Project,

        [switch] $WithSecrets
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
        $groups = @()
        try {
            $groups = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                            -HostName 'dev.azure.com' -ApiVersion '7.1-preview.2' `
                            -Path "$($proj.id)/_apis/distributedtask/variablegroups")
        }
        catch {
            # Named, not skipped: a project whose library could not be read is not a project
            # without variable groups.
            $unreadable.Add($proj.name)
            Write-Verbose "Could not read variable groups in '$($proj.name)': $($_.Exception.Message)"
            continue
        }

        foreach ($group in $groups) {
            $variables = @($group.variables.PSObject.Properties)
            $secrets   = @($variables | Where-Object { $_.Value.isSecret })
            $isKeyVault = $group.type -eq 'AzureKeyVault'

            if ($WithSecrets -and -not $secrets.Count -and -not $isKeyVault) { continue }

            $allPipelines = $null
            $authorizedCount = $null
            $openedBy = $null
            $openedOn = $null
            try {
                $perms = Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                             -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                             -Path "$($proj.id)/_apis/pipelines/pipelinePermissions/variablegroup/$($group.id)"
                # Omitted when the setting is off, so absence is false - but a failed call stays
                # $null, which is a different claim.
                $allPipelines = [bool] $perms.allPipelines.authorized
                $authorizedCount = @($perms.pipelines).Count
                # WHO opened it and WHEN. The decision is usually old and the person who made it
                # has often moved on - a group opened three years ago by someone reasoning about
                # a pipeline that no longer exists is the common case, and neither the count nor
                # the boolean says so.
                $openedBy = $perms.allPipelines.authorizedBy.displayName
                $openedOn = $perms.allPipelines.authorizedOn
            }
            catch { Write-Verbose "Could not read pipeline permissions for group '$($group.name)': $($_.Exception.Message)" }

            [PSCustomObject]@{
                PSTypeName             = 'MsecAzureDevOpsVariableGroup'
                Organization           = $Organization
                Project                = $proj.name
                Name                   = $group.name
                Type                   = $group.type
                # Where the secrets actually live, for a Key Vault-backed group.
                KeyVault               = if ($isKeyVault) { $group.providerData.vault } else { $null }
                VariableCount          = $variables.Count
                SecretCount            = $secrets.Count
                # NAMES only - see the help on why values are dropped.
                SecretNames            = ($secrets | ForEach-Object { $_.Name } | Sort-Object) -join ', '
                VariableNames          = ($variables | ForEach-Object { $_.Name } | Sort-Object) -join ', '
                # TRUE IS THE PERMISSIVE STATE. Someone ticked "Grant access permission to all
                # pipelines", so any pipeline in the project may reference this group with no
                # further approval. FALSE means pipelines are authorised one at a time - the
                # first run prompts someone, and that pipeline then shows in
                # AuthorizedPipelineCount.
                OpenToAllPipelines = $allPipelines
                AuthorizedPipelineCount = $authorizedCount
                OpenedBy               = $openedBy
                OpenedOn               = $openedOn
                # Shared groups are reachable from more than the project that owns them.
                IsShared               = [bool] $group.isShared
                SharedWithProjectCount = @($group.variableGroupProjectReferences).Count
                ModifiedBy             = $group.modifiedBy.displayName
                ModifiedOn             = $group.modifiedOn
                CreatedBy              = $group.createdBy.displayName
                Id                     = $group.id
            }
        }
    }

    if ($unreadable.Count) {
        $shown = ($unreadable | Select-Object -First 5) -join ', '
        $more  = if ($unreadable.Count -gt 5) { " and $($unreadable.Count - 5) more" } else { '' }
        Write-Warning "$($unreadable.Count) project(s) refused their variable groups: $shown$more. Those groups are NOT in this output - treat them as unread, not as projects without a library."
    }
}
