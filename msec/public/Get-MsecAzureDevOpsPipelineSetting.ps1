function Get-MsecAzureDevOpsPipelineSetting {
    <#
    .SYNOPSIS
        Project-level pipeline security settings - fork protection, job authorization scope,
        settable variables, shell argument sanitising - one row per project.

    .DESCRIPTION
        These are the switches that decide what a pipeline is allowed to do, set once per project
        and rarely revisited. They are not visible from a pipeline definition, so a repository can
        look well governed while the project it lives in allows a fork's build to read its
        secrets.

        THE FORK SETTINGS ARE THE ONES TO READ FIRST, and they only make sense together. A fork
        of a public repository is code from someone outside the organization. If builds of forks
        are enabled AND secrets are not withheld from them, a pull request from a stranger runs
        with your credentials. BuildsEnabledForForks being false makes the rest moot - which is
        why they are reported as separate columns rather than a single verdict.

        JOB AUTHORIZATION SCOPE decides whether a pipeline's token can reach other projects.
        Limited to the current project is the safer setting; unlimited means a compromised
        pipeline in a sandbox project can act across the organization.

        SETTABLE VARIABLES AT QUEUE TIME let whoever starts a run override variables the pipeline
        defined. Restricting it is what stops a run-time override changing what the pipeline does.

        UNRECOGNISED SETTINGS ARE NAMED, NOT DROPPED. Azure DevOps adds settings to this endpoint
        and a column-per-known-key report silently loses them, so anything this command has not
        been taught appears in OtherSettings with its value.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER Project
        Restrict to one project. All projects by default.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso' |
            Format-Table Project, BuildsEnabledForForks, SecretsWithheldFromForks, JobAuthScopeLimited

    .EXAMPLE
        # The combination that lets an outsider's pull request run with your credentials.
        Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso' |
            Where-Object { $_.BuildsEnabledForForks -and -not $_.SecretsWithheldFromForks }

    .OUTPUTS
        PSCustomObject per project, PSTypeName 'MsecAzureDevOpsPipelineSetting'.

    .NOTES
        Needs Connect-Msec and organization membership. One call per project.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [string] $Project
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

    # Keys with a column of their own. Anything else the endpoint returns lands in OtherSettings.
    $modelled = @(
        'forkProtectionEnabled', 'buildsEnabledForForks', 'enforceJobAuthScopeForForks',
        'enforceNoAccessToSecretsFromForks', 'enforceJobAuthScope', 'enforceJobAuthScopeForReleases',
        'enforceSettableVar', 'enableShellTasksArgsSanitizing', 'enableShellTasksArgsSanitizingAudit',
        'enforceReferencedRepoScopedToken', 'enforceReferencedGitHubRepoScopedToken',
        'enforceEvenStricterJobAuthScopeInRunRelatedApis',
        'disableImpliedYAMLCiTrigger', 'statusBadgesArePrivate', 'publishPipelineMetadata',
        'disableClassicBuildPipelineCreation', 'disableClassicReleasePipelineCreation'
    )

    $unreadable = [System.Collections.Generic.List[string]]::new()

    foreach ($proj in $projects) {
        $settings = $null
        try {
            $settings = Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                            -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                            -Path "$($proj.id)/_apis/build/generalsettings"
        }
        catch {
            $unreadable.Add($proj.name)
            Write-Verbose "Could not read pipeline settings for '$($proj.name)': $($_.Exception.Message)"
            continue
        }

        $other = @($settings.PSObject.Properties |
                   Where-Object { $_.Name -notin $modelled } |
                   ForEach-Object { "$($_.Name)=$($_.Value)" } | Sort-Object)

        [PSCustomObject]@{
            PSTypeName                = 'MsecAzureDevOpsPipelineSetting'
            Organization              = $Organization
            Project                   = $proj.name

            # Fork settings, reported separately because they only mean anything together.
            ForkProtectionEnabled     = [bool] $settings.forkProtectionEnabled
            BuildsEnabledForForks     = [bool] $settings.buildsEnabledForForks
            # Named for the SAFE state: true means secrets are withheld. The API field is
            # enforceNoAccessToSecretsFromForks, a double negative that is easy to read backwards.
            SecretsWithheldFromForks  = [bool] $settings.enforceNoAccessToSecretsFromForks
            ForkJobAuthScopeLimited   = [bool] $settings.enforceJobAuthScopeForForks

            # Can a pipeline's token reach beyond its own project?
            JobAuthScopeLimited       = [bool] $settings.enforceJobAuthScope
            JobAuthScopeLimitedForReleases = [bool] $settings.enforceJobAuthScopeForReleases
            # Narrower still: the token reaches only the repositories the pipeline actually
            # references, rather than every repository in the project. Surfaced by OtherSettings
            # on the first run against a live organization, where it varied between projects -
            # which is exactly what the catch-all is for.
            ReferencedRepoScopedToken       = [bool] $settings.enforceReferencedRepoScopedToken
            ReferencedGitHubRepoScopedToken = [bool] $settings.enforceReferencedGitHubRepoScopedToken
            StricterJobAuthScopeInRunApis   = [bool] $settings.enforceEvenStricterJobAuthScopeInRunRelatedApis

            # Can whoever queues a run override variables the pipeline defined?
            SettableVarsRestricted    = [bool] $settings.enforceSettableVar

            # Shell task argument sanitising - the mitigation for argument injection through
            # pipeline variables.
            ShellArgsSanitised        = [bool] $settings.enableShellTasksArgsSanitizing
            ShellArgsSanitisingAudit  = [bool] $settings.enableShellTasksArgsSanitizingAudit

            ImpliedYamlCiTriggerDisabled = [bool] $settings.disableImpliedYAMLCiTrigger
            StatusBadgesPrivate       = [bool] $settings.statusBadgesArePrivate
            PublishPipelineMetadata   = [bool] $settings.publishPipelineMetadata
            ClassicBuildDisabled      = [bool] $settings.disableClassicBuildPipelineCreation
            ClassicReleaseDisabled    = [bool] $settings.disableClassicReleasePipelineCreation

            # Settings this module has not been taught, with their values.
            OtherSettings             = if ($other.Count) { $other -join '; ' } else { '' }
        }
    }

    if ($unreadable.Count) {
        $shown = ($unreadable | Select-Object -First 5) -join ', '
        $more  = if ($unreadable.Count -gt 5) { " and $($unreadable.Count - 5) more" } else { '' }
        Write-Warning "$($unreadable.Count) project(s) refused their pipeline settings: $shown$more. Those projects are NOT in this output - treat them as unread, not as configured safely."
    }
}
