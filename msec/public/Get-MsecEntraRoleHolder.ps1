function Get-MsecEntraRoleHolder {
    <#
    .SYNOPSIS
        Every principal holding ANY Entra directory role - not only privileged ones -
        separating what the role is ASSIGNED TO from who EFFECTIVELY holds it, with the
        activation state of each.

    .DESCRIPTION
        Answers "who and what can administer this tenant".

        EVERY ROLE BY DEFAULT, privileged or not: Global Reader and Message Center
        Reader come back alongside Global Administrator. Pass -HighlyPrivilegedOnly for
        the escalation-capable subset. The command was once called
        Get-MsecEntraPrivilegedPrincipal, which read as though the filter were always on
        - it never was, and the old name misled often enough to be worth changing.

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

        It reads the unified role-management endpoints rather than the older
        /directoryRoles, which has four blind spots this does not - msec used to have a
        second command built on that endpoint, and these are why it was retired rather
        than kept as a lighter alternative:

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
             same risk as a tenant-wide one, and /directoryRoles cannot tell them apart.

          4. Custom roles. They are roleDefinitions and never appear as directoryRole
             objects, so a bespoke role granting
             microsoft.directory/roleAssignments went unseen entirely.

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

    .PARAMETER Role
        One or more roles to report on, given as display names, roleTemplateIds, or a
        mix. Tab completes. Mutually exclusive with -HighlyPrivilegedOnly, which is a
        different way of naming the same kind of subset.

        A name is matched against three things, in this order, case-insensitively:
        the roleTemplateId or definition id; the display name THIS tenant reports; and
        the canonical name msec knows from Get-MsecPrivilegedRoleTemplate.

        That third one is the point of the parameter. Graph returns Global
        Administrator under its legacy name 'Company Administrator' on many tenants, so
        -Role 'Global Administrator' resolves through the canonical map to
        62e90394-69f5-4237-9190-012177145e10 and matches the role anyway. Matching only
        display names would have reproduced the exact defect this module already carried
        in its Global Admin count.

        AN UNRECOGNISED VALUE IS A TERMINATING ERROR listing the tenant's roles, rather
        than an empty result. A misspelled role that returned nothing would be
        indistinguishable from a role nobody holds - a clean bill of health that is
        really a typo, which is the worst way for this command to be wrong. A role that
        resolves but has no definition in this tenant is NOT an error: that is a genuine
        empty answer, reported as no rows and a verbose note.

        Filtering happens server-side, one request per named role, instead of reading
        every assignment in the tenant and discarding the rest. Asking who holds one
        role is therefore cheap on a large directory, and group expansion only runs for
        groups that hold the named roles.

    .PARAMETER AssignmentType
        Which assignments to read: 'All' (default), 'Active' (standing assignments
        only - no premium licence needed), or 'Eligible' (PIM eligibility only,
        requires Entra ID P2).

    .PARAMETER HighlyPrivilegedOnly
        Return only roles that can grant further access, reset credentials, or read
        broadly. The set is defined in Get-MsecPrivilegedRoleTemplate. Mutually
        exclusive with -Role: naming roles explicitly already is the filter, and
        combining the two invites an empty result that reads as an answer
        (-Role 'Global Reader' -HighlyPrivilegedOnly can only ever be zero rows).

    .PARAMETER NoGroupExpansion
        Return assignments as Entra records them: one row per assignment, with the
        assignee named and the effective principal left $null. Useful for "what is
        assigned to what", and the honest choice when the app cannot read group
        membership - but it is NOT the effective privileged population and must not be
        counted as one.

    .EXAMPLE
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly

    .EXAMPLE
        # One role. Works whether the directory calls it 'Global Administrator' or
        # 'Company Administrator', and costs one request rather than a tenant sweep.
        Get-MsecEntraRoleHolder -Role 'Global Administrator'

    .EXAMPLE
        # Several, mixing a canonical name with a raw template id.
        Get-MsecEntraRoleHolder -Role 'Global Administrator', 'User Administrator',
                                      'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'

    .EXAMPLE
        # The tier-0 review: who can administer identity, and can they use it today?
        Get-MsecEntraRoleHolder -Role 'Global Administrator', 'Privileged Role Administrator' |
            Format-Table EffectiveName, RoleName, AssignmentType, IsActiveNow

    .EXAMPLE
        # A custom role, by its definition id - the canonical map only covers built-ins.
        Get-MsecEntraRoleHolder -Role '4f9c8e21-0d3b-4a77-9e18-7c2d5b6a1f04'

    .EXAMPLE
        # People only, then applications only. EffectiveType is the HOLDER's kind -
        # PrincipalType would say 'group' for anyone who inherited the role.
        Get-MsecEntraRoleHolder | Where-Object EffectiveType -eq 'user'
        Get-MsecEntraRoleHolder | Where-Object EffectiveType -eq 'servicePrincipal'

    .EXAMPLE
        # How the privileged population splits between people and applications.
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
            Group-Object EffectiveType -NoElement

    .EXAMPLE
        # Privilege that arrives through a group - the path most reviews miss. The
        # assignee differs from the holder exactly when the role was inherited.
        Get-MsecEntraRoleHolder | Where-Object PrincipalType -eq 'group' |
            Format-Table EffectiveName, RoleName, PrincipalName, MembershipType

    .EXAMPLE
        # PIM for Groups: people who hold nothing today but can activate into a group
        # that carries a role. Invisible to every /members endpoint.
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
            Where-Object MembershipType -eq 'Eligible' |
            Format-Table EffectiveName, RoleName, PrincipalName

    .EXAMPLE
        # Privilege usable right now - nothing left to activate on either link.
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
            Where-Object IsActiveNow

    .EXAMPLE
        # Standing tenant-wide privilege: the assignments PIM was meant to remove.
        Get-MsecEntraRoleHolder -AssignmentType Active -HighlyPrivilegedOnly |
            Where-Object IsTenantScoped

    .EXAMPLE
        # Distinct humans who can administer the tenant. Count holders, not rows: one
        # person inheriting a role through two groups is one administrator.
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly |
            Where-Object { $_.EffectiveType -eq 'user' -and $_.IsResolved } |
            Sort-Object EffectiveId -Unique

    .EXAMPLE
        # External identities holding privileged roles, and privileged accounts synced
        # from on-premises AD. Both should be short, deliberate lists.
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly | Where-Object UserType -eq 'Guest'
        Get-MsecEntraRoleHolder -HighlyPrivilegedOnly | Where-Object IsDirectorySynced

    .OUTPUTS
        PSCustomObject per (role, principal, assignment type). See .NOTES.

    .NOTES
        Each row is a [PSCustomObject] with PSTypeName 'MsecEntraRoleHolder',
        whose DefaultDisplayPropertySet (EffectiveName, EffectiveType, RoleName,
        AssignmentType, PrincipalName) is registered in Msec.psm1. The holder leads,
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
        assignment collections. Without -Role the unfiltered list is attempted first
        and, only if Graph rejects it, the query fans out to one call per role
        definition - correct either way, one round trip in the common case. With -Role
        the fan-out is taken deliberately and narrowed to the named roles, which is
        cheaper than the unfiltered sweep rather than a fallback from it.

        Each run caches the tenant's role definitions (id, templateId, displayName,
        isBuiltIn) so the -Role completer has real names to offer without ever calling
        Graph from the prompt. Nothing sensitive: role names and ids only.
    #>
    [CmdletBinding(DefaultParameterSetName = 'AllRoles')]
    param(
        # Names or roleTemplateIds, or a mix - see .PARAMETER Role for why both, and why
        # a name is matched against more than one thing.
        [Parameter(ParameterSetName = 'ByRole', Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            try {
                $module = Get-Module Msec
                if (-not $module) { return }
                $word = ([string]$wordToComplete).Trim("'`"")

                # Two sources, so completion works before this command has ever run: the
                # curated privileged names are static, and the tenant's own roles come from
                # the cache the last run wrote. NEVER a Graph call - the prompt would block
                # on every Tab, and when Graph is unhealthy it does not fail fast, it hangs.
                #
                # Read-MsecCache and Get-MsecPrivilegedRoleTemplate are private, and
                # completers run outside module scope; invoking the scriptblock against the
                # module object runs it where private functions resolve.
                $candidates = & $module {
                    $canonical = Get-MsecPrivilegedRoleTemplate
                    $byName = [ordered]@{}

                    foreach ($c in @(Read-MsecCache -Name 'directory-roles')) {
                        $templateId = [string]$c.TemplateId
                        $directory  = [string]$c.DisplayName
                        # Prefer the canonical name for a role msec knows: it is what
                        # someone will type, and it is stable across tenants.
                        $name = if ($canonical.ContainsKey($templateId)) { $canonical[$templateId] } else { $directory }
                        if (-not $name) { continue }

                        # Surfacing both names where they differ turns the legacy-name
                        # surprise ('Company Administrator') into something you can see.
                        $byName[$name] = if ($directory -and $directory -ne $name) {
                            "$name  -  the directory calls this '$directory'"
                        }
                        else { $name }
                    }

                    # A role nobody holds may have no cached row, and asking about it is a
                    # legitimate question with a legitimate empty answer - so the curated
                    # names complete regardless of what the cache saw.
                    foreach ($kv in $canonical.GetEnumerator()) {
                        if (-not $byName.Contains($kv.Value)) { $byName[$kv.Value] = "$($kv.Value)  -  highly privileged" }
                    }

                    $byName.GetEnumerator() | ForEach-Object {
                        [pscustomobject]@{ Name = $_.Key; Detail = $_.Value }
                    }
                }

                $candidates | Where-Object { $_.Name -like "$word*" } | Sort-Object Name |
                    ForEach-Object {
                        $insert = if ($_.Name -match "[\s']") { "'" + ($_.Name -replace "'", "''") + "'" } else { $_.Name }
                        [System.Management.Automation.CompletionResult]::new(
                            $insert, $_.Name, 'ParameterValue', $_.Detail)
                    }
            }
            catch {
                # A completer must never throw or the prompt breaks.
            }
        })]
        [string[]] $Role,

        [Parameter()]
        [ValidateSet('All', 'Active', 'Eligible')]
        [string] $AssignmentType = 'All',

        [Parameter(ParameterSetName = 'AllRoles')]
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

    # Feeds the -Role completer on the next run. Never fatal: without an Azure context
    # there is no tenant to scope a cache to, and Save-MsecCache degrades to verbose.
    Save-MsecCache -Name 'directory-roles' -Item @(
        $definitions | ForEach-Object {
            [pscustomobject]@{
                Id          = [string]$_.id
                TemplateId  = [string]$_.templateId
                DisplayName = [string]$_.displayName
                IsBuiltIn   = [bool]$_.isBuiltIn
            }
        }
    )

    # ---- -Role resolution ---------------------------------------------------------
    # $null means every role; otherwise the definitions to query, which the assignment
    # reader turns into one filtered call each rather than a full-tenant sweep.
    $targetDefinitions = $null
    $selectedIds = $null

    if ($PSCmdlet.ParameterSetName -eq 'ByRole') {
        $byTemplateId = @{}; $byId = @{}; $byDisplayName = @{}
        foreach ($d in $definitions) {
            if ($d.templateId)  { $byTemplateId[([string]$d.templateId).ToLowerInvariant()]   = $d }
            if ($d.id)          { $byId[([string]$d.id).ToLowerInvariant()]                   = $d }
            if ($d.displayName) { $byDisplayName[([string]$d.displayName).ToLowerInvariant()] = $d }
        }

        # Canonical name -> roleTemplateId. This is the entry that makes the parameter
        # worth having: -Role 'Global Administrator' resolves through here to
        # 62e90394-... and then matches the definition even on a tenant whose directory
        # calls that role 'Company Administrator'. Matching display names alone would
        # reproduce exactly the bug this module already had in its Global Admin count.
        $canonicalToTemplate = @{}
        foreach ($kv in $highlyPrivileged.GetEnumerator()) {
            $canonicalToTemplate[([string]$kv.Value).ToLowerInvariant()] = [string]$kv.Key
        }

        $selected   = @{}
        $unresolved = [System.Collections.Generic.List[string]]::new()

        foreach ($value in $Role) {
            $key = ([string]$value).Trim().ToLowerInvariant()
            if (-not $key) { continue }

            $def = $null
            if     ($byTemplateId.ContainsKey($key))  { $def = $byTemplateId[$key] }
            elseif ($byId.ContainsKey($key))          { $def = $byId[$key] }
            elseif ($byDisplayName.ContainsKey($key)) { $def = $byDisplayName[$key] }
            elseif ($canonicalToTemplate.ContainsKey($key)) {
                $templateId = $canonicalToTemplate[$key]
                if ($byTemplateId.ContainsKey($templateId)) { $def = $byTemplateId[$templateId] }
                else {
                    # A name msec knows, with no definition in this tenant. The role is
                    # real and simply has nobody in it: an empty answer, not an error.
                    Write-Verbose "Role '$value' has no roleDefinition in this tenant, so nothing holds it."
                    continue
                }
            }

            if ($def) { $selected[[string]$def.id] = $def }
            else      { $unresolved.Add([string]$value) }
        }

        # A misspelled role that quietly returned nothing would be indistinguishable from
        # a role nobody holds - which is the single most dangerous way for this command to
        # be wrong. So an unrecognised value is fatal, and says what it would have taken.
        if ($unresolved.Count) {
            $plural = if ($unresolved.Count -gt 1) { 's' } else { '' }
            $known = (@($definitions | ForEach-Object { $_.displayName } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
            throw ("Unrecognised role$plural`: $($unresolved -join ', '). Pass a role's display name as this tenant reports it, its roleTemplateId, or one of the canonical names msec knows (Global Administrator, User Administrator, ...) - matching is case-insensitive, and Tab completes. Roles in this tenant: $known")
        }

        $targetDefinitions = @($selected.Values)
        $selectedIds = $selected

        # Every named role resolved to something with no definition here. Nothing to ask
        # Graph about, and no rows to emit.
        if (-not $targetDefinitions.Count) { return }
    }

    # ---- Assignment collections ---------------------------------------------------
    # Nested so it closes over $definitions; the retry-with-filter shape is identical
    # for the active and the eligible endpoint and shouldn't be written twice.
    function Get-MsecRoleAssignmentCollection {
        param(
            [Parameter(Mandatory)][string] $Segment,

            # When supplied, go straight to one filtered call per definition instead of
            # pulling every assignment in the tenant and discarding most of it. -Role
            # takes this path deliberately: asking who holds one role should cost one
            # request, not a full sweep of a large directory.
            [object[]] $Definition
        )

        $collection = "/v1.0/roleManagement/directory/$Segment"

        if (-not $Definition) {
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
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($def in @(if ($Definition) { $Definition } else { $definitions })) {
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
        foreach ($a in (Get-MsecRoleAssignmentCollection -Segment 'roleAssignments' -Definition $targetDefinitions)) {
            $assignments.Add([pscustomobject]@{ Kind = 'Active'; Item = $a })
        }
    }

    if ($AssignmentType -in @('All', 'Eligible')) {
        try {
            foreach ($e in (Get-MsecRoleAssignmentCollection -Segment 'roleEligibilityScheduleInstances' -Definition $targetDefinitions)) {
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
    # Mutated in place by ConvertTo-MsecRolePrincipalRow so the totals can be reported
    # once at the end of the run rather than warned about per row.
    $stats = @{ UnreadablePrincipals = 0; UnknownHolders = 0 }

    # The row shape lives in ConvertTo-MsecRolePrincipalRow, with the principal helpers
    # it uses - Get-MsecPrincipalObjectType, Get-MsecPrincipalDisplayKey,
    # Test-MsecPrincipalUnnamed. Kept out of here so every column of a privileged-access
    # row can be tested without mocking a tenant's worth of Graph endpoints.
    $row = {
        param($Context, $Assignee, $Effective, [string] $MembershipType)

        $params = @{
            Context   = $Context
            Assignee  = $Assignee
            Effective = $Effective
            Stats     = $stats
        }
        # -MembershipType is ValidateSet'd, so an empty string cannot be bound: a
        # direct assignment must omit the parameter rather than pass $null through.
        if ($MembershipType) { $params['MembershipType'] = $MembershipType }

        ConvertTo-MsecRolePrincipalRow @params
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

        # -Role already filtered server-side, one request per named role. Re-checked here
        # so a Graph that ignored the $filter cannot widen the answer past what was asked
        # for - a role holder appearing in output nobody requested would be read as a
        # finding about that role.
        if ($selectedIds -and -not $selectedIds.ContainsKey($definitionId)) { continue }

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
            & $row $context $principal $principal
            continue
        }

        if ($NoGroupExpansion) {
            # Asked for the assignment-level view. The assignee is known, the holders
            # are deliberately not looked up, so the effective principal is unknown.
            & $row $context $principal $null
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
            & $row $context $principal $member.Principal $member.Membership
            $emitted++
        }

        # A group whose membership resolved to nobody - empty, unreadable, or holding
        # only empty nested groups - still holds the role. Dropping it would delete a
        # live privilege path from the output: whoever can write that group's membership
        # can take the role tomorrow without touching a role assignment. So the
        # assignment is reported with its holder unknown rather than not reported.
        if ($emitted -eq 0) {
            & $row $context $principal $null
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
