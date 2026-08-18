function Get-MsecEntraDirectoryRoleMember {
    <#
    .SYNOPSIS
        Lists who holds which Microsoft Entra directory role, one flat row per
        role member, flagging the highly-privileged roles.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/directoryRoles and then each role's /members,
        projecting one row per (role, member) pair. This is the standing
        privileged-access inventory: who can do what in the directory right now.

        Use it for the "how many Global Administrators do we have" question that
        every access review and ISO 27001 A.5.18 / A.8.2 check asks. A tenant with
        six permanent Global Admins and no Conditional Access is a materially
        different risk from one with two.

        IMPORTANT - this reflects PERMANENT (active) assignments only. Graph's
        /directoryRoles endpoint returns *activated* roles and their direct
        members; it does not include PIM-eligible assignments that nobody has
        activated. In a tenant using PIM the true privileged population is
        therefore larger than this list, and in a tenant without premium
        licensing (where PIM is unavailable) this list IS the whole population.
        Get-MsecEntraTenantSecuritySetting reports both this count and whether
        the tenant is even premium-licensed, so the two read together.

        Use Get-MsecEntraPrivilegedPrincipal instead when you need the EFFECTIVE
        privileged population: it reads the unified role-management endpoints, so it
        includes PIM-eligible assignments, expands role-assignable groups to the
        users inside them, and reports assignment scope. This function remains the
        lighter, single-permission view of active assignments.

        A role with no members may not appear at all: Entra activates a role
        directory object lazily, so an empty role can be absent rather than
        present-with-zero-members. Absence here means "no active members", not
        "role does not exist".

        Requires the 'RoleManagement.Read.Directory' application permission. A
        clearer error is raised on the typical 403.

    .PARAMETER HighlyPrivilegedOnly
        Return only members of the roles flagged IsHighlyPrivileged - the roles
        that can grant themselves or others further access, reset credentials,
        or read/exfiltrate broadly. See .NOTES for the list.

    .EXAMPLE
        Get-MsecEntraDirectoryRoleMember | Group-Object RoleName | Sort-Object Count -Descending

    .EXAMPLE
        # The headline access-review question.
        Get-MsecEntraDirectoryRoleMember |
            Where-Object RoleName -eq 'Global Administrator' |
            Select-Object UserPrincipalName, AccountEnabled

    .EXAMPLE
        # Anything privileged that is a service principal rather than a person.
        Get-MsecEntraDirectoryRoleMember -HighlyPrivilegedOnly |
            Where-Object MemberType -ne 'user'

    .OUTPUTS
        PSCustomObject per (role, member) pair. See .NOTES for the projection.

    .NOTES
        Each row is a [PSCustomObject] with PSTypeName
        'MsecEntraDirectoryRoleMember', whose DefaultDisplayPropertySet
        (RoleName, UserPrincipalName, MemberType, AccountEnabled) is registered
        in msec.psm1.

        Projection:
          directoryRole.displayName        -> RoleName
          directoryRole.roleTemplateId     -> RoleTemplateId
          (derived from the template id)   -> IsHighlyPrivileged
          member.id                        -> MemberId
          member.'@odata.type'             -> MemberType  ('user' / 'group' / 'servicePrincipal')
          member.displayName               -> DisplayName
          member.userPrincipalName         -> UserPrincipalName  ($null for non-users)
          member.accountEnabled            -> AccountEnabled     ($null where not applicable)
          <entire member object verbatim>  -> Raw

        Roles flagged IsHighlyPrivileged come from Get-MsecPrivilegedRoleTemplate
        (by roleTemplateId, so a renamed role still matches): Global Administrator, Privileged Role Administrator,
        Privileged Authentication Administrator, Application Administrator,
        Cloud Application Administrator, Conditional Access Administrator,
        Security Administrator, User Administrator, Exchange Administrator,
        Intune Administrator, SharePoint Administrator, Hybrid Identity
        Administrator, Domain Name Administrator, Partner Tier2 Support.

        Members are matched by roleTemplateId rather than displayName because
        display names are localisable and editable; template ids are stable
        GUIDs that are identical in every tenant and every cloud.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $HighlyPrivilegedOnly
    )

    Assert-MsecSession

    # Stable, cloud-independent role template GUIDs. Shared with
    # Get-MsecEntraPrivilegedPrincipal so the two cannot disagree about what counts as
    # privileged on the same tenant.
    $highlyPrivileged = Get-MsecPrivilegedRoleTemplate

    try {
        $roles = @(Invoke-MsecGraphRequest -Path '/v1.0/directoryRoles' -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /directoryRoles. The msec app needs the 'RoleManagement.Read.Directory' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
        }
        throw
    }

    foreach ($role in $roles) {
        $isPriv = $highlyPrivileged.ContainsKey([string]$role.roleTemplateId)
        if ($HighlyPrivilegedOnly -and -not $isPriv) { continue }

        # Members are a mixed collection (users, groups, service principals), so no
        # $select here: the projected fields don't all exist on every type and Graph
        # rejects a $select naming one that doesn't apply to a returned type.
        try {
            $members = @(Invoke-MsecGraphRequest -Path "/v1.0/directoryRoles/$($role.id)/members" -All)
        }
        catch {
            # One unreadable role must not sink the whole inventory - the useful
            # output is the other roles. Surface it so it isn't silently a zero.
            Write-Warning "Could not read members of role '$($role.displayName)': $($_.Exception.Message)"
            continue
        }

        foreach ($m in $members) {
            # '@odata.type' arrives as '#microsoft.graph.user'; keep just the type.
            $type = if ($m.'@odata.type') {
                ($m.'@odata.type' -replace '^#?microsoft\.graph\.', '')
            } else { $null }

            [PSCustomObject]@{
                PSTypeName         = 'MsecEntraDirectoryRoleMember'

                RoleName           = $role.displayName
                RoleTemplateId     = $role.roleTemplateId
                IsHighlyPrivileged = $isPriv

                MemberId           = $m.id
                MemberType         = $type
                DisplayName        = $m.displayName
                UserPrincipalName  = $m.userPrincipalName
                AccountEnabled     = $m.accountEnabled

                Raw                = $m
            }
        }
    }
}
