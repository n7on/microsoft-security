function Get-MsecAzureDevOpsOrganizationPolicy {
    <#
    .SYNOPSIS
        The organization-wide Azure DevOps policies from Organization Settings > Policies -
        third-party OAuth access, SSH, PAT creation, guest access, public projects, audit
        logging - as one row per policy.

    .DESCRIPTION
        These are the ORGANIZATION's ceiling, the same role the SharePoint tenant settings and
        the Teams Global policy play: a well-governed project inside an organization that allows
        third-party OAuth apps and unrestricted PAT creation is still exposed, and reviewing
        projects or pipelines one at a time never surfaces it.

        THERE IS NO REST API FOR THIS, and that is worth knowing before you rely on it.
        _apis/organizationpolicy/policies does not exist - it 404s on every api-version and on
        both hosts. The only source is the data provider behind the portal's own settings page:

            GET https://dev.azure.com/{org}/_settings/organizationPolicy?__rt=fps&__ver=2

        That is an INTERNAL route. It needs no extra permission beyond organization membership,
        it returns the same data the page renders, and Microsoft can change or remove it without
        notice or a version bump. If this command starts returning nothing, that is the first
        thing to suspect.

        THE PORTAL SHOWS SOME TOGGLES INVERTED. Four policies are named for what they forbid -
        Policy.DisallowOAuthAuthentication and friends - so the page renders the opposite of the
        stored value: DisallowOAuthAuthentication = True appears as "Third-party application
        access via OAuth: Off". Value is reported RAW, as the API gives it, and IsInverted says
        when the page disagrees. Reading the raw value together with the policy name is
        unambiguous; reading it against the page's label is not.

        IsExplicit MATTERS AS MUCH AS THE VALUE. A policy nobody ever set reports its default,
        and the provider says so separately. A default that happens to be safe today is not a
        decision anyone made, and nothing stops it changing.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/, e.g. 'contoso'.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
            Format-Table Category, Setting, Value, IsExplicit

    .EXAMPLE
        # Everything still sitting on its default, i.e. never decided by anyone.
        Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
            Where-Object { -not $_.IsExplicit }

    .OUTPUTS
        PSCustomObject per policy, PSTypeName 'MsecAzureDevOpsOrganizationPolicy'.

    .NOTES
        Needs Connect-Msec, and the msec app's service principal must be a member of the ADO
        organization (Organization Settings > Users > Add) with Basic access. That is granted
        INSIDE Azure DevOps, not through Entra API permissions, so New-MsecApp cannot do it.

        Verified against a live organization: 13 policies in 4 groups.

        A POLICY THAT IS ON IS A SETTING, NOT A CAPABILITY. These rows report what the
        organization has configured; they do not report what Azure DevOps will actually let
        anyone do. The two can disagree, and 'Allow public projects' is the case where they
        did: measured on a live organization it read Value True and IsExplicit True - somebody
        had deliberately turned it on - while the product refused to create a public project at
        all, offering GitHub instead. The reason is that PUBLIC PROJECTS ARE RETIRED: Microsoft
        removed the ability to create one or to make a private project public, and existing
        public projects convert to private during 2027. The toggle still renders, still stores
        a value and still reports IsExplicit - and means nothing. A vestigial setting is a
        worse failure than a wrong one, because it reads as a live permission in both
        directions.

        So an enabled policy here is the right place to START a question, not the answer to it.
        Reading 'Allow public projects: True' as "this organization can publish its code" was
        wrong on the one organization it was tested against - the only way to know is to try it,
        or to check what the projects actually are (Get-MsecAzureDevOpsRepository reports the
        repositories; project visibility is on the project). The reverse error is not possible
        in the same way: a policy that is OFF really does mean the capability is unavailable.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization
    )

    Assert-MsecSession

    # The provider groups the policies itself - applicationConnection, security, user, privacy -
    # so there is no category table here to drift out of date. Only the casing is ours.
    $categoryNames = @{
        applicationConnection = 'Application connection'
        security              = 'Security'
        user                  = 'User'
        privacy               = 'Privacy'
    }

    # Not Invoke-MsecAzureDevOpsRequest: that appends an api-version, and this internal route
    # takes __rt/__ver instead and 404s with one attached.
    try {
        $token = Get-MsecAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798'
    }
    catch {
        throw "Could not acquire an Entra token for Azure DevOps. This is a token-request failure (Entra-side), NOT an ADO membership failure. Check the msec app's certificate is still valid and that Connect-Msec succeeded. Original error: $($_.Exception.Message)"
    }

    $uri = "https://dev.azure.com/$Organization/_settings/organizationPolicy?__rt=fps&__ver=2"
    try {
        $response = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '401|403|Unauthorized|Forbidden') {
            throw "Unauthorized reading organization policies in '$Organization'. The msec app's service principal needs to be a member of the ADO organization (Organization Settings > Users > Add) with Basic access - Stakeholder is not enough. This is granted inside Azure DevOps, not through Entra, so New-MsecApp cannot do it. Original error: $detail"
        }
        throw "Could not read organization policies in '$Organization': $detail"
    }

    $provider = ($response.Content | ConvertFrom-Json).fps.dataProviders.data.'ms.vss-admin-web.organization-policies-data-provider'
    if (-not $provider -or -not $provider.policies) {
        # Named rather than returned empty: this is the internal route changing shape, which is
        # exactly the risk the help warns about - and an empty list would read as an
        # organization with no policies rather than a source that stopped working.
        Write-Warning "The organization-policies data provider returned nothing for '$Organization'. This route is internal to the portal and may have changed shape - treat this as UNREAD, not as an organization with no policies set."
        return
    }

    # The four policies named for what they forbid, which the page therefore renders inverted.
    $inverted = @($provider.invertedPolicies)

    foreach ($group in $provider.policies.PSObject.Properties) {
        foreach ($entry in $group.Value) {
            $name = [string] $entry.policy.name
            if (-not $name) { continue }

            [PSCustomObject]@{
                PSTypeName   = 'MsecAzureDevOpsOrganizationPolicy'
                Category     = if ($categoryNames.ContainsKey($group.Name)) { $categoryNames[$group.Name] } else { $group.Name }
                # The portal's own label. Far more use in a review than the raw name, which is
                # kept alongside it for filtering and for scripts.
                Setting      = $entry.description
                # effectiveValue is what is in force including anything inherited; value is only
                # what this organization set.
                Value        = $entry.policy.effectiveValue
                # ABSENCE MEANS SET. The provider omits isValueUndefined entirely for a policy
                # someone configured, and emits it as true for one still on its default - so
                # there is no third "unknown" state to preserve here, and treating the missing
                # property as unknown reported the three explicitly-set policies as blank.
                IsExplicit   = -not [bool] $entry.policy.isValueUndefined
                # True where the settings page shows the OPPOSITE of Value, because the policy is
                # named for what it forbids.
                IsInverted   = $inverted -contains $name
                # The 'Policy.' prefix is on every one of them, so it distinguishes nothing.
                Policy       = $name -replace '^Policy\.', ''
                Organization = $Organization
            }
        }
    }
}
