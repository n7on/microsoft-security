function Get-MsecEntraGroupMember {
    <#
    .SYNOPSIS
        Lists the members of one or more Entra groups as flat rows - one per (group, member),
        so several groups can be asked for at once and the answer stays a table.

    .DESCRIPTION
        Takes group names, resolves each to the groups that match, and emits one row per
        member. The group name is on every row, which is what lets the output of several
        groups be sorted, grouped and exported as a single table rather than needing one call
        per group.

        DISPLAY NAMES ARE NOT UNIQUE IN ENTRA. Two groups can genuinely share one, so a name
        that matches several returns ALL of them rather than picking one, and GroupId is on
        every row to tell them apart. A name that matches nothing is named in a warning rather
        than passing silently - an empty result from a typo looks exactly like an empty group.

        MEMBERS ARE NOT ONLY USERS. A group can hold service principals, devices, nested
        groups and contacts, and MemberType says which. Filtering to users here would quietly
        drop the service principal somebody added to an access group, which is the member most
        worth noticing. Filter in PowerShell when users are all you want.

        PIM-ELIGIBLE MEMBERS ARE INCLUDED, marked MembershipType 'Eligible'. Where a group is
        governed by PIM for Groups, people are ELIGIBLE members rather than actual ones: they
        activate the membership and only then hold whatever the group grants. They appear on
        no /members endpoint at all, so a group whose whole membership is eligible reads as
        EMPTY - the group looks unused while a queue of people is one activation away. Anything
        that lists group membership and omits them is wrong in the most dangerous direction.

        AN EMPTY GROUP EMITS A ROW, with MemberType 'None'. "The group exists and has nobody in
        it" and "the group was not found" are different answers and must not both be silence.
        Groups whose membership could not be read at all also emit that row, with a warning -
        never an empty group that looks clean.

        By default the DIRECT members are listed, which is what the portal shows: a nested
        group appears as one row of MemberType 'group'.

        -Recurse EXPANDS NESTED GROUPS INSTEAD OF LISTING THEM. The people inside a nested
        group come back as members in their own right, and the nested group itself does not
        appear at all - the question being asked is "who is in here", and a group is not a who.
        Nesting can be several levels deep and is followed all the way down.

        A person reachable through two different nested groups is ONE row, not two. Active and
        Eligible are not collapsed into each other though: someone with standing membership who
        is ALSO eligible for it is a real state, and one worth seeing rather than rounding away.

    .PARAMETER Name
        Group display names. Wildcards are supported ('sg-prod-*'), in which case every group
        matching is returned. Without a wildcard the match is exact.

    .PARAMETER Id
        Group object ids, for when a display name is ambiguous or you already have the id.
        Combines with -Name.

    .PARAMETER Recurse
        Expand nested groups: a member of a member group is returned as a member, and the
        nested group itself is not listed. Without it, a nested group is one row of MemberType
        'group' and its own members are not expanded.

        PIM-eligible membership is read for every nested group as well, not only the ones you
        named - otherwise a nested group governed by PIM would contribute nobody and the
        recursion would quietly be less complete than the single-group case.

        Aliased to -Transitive, which is the Graph word for the same idea.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecEntraGroupMember -Name 'sg-admins', 'sg-devops'

    .EXAMPLE
        # Several groups as one table, grouped for reading.
        Get-MsecEntraGroupMember -Name 'sg-prod-*' |
            Sort-Object GroupName, MemberName |
            Format-Table GroupName, MemberName, MemberUserPrincipalName, MemberType, MembershipType

    .EXAMPLE
        # The members no MFA or Conditional Access policy covers.
        Get-MsecEntraGroupMember -Name 'sg-*' |
            Where-Object { $_.MemberType -eq 'servicePrincipal' -or $_.UserType -eq 'Guest' }

    .EXAMPLE
        # Standing access versus PIM-eligible, per group.
        Get-MsecEntraGroupMember -Name 'sg-admins' -Recurse |
            Group-Object GroupName, MembershipType | Select-Object Name, Count

    .EXAMPLE
        # Everyone who is effectively in the group, however deeply nested - and no group rows.
        Get-MsecEntraGroupMember -Name 'sg-admins' -Recurse |
            Sort-Object MemberName |
            Format-Table MemberName, MemberUserPrincipalName, MemberType, MembershipType

    .EXAMPLE
        # Groups that are empty - which a naive listing cannot tell from a mistyped name.
        Get-MsecEntraGroupMember -Name 'sg-*' | Where-Object MemberType -eq 'None'

    .OUTPUTS
        PSCustomObject per (group, member), PSTypeName 'MsecEntraGroupMember'.

    .NOTES
        Needs Connect-Msec and the 'Group.Read.All' application permission, plus
        'PrivilegedEligibilitySchedule.Read.AzureADGroup' for the eligible members. New-MsecApp
        grants both. Without the second, eligible members are missing and a warning says so
        rather than the group quietly reading as smaller than it is.

        Projection (Graph field -> output property):
          <group> displayName / id     -> GroupName / GroupId
          <group> securityEnabled, mailEnabled, isAssignableToRole
                                       -> GroupType / IsRoleAssignable
          <member> @odata.type         -> MemberType ('user' / 'group' / 'servicePrincipal' / ...)
          <member> displayName / id    -> MemberName / MemberId
          <member> userPrincipalName   -> MemberUserPrincipalName
          <member> accountEnabled      -> AccountEnabled
          <member> userType            -> UserType ('Member' / 'Guest')
          <member> onPremisesSyncEnabled -> OnPremisesSyncEnabled
          <which endpoint answered>    -> MembershipType ('Active' / 'Eligible')
          <entire member object>       -> Raw
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position = 0)]
        [string[]] $Name,

        [Parameter()]
        [string[]] $Id,

        [Parameter()]
        [Alias('Transitive')]
        [switch] $Recurse
    )

    Assert-MsecSession

    if (-not $Name -and -not $Id) {
        throw 'Give at least one -Name or -Id. Listing every group in the tenant is not the intent here; use -Name ''*'' if it really is.'
    }

    $groupSelect = 'id,displayName,description,securityEnabled,mailEnabled,mailNickname,isAssignableToRole,createdDateTime'

    # ---- resolve the groups -----------------------------------------------------------------

    $groups = [System.Collections.Generic.List[object]]::new()
    $seenGroupIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $addGroup = {
        param($Group)
        if ($Group -and $Group.id -and $seenGroupIds.Add([string] $Group.id)) { $groups.Add($Group) }
    }

    foreach ($groupId in @($Id | Where-Object { $_ })) {
        try {
            & $addGroup (Invoke-MsecGraphRequest -Path "/v1.0/groups/$groupId`?`$select=$groupSelect")
        }
        catch {
            Write-Warning "No group with id '$groupId' could be read: $(Get-MsecGraphErrorMessage $_)"
        }
    }

    # A wildcard cannot be pushed into $filter, so those are matched client-side against the
    # group list. Exact names go through $filter, which is one small request instead.
    $wildcards = @($Name | Where-Object { $_ -and [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($_) })
    $exact     = @($Name | Where-Object { $_ -and -not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($_) })

    foreach ($groupName in $exact) {
        $filter = [uri]::EscapeDataString("displayName eq '$($groupName -replace "'", "''")'")
        $matched = @()
        try {
            $matched = @(Invoke-MsecGraphRequest -All -Path "/v1.0/groups?`$select=$groupSelect&`$filter=$filter")
        }
        catch {
            Write-Warning "Could not look up group '$groupName': $(Get-MsecGraphErrorMessage $_)"
            continue
        }

        if (-not $matched.Count) {
            # Named explicitly: an empty result from a typo is indistinguishable from an empty
            # group unless this says which happened.
            Write-Warning "No group is named '$groupName'."
            continue
        }
        if ($matched.Count -gt 1) {
            Write-Warning "$($matched.Count) groups are named '$groupName'. All of them are included - GroupId tells them apart."
        }
        foreach ($g in $matched) { & $addGroup $g }
    }

    if ($wildcards.Count) {
        $all = @()
        try {
            $all = @(Invoke-MsecGraphRequest -All -Path "/v1.0/groups?`$select=$groupSelect")
        }
        catch {
            Write-Warning "Could not list groups to match the wildcard pattern(s): $(Get-MsecGraphErrorMessage $_)"
        }

        foreach ($pattern in $wildcards) {
            $matched = @($all | Where-Object { $_.displayName -like $pattern })
            if (-not $matched.Count) {
                Write-Warning "No group name matches '$pattern'."
                continue
            }
            foreach ($g in $matched) { & $addGroup $g }
        }
    }

    if (-not $groups.Count) { return }

    $endpoint = if ($Recurse) { 'transitiveMembers' } else { 'members' }

    foreach ($group in $groups) {
        $groupName = [string] $group.displayName
        $groupId   = [string] $group.id

        $groupType = if ($group.isAssignableToRole) { 'RoleAssignable' }
                     elseif ($group.securityEnabled -and $group.mailEnabled) { 'MailEnabledSecurity' }
                     elseif ($group.securityEnabled) { 'Security' }
                     elseif ($group.mailEnabled) { 'Distribution' }
                     else { 'Unknown' }

        $common = [ordered]@{
            GroupName        = $groupName
            GroupId          = $groupId
            GroupType        = $groupType
            IsRoleAssignable = [bool] $group.isAssignableToRole
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        $readFailed = $false

        # Groups reached through nesting. Collected even though they are not emitted as
        # members, because their PIM-eligible members have to be asked for separately - see
        # below. /transitiveMembers returns them alongside the leaf principals, so this costs
        # nothing extra.
        $nestedGroupIds = [System.Collections.Generic.List[string]]::new()

        try {
            foreach ($m in @(Invoke-MsecGraphRequest -All -Path "/v1.0/groups/$groupId/$endpoint")) {
                $type = [string] $m.'@odata.type'

                # RECURSING MEANS THE NESTED GROUP IS EXPANDED, NOT LISTED. /transitiveMembers
                # returns the nested groups themselves as well as the people inside them, so
                # without this a recursive listing shows both - the group as a "member", and
                # again as everyone in it. The question -Recurse answers is "who is in here",
                # and a group is not a who.
                if ($Recurse -and $type -eq '#microsoft.graph.group') {
                    if ($m.id) { $nestedGroupIds.Add([string] $m.id) }
                    continue
                }

                $rows.Add((New-MsecGroupMemberRow -Common $common -Member $m -MembershipType 'Active'))
            }
        }
        catch {
            $readFailed = $true
            Write-Warning "Could not read the members of group '$groupName' ($groupId), so it is reported as a single unresolved row rather than as its members. The msec app needs 'Group.Read.All'. Graph said: $(Get-MsecGraphErrorMessage $_)"
        }

        # PIM for Groups. See the note in .DESCRIPTION: these people are on no /members
        # endpoint, so without this a PIM-governed group reads as empty.
        #
        # ASKED OF EVERY NESTED GROUP TOO when recursing. Expanding nesting through
        # /transitiveMembers only flattens ACTUAL membership, so a nested group governed by PIM
        # contributes nobody - and the recursion would silently be less complete than the
        # single-group case it replaced.
        #
        # accessId 'member' only. An OWNER does not hold what the group grants; they can add
        # themselves and then hold it, which is a real escalation path but a different finding,
        # and counting owners as members would overstate the membership.
        $eligibilityTargets = @($groupId) + @($nestedGroupIds)
        foreach ($targetId in $eligibilityTargets) {
            try {
                $eligibleFilter = [uri]::EscapeDataString("groupId eq '$targetId'")
                $eligible = @(Invoke-MsecGraphRequest -All -Path (
                    "/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?`$expand=principal&`$filter=$eligibleFilter"))

                foreach ($e in @($eligible | Where-Object { $_.accessId -eq 'member' })) {
                    if ($e.principal) {
                        $rows.Add((New-MsecGroupMemberRow -Common $common -Member $e.principal -MembershipType 'Eligible'))
                    }
                }
            }
            catch {
                # Not fatal: most groups are not PIM-governed, and the permission is separate.
                Write-Verbose "Could not read PIM-eligible members of group $targetId - any eligible member is NOT in this output: $(Get-MsecGraphErrorMessage $_)"
            }
        }

        # ONE ROW PER PERSON PER MEMBERSHIP KIND. Recursion can reach the same person through
        # two different nested groups, and the eligibility pass can reach them through several
        # too - all describing the same fact. Active and Eligible are NOT collapsed together:
        # someone with standing membership who is also eligible for it is a real state, and one
        # worth seeing rather than rounding away.
        $rows = @($rows | Group-Object -Property MemberId, MembershipType | ForEach-Object { $_.Group[0] })

        if ($rows.Count) {
            $rows
            continue
        }

        if ($rows.Count) {
            $rows
            continue
        }

        # No members, or none readable. Either way a row, so the group is visibly accounted
        # for - an empty group and a mistyped name must not both be silence.
        [PSCustomObject]($common + [ordered]@{
            PSTypeName              = 'MsecEntraGroupMember'
            MemberName              = $null
            MemberUserPrincipalName = $null
            MemberType              = if ($readFailed) { 'Unreadable' } else { 'None' }
            MemberId                = $null
            MembershipType          = $null
            AccountEnabled          = $null
            UserType                = $null
            OnPremisesSyncEnabled   = $null
            Raw                     = $group
        })
    }
}
