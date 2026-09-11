function Get-MsecAzureDevOpsOrganization {
    <#
    .SYNOPSIS
        Every Azure DevOps organization connected to the Entra tenant, with its owner.

    .DESCRIPTION
        Anyone in the tenant can create an Azure DevOps organization, and by default nothing
        announces it. The result is organizations nobody is reviewing: created for a trial or a
        side project, owned by one person, holding repositories and service connections that no
        governance process knows about. Measured on a live tenant: 28 organizations, most of them
        named after individuals.

        THIS IS THE COMMAND THAT TELLS YOU WHAT TO POINT THE OTHERS AT. Every other
        Get-MsecAzureDevOps* command takes -Organization, and the answer is only as complete as
        the list of organizations you thought to check.

        THE ENDPOINT IS INTERNAL. There is no documented REST API for enumerating a tenant's
        organizations; this is the route behind the Azure DevOps organization list in the Entra
        admin portal, and it returns CSV rather than JSON. Microsoft can change or remove it
        without notice. If this starts returning nothing, that is the first thing to suspect -
        which is why an empty result warns rather than reporting a tenant with no organizations.

        THE OWNER IS THE ACCOUNTABLE PERSON, not necessarily an administrator. It is whoever
        created the organization or had ownership transferred to them, and it is the single most
        useful column here: an organization whose owner has left the company is one nobody can
        administer.

    .PARAMETER TenantId
        The Entra tenant to enumerate. Defaults to the tenant of the current msec session, which
        is almost always what you want.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsOrganization | Sort-Object Owner

    .EXAMPLE
        # Organizations named after a person - usually personal, usually unreviewed.
        Get-MsecAzureDevOpsOrganization |
            Where-Object { $_.Organization -notmatch '^(contoso|prod|shared)' }

    .EXAMPLE
        # Feed the whole estate through another command.
        Get-MsecAzureDevOpsOrganization | ForEach-Object {
            Get-MsecAzureDevOpsOrganizationPolicy -Organization $_.Organization
        }

    .OUTPUTS
        PSCustomObject per organization, PSTypeName 'MsecAzureDevOpsOrganization'.

    .NOTES
        Needs Connect-Msec. The app needs no membership in the organizations it lists - this is a
        tenant-level query - but it does need to be able to acquire an Azure DevOps token, which
        Connect-Msec handles.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $TenantId
    )

    Assert-MsecSession

    if (-not $TenantId) { $TenantId = $script:MsecSession.TenantId }
    if (-not $TenantId) { throw 'No tenant id in the session and none given. Pass -TenantId.' }

    try {
        $token = Get-MsecAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798'
    }
    catch {
        throw "Could not acquire an Entra token for Azure DevOps. This is a token-request failure (Entra-side). Check the msec app's certificate is still valid and that Connect-Msec succeeded. Original error: $($_.Exception.Message)"
    }

    # Not Invoke-MsecAzureDevOpsRequest: that builds https://{host}/{organization}/... and appends
    # an api-version, and this route is tenant-scoped with neither.
    $uri = "https://aex.dev.azure.com/_apis/EnterpriseCatalog/Organizations?tenantId=$TenantId"
    try {
        $response = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '401|403|Unauthorized|Forbidden') {
            throw "Forbidden listing organizations in tenant '$TenantId'. This is a tenant-level query and needs an identity the tenant recognises; being a member of one organization is not the same thing. Original error: $detail"
        }
        throw "Could not list organizations in tenant '$TenantId': $detail"
    }

    # CSV, not JSON - see the help.
    $rows = @($response.Content | ConvertFrom-Csv)
    if (-not $rows.Count) {
        Write-Warning "No organizations returned for tenant '$TenantId'. This route is internal to the Azure DevOps admin portal and may have changed shape - treat this as UNREAD, not as a tenant with no organizations."
        return
    }

    foreach ($row in $rows) {
        [PSCustomObject]@{
            PSTypeName   = 'MsecAzureDevOpsOrganization'
            TenantId     = $TenantId
            Organization = $row.'Organization Name'
            # Whoever created it or had ownership transferred to them. An organization whose
            # owner has left is one nobody can administer.
            Owner        = $row.Owner
            Url          = $row.Url
            Id           = $row.'Organization Id'
        }
    }
}
