function Get-MsecAdoServiceConnection {
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
        Get-MsecAdoServiceConnection -Organization 'contoso' |
            Sort-Object Type | Format-Table Name, Type, AuthScheme, IsShared

    .EXAMPLE
        # Connections to Azure subscriptions specifically: find forgotten ones, and audit
        # the auth scheme - Service Principal vs Managed Identity vs Federated Workload
        # Identity. A long-lived secret here is a standing key to a subscription.
        Get-MsecAdoServiceConnection -Organization 'contoso' |
            Where-Object Type -eq 'azurerm' |
            Select-Object Name, AuthScheme, @{ n = 'SubId'; e = { $_.Raw.data.subscriptionId } },
                          CreatedByName, Projects

    .EXAMPLE
        # Highly shared connections - broad blast radius if one is compromised, because
        # any pipeline in any of those projects can use it.
        Get-MsecAdoServiceConnection -Organization 'contoso' |
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

        Each row is a [PSCustomObject] with PSTypeName 'MsecAdoServiceConnection'.
        Default Format-Table view: Name, Type, AuthScheme, IsShared - registered
        in msec.psm1. Raw and other columns remain accessible via property
        access or Format-List.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Organization,

        [Parameter()]
        [string] $Project
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
    foreach ($p in $projects) {
        $epUri = "https://dev.azure.com/$Organization/$p/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4"
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
        Write-Verbose "Project '$p': $endpointCount service endpoint(s) visible"

        foreach ($e in $resp.value) {
            if ($seen.ContainsKey($e.id)) { continue }
            $seen[$e.id] = $true

            # Project names where this endpoint is exposed - useful to spot
            # widely-shared connections (broad blast radius).
            $projectNames = @($e.serviceEndpointProjectReferences.projectReference.name)

            [PSCustomObject]@{
                PSTypeName    = 'MsecAdoServiceConnection'
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
                Raw           = $e
            }
        }
    }

    Write-Verbose "Walked $($projects.Count) project(s); $totalEndpointsSeen total endpoint reference(s) (incl. duplicates from shared connections); $($seen.Count) unique service connection(s) returned"
    if ($projects.Count -gt 0 -and $seen.Count -eq 0) {
        Write-Warning "Walked $($projects.Count) project(s) but found zero service connections. This almost always means the msec SP has 'Project Reader' access (so it can SEE projects) but doesn't have read access to service connections themselves - they have their own permission gate. Either add the SP to each project's 'Endpoint Administrators' group, or grant Reader role at Project Settings > Pipelines > Service connections > Security."
    }
}
