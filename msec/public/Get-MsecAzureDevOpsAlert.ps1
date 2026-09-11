function Get-MsecAzureDevOpsAlert {
    <#
    .SYNOPSIS
        Advanced Security alerts across an Azure DevOps organization - secret, dependency and
        code scanning findings - as one row per alert.

    .DESCRIPTION
        What the Security Overview page shows, as objects. Secret scanning finds credentials
        committed to source; the alert is a live exposure, not a code-quality opinion.

        THERE IS NO ORGANIZATION-WIDE ALERTS ENDPOINT. Confirmed by enumerating the Advanced
        Security service's own routes: every alerts route is
        {project}/_apis/alert/repositories/{repository}/alerts. The portal's org-level view
        aggregates client-side, and so does this - one call per enabled repository.

        THE REPOSITORY LIST COMES FROM ENABLEMENT, NOT FROM THE GIT API, and that is deliberate.
        _apis/git/repositories returns only what the caller can see - measured on a live
        organization, an app saw 95 repositories where a person with a PAT saw 220 - and it
        returns them with a 200, so the shortfall is invisible. _apis/management/enablement is
        ORGANIZATION-scoped, lists every repository with Advanced Security switched on, and is
        readable by an org member. The git call is used only to put names to ids; a repository
        whose name cannot be resolved is still queried and reported by id.

        A REPOSITORY THAT CANNOT BE READ FAILS LOUDLY. Alerts return 403, never an empty list,
        so unreadable repositories are counted and named rather than passing as clean. That is
        the property that makes this command trustworthy where a service-connection inventory
        was not.

        THE SECRET ITSELF IS NOT RETURNED. The API includes a truncatedSecret field holding a
        fragment of the credential it found. This command drops it: the output of a security
        report ends up in mailboxes and spreadsheets, and a partial credential in a spreadsheet
        is a second exposure. Title carries the secret TYPE, which is what triage needs.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/, e.g. 'contoso'.

    .PARAMETER State
        Filter by alert state. Default 'active' - the alerts that still matter. 'all' includes
        fixed and dismissed ones.

    .PARAMETER AlertType
        Filter by kind: secret, dependency, code. All kinds by default.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsAlert -Organization 'contoso' |
            Format-Table Project, Repository, Severity, AlertType, Title, AgeDays

    .EXAMPLE
        # The ones to act on first: live credentials, high confidence, oldest first.
        Get-MsecAzureDevOpsAlert -Organization 'contoso' |
            Where-Object { $_.AlertType -eq 'secret' -and $_.Confidence -eq 'high' } |
            Sort-Object AgeDays -Descending

    .OUTPUTS
        PSCustomObject per alert, PSTypeName 'MsecAzureDevOpsAlert'.

    .NOTES
        Needs Connect-Msec, and the msec app must be a member of the ADO organization AND hold
        Advanced Security alert read. Organization membership alone is not enough - the alerts
        call returns 403 while enablement and repository listing succeed.

        One call per enabled repository, so this is slow on a large organization: 87 enabled
        repositories on the tenant it was built against.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [ValidateSet('active', 'fixed', 'dismissed', 'all')]
        [string] $State = 'active',

        [ValidateSet('secret', 'dependency', 'code')]
        [string[]] $AlertType
    )

    Assert-MsecSession

    # Organization-scoped and authoritative about what is switched on. See the help for why the
    # git repository list is not used for this.
    $enablement = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                        -HostName 'advsec.dev.azure.com' -ApiVersion '7.2-preview.1' `
                        -Path '_apis/management/enablement')
    $enabled = @($enablement.reposEnablementStatus | Where-Object { $_.advSecEnabled })

    if (-not $enabled.Count) {
        Write-Warning "No repositories report Advanced Security as enabled in '$Organization'. If the portal disagrees, treat this as UNREAD rather than as an organization with no scanning."
        return
    }
    Write-Verbose "$($enabled.Count) repository(ies) with Advanced Security enabled."

    # Names only. Ids that do not resolve are still queried - see the help.
    $repoName = @{}
    $projectName = @{}
    try {
        foreach ($repo in @(Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' -ApiVersion '7.1' -Path '_apis/git/repositories' -All)) {
            $repoName[[string] $repo.id] = $repo.name
            $projectName[[string] $repo.project.id] = $repo.project.name
        }
    }
    catch {
        Write-Warning "Could not list repositories to resolve names, so alerts are reported by id: $($_.Exception.Message)"
    }

    $unreadable = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $enabled) {
        $projectId = [string] $entry.projectId
        $repositoryId = [string] $entry.repositoryId
        $label = "$($projectName[$projectId] ?? $projectId)/$($repoName[$repositoryId] ?? $repositoryId)"

        $path = "$projectId/_apis/alert/repositories/$repositoryId/alerts"
        if ($State -ne 'all') { $path += "?criteria.states=$State" }

        try {
            $alerts = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                            -HostName 'advsec.dev.azure.com' -ApiVersion '7.2-preview.1' `
                            -Path $path -All)
        }
        catch {
            # Named, not skipped. 403 here means the app lacks Advanced Security alert read on
            # that repository - a repository whose findings are missing from the report, which
            # must not read as a repository with none.
            $unreadable.Add($label)
            Write-Verbose "Could not read alerts for '$label': $($_.Exception.Message)"
            continue
        }

        foreach ($alert in $alerts) {
            if ($AlertType -and $alert.alertType -notin $AlertType) { continue }

            # First physical location is where the finding is; the rest are duplicates of the
            # same secret elsewhere in history.
            $location = @($alert.physicalLocations)[0]

            [PSCustomObject]@{
                PSTypeName    = 'MsecAzureDevOpsAlert'
                Organization  = $Organization
                Project       = $projectName[$projectId] ?? $projectId
                Repository    = $repoName[$repositoryId] ?? $repositoryId
                AlertId       = $alert.alertId
                AlertType     = $alert.alertType
                Severity      = $alert.severity
                State         = $alert.state
                Confidence    = $alert.confidence
                # The secret TYPE, not the secret. truncatedSecret is deliberately dropped.
                Title         = $alert.title
                FilePath      = $location.filePath
                Tool          = @($alert.tools)[0].name
                FirstSeen     = $alert.firstSeenDate
                LastSeen      = $alert.lastSeenDate
                FixedDate     = $alert.fixedDate
                # How long it has been sitting there. For a committed credential this is the
                # number that matters: exposure is cumulative and does not stop at detection.
                AgeDays       = if ($alert.firstSeenDate) { [int] ([DateTime]::UtcNow - [DateTime] $alert.firstSeenDate).TotalDays } else { $null }
                IsAutoFixable = $alert.isAutoFixable
            }
        }
    }

    if ($unreadable.Count) {
        $shown = ($unreadable | Select-Object -First 5) -join ', '
        $more  = if ($unreadable.Count -gt 5) { " and $($unreadable.Count - 5) more" } else { '' }
        Write-Warning "$($unreadable.Count) of $($enabled.Count) enabled repository(ies) refused their alerts: $shown$more. Those findings are NOT in this output. The msec app needs Advanced Security alert read - organization membership alone returns 403 here while enablement and repository listing succeed."
    }
}
