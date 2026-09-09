function Get-MsecAzureDevOpsUser {
    <#
    .SYNOPSIS
        Every user in an Azure DevOps organization and the groups they belong to - one row per
        membership, for an access review.

    .DESCRIPTION
        Answers "who can reach this organization, and through what". ADO permissions are almost
        always granted through group membership, so a user list without groups says nothing
        about what anyone can do.

        PAGINATED, WHICH THE OBVIOUS IMPLEMENTATION IS NOT. The ADO graph APIs return one page
        and put the cursor in the X-MS-ContinuationToken RESPONSE HEADER. Reading only
        $response.value returns the first page with no error and no sign that more existed - in
        an access review the users that go missing look exactly like users who do not exist.

        GROUP NAMES ARE RESOLVED FROM ONE FETCH, not one call per membership. The direct
        translation of "for each user, for each membership, get the group" is a call per
        membership - on a few hundred users that is thousands of round trips for a few dozen
        distinct groups.

        A USER IN NO GROUP STILL GETS A ROW, with Group '(none)'. Emitting nothing for them
        would drop the account from the review entirely, and an account nobody granted anything
        to is worth seeing rather than losing.

        ORIGIN SEPARATES ENTRA-BACKED ACCOUNTS FROM LOCAL ONES. An 'aad' user is governed by
        Conditional Access, MFA and the joiner/leaver process; a 'vsts' user is an account that
        exists only inside Azure DevOps and survives everything that happens in Entra.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/, e.g. 'contoso'.

    .PARAMETER SubjectType
        Restrict to particular subject SUBTYPES: 'aad' (Entra-backed), 'msa' (Microsoft
        account), 'svc' (service identity), 'imp' (imported). Omitted by default, which returns
        every kind - including service identities, so a service principal quietly holding
        Project Collection Administrators shows up without asking for it.

        These are the codes the API uses. Passing anything else - 'user', 'group' - is not
        rejected: it matches no subtype and returns an EMPTY LIST, which reads as an
        organization with nobody in it.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecAzureDevOpsUser -Organization 'contoso' | Format-Table DisplayName, PrincipalName, Group

    .EXAMPLE
        # The membership that matters most.
        Get-MsecAzureDevOpsUser -Organization 'contoso' |
            Where-Object Group -match 'Project Collection Administrators'

    .EXAMPLE
        # Accounts that exist only in Azure DevOps - no Conditional Access, no leaver process.
        Get-MsecAzureDevOpsUser -Organization 'contoso' | Where-Object Origin -ne 'aad' |
            Select-Object DisplayName, PrincipalName -Unique

    .EXAMPLE
        # Service identities only.
        Get-MsecAzureDevOpsUser -Organization 'contoso' -SubjectType svc

    .OUTPUTS
        PSCustomObject per (user, group), PSTypeName 'MsecAzureDevOpsUser'.

    .NOTES
        Needs Connect-Msec, and the msec app's service principal must be a member of the ADO
        organization (Organization Settings > Users > Add) with at least Reader. That is granted
        INSIDE Azure DevOps, not through Entra API permissions, so New-MsecApp cannot do it.

        One call per user is unavoidable - memberships are only addressable per subject - so
        this is O(users) round trips and takes a while on a large organization.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        # ValidateSet, because a wrong value here does not fail - it silently filters everything
        # out. 'user' and 'group' look like the obvious values and are not.
        [ValidateSet('aad', 'msa', 'svc', 'imp')]
        [string[]] $SubjectType
    )

    Assert-MsecSession

    # Groups first, once, as a lookup. See the note in the help about why this is not done per
    # membership.
    $groups = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization -Path '_apis/graph/groups' -All)
    $groupByDescriptor = @{}
    foreach ($group in $groups) {
        if ($group.descriptor) { $groupByDescriptor[[string] $group.descriptor] = $group }
    }
    Write-Verbose "Resolved $($groupByDescriptor.Count) group(s) in '$Organization'."

    # NO subjectTypes FILTER BY DEFAULT. The parameter takes subtype codes - aad, msa, svc, imp -
    # not subject kinds, and /graph/users already returns only users. Sending 'user' matches no
    # subtype at all and comes back empty, which is indistinguishable from an organization the
    # app cannot read.
    $path = '_apis/graph/users'
    if ($SubjectType) { $path += "?subjectTypes=$($SubjectType -join ',')" }
    $subjects = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization -Path $path -All)

    if (-not $subjects.Count) {
        Write-Warning "No subjects returned for '$Organization'. That is not the same as an empty organization - it usually means the app can authenticate but cannot read the identity graph. Treat this as unread, not as clean."
        return
    }

    foreach ($subject in $subjects) {
        $descriptor = [string] $subject.descriptor
        if (-not $descriptor) { continue }

        # direction=up walks from the subject to the containers it belongs to. Memberships are
        # only addressable per subject, so this call cannot be batched.
        $memberships = @()
        $unreadable = $false
        try {
            # $($descriptor), NOT $descriptor. '?' is a legal character in a PowerShell variable
            # name, so "$descriptor?direction=up" parses as the variable 'descriptor?direction'
            # - undefined, therefore empty - and the URL silently becomes
            # '_apis/graph/memberships/=up'. It fails as a 404 per user, which reads like a
            # missing identity rather than a mangled request.
            $memberships = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                                 -Path "_apis/graph/memberships/$($descriptor)?direction=up")
        }
        catch {
            # Named, not dropped: a user whose memberships could not be read is not a user with
            # no access, and silently omitting them understates the review.
            Write-Warning "Could not read group memberships for '$($subject.principalName)': $($_.Exception.Message)"
            $unreadable = $true
        }

        $rows = foreach ($membership in $memberships) {
            $container = [string] $membership.containerDescriptor
            $group = $groupByDescriptor[$container]

            [PSCustomObject]@{
                PSTypeName     = 'MsecAzureDevOpsUser'
                Organization   = $Organization
                DisplayName    = $subject.displayName
                PrincipalName  = $subject.principalName
                # 'aad' is Entra-backed; 'vsts' exists only inside Azure DevOps.
                Origin         = $subject.origin
                SubjectKind    = $subject.subjectKind
                # A container this module could not resolve is reported by its descriptor rather
                # than as a blank - the membership is real either way.
                Group          = if ($group) { $group.displayName } else { "(unresolved: $container)" }
                GroupPrincipal = if ($group) { $group.principalName } else { $null }
                Descriptor     = $descriptor
            }
        }
        $rows = @($rows)

        if ($rows.Count) {
            $rows
        }
        else {
            [PSCustomObject]@{
                PSTypeName     = 'MsecAzureDevOpsUser'
                Organization   = $Organization
                DisplayName    = $subject.displayName
                PrincipalName  = $subject.principalName
                Origin         = $subject.origin
                SubjectKind    = $subject.subjectKind
                # '(none)' and '(unreadable)' are different answers and must not collapse: one
                # is an account with no group, the other is an account we failed to ask about.
                Group          = if ($unreadable) { '(unreadable)' } else { '(none)' }
                GroupPrincipal = $null
                Descriptor     = $descriptor
            }
        }
    }
}
