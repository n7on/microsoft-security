function ConvertTo-MsecRolePrincipalRow {
    <#
    .SYNOPSIS
        The projection for "a principal holds a directory role" - one row of
        Get-MsecEntraRoleHolder's output.

    .DESCRIPTION
        Separated from its caller for two reasons: Get-MsecEntraRoleHolder is long
        enough without it, and the row shape is the part most worth testing
        directly - every column here is a claim about privileged access, and a
        test can pin all of them without mocking a tenant's worth of Graph
        endpoints.

        It also has some history worth knowing. msec used to have two commands
        reading role membership from different endpoints, each building its own
        rows, and their columns had drifted apart: the same fact was called
        MemberId in one and PrincipalId in the other, so no single Where-Object
        filtered both. Consolidating the projection here came first; retiring the
        redundant command came after, once it was clear the shapes were the only
        real difference between them.

        TWO PRINCIPALS PER ROW is the shape, and the reason the row is not just a
        flat member record:

          PrincipalName / PrincipalType / PrincipalId
              What the role is ASSIGNED TO. A group whenever a group holds the
              role, and the object you would act on to revoke the assignment.

          EffectiveName / EffectiveType / EffectiveId
              Who ends up HOLDING it. The same object as the assignee on a direct
              assignment; a member for an expanded group; $null when the holders
              of an assigned group are not known.

        A row with PrincipalType 'group' and no EffectiveId is therefore an
        assignment whose holders were not determined - unreadable, empty, or
        -NoGroupExpansion - and never a claim that nobody holds the role.

    .PARAMETER Context
        Hashtable of the per-assignment facts the caller already resolved:
        RoleName, RoleTemplateId, IsHighlyPrivileged, AssignmentType, PrincipalId
        (the assignee id fallback), Scope, DirectoryScopeId, IsTenantScoped,
        EndDateTime, Raw.

    .PARAMETER Assignee
        The Graph principal the role is assigned to.

    .PARAMETER Effective
        The Graph principal that ends up holding the role, or $null when that is
        not known. Pass the same object as -Assignee for a direct assignment.

    .PARAMETER MembershipType
        How the effective principal sits inside the assignee - 'Active' or
        'Eligible'. Omit when holder and assignee are the same object; the row
        then reports $null, which is how a direct assignment is identified.

    .PARAMETER Stats
        Optional hashtable with UnreadablePrincipals and UnknownHolders keys,
        incremented in place so the caller can report the totals once at the end
        of a run instead of warning per row. A blank name in an access review reads
        as a broken report rather than as 'unknown', so those counts are what let a
        caller say which it is.

    .OUTPUTS
        One PSCustomObject with PSTypeName 'MsecEntraRoleHolder'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context,

        [Parameter()]
        $Assignee,

        [Parameter()]
        $Effective,

        [Parameter()]
        [ValidateSet('Active', 'Eligible')]
        [string] $MembershipType,

        [Parameter()]
        [hashtable] $Stats
    )

    $assigneeType = Get-MsecPrincipalObjectType $Assignee
    $assigneeId   = if ($Assignee -and $Assignee.id) { $Assignee.id } else { $Context.PrincipalId }
    $assigneeName = Get-MsecPrincipalDisplayKey -Principal $Assignee -FallbackId $assigneeId

    $effectiveType = Get-MsecPrincipalObjectType $Effective
    $effectiveId   = if ($Effective) { $Effective.id } else { $null }
    $effectiveName = if ($Effective) { Get-MsecPrincipalDisplayKey -Principal $Effective -FallbackId $effectiveId } else { $null }

    # Resolved means we know who ends up with the privilege. An assigned group whose
    # membership was not determined fails this, and so does a principal Graph
    # returned as an id-only shell - two different causes, one honest verdict.
    $unnamed    = ($null -ne $Effective) -and (Test-MsecPrincipalUnnamed $Effective)
    $isResolved = ($null -ne $Effective) -and -not $unnamed

    if ($Stats) {
        # Counted apart, because the fix differs: an identity the app cannot name
        # needs a permission grant, an assigned group we did not look inside needs
        # expansion (or is simply this endpoint's documented limit).
        if ($unnamed)             { $Stats.UnreadablePrincipals++ }
        if ($null -eq $Effective) { $Stats.UnknownHolders++ }
    }

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
        PSTypeName         = 'MsecEntraRoleHolder'

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
