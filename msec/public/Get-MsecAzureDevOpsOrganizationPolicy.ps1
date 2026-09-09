function Get-MsecAzureDevOpsOrganizationPolicy {
    <#
    .SYNOPSIS
        The organization-wide Azure DevOps security policies - guest access, OAuth and SSH
        authentication, public projects, who may invite users - as one row per policy.

    .DESCRIPTION
        Calls the Azure DevOps REST API:

            GET https://dev.azure.com/{org}/_apis/organizationpolicy/policies

        These are the ORGANIZATION's ceiling, the same role the SharePoint tenant settings and
        the Teams Global policy play: a well-governed project inside an organization that allows
        third-party OAuth apps and alternate credentials is still exposed, and reviewing
        projects or pipelines one at a time never surfaces it.

        There are only about a dozen of these and every one of them is a security control, so
        unlike Get-MsecTeamsPolicy there is no projection to argue with - all of them are
        returned. Category groups them for reading.

        IsExplicit MATTERS AS MUCH AS THE VALUE. A policy nobody ever set reports its default,
        and the API says so separately; a default that happens to be safe today is not a
        decision anyone made, and it is not guaranteed to stay safe. So the row carries both
        the effective value and whether it was set on purpose, rather than flattening the two
        into one column that reads as deliberate configuration.

        THE APP'S ACCESS IS GRANTED INSIDE AZURE DEVOPS, NOT IN ENTRA. New-MsecApp cannot
        provision it - see the notes.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/, e.g. 'contoso'
        for https://dev.azure.com/contoso.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'

    .EXAMPLE
        # The ones that widen who can reach the organization.
        Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
            Where-Object Category -eq 'Access' |
            Format-Table Setting, Value, IsExplicit

    .EXAMPLE
        # Everything still sitting on its default, i.e. never decided.
        Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
            Where-Object { -not $_.IsExplicit }

    .OUTPUTS
        PSCustomObject per policy, PSTypeName 'MsecAzureDevOpsOrganizationPolicy'.

    .NOTES
        Needs Connect-Msec, and the msec app's service principal must be a member of the ADO
        organization with at least Reader at the project-collection level. That is configured
        INSIDE Azure DevOps (Organization Settings > Users > Add), NOT through Entra API
        permissions - so New-MsecApp cannot grant it, and the usual 401/403 is turned into an
        error that says exactly this.

        Reading these policies additionally needs the app to be able to see organization
        settings, which project-scoped Reader does not cover. If the call 401s while
        Get-MsecAzureDevOpsServiceConnection works, that is the difference.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization
    )

    Assert-MsecSession

    # Grouping only - the API returns no categories, and every policy it returns is a security
    # control. An unrecognised name still comes back, under 'Other': the list grows as Microsoft
    # adds policies, and dropping one because this table has not caught up would hide exactly
    # the new setting nobody has reviewed yet.
    $categories = @{
        'Policy.DisallowAadGuestUserAccess'          = 'Access'      # Entra guests in the org at all
        'Policy.AllowAnonymousAccess'                = 'Access'      # public projects
        'Policy.AllowRequestAccessToken'             = 'Access'       # users can ask for access
        'Policy.AllowTeamAdminsInvitationsAccessToken' = 'Access'    # project admins can invite
        'Policy.DisallowOAuthAuthentication'         = 'Authentication' # third-party OAuth apps
        'Policy.DisallowSecureShell'                 = 'Authentication' # SSH keys
        'Policy.EnforceAADConditionalAccess'         = 'Authentication' # CA applied to ADO
        'Policy.DisallowBasicAuthentication'         = 'Authentication' # alternate credentials
        'Policy.LogAuditEvents'                      = 'Auditing'
        'Policy.ArtifactsExternalPackageProtectionToken' = 'Supply chain'
        'Policy.EnforceSettableVar'                  = 'Pipelines'    # settable-at-queue-time vars
        'Policy.EnforceJobAuthScope'                 = 'Pipelines'    # job token scoped to project
        'Policy.EnforceJobAuthScopeForReleases'      = 'Pipelines'
        'Policy.EnforceReferencedRepoScopedToken'    = 'Pipelines'
    }

    # ADO is a separate Entra resource - 499b84ac-1321-427f-aa17-267ca6975798 is Microsoft's
    # well-known Azure DevOps app ID. Get-MsecAccessToken appends /.default itself, so pass the
    # bare resource identifier (NOT '.../.default' - that produces a malformed
    # '.../default/.default' scope and Entra 400s).
    try {
        $token = Get-MsecAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798'
    }
    catch {
        throw "Could not acquire an Entra token for Azure DevOps. This is a token-request failure (Entra-side), NOT an ADO membership failure. Check the msec app's certificate is still valid and that Connect-Msec succeeded. Original error: $($_.Exception.Message)"
    }

    $uri = "https://dev.azure.com/$Organization/_apis/organizationpolicy/policies?api-version=7.1-preview.1"
    try {
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '401|403|Unauthorized|Forbidden') {
            throw "Unauthorized reading organization policies in '$Organization'. The msec app's service principal needs to be a member of the ADO organization (Organization Settings > Users > Add) with at least Reader at the PROJECT-COLLECTION level - project-scoped Reader can list projects and service connections but cannot read organization settings. This is granted inside Azure DevOps, not through Entra, so New-MsecApp cannot do it. Original error: $detail"
        }
        throw "Could not read organization policies in '$Organization': $detail"
    }

    # The API has shipped more than one shape for this: each entry either carries a nested
    # 'policy' object or is flat. Both are handled rather than guessed at, because the failure
    # mode of guessing is a report of empty rows that looks like an organization with no
    # policies set.
    $entries = @($response.value)
    if (-not $entries.Count) {
        Write-Warning "No organization policies returned for '$Organization'. That is not the same as none being set - it usually means the account can authenticate but cannot see organization settings. Treat this as unread, not as clean."
        return
    }

    foreach ($entry in $entries) {
        $policy = if ($entry.PSObject.Properties.Name -contains 'policy' -and $entry.policy) { $entry.policy } else { $entry }

        $name = [string] $policy.name
        if (-not $name) { continue }

        # effectiveValue is what is actually in force, including anything inherited; value is
        # what this organization set. Prefer the effective one - it is the answer to "what
        # happens today".
        $value = if ($policy.PSObject.Properties.Name -contains 'effectiveValue') { $policy.effectiveValue } else { $policy.value }

        # isValueUndefined is the API saying "nobody set this, you are seeing a default".
        $explicit = if ($policy.PSObject.Properties.Name -contains 'isValueUndefined') { -not [bool] $policy.isValueUndefined } else { $null }

        [PSCustomObject]@{
            PSTypeName = 'MsecAzureDevOpsOrganizationPolicy'
            Category   = if ($categories.ContainsKey($name)) { $categories[$name] } else { 'Other' }
            # The 'Policy.' prefix is on every one of them, so it distinguishes nothing.
            Setting    = $name -replace '^Policy\.', ''
            Value      = if ($null -eq $value) { '(not set)' } else { [string] $value }
            # $null, not $true, when the API did not say - "we do not know whether this was
            # deliberate" is not the same claim as "it was".
            IsExplicit = $explicit
            Organization = $Organization
        }
    }
}
