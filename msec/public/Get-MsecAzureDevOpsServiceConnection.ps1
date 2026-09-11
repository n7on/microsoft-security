function Get-MsecAzureDevOpsServiceConnection {
    <#
    .SYNOPSIS
        Lists every service connection (service endpoint) in an Azure DevOps
        organization, projected to flat PowerShell rows with the full Graph
        object preserved in Raw.

    .DESCRIPTION
        Calls the Azure DevOps REST API:

            GET https://dev.azure.com/{org}/{project}/_apis/serviceendpoint/endpoints
                ?api-version=7.1-preview.4

        Service connections are project-scoped in ADO, but commonly *shared*
        across projects. This function walks all projects in the org by default
        and de-duplicates by endpoint Id, so each connection appears as one row
        even if it's exposed to multiple projects. The 'Projects' column lists
        every project the connection is currently shared to.

        See the examples for the audit-relevant questions the ADO portal makes painful.

    .EXAMPLE
        # All service connections, sorted by what they connect to.
        Get-MsecAzureDevOpsServiceConnection -Organization 'contoso' |
            Sort-Object Type | Format-Table Name, Type, AuthScheme, IsShared

    .EXAMPLE
        # Connections to Azure subscriptions specifically: find forgotten ones, and audit
        # the auth scheme - Service Principal vs Managed Identity vs Federated Workload
        # Identity. A long-lived secret here is a standing key to a subscription.
        Get-MsecAzureDevOpsServiceConnection -Organization 'contoso' |
            Where-Object Type -eq 'azurerm' |
            Select-Object Name, AuthScheme, @{ n = 'SubId'; e = { $_.Raw.data.subscriptionId } },
                          CreatedByName, Projects

    .EXAMPLE
        # Highly shared connections - broad blast radius if one is compromised, because
        # any pipeline in any of those projects can use it.
        Get-MsecAzureDevOpsServiceConnection -Organization 'contoso' |
            Where-Object { $_.Projects.Count -gt 3 } |
            Sort-Object { $_.Projects.Count } -Descending

    .PARAMETER Organization
        Azure DevOps organization name. The bit before .visualstudio.com in
        the legacy URL, or the path segment after dev.azure.com/ in the modern
        URL. E.g. 'contoso' for https://dev.azure.com/contoso.

    .PARAMETER Project
        Restrict to one project. When omitted, walks every project in the org
        (so the result is the org-wide unique list).

    .NOTES
        The msec app's service principal must be added as a member of the ADO
        organization with at least "Reader" permissions at the project-collection
        level (or project-scoped reader on every project you want to query).
        This is configured INSIDE Azure DevOps (Organization Settings > Users),
        NOT via Entra API permissions - so it's NOT something New-MsecApp can
        provision. A clearer error is raised on the typical 401/403.

        Each row is a [PSCustomObject] with PSTypeName 'MsecAzureDevOpsServiceConnection'.
        Default Format-Table view: Name, Type, AuthScheme, IsShared - registered
        in Msec.psm1. Raw and other columns remain accessible via property
        access or Format-List.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Organization,

        [Parameter()]
        [string] $Project,

        # Who can use or administer each connection, and which pipelines may reference it.
        # OPT-IN because it costs two extra calls per connection - 243 connections on the
        # organization this was built against, so nearly 500 round trips.
        #
        # Without it the security columns are $null, which reads as "not collected" rather than
        # "nobody has access" - the same distinction this command draws everywhere else.
        [Parameter()]
        [switch] $IncludeSecurity
    )

    Assert-MsecSession

    # ADO is a separate Entra resource - 499b84ac-1321-427f-aa17-267ca6975798
    # is Microsoft's well-known Azure DevOps app ID. Get-MsecAccessToken appends
    # /.default itself, so pass the bare resource identifier (NOT '.../.default'
    # - that produces a malformed '.../default/.default' scope and Entra 400s).
    try {
        $token = Get-MsecAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798'
    }
    catch {
        throw "Could not acquire an Entra token for Azure DevOps. This is a token-request failure (Entra-side), NOT an ADO membership failure. Check the msec app's certificate is still valid and that Connect-Msec succeeded. Original error: $($_.Exception.Message)"
    }
    $headers = @{ Authorization = "Bearer $token" }

    # Resolve projects to walk.
    $projects = if ($Project) {
        @($Project)
    }
    else {
        $projUri = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1"
        try {
            $resp = Invoke-RestMethod -Method GET -Uri $projUri -Headers $headers -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -match '401|Unauthorized|403|Forbidden') {
                throw "Unauthorized listing projects in '$Organization'. The msec app's service principal needs to be added as a member of the ADO organization (Organization Settings > Users > Add) and granted at least Reader access. Original error: $($_.Exception.Message)"
            }
            throw
        }
        Write-Verbose "Listed $($resp.count) projects in '$Organization'"
        @($resp.value.name)
    }

    # Walk projects, dedupe by endpoint Id. Shared service connections appear in
    # multiple projects' /endpoints responses; the first sighting wins, and we
    # collect every project the endpoint is exposed to from its
    # serviceEndpointProjectReferences array.
    $seen = @{}
    $totalEndpointsSeen = 0
    # Projects that answered 200 with nothing in them. Tracked because that answer is
    # ambiguous - see the warning at the end.
    $emptyProjects = [System.Collections.Generic.List[string]]::new()
    # Counted so -IncludeSecurity cannot look like a no-op when the reads are refused.
    $securityFailures = 0
    $securityTried    = 0
    foreach ($p in $projects) {
        # Encoded: project names routinely contain spaces - 17 of 36 did on the organization
        # this was built against - and passing one raw to -Project built a malformed URL.
        $epUri = "https://dev.azure.com/$Organization/$([uri]::EscapeDataString($p))/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4"
        try {
            $resp = Invoke-RestMethod -Method GET -Uri $epUri -Headers $headers -ErrorAction Stop
        }
        catch {
            # One unauthorised project shouldn't kill the org-wide walk.
            Write-Warning "Could not list service endpoints for project '$p': $($_.Exception.Message)"
            continue
        }
        $endpointCount = @($resp.value).Count
        $totalEndpointsSeen += $endpointCount
        if ($endpointCount -eq 0) { $emptyProjects.Add($p) }
        Write-Verbose "Project '$p': $endpointCount service endpoint(s) visible"

        foreach ($e in $resp.value) {
            if ($seen.ContainsKey($e.id)) { continue }
            $seen[$e.id] = $true

            # Project names where this endpoint is exposed - useful to spot
            # widely-shared connections (broad blast radius).
            $projectNames = @($e.serviceEndpointProjectReferences.projectReference.name)

            $security = [pscustomobject]@{
                Administrators = $null; AdministratorCount = $null; UserCount = $null
                ReaderCount = $null; OpenToAllPipelines = $null; AuthorizedPipelineCount = $null
                OpenedBy = $null; OpenedOn = $null
            }
            if ($IncludeSecurity) {
                $securityTried++
                # The endpoint's own project, which is where both of these are addressed from.
                $ownerProjectId = @($e.serviceEndpointProjectReferences.projectReference.id)[0]

                try {
                    $roles = @((Invoke-RestMethod -Method GET -Headers $headers -Uri (
                        "https://dev.azure.com/$Organization/_apis/securityroles/scopes/distributedtask.serviceendpointrole" +
                        "/roleassignments/resources/$($ownerProjectId)_$($e.id)?api-version=7.1-preview.1")).value)

                    $byRole = { param($n) @($roles | Where-Object { $_.role.name -eq $n }) }
                    $admins = & $byRole 'Administrator'
                    $security.Administrators     = ($admins | ForEach-Object { $_.identity.displayName } | Sort-Object -Unique) -join '; '
                    $security.AdministratorCount = $admins.Count
                    $security.UserCount          = @(& $byRole 'User').Count
                    $security.ReaderCount        = @(& $byRole 'Reader').Count
                }
                catch {
                    # Left $null. A connection whose roles could not be read must not report as
                    # having no administrators. Counted, and reported once at the end - a silent
                    # $null makes the switch look like it does nothing.
                    $securityFailures++
                    Write-Verbose "Could not read roles for '$($e.name)': $($_.Exception.Message)"
                }

                try {
                    $perms = (Invoke-RestMethod -Method GET -Headers $headers -Uri (
                        "https://dev.azure.com/$Organization/$ownerProjectId/_apis/pipelines/pipelinePermissions/endpoint/$($e.id)?api-version=7.1-preview.1"))
                    # The field is absent unless the setting is on, so absence is false - but a
                    # failed CALL stays $null above, which is a different thing.
                    $security.OpenToAllPipelines  = [bool] $perms.allPipelines.authorized
                    $security.AuthorizedPipelineCount = @($perms.pipelines).Count
                    # Who opened it, and when - the decision is usually old.
                    $security.OpenedBy = $perms.allPipelines.authorizedBy.displayName
                    $security.OpenedOn = $perms.allPipelines.authorizedOn
                }
                catch {
                    Write-Verbose "Could not read pipeline permissions for '$($e.name)': $($_.Exception.Message)"
                }
            }

            [PSCustomObject]@{
                PSTypeName    = 'MsecAzureDevOpsServiceConnection'
                Id            = $e.id
                Name          = $e.name
                Type          = $e.type
                Url           = $e.url
                Description   = $e.description
                IsShared      = [bool]$e.isShared
                IsReady       = [bool]$e.isReady
                AuthScheme    = $e.authorization.scheme
                CreatedByName = $e.createdBy.displayName
                Projects      = $projectNames

                # $null unless -IncludeSecurity: not collected, not "none".
                Administrators          = $security.Administrators
                AdministratorCount      = $security.AdministratorCount
                UserCount               = $security.UserCount
                ReaderCount             = $security.ReaderCount
                # TRUE IS THE PERMISSIVE STATE: "Grant access permission to all pipelines" is on,
                # so any pipeline in the project may authenticate through this connection with no
                # further approval. FALSE means pipelines are authorised individually, and those
                # appear in AuthorizedPipelineCount. The API omits the field entirely when the
                # setting is off, so absence is reported as false - but a failed CALL stays $null.
                OpenToAllPipelines  = $security.OpenToAllPipelines
                AuthorizedPipelineCount = $security.AuthorizedPipelineCount
                OpenedBy                = $security.OpenedBy
                OpenedOn                = $security.OpenedOn

                Raw           = $e
            }
        }
    }

    Write-Verbose "Walked $($projects.Count) project(s); $totalEndpointsSeen total endpoint reference(s) (incl. duplicates from shared connections); $($seen.Count) unique service connection(s) returned"
    # WHAT THIS NEEDS IS THE 'User' ROLE, established against a live organization after four
    # wrong answers. Service connections use ROLE ASSIGNMENTS
    # (distributedtask.serviceendpointrole), not the ServiceEndpoints security namespace - an
    # allow on that namespace is accepted, stored, reported back, and confers nothing. And
    # within the role model, 'Reader' is not enough: an identity holding Reader on every
    # connection in a project, inherited and effective, still gets an empty list. 'User' is what
    # this API checks.
    #
    # GRANT IT ONCE FOR THE ORGANIZATION, on the namespace side. The two permission systems are
    # connected: an allow at the ServiceEndpoints root token 'endpoints' surfaces as an inherited
    # ROLE on every project and connection.
    #
    #   ViewEndpoint (bit 16) -> inherited Reader -> still an empty list
    #   Use          (bit 1)  -> inherited User   -> what this API checks
    #
    #   ./tools/Grant-MsecAzureDevOpsPermission.ps1 -Organization <org> -Identity <group> `
    #       -Namespace ServiceEndpoints -Permission Use -Scope Organization -Pat $pat -Apply
    #
    # Verified: one write took an organization from 70 connections in 1 project to 243 across 14.
    # Per-project role assignments (-RoleName User -Scope Project) do the same thing one project
    # at a time and are not needed.
    #
    # 'User' means "may authenticate through this connection", which reads alarming for a
    # read-only module. In practice the app would also need to author and run a pipeline to
    # exploit it, which needs Contribute on a repository and build permissions it does not have.
    # Worth knowing rather than waving away.
    #
    # A PROJECT WITH NO VISIBLE ENDPOINTS RETURNS 200 AND AN EMPTY LIST - the same answer as a
    # project that genuinely has none. Service connections are permissioned per connection, so an
    # identity can see some and not others within one project, and the response never says what
    # it withheld. Measured on a live organization: an app in [Project]\Readers on 36 projects
    # saw 70 connections in 1 project where a person saw 155 across 14.
    #
    # The shortfall is still reported rather than assumed away, because a project can withhold
    # connections for reasons this command cannot see - but the usual cause is the missing
    # 'User' role above.
    if ($IncludeSecurity -and $securityFailures) {
        $which = if ($securityFailures -eq $securityTried) { 'every connection' } else { "$securityFailures of $securityTried connection(s)" }
        Write-Warning "-IncludeSecurity could not read role assignments for $which, so Administrators, AdministratorCount, UserCount and ReaderCount are `$null rather than counts. Reading a connection's roles needs more than listing it - grant the group 'Administer' is NOT required, but the reader must be able to see the role assignments on the endpoint scope."
    }

    if ($emptyProjects.Count) {
        $shown = ($emptyProjects | Select-Object -First 5) -join ', '
        $more  = if ($emptyProjects.Count -gt 5) { " and $($emptyProjects.Count - 5) more" } else { '' }
        Write-Warning "$($emptyProjects.Count) of $($projects.Count) project(s) returned no service connections: $shown$more. That is NOT proof they have none - this API answers 200 with an empty list for connections the caller cannot see. Compare against what a person sees in the portal before treating this as the full picture."
    }
}
