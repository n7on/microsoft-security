function Get-MsecAzureDevOpsRepository {
    <#
    .SYNOPSIS
        Every Git repository in an Azure DevOps organization with the protections on its default
        branch - reviewers, build validation, secret push protection, Advanced Security.

    .DESCRIPTION
        The question this answers is "which repositories can be changed without anyone looking".
        A repository whose default branch has no blocking policy accepts a direct push to main;
        one whose minimum-reviewer policy counts the author's own vote accepts a self-approved
        pull request, which is the same thing with more steps.

        POLICIES ARE FETCHED ONCE PER PROJECT, not once per repository. The policy configuration
        endpoint is project-scoped and returns every policy for every repository in one call, so
        a few dozen calls cover hundreds of repositories.

        A POLICY ONLY COUNTS IF IT IS ENABLED AND BLOCKING. Azure DevOps lets a policy be
        configured, enabled, and non-blocking - it shows in the pull request as advice and stops
        nothing. Reporting that as protection would overstate the posture, so the Require*
        columns mean "enabled AND blocking" and PolicyCount reports everything found.

        SCOPE IS RESOLVED, NOT ASSUMED. A policy can be scoped to one repository or to every
        repository in the project (a null repository id), and to an exact branch, a prefix, or
        the whole repository (an empty ref). All four are matched against the default branch,
        because a project-wide policy protects a repository just as well as a per-repository one.

        THIS COMMAND IS ONLY AS COMPLETE AS THE APP'S READ ACCESS. Azure DevOps returns the
        repositories the caller can see, with a 200 - it does not say what it withheld. An app
        without Read on the Git Repositories namespace silently sees a subset. See the notes.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER Project
        Restrict to one project. All projects by default.

    .PARAMETER Unprotected
        Only repositories whose default branch requires NO REVIEWER - the ones a change can
        reach main through without anyone else looking.

        Deliberately not "no blocking policy at all": on a real organization every repository
        had at least one, because a single project-wide secrets-scanning rule applies to all of
        them. By that measure nothing was ever unprotected, which is true and useless. The
        reviewer requirement is the control that decides whether a human sees the change.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsRepository -Organization 'contoso' |
            Format-Table Project, Repository, DefaultBranch, MinimumReviewers, RequireBuildValidation

    .EXAMPLE
        # Repositories anyone can push to unreviewed.
        Get-MsecAzureDevOpsRepository -Organization 'contoso' -Unprotected |
            Sort-Object Project, Repository

    .EXAMPLE
        # Protected on paper only: a reviewer policy the author can satisfy alone.
        Get-MsecAzureDevOpsRepository -Organization 'contoso' |
            Where-Object { $_.MinimumReviewers -ge 1 -and $_.SelfApprovalAllowed }

    .OUTPUTS
        PSCustomObject per repository, PSTypeName 'MsecAzureDevOpsRepository'.

    .NOTES
        Needs Connect-Msec, and the msec app must be a member of the ADO organization with Read
        on the Git Repositories namespace. Without it the organization returns only the
        repositories the app happens to see and says nothing about the rest - measured on a live
        organization, 95 of 220. Grant it once for the whole organization:

            ./tools/Grant-MsecAzureDevOpsPermission.ps1 -Organization <org> `
                -Identity <group> -Permission GenericRead -Scope Organization -Pat $pat -Apply
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [string] $Project,

        [switch] $Unprotected
    )

    Assert-MsecSession

    $repositories = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                          -HostName 'dev.azure.com' -ApiVersion '7.1' -Path '_apis/git/repositories' -All)
    if ($Project) { $repositories = @($repositories | Where-Object { $_.project.name -eq $Project }) }

    if (-not $repositories.Count) {
        Write-Warning "No repositories returned for '$Organization'. That is 'nothing was read', not 'no repositories' - check the app has Read on the Git Repositories namespace."
        return
    }
    Write-Verbose "$($repositories.Count) repository(ies)."

    # Organization-scoped, one call, covers every repository Advanced Security knows about.
    $advSec = @{}
    try {
        $enablement = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                            -HostName 'advsec.dev.azure.com' -ApiVersion '7.2-preview.1' `
                            -Path '_apis/management/enablement')
        foreach ($entry in @($enablement.reposEnablementStatus)) {
            $advSec[[string] $entry.repositoryId] = $entry
        }
    }
    catch {
        Write-Warning "Could not read Advanced Security enablement, so those columns are `$null rather than false: $($_.Exception.Message)"
    }

    # Project-scoped, so fetched once per project rather than once per repository.
    $policiesByProject = @{}
    foreach ($projectId in @($repositories.project.id | Sort-Object -Unique)) {
        try {
            $policiesByProject[$projectId] = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                                                   -HostName 'dev.azure.com' -ApiVersion '7.1' `
                                                   -Path "$projectId/_apis/policy/configurations" -All)
        }
        catch {
            # Named, not skipped: no policies read is not the same as no policies configured,
            # and the repositories in that project would otherwise all report unprotected.
            Write-Warning "Could not read branch policies for project $projectId, so its repositories report `$null protection rather than none: $($_.Exception.Message)"
            $policiesByProject[$projectId] = $null
        }
    }

    foreach ($repository in $repositories) {
        $projectId = [string] $repository.project.id
        $policies  = $policiesByProject[$projectId]
        $defaultRef = [string] $repository.defaultBranch          # refs/heads/main

        $applicable = @()
        if ($null -ne $policies) {
            $applicable = @($policies | Where-Object {
                if (-not $_.isEnabled) { return $false }
                foreach ($scope in @($_.settings.scope)) {
                    # A null repository id means every repository in the project.
                    $repoMatches = (-not $scope.repositoryId) -or ([string] $scope.repositoryId -eq [string] $repository.id)
                    if (-not $repoMatches) { continue }

                    # An empty ref means the whole repository, which covers the default branch.
                    if (-not $scope.refName) { return $true }
                    if ($scope.matchKind -eq 'Exact'  -and $scope.refName -eq $defaultRef) { return $true }
                    if ($scope.matchKind -eq 'Prefix' -and $defaultRef -and $defaultRef.StartsWith([string] $scope.refName)) { return $true }
                }
                return $false
            })
        }

        # Blocking only - see the help. A non-blocking policy is advice.
        $blocking = @($applicable | Where-Object { $_.isBlocking })
        $ofType   = { param($name) @($blocking | Where-Object { $_.type.displayName -eq $name }) }

        $reviewers = & $ofType 'Minimum number of reviewers' | Select-Object -First 1
        $required  = @(& $ofType 'Required reviewers')
        $fileSize  = & $ofType 'File size restriction' | Select-Object -First 1
        $enablement = $advSec[[string] $repository.id]

        # EVERY BLOCKING POLICY THIS COMMAND DOES NOT MODEL, BY NAME. Azure DevOps adds policy
        # types, organizations write custom ones, and a column-per-known-type report silently
        # drops what it has not been taught. A reviewer can see something is there and go look.
        $modelled = @('Minimum number of reviewers', 'Required reviewers', 'Build',
                      'Require a merge strategy', 'Secrets scanning restriction',
                      'Comment requirements', 'Work item linking', 'File size restriction')
        $other = @($blocking | Where-Object { $_.type.displayName -notin $modelled } |
                   ForEach-Object { $_.type.displayName } | Sort-Object -Unique)

        $row = [PSCustomObject]@{
            PSTypeName             = 'MsecAzureDevOpsRepository'
            Organization           = $Organization
            Project                = $repository.project.name
            Repository             = $repository.name
            # Trimmed: 'refs/heads/main' is the same information as 'main' with more to read.
            DefaultBranch          = if ($defaultRef) { $defaultRef -replace '^refs/heads/', '' } else { $null }
            IsDisabled             = [bool] $repository.isDisabled
            SizeMB                 = if ($null -ne $repository.size) { [math]::Round($repository.size / 1MB, 1) } else { $null }

            # $null rather than 0 when policies could not be read - see the warning above.
            MinimumReviewers       = if ($null -eq $policies) { $null } elseif ($reviewers) { [int] $reviewers.settings.minimumApproverCount } else { 0 }
            # Named individuals or groups that must approve, on top of the count above.
            RequiredReviewers      = if ($null -eq $policies) { $null } else { @($required | ForEach-Object { @($_.settings.requiredReviewerIds).Count } | Measure-Object -Sum).Sum }
            # The author's own approval counting towards the minimum makes a one-reviewer policy
            # satisfiable by the person who wrote the change.
            SelfApprovalAllowed    = if ($reviewers) { [bool] $reviewers.settings.creatorVoteCounts } else { $null }
            # Without this, whoever pushed last can approve their own push even when the author
            # cannot - the same hole reached by a different route.
            BlockLastPusherVote    = if ($reviewers) { [bool] $reviewers.settings.blockLastPusherVote } else { $null }
            # Approvals are voided by a new push. Without it, approve-then-change lands unreviewed
            # code behind an approval given for something else.
            ResetVotesOnPush       = if ($reviewers) { [bool] $reviewers.settings.resetOnSourcePush } else { $null }
            RequireVoteOnLastIteration = if ($reviewers) { [bool] $reviewers.settings.requireVoteOnLastIteration } else { $null }
            RequireVoteOnEachIteration = if ($reviewers) { [bool] $reviewers.settings.requireVoteOnEachIteration } else { $null }
            # A rejection surviving a push is what stops "push until the objection goes away".
            ResetRejectionsOnPush  = if ($reviewers) { [bool] $reviewers.settings.resetRejectionsOnSourcePush } else { $null }
            AllowDownvotes         = if ($reviewers) { [bool] $reviewers.settings.allowDownvotes } else { $null }

            RequireBuildValidation = if ($null -eq $policies) { $null } else { @(& $ofType 'Build').Count -gt 0 }
            RequireMergeStrategy   = if ($null -eq $policies) { $null } else { @(& $ofType 'Require a merge strategy').Count -gt 0 }
            RequireCommentResolution = if ($null -eq $policies) { $null } else { @(& $ofType 'Comment requirements').Count -gt 0 }
            RequireWorkItemLink    = if ($null -eq $policies) { $null } else { @(& $ofType 'Work item linking').Count -gt 0 }
            # Push protection: blocks a commit containing a detected secret from landing at all,
            # which is the control that stops the alerts this module reports elsewhere.
            BlockSecretPush        = if ($null -eq $policies) { $null } else { @(& $ofType 'Secrets scanning restriction').Count -gt 0 }
            MaxFileSizeMB          = if ($fileSize) { [math]::Round([double] $fileSize.settings.maximumGitBlobSizeInBytes / 1MB, 1) } else { $null }

            AdvancedSecurity       = if ($enablement) { [bool] $enablement.advSecEnabled } else { $null }
            CodeQL                 = if ($enablement) { [bool] $enablement.advSecEnablementFeatures.codeQLEnabled } else { $null }
            Dependabot             = if ($enablement) { [bool] $enablement.advSecEnablementFeatures.dependabotEnabled } else { $null }
            DependencyScanning     = if ($enablement) { [bool] $enablement.advSecEnablementFeatures.dependencyScanningInjectionEnabled } else { $null }

            # Everything scoped here, blocking or not, so a number that looks low can be checked.
            PolicyCount            = if ($null -eq $policies) { $null } else { $applicable.Count }
            BlockingPolicyCount    = if ($null -eq $policies) { $null } else { $blocking.Count }
            # Blocking policy types with no column of their own - custom policies, and anything
            # Azure DevOps adds after this was written.
            OtherPolicies          = if ($null -eq $policies) { $null } elseif ($other.Count) { $other -join '; ' } else { '' }
        }

        # See the help: a reviewer requirement, not merely some blocking policy. $null means
        # policies could not be read, which is not evidence of being unprotected.
        if ($Unprotected -and ($null -eq $row.MinimumReviewers -or $row.MinimumReviewers -gt 0)) { continue }
        $row
    }
}
