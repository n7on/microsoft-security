#Requires -Module Pester
#
# Tests for the private role-holder row projection. Every column here is a claim about
# privileged access, so they are pinned directly rather than only through
# Get-MsecEntraRoleHolder's Graph mocks - the cases that matter most (an unnamed
# principal, an unexpanded group) are the ones hardest to reach through the full stack.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-MsecRolePrincipalRow' {

    BeforeEach {
        $script:Context = @{
            RoleName           = 'Global Administrator'
            RoleTemplateId     = '62e90394-69f5-4237-9190-012177145e10'
            IsHighlyPrivileged = $true
            AssignmentType     = 'Active'
            PrincipalId        = 'fallback-id'
            Scope              = 'Tenant'
            DirectoryScopeId   = '/'
            IsTenantScoped     = $true
            EndDateTime        = $null
            Raw                = [pscustomobject]@{ id = 'assignment-1' }
        }
    }

    It 'reports a direct assignment with holder and assignee as the same object' {
        $row = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $user = [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.user'; id = 'u1'
                displayName = 'Anton'; userPrincipalName = 'anton@x.com'
                accountEnabled = $true; userType = 'Member'; onPremisesSyncEnabled = $null
            }
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $user -Effective $user
        }

        $row.EffectiveId       | Should -Be 'u1'
        $row.PrincipalId       | Should -Be 'u1'
        $row.EffectiveName     | Should -Be 'anton@x.com'
        $row.PrincipalName     | Should -Be 'anton@x.com'
        $row.EffectiveType     | Should -Be 'user'
        # A direct assignment is identified by MembershipType being $null and the two
        # ids agreeing - there is no separate is-direct column to fall out of step.
        $row.MembershipType    | Should -BeNullOrEmpty
        $row.IsResolved        | Should -BeTrue
        $row.IsActiveNow       | Should -BeTrue
        $row.UserType          | Should -Be 'Member'
        # Graph reports cloud-only as null; the row must say $false, not $null.
        $row.IsDirectorySynced | Should -BeFalse
        $row.PSObject.TypeNames | Should -Contain 'MsecEntraRoleHolder'
    }

    It 'keeps the assignee and drops the holder for an unexpanded group' {
        $row = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $group = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g1'; displayName = 'sg-admins' }
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $group -Effective $null
        }

        $row.PrincipalId    | Should -Be 'g1'
        $row.PrincipalType  | Should -Be 'group'
        $row.PrincipalName  | Should -Be 'sg-admins'
        $row.EffectiveId    | Should -BeNullOrEmpty
        $row.EffectiveName  | Should -BeNullOrEmpty
        $row.IsResolved     | Should -BeFalse
        # Nobody known to hold it, so "usable right now" has no answer - NOT $false,
        # which would assert the privilege is dormant.
        $row.IsActiveNow    | Should -BeNullOrEmpty
    }

    It 'distinguishes an eligible holder inside an active assignment' {
        $row = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $group = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g1'; displayName = 'sg-admins' }
            $user  = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u9'; userPrincipalName = 'pim@x.com' }
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $group -Effective $user -MembershipType 'Eligible'
        }

        # Both links must be active to use the role. The assignment is, the membership
        # is not - so the privilege is real but not usable without an activation.
        $row.AssignmentType | Should -Be 'Active'
        $row.MembershipType | Should -Be 'Eligible'
        $row.IsActiveNow    | Should -BeFalse
        $row.IsResolved     | Should -BeTrue
        $row.PrincipalType  | Should -Be 'group'
        $row.EffectiveType  | Should -Be 'user'
    }

    It 'treats a principal Graph would not name as unresolved, but keeps its id' {
        $out = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            # The id-only shell: full property schema, every value null.
            $shell = [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.user'; id = 'u404'
                displayName = $null; userPrincipalName = $null; accountEnabled = $null
                userType = $null; onPremisesSyncEnabled = $null
            }
            $stats = @{ UnreadablePrincipals = 0; UnknownHolders = 0 }
            $row = ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $shell -Effective $shell -Stats $stats
            [pscustomobject]@{ Row = $row; Stats = $stats }
        }

        $out.Row.IsResolved    | Should -BeFalse
        # Never a blank cell - the id is what you would act on.
        $out.Row.EffectiveName | Should -Be 'u404'
        # Detail columns must not assert anything about an identity we cannot read.
        $out.Row.UserType          | Should -BeNullOrEmpty
        $out.Row.IsDirectorySynced | Should -BeNullOrEmpty
        # Counted as unreadable (needs a permission grant), NOT as an unknown holder
        # (needs group expansion) - the two have different fixes.
        $out.Stats.UnreadablePrincipals | Should -Be 1
        $out.Stats.UnknownHolders       | Should -Be 0
    }

    It 'counts an absent holder as an unknown holder, not an unreadable principal' {
        $stats = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $group = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g1'; displayName = 'sg' }
            $stats = @{ UnreadablePrincipals = 0; UnknownHolders = 0 }
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $group -Effective $null -Stats $stats | Out-Null
            $stats
        }

        $stats.UnknownHolders       | Should -Be 1
        $stats.UnreadablePrincipals | Should -Be 0
    }

    It 'names a service principal by displayName and leaves user-only columns null' {
        $row = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $sp = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.servicePrincipal'
                                     id = 'sp1'; displayName = 'break-glass'; accountEnabled = $true }
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $sp -Effective $sp
        }

        $row.EffectiveName     | Should -Be 'break-glass'
        $row.EffectiveType     | Should -Be 'servicePrincipal'
        # UserPrincipalName stays strictly a UPN, so filtering on it stays exact.
        $row.UserPrincipalName | Should -BeNullOrEmpty
        $row.UserType          | Should -BeNullOrEmpty
        $row.IsDirectorySynced | Should -BeNullOrEmpty
        $row.AccountEnabled    | Should -BeTrue
    }

    It 'falls back to the context PrincipalId when the assignee object is absent' {
        $row = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            # Graph omits the expanded principal when the app cannot read it at all.
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $null -Effective $null
        }

        $row.PrincipalId   | Should -Be 'fallback-id'
        $row.PrincipalName | Should -Be 'fallback-id'
        $row.PrincipalType | Should -BeNullOrEmpty
        $row.IsResolved    | Should -BeFalse
    }

    It 'carries the context''s assignment facts through unchanged' {
        $row = InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $Ctx.AssignmentType   = 'Eligible'
            $Ctx.Scope            = 'AdministrativeUnit:au-1'
            $Ctx.DirectoryScopeId = '/administrativeUnits/au-1'
            $Ctx.IsTenantScoped   = $false
            $Ctx.EndDateTime      = '2026-12-31T00:00:00Z'
            $user = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
            ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $user -Effective $user
        }

        $row.AssignmentType   | Should -Be 'Eligible'
        $row.Scope            | Should -Be 'AdministrativeUnit:au-1'
        $row.DirectoryScopeId | Should -Be '/administrativeUnits/au-1'
        $row.IsTenantScoped   | Should -BeFalse
        $row.EndDateTime      | Should -Be '2026-12-31T00:00:00Z'
        $row.RoleTemplateId   | Should -Be '62e90394-69f5-4237-9190-012177145e10'
        $row.Raw.id           | Should -Be 'assignment-1'
        # An eligible assignment is not usable until activated, whatever the membership.
        $row.IsActiveNow      | Should -BeFalse
    }

    It 'rejects a MembershipType outside the two real states' {
        InModuleScope msec -Parameters @{ Ctx = $script:Context } {
            param($Ctx)
            $user = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
            { ConvertTo-MsecRolePrincipalRow -Context $Ctx -Assignee $user -Effective $user -MembershipType 'Maybe' } |
                Should -Throw
        }
    }
}
