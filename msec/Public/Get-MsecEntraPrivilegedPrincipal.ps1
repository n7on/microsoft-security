function Get-MsecEntraPrivilegedPrincipal {
    <#
    .SYNOPSIS
        Every principal holding an Entra directory role, separating what the role is
        ASSIGNED TO from who EFFECTIVELY holds it, with the activation state of each.

    .DESCRIPTION
        Answers "who and what can administer this tenant".

        TWO PRINCIPALS PER ROW, which is the whole shape of this output. A directory
        role can be assigned to a user, a service principal, or a role-assignable
        group - so the thing assigned is not always the thing that ends up with the
        privilege, and a row that conflates them cannot describe a group assignment
        honestly:

          PrincipalName / PrincipalType / PrincipalId
              What the role is assigned to. This is Graph's own principalId on the
              assignment, so it is a GROUP whenever a group holds the role, and it is
              the object you would act on to revoke the assignment itself.

          EffectiveName / EffectiveType / EffectiveId
              Who ends up holding the role. The same object as the assignee for a
              direct assignment; a member of the group for a group assignment; $null
              when an assigned group's membership could not be determined.

          MembershipType
              How the effective principal sits inside the assignee: 'Active' or
              'Eligible', and $null when the two are the same object.

        So a group of five yields five rows with one assignee and five holders. Count
        holders (EffectiveId) for "how many administrators", count assignments (Raw.id)
        for "how many grants", and neither question contaminates the other.

        It reads the unified role-management endpoints rather than /directoryRoles,
        which closes three blind spots in Get-MsecEntraDirectoryRoleMember:

          1. PIM-eligible assignments. /directoryRoles returns *activated* roles and
             their *active* members, so in a tenant using PIM most administrators are
             absent entirely - the report reads "two Global Admins" for a tenant with
             fourteen.

          2. Group membership. /directoryRoles/{id}/members returns the role-assignable
             *group* object; the principals inside it never appear. Here a group is
             expanded transitively, so adding someone to a group cannot hide them from
             a review. Both ACTUAL and PIM-ELIGIBLE members are read - see PIM FOR
             GROUPS below, because the second kind is invisible to every /members
             endpoint.

          3. Scope. A User Administrator confined to one administrative unit is not the
             same risk as a tenant-wide one.

        A principal that is both actively assigned and separately eligible for the same
        role produces two rows. Those are two distinct facts, and collapsing them would
        hide a standing assignment behind a well-governed one.

        Because expansion is transitive, the assignee is the group the ROLE is on, not
        the innermost nested group a member happens to sit in - the former is what you
        would act on, the latter is an implementation detail of the directory.

        PIM FOR GROUPS. A group governed by PIM has ELIGIBLE members, who activate the
        membership before they hold anything the group carries. /transitiveMembers
        returns only ACTUAL members, so such a group reads as empty there - the tenant
        appears to have nobody in the role while a queue of administrators sits one
        activation away from it. Eligible memberships are therefore read separately from
        /identityGovernance/privilegedAccess/group/eligibilityScheduleInstances and
        emitted with MembershipType = 'Eligible'.

        TWO LINKS, TWO COLUMNS, ONE ANSWER. Using a role held through a group requires
        both the assignment (AssignmentType) and the membership (MembershipType) to be
        active. Each column stays faithful to its own link rather than being folded
        together, because "the assignment is active" and "this person can use it right
        now" are different facts and a report needs both. IsActiveNow is the conjunction
        - true only when nothing needs activating - and is $null where no holder is
        known.

        Group OWNERS are excluded. An owner of a role-assignable group does not hold the
        role - they can add themselves as a member and then hold it. That is a genuine
        escalation path and worth its own review, but counting owners as role holders
        would overstate the privileged population.

        AZURE RBAC IS NOT COVERED. A directory role can only be assigned to a user,
        group, or service principal, so an assignee here is never a management group or
        subscription. Azure RBAC - Owner and User Access Administrator over the
        management-group hierarchy - is a separate plane and a separate route to
        effective control; see Search-MsecAzureResourceGraph.

        PERMISSIONS. Reading role assignments and reading the identities they point at
        are separate grants, and having only the first is the failure mode that looks
        like success: 'RoleManagement.Read.Directory' returns every assignment, but
        Graph then hands back each principal as an id-and-type shell with every
        property null, so the report is complete and entirely anonymous. Naming the
        principals needs 'User.Read.All', 'Group.Read.All' and 'Application.Read.All';
        Group.Read.All also covers expanding groups to their members. PIM-eligible group
        membership needs 'PrivilegedEligibilitySchedule.Read.AzureADGroup'. Anything
        missing produces a warning - never a silent blank.

        DEGRADED, NOT FAILED, on a tenant without Entra ID P2: eligibility cannot exist
        without premium licensing, so /roleEligibilityScheduleInstances is rejected.
        That is warned about and the active assignments are still returned - and in such
        a tenant those ARE the whole privileged population. Get-MsecEntraLicense
        confirms which case you are in.

    .PARAMETER AssignmentType
        Which assignments to read: 'All' (default), 'Active' (standing assignments
        only - no premium licence needed), or 'Eligible' (PIM eligibility only,
        requires Entra ID P2).

    .PARAMETER HighlyPrivilegedOnly
        Return only roles that can grant further access, reset credentials, or read
        broadly. The set is defined in Get-MsecPrivilegedRoleTemplate.

    .PARAMETER NoGroupExpansion
        Return assignments as Entra records them: one row per assignment, with the
        assignee named and the effective principal left $null. Useful for "what is
        assigned to what", and the honest choice when the app cannot read group
        membership - but it is NOT the effective privileged population and must not be
        counted as one.

    .EXAMPLE
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly

    .EXAMPLE
        # People only, then applications only. EffectiveType is the HOLDER's kind -
        # PrincipalType would say 'group' for anyone who inherited the role.
        Get-MsecEntraPrivilegedPrincipal | Where-Object EffectiveType -eq 'user'
        Get-MsecEntraPrivilegedPrincipal | Where-Object EffectiveType -eq 'servicePrincipal'

    .EXAMPLE
        # How the privileged population splits between people and applications.
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly |
            Group-Object EffectiveType -NoElement

    .EXAMPLE
        # Privilege that arrives through a group - the path most reviews miss. The
        # assignee differs from the holder exactly when the role was inherited.
        Get-MsecEntraPrivilegedPrincipal | Where-Object PrincipalType -eq 'group' |
            Format-Table EffectiveName, RoleName, PrincipalName, MembershipType

    .EXAMPLE
        # PIM for Groups: people who hold nothing today but can activate into a group
        # that carries a role. Invisible to every /members endpoint.
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly |
            Where-Object MembershipType -eq 'Eligible' |
            Format-Table EffectiveName, RoleName, PrincipalName

    .EXAMPLE
        # Privilege usable right now - nothing left to activate on either link.
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly |
            Where-Object IsActiveNow

    .EXAMPLE
        # Standing tenant-wide privilege: the assignments PIM was meant to remove.
        Get-MsecEntraPrivilegedPrincipal -AssignmentType Active -HighlyPrivilegedOnly |
            Where-Object IsTenantScoped

    .EXAMPLE
        # Distinct humans who can administer the tenant. Count holders, not rows: one
        # person inheriting a role through two groups is one administrator.
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly |
            Where-Object { $_.EffectiveType -eq 'user' -and $_.IsResolved } |
            Sort-Object EffectiveId -Unique

    .EXAMPLE
        # External identities holding privileged roles, and privileged accounts synced
        # from on-premises AD. Both should be short, deliberate lists.
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly | Where-Object UserType -eq 'Guest'
        Get-MsecEntraPrivilegedPrincipal -HighlyPrivilegedOnly | Where-Object IsDirectorySynced

    .OUTPUTS
        PSCustomObject per (role, principal, assignment type). See .NOTES.

    .NOTES
        Each row is a [PSCustomObject] with PSTypeName 'MsecEntraPrivilegedPrincipal',
        whose DefaultDisplayPropertySet (EffectiveName, EffectiveType, RoleName,
        AssignmentType, PrincipalName) is registered in msec.psm1. The holder leads,
        because that is who a review is about; the assignee trails, so an inherited role
        shows the group it came from. On a direct assignment the two hold the same value,
        which is the truth rather than a redundancy: assigned to X, held by X.

        EffectiveName and PrincipalName are identifiers resolved by type -
        userPrincipalName for a user, displayName for a service principal or group, the
        id if Graph would name neither. The matching *Type column says which you are
        reading, so neither is ever ambiguous.

        The detail columns - DisplayName, UserPrincipalName, AccountEnabled, UserType,
        IsDirectorySynced - all describe the EFFECTIVE principal, because that is the
        identity that would be remediated. UserPrincipalName is strictly a UPN and $null
        for every non-user, so it stays exact for filtering.

        Projection:
          roleDefinition.displayName    -> RoleName
          roleDefinition.templateId     -> RoleTemplateId
          (derived from the template id)-> IsHighlyPrivileged
          (which endpoint it came from) -> AssignmentType     'Active' / 'Eligible'
          assignment.principal          -> PrincipalName, PrincipalType, PrincipalId
                                           (what the role is assigned to - a group when
                                           a group holds it)
          group member, or the assignee -> EffectiveName, EffectiveType, EffectiveId
                                           (who holds it; $null if undeterminable)
          (how the holder sits in it)   -> MembershipType     'Active'/'Eligible'; $null when
                                           holder and assignee are the same object
          (nothing left to activate?)   -> IsActiveNow        ($null if no known holder)
          effective.displayName         -> DisplayName
          effective.userPrincipalName   -> UserPrincipalName  ($null for non-users)
          effective.accountEnabled      -> AccountEnabled
          effective.userType            -> UserType           'Member'/'Guest', users only
          effective.onPremisesSyncEnabled -> IsDirectorySynced (users only; null = cloud-only)
          (is the holder known?)        -> IsResolved
          assignment.directoryScopeId   -> Scope, DirectoryScopeId, IsTenantScoped
          instance.endDateTime          -> EndDateTime        ($null = never expires)
          <the assignment object>       -> Raw

        There is no separate direct-or-inherited column: a row is direct exactly when
        PrincipalId and EffectiveId are equal and MembershipType is $null. A third field
        asserting the same thing could only ever drift out of agreement with them.

        A group assignment whose membership cannot be determined - no active or eligible
        members, unreadable, or -NoGroupExpansion - still yields its row, with the
        assignee named and the effective principal $null. Deleting it would remove a live
        privilege path from the report: whoever can write that group's membership can
        take the role tomorrow without touching a role assignment. EVERY ASSIGNMENT
        YIELDS AT LEAST ONE ROW.

        IsResolved answers one question: do we know who ends up with this privilege? It
        is $false for the undeterminable group above, and for a holder Graph returned as
        id and type only because the app may read role assignments but not directory
        objects. Filter it out for a headcount; read it when auditing dormant privilege
        paths; never present those rows as a completed review.

        A BLANK EffectiveName is therefore never a defect - it is an assignment whose
        holder is unknown, and the count of them is reported in a warning at the end of
        every run so an empty cell is not left to be interpreted. The usual cause is a
        PIM-governed group without 'PrivilegedEligibilitySchedule.Read.AzureADGroup'
        granted, which makes a group full of eligible administrators look empty.

        EndDateTime is $null for every active assignment (the roleAssignments endpoint
        carries no schedule - those are permanent by definition) and for permanent
        eligibility. A non-null value only ever means time-bound eligibility.

        Scope is 'Tenant' for directoryScopeId '/', 'AdministrativeUnit:<id>' for an
        AU-scoped assignment, and the raw scope id otherwise. AU display names are not
        resolved: that needs AdministrativeUnit.Read.All, a wider grant than this
        inventory justifies.

        A role definition referenced by an assignment but absent from the
        roleDefinitions collection - deprecated and hidden built-ins are the usual
        culprits - is fetched individually, once per id. Only if that also fails does
        RoleName fall back to '<unknown role {id}>'.

        CUSTOM ROLES are never flagged IsHighlyPrivileged, because the flag is a lookup
        of known built-in template ids. A custom role holding
        microsoft.directory/roleAssignments permissions is genuinely privileged and will
        appear with IsHighlyPrivileged = $false. Review custom roles by hand; there is
        no reliable way to score their permission sets.

        Graph has historically required a $filter on the directory provider's
        assignment collections. The unfiltered list is attempted first and, only if
        Graph rejects it, the query fans out to one call per role definition - correct
        either way, one round trip in the common case.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('All', 'Active', 'Eligible')]
        [string] $AssignmentType = 'All',

        [Parameter()]
        [switch] $HighlyPrivilegedOnly,

        [Parameter()]
        [switch] $NoGroupExpansion
    )

    Assert-MsecSession

    $highlyPrivileged = Get-MsecPrivilegedRoleTemplate

    # ---- Role definitions: roleDefinitionId -> definition -------------------------
    # Also the permission probe. Failing here means nothing downstream can work, so
    # this is the one call allowed to be fatal.
    try {
        $definitions = @(Invoke-MsecGraphRequest -All `
            -Path '/v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName,templateId,isBuiltIn')
    }
    catch {
        $detail = Get-MsecGraphErrorMessage $_
        if ($_.Exception.Message -match '403|Forbidden' -or $detail -match 'Forbidden|Authorization_RequestDenied') {
            throw "Forbidden when calling /roleManagement/directory/roleDefinitions. The msec app needs the 'RoleManagement.Read.Directory' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $detail"
        }
        throw
    }

    $definitionById = @{}
    foreach ($d in $definitions) { $definitionById[[string]$d.id] = $d }

    # ---- Assignment collections ---------------------------------------------------
    # Nested so it closes over $definitions; the retry-with-filter shape is identical
    # for the active and the eligible endpoint and shouldn't be written twice.
    function Get-MsecRoleAssignmentCollection {
        param([Parameter(Mandatory)][string] $Segment)

        $collection = "/v1.0/roleManagement/directory/$Segment"

        try {
            return @(Invoke-MsecGraphRequest -Path ($collection + '?$expand=principal') -All)
        }
        catch {
            $detail = Get-MsecGraphErrorMessage $_
            # Only a "you must filter this" rejection is retryable. A 403 or a
            # licensing error must propagate to the caller, which knows how to
            # describe it.
            if ($detail -notmatch 'filter|not supported|Unsupported|BadRequest') { throw }
            Write-Verbose "Unfiltered $Segment list rejected ($detail); falling back to one call per role definition."
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($def in $definitions) {
            $filter = [uri]::EscapeDataString("roleDefinitionId eq '$($def.id)'")
            try {
                $page = @(Invoke-MsecGraphRequest -All `
                    -Path ($collection + '?$expand=principal&$filter=' + $filter))
                if ($page.Count) { $rows.AddRange([object[]]$page) }
            }
            catch {
                Write-Warning "Could not read $Segment for role '$($def.displayName)': $(Get-MsecGraphErrorMessage $_)"
            }
        }
        return $rows.ToArray()
    }

    $assignments = [System.Collections.Generic.List[object]]::new()

    if ($AssignmentType -in @('All', 'Active')) {
        foreach ($a in (Get-MsecRoleAssignmentCollection -Segment 'roleAssignments')) {
            $assignments.Add([pscustomobject]@{ Kind = 'Active'; Item = $a })
        }
    }

    if ($AssignmentType -in @('All', 'Eligible')) {
        try {
            foreach ($e in (Get-MsecRoleAssignmentCollection -Segment 'roleEligibilityScheduleInstances')) {
                $assignments.Add([pscustomobject]@{ Kind = 'Eligible'; Item = $e })
            }
        }
        catch {
            # Two very different causes, needing opposite responses: buy a licence
            # (or accept that eligibility cannot exist) versus grant a permission.
            # Guessing wrong sends people through a consent cycle that cannot help.
            $detail = Get-MsecGraphErrorMessage $_
            if ($detail -match 'premium|licen[cs]e|AadPremium|P2') {
                Write-Warning "PIM-eligible assignments are unavailable: this tenant has no Entra ID P2 licence, so role eligibility cannot exist here and the active assignments returned ARE the complete privileged population. Graph said: $detail"
            }
            else {
                Write-Warning "Could not read PIM-eligible assignments (/roleEligibilityScheduleInstances) - returning ACTIVE assignments only, so this list is INCOMPLETE if the tenant uses PIM. The msec app needs 'RoleManagement.Read.Directory'. Graph said: $detail"
            }
        }
    }

    # ---- Group expansion ----------------------------------------------------------
    function Get-MsecGroupPrincipalMember {
        param([Parameter(Mandatory)][string] $GroupId, [string] $GroupName)

        # Transitive, so a group nested inside the role-assignable group still yields
        # its principals - which is exactly how privileged access hides.
        #
        # Asked ONE TYPE AT A TIME, via an OData cast, for two reasons. First, the
        # plain collection returns only Graph's default property subset: no userType,
        # no accountEnabled, so a guest administrator inherited through a group would
        # read as an ordinary member of unknown status. A $select fixes that, but Graph
        # rejects a $select naming a property that does not exist on every type in a
        # heterogeneous collection - hence per-type casts. Second, the cast drops the
        # nested groups for free: they are structure rather than principals that can
        # sign in, and their own members are already flattened into this list, so
        # emitting them would double-count.
        $casts = @(
            @{ Type = 'user'
               Path = '/microsoft.graph.user?$select=id,displayName,userPrincipalName,accountEnabled,userType,onPremisesSyncEnabled' }
            @{ Type = 'servicePrincipal'
               Path = '/microsoft.graph.servicePrincipal?$select=id,displayName,accountEnabled,servicePrincipalType' }
        )

        $members = [System.Collections.Generic.List[object]]::new()
        $failures = 0

        foreach ($cast in $casts) {
            try {
                foreach ($m in @(Invoke-MsecGraphRequest -All -Path "/v1.0/groups/$GroupId/transitiveMembers$($cast.Path)")) {
                    # A cast response may omit @odata.type, since the cast implies it.
                    # PrincipalType must not go null just because we asked precisely.
                    if (-not $m.'@odata.type') {
                        $m | Add-Member -NotePropertyName '@odata.type' -NotePropertyValue "#microsoft.graph.$($cast.Type)" -Force
                    }
                    $members.Add([pscustomobject]@{ Principal = $m; Membership = 'Active' })
                }
            }
            catch {
                $failures++
                Write-Warning "Could not read the $($cast.Type) members of group '$GroupName' ($GroupId) - any privileged $($cast.Type) inside it is NOT in this output. Graph said: $(Get-MsecGraphErrorMessage $_)"
            }
        }

        # Every cast failing is indistinguishable from an empty group here, and the two
        # must not be conflated: the caller emits an unresolved row either way, but only
        # this warning says the group might be full of administrators we cannot see.
        if ($failures -eq $casts.Count) {
            Write-Warning "Group '$GroupName' ($GroupId) could not be expanded at all, so it is reported as a single row with IsResolved = `$false rather than as its members. The msec app needs 'Group.Read.All'."
        }

        # PIM FOR GROUPS. /transitiveMembers returns only ACTUAL members. Where a group
        # is governed by PIM, people are ELIGIBLE members instead - they activate the
        # membership, and only then hold the role the group carries. Those people are on
        # a different endpoint entirely, and without this call a group whose whole
        # membership is eligible reads as empty: the tenant looks like it has nobody in
        # the role while a queue of administrators is one activation away. That is the
        # worst possible way to be wrong about privileged access, so it is read here
        # rather than left to the caller to notice.
        #
        # accessId 'owner' is deliberately excluded. A group owner does not hold the
        # role; they can add themselves as a member and then hold it. That is a real
        # escalation path but a different finding, and counting owners as role holders
        # would overstate the population.
        try {
            $eligibleFilter = [uri]::EscapeDataString("groupId eq '$GroupId'")
            $eligible = @(Invoke-MsecGraphRequest -All -Path (
                '/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$expand=principal&$filter=' + $eligibleFilter))

            foreach ($e in ($eligible | Where-Object { $_.accessId -eq 'member' })) {
                $p = $e.principal
                if (-not $p) {
                    # Nothing but an id came back; keep the row rather than lose the
                    # person, and let the unnamed-principal accounting flag it.
                    $p = [pscustomobject]@{ id = $e.principalId }
                }
                $members.Add([pscustomobject]@{ Principal = $p; Membership = 'Eligible' })
            }
        }
        catch {
            $detail = Get-MsecGraphErrorMessage $_
            if ($detail -match 'premium|licen[cs]e|AadPremium|P2') {
                Write-Verbose "PIM for Groups is unavailable on this tenant (no Entra ID P2), so group '$GroupName' can have no eligible members: $detail"
            }
            else {
                Write-Warning "Could not read PIM-eligible members of group '$GroupName' ($GroupId) - anyone who is an ELIGIBLE rather than active member of it is NOT in this output, and a PIM-governed group can legitimately have no active members at all. The msec app needs 'PrivilegedEligibilitySchedule.Read.AzureADGroup'. Graph said: $detail"
            }
        }

        return $members.ToArray()
    }

    # ---- Projection ---------------------------------------------------------------
    # Mutated by the nested row builder, which cannot assign to an outer scalar.
    $stats = @{ UnreadablePrincipals = 0; UnknownHolders = 0 }

    # '@odata.type' arrives as '#microsoft.graph.user'; keep just the type.
    function Get-MsecPrincipalObjectType {
        param($Principal)
        if ($Principal -and $Principal.'@odata.type') {
            return ($Principal.'@odata.type' -replace '^#?microsoft\.graph\.', '')
        }
        return $null
    }

    # The identifier, resolved by type - a UPN for a user, a name for anything else,
    # which has none. The matching *Type column says which you are reading, so one
    # column can carry both without ambiguity.
    function Get-MsecPrincipalDisplayKey {
        param($Principal, [string] $FallbackId)
        if ($Principal.userPrincipalName) { return $Principal.userPrincipalName }
        if ($Principal.displayName)       { return $Principal.displayName }
        return $FallbackId
    }

    # Graph answers a read the caller isn't entitled to by returning the object's full
    # property SCHEMA with every value null - id and @odata.type only. Privilege held
    # by an identity this app cannot name is not something an access review may present
    # as a blank cell: an unnamed administrator has to read as an unknown.
    function Test-MsecPrincipalUnnamed {
        param($Principal)
        if (-not $Principal) { return $true }
        switch (Get-MsecPrincipalObjectType $Principal) {
            'user'  { return (-not $Principal.userPrincipalName) }
            default { return (-not $Principal.displayName) }
        }
    }

    function ConvertTo-MsecPrincipalRow {
        param(
            $Context,
            # What the role is assigned to - Graph's principalId. A group when a group
            # holds the role.
            $Assignee,
            # Who ends up holding it. The same object as $Assignee for a direct
            # assignment; a member for a group assignment; $null when the members of an
            # assigned group could not be determined.
            $Effective,
            [ValidateSet('Active', 'Eligible')] [string] $MembershipType
        )

        $assigneeType = Get-MsecPrincipalObjectType $Assignee
        $assigneeId   = if ($Assignee -and $Assignee.id) { $Assignee.id } else { $Context.PrincipalId }
        $assigneeName = Get-MsecPrincipalDisplayKey -Principal $Assignee -FallbackId $assigneeId

        $effectiveType = Get-MsecPrincipalObjectType $Effective
        $effectiveId   = if ($Effective) { $Effective.id } else { $null }
        $effectiveName = if ($Effective) { Get-MsecPrincipalDisplayKey -Principal $Effective -FallbackId $effectiveId } else { $null }

        # Resolved means we know who ends up with the privilege. An assigned group whose
        # membership could not be determined fails this, and so does a principal Graph
        # returned as an id-only shell - two different causes, one honest verdict.
        $unnamed    = ($null -ne $Effective) -and (Test-MsecPrincipalUnnamed $Effective)
        $isResolved = ($null -ne $Effective) -and -not $unnamed
        if ($unnamed) { $stats.UnreadablePrincipals++ }

        # Counted separately from an unnamed principal, because the fix is different:
        # this is an assigned group we could not see inside, not an identity we could
        # not name. Both leave a blank cell in the table, and a blank cell reads as a
        # broken report rather than as 'unknown' - so the count is reported at the end.
        if ($null -eq $Effective) { $stats.UnknownHolders++ }

        # The detail columns describe the EFFECTIVE principal - the identity that holds
        # the role and would be remediated - not the group it came through.
        $userType = if ($effectiveType -eq 'user' -and -not $unnamed) { $Effective.userType } else { $null }

        # Graph reports cloud-only objects as null here rather than false, so the two
        # cases have to be told apart deliberately. A synced privileged account means
        # on-premises Active Directory is a path to tenant admin, which is why
        # Microsoft's own guidance is that admin accounts be cloud-only.
        $isSynced = if ($effectiveType -ne 'user' -or $unnamed) { $null }
                    else { [bool]$Effective.onPremisesSyncEnabled }

        # Two links must both be active to use a role held through a group: the role ->
        # principal assignment, and the effective principal's membership of it.
        # AssignmentType and MembershipType each stay faithful to their own link; this
        # is the answer to "can this identity use the role right now", which neither
        # column can give alone. $null where nobody is known to hold it.
        $isActiveNow = if (-not $isResolved) { $null }
                       else { ($Context.AssignmentType -eq 'Active') -and ($MembershipType -ne 'Eligible') }

        [PSCustomObject]@{
            PSTypeName         = 'MsecEntraPrivilegedPrincipal'

            RoleName           = $Context.RoleName
            RoleTemplateId     = $Context.RoleTemplateId
            IsHighlyPrivileged = $Context.IsHighlyPrivileged

            # Who ends up with the privilege.
            EffectiveName      = $effectiveName
            EffectiveType      = $effectiveType
            EffectiveId        = $effectiveId

            # What the role is assigned to.
            PrincipalName      = $assigneeName
            PrincipalType      = $assigneeType
            PrincipalId        = $assigneeId

            AssignmentType     = $Context.AssignmentType
            MembershipType     = if ($MembershipType) { $MembershipType } else { $null }
            IsActiveNow        = $isActiveNow

            DisplayName        = $Effective.displayName
            UserPrincipalName  = $Effective.userPrincipalName
            AccountEnabled     = $Effective.accountEnabled
            UserType           = $userType
            IsDirectorySynced  = $isSynced

            Scope              = $Context.Scope
            DirectoryScopeId   = $Context.DirectoryScopeId
            IsTenantScoped     = $Context.IsTenantScoped
            EndDateTime        = $Context.EndDateTime

            IsResolved         = $isResolved

            Raw                = $Context.Raw
        }
    }

    # Several roles are routinely assigned to the same group; expand each group once.
    $groupCache = @{}

    # Ids already looked up individually, successfully or not, so a definition the
    # collection omits costs one call rather than one per assignment.
    $probedDefinitions = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($entry in $assignments) {
        $item = $entry.Item

        $definitionId = [string]$item.roleDefinitionId
        $definition = $definitionById[$definitionId]

        # The roleDefinitions collection does not always contain every definition an
        # assignment can reference - deprecated and hidden built-ins are the usual
        # culprits. Naming the role is the whole point of the row, so fetch the
        # definition directly rather than printing a GUID at the reviewer.
        if (-not $definition -and -not $probedDefinitions.Contains($definitionId)) {
            $probedDefinitions.Add($definitionId) | Out-Null
            try {
                $definition = Invoke-MsecGraphRequest -Path "/v1.0/roleManagement/directory/roleDefinitions/$definitionId"
                if ($definition) { $definitionById[$definitionId] = $definition }
            }
            catch {
                Write-Warning "Role definition '$definitionId' is referenced by an assignment but could not be read, so that role is reported by id only. Graph said: $(Get-MsecGraphErrorMessage $_)"
            }
        }

        # Built-in definitions carry templateId; fall back to the definition id, which
        # for built-ins is the same GUID, and for a custom role is at least stable.
        $templateId = if ($definition -and $definition.templateId) { [string]$definition.templateId }
                      elseif ($definition) { [string]$definition.id }
                      else { $definitionId }

        $isPriv = $highlyPrivileged.ContainsKey($templateId)
        if ($HighlyPrivilegedOnly -and -not $isPriv) { continue }

        $scopeId = [string]$item.directoryScopeId
        $scope = if (-not $scopeId -or $scopeId -eq '/') { 'Tenant' }
                 elseif ($scopeId -match '^/administrativeUnits/(?<id>.+)$') { "AdministrativeUnit:$($Matches['id'])" }
                 else { $scopeId }

        $context = @{
            RoleName           = if ($definition) { $definition.displayName } else { "<unknown role $definitionId>" }
            RoleTemplateId     = $templateId
            IsHighlyPrivileged = $isPriv
            AssignmentType     = $entry.Kind
            PrincipalId        = $item.principalId
            Scope              = $scope
            DirectoryScopeId   = if ($scopeId) { $scopeId } else { '/' }
            IsTenantScoped     = ($scope -eq 'Tenant')
            # Only eligibility has a schedule; an active assignment from this endpoint
            # is permanent, so a date here would be an invention.
            EndDateTime        = if ($entry.Kind -eq 'Eligible') { $item.endDateTime } else { $null }
            Raw                = $item
        }

        # Graph's principal on a role assignment is what the role is ASSIGNED TO, which
        # is what PrincipalName / PrincipalType / PrincipalId report on every row.
        $principal = $item.principal
        $principalType = Get-MsecPrincipalObjectType $principal

        # A user or service principal is both the assignee and the holder: one row where
        # the two coincide.
        if ($principalType -ne 'group') {
            ConvertTo-MsecPrincipalRow -Context $context -Assignee $principal -Effective $principal
            continue
        }

        if ($NoGroupExpansion) {
            # Asked for the assignment-level view. The assignee is known, the holders
            # are deliberately not looked up, so the effective principal is unknown.
            ConvertTo-MsecPrincipalRow -Context $context -Assignee $principal -Effective $null
            continue
        }

        $groupId = [string]$principal.id
        if (-not $groupCache.ContainsKey($groupId)) {
            $groupCache[$groupId] = Get-MsecGroupPrincipalMember -GroupId $groupId -GroupName $principal.displayName
        }

        # One row per member: same assignee, different holder. A group of five is five
        # rows, so counting holders never double-counts the group itself.
        $emitted = 0
        foreach ($member in $groupCache[$groupId]) {
            ConvertTo-MsecPrincipalRow -Context $context -Assignee $principal `
                -Effective $member.Principal -MembershipType $member.Membership
            $emitted++
        }

        # A group whose membership resolved to nobody - empty, unreadable, or holding
        # only empty nested groups - still holds the role. Dropping it would delete a
        # live privilege path from the output: whoever can write that group's membership
        # can take the role tomorrow without touching a role assignment. So the
        # assignment is reported with its holder unknown rather than not reported.
        if ($emitted -eq 0) {
            ConvertTo-MsecPrincipalRow -Context $context -Assignee $principal -Effective $null
        }
    }

    # Reading assignments and reading the identities they point at are separate grants.
    # With only the former, Graph returns principals as id-plus-type shells, and this
    # command would otherwise hand back a table of blank names that looks like a
    # finished access review. Say so once, loudly, with the count.
    if ($stats.UnreadablePrincipals -gt 0) {
        Write-Warning "$($stats.UnreadablePrincipals) privileged principal(s) could not be named: Microsoft Graph returned them as id-only objects, which means the msec app may read role assignments but not the user, group and service principal objects they point at. Those rows carry a PrincipalId and IsResolved = `$false, and are NOT an access review. Grant the msec app 'User.Read.All', 'Group.Read.All' and 'Application.Read.All' and re-run New-MsecApp, then Disconnect-Msec / Connect-Msec to drop the cached token."
    }

    # An empty EffectiveName in a table reads as a broken report, not as 'the holder is
    # unknown' - so the blanks are accounted for explicitly rather than left to be
    # interpreted. Suppressed under -NoGroupExpansion, where every group row is meant to
    # have no holder and saying so once per run would be noise.
    if ($stats.UnknownHolders -gt 0 -and -not $NoGroupExpansion) {
        Write-Warning "$($stats.UnknownHolders) role assignment(s) have an UNKNOWN HOLDER - the blank EffectiveName / EffectiveType rows, where IsResolved is `$false. Each is a role assigned to a group whose membership could not be determined: the group is genuinely empty, or its members are PIM-ELIGIBLE rather than active and the msec app lacks 'PrivilegedEligibilitySchedule.Read.AzureADGroup' (re-run New-MsecApp, then Disconnect-Msec / Connect-Msec). A group named after the role it carries with no active members is usually the second case, and the people eligible for it are missing from this output. Warnings above name each group."
    }
}
