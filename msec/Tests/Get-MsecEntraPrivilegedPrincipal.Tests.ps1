#Requires -Module Pester
#
# Tests for Get-MsecEntraPrivilegedPrincipal. The behaviours that matter are the ones a
# partial implementation would get wrong and still look plausible: eligible
# assignments appearing at all, role-assignable groups expanding to the users inside
# them, nested groups not double-counting, AU-scoped assignments not being read as
# tenant-wide, and a tenant without Entra ID P2 degrading to a warning rather than
# either failing or silently reporting a short list.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraPrivilegedPrincipal' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId        = 'tenant'
                ClientId        = 'client'
                KeyVaultName    = 'kv-test'
                KeyName         = 'msec-app'
                ThumbprintBytes = $Thumb
                Tokens          = @{}
            }
        }
    }

    It 'merges active and eligible assignments, expands groups, and flags privileged roles by template id' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    # Renamed away from 'Global Administrator' to prove the privileged
                    # flag is a templateId lookup, not a display-name match.
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Tenant God Mode'; isBuiltIn = $true
                    }
                    [pscustomobject]@{
                        id = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        templateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        displayName = 'Global Reader'; isBuiltIn = $true
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; displayName = 'Anton'
                            userPrincipalName = 'anton@example.com'; accountEnabled = $true
                        }
                    }
                    # A role assigned to a role-assignable GROUP. The whole point: the
                    # users inside must surface, not just the group object.
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Tier0 Admins'
                        }
                    }
                    [pscustomobject]@{
                        id = 'ra3'; roleDefinitionId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        principalId = 'u9'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u9'; userPrincipalName = 'auditor@example.com'; accountEnabled = $true
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 're1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u2'; directoryScopeId = '/'
                        startDateTime = '2026-01-01T00:00:00Z'; endDateTime = $null
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; displayName = 'Eligible Erik'
                            userPrincipalName = 'erik@example.com'; accountEnabled = $true
                        }
                    }
                ) }
            }
            # Members are fetched one type at a time via an OData cast, so the $select
            # can name user-only properties. A cast response omits @odata.type, which
            # the function must fill in from the cast it asked for.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/groups/g1/transitiveMembers/microsoft.graph.user' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'u3'; displayName = 'Nested Nina'
                        userPrincipalName = 'nina@example.com'; accountEnabled = $true
                        userType = 'Guest'; onPremisesSyncEnabled = $null
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/groups/g1/transitiveMembers/microsoft.graph.servicePrincipal' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'sp1'; displayName = 'break-glass-app'; accountEnabled = $true }
                ) }
            }
            # The uncast collection must not be used - it returns nested groups and a
            # property subset without userType or accountEnabled.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/groups/g1/transitiveMembers$' } -MockWith {
                throw 'the uncast transitiveMembers collection must not be queried'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'privilegedAccess/group/eligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraPrivilegedPrincipal
        }

        # 2 direct user rows + 1 eligible + 2 expanded group members. The group itself
        # is REPLACED by its members, and the nested group row is skipped - so a group
        # of two contributes two rows, not three.
        $rows.Count | Should -Be 5

        $ga = @($rows | Where-Object RoleTemplateId -eq '62e90394-69f5-4237-9190-012177145e10')
        $ga.Count | Should -Be 4
        ($ga | Select-Object -Unique IsHighlyPrivileged).IsHighlyPrivileged | Should -BeTrue
        ($ga | Select-Object -Unique RoleName).RoleName | Should -Be 'Tenant God Mode'

        # The eligible administrator - invisible to Get-MsecEntraDirectoryRoleMember.
        $erik = $rows | Where-Object EffectiveId -eq 'u2'
        $erik.AssignmentType | Should -Be 'Eligible'
        $erik.MembershipType | Should -BeNullOrEmpty   # assignee and holder are one object
        $erik.EndDateTime    | Should -BeNullOrEmpty   # permanently eligible
        $erik.IsActiveNow    | Should -BeFalse         # eligibility must be activated

        # Active assignments carry no schedule, so EndDateTime must not be invented.
        $u1 = $rows | Where-Object EffectiveId -eq 'u1'
        $u1.AssignmentType | Should -Be 'Active'
        $u1.EndDateTime    | Should -BeNullOrEmpty
        $u1.IsActiveNow    | Should -BeTrue

        # On a direct assignment the assignee IS the holder - both sets of columns carry
        # the same identity rather than one of them being empty.
        $u1.PrincipalId    | Should -Be 'u1'
        $u1.PrincipalType  | Should -Be 'user'
        $u1.PrincipalName  | Should -Be 'anton@example.com'
        $u1.EffectiveName  | Should -Be 'anton@example.com'
        $u1.MembershipType | Should -BeNullOrEmpty

        # No row is left with an unknown holder: every group resolved.
        @($rows | Where-Object { -not $_.IsResolved }).Count | Should -Be 0

        $nina = $rows | Where-Object EffectiveId -eq 'u3'
        # The ASSIGNEE is the group the role is on - the object you would act on to
        # revoke the assignment - while the HOLDER is the person inside it.
        $nina.PrincipalName     | Should -Be 'Tier0 Admins'
        $nina.PrincipalType     | Should -Be 'group'
        $nina.PrincipalId       | Should -Be 'g1'
        $nina.EffectiveName     | Should -Be 'nina@example.com'
        # The cast response carried no @odata.type; the cast itself must supply it.
        $nina.EffectiveType     | Should -Be 'user'
        $nina.MembershipType    | Should -Be 'Active'
        $nina.RoleName          | Should -Be 'Tenant God Mode'
        # Detail columns describe the HOLDER, not the group it came through.
        $nina.UserPrincipalName | Should -Be 'nina@example.com'
        # A GUEST holding a privileged role through a group, and its enabled state -
        # both of which the uncast collection's property subset would have hidden.
        $nina.UserType          | Should -Be 'Guest'
        $nina.AccountEnabled    | Should -BeTrue
        $nina.IsDirectorySynced | Should -BeFalse   # Graph reports cloud-only as null

        # A service principal has no UPN - so UserPrincipalName stays null (it is
        # strictly a UPN, and the blank is how you spot an app), and DisplayName names
        # it - so a privileged application is never an anonymous row.
        $sp = $rows | Where-Object EffectiveId -eq 'sp1'
        $sp.EffectiveType     | Should -Be 'servicePrincipal'
        $sp.UserPrincipalName | Should -BeNullOrEmpty
        $sp.DisplayName       | Should -Be 'break-glass-app'
        # ...and EffectiveName falls back to that name, so the pair (type, name)
        # identifies an app as well as it identifies a person.
        $sp.EffectiveName     | Should -Be 'break-glass-app'
        $sp.IsResolved        | Should -BeTrue
        # UserType and IsDirectorySynced are user-only facts; inventing them for an
        # app would put 'Member' next to something that has no account type at all.
        $sp.UserType          | Should -BeNullOrEmpty
        $sp.IsDirectorySynced | Should -BeNullOrEmpty

        # The group is never its own holder when it resolved - counting both the group
        # and its members would inflate every report built on this.
        $rows | Where-Object EffectiveId -eq 'g1' | Should -BeNullOrEmpty
        # The nested group is structure, not a principal.
        $rows | Where-Object EffectiveId -eq 'g2' | Should -BeNullOrEmpty

        # Global Reader is read-only and deliberately not privileged.
        ($rows | Where-Object EffectiveId -eq 'u9').IsHighlyPrivileged | Should -BeFalse

        $rows[0].PSObject.TypeNames | Should -Contain 'MsecEntraPrivilegedPrincipal'
    }

    It 'projects administrative-unit scope and does not read it as tenant-wide' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        templateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        displayName = 'User Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        principalId = 'u1'; directoryScopeId = '/administrativeUnits/au-guid'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'scoped@example.com'
                        }
                    }
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        principalId = 'u2'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; userPrincipalName = 'tenantwide@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraPrivilegedPrincipal
        }

        $scoped = $rows | Where-Object PrincipalId -eq 'u1'
        $scoped.Scope            | Should -Be 'AdministrativeUnit:au-guid'
        $scoped.IsTenantScoped   | Should -BeFalse
        $scoped.DirectoryScopeId | Should -Be '/administrativeUnits/au-guid'

        $wide = $rows | Where-Object PrincipalId -eq 'u2'
        $wide.Scope          | Should -Be 'Tenant'
        $wide.IsTenantScoped | Should -BeTrue
    }

    It 'warns about the missing licence and still returns active assignments when the tenant has no Entra ID P2' {
        $result = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).'),
                    'GraphError', 'InvalidOperation', $null)
                throw $err
            }

            # The 403 body is what tells licensing apart from permission; without
            # ErrorDetails the function must fall back to the permission wording.
            $warnings = @()
            $rows = Get-MsecEntraPrivilegedPrincipal -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # Active assignments survive - a failed eligibility read must not sink them.
        $result.Rows.Count       | Should -Be 1
        $result.Rows[0].RoleName | Should -Be 'Global Administrator'

        # And the incompleteness is stated, not swallowed.
        $result.Warnings.Count | Should -BeGreaterThan 0
        ($result.Warnings -join ' ') | Should -Match 'INCOMPLETE|licence'
    }

    It 'skips the eligibility call entirely with -AssignmentType Active' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                throw 'eligibility must not be queried when -AssignmentType Active'
            }

            Get-MsecEntraPrivilegedPrincipal -AssignmentType Active
        }

        $rows.Count              | Should -Be 1
        $rows[0].AssignmentType  | Should -Be 'Active'
    }

    It 'fetches a role definition the collection omits rather than reporting a bare GUID' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # The collection knows nothing about the assigned definition...
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions\?' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            # ...but a direct read of it succeeds, as it does for hidden built-ins.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions/11111111' } -MockWith {
                [pscustomobject]@{
                    id = '11111111-2222-3333-4444-555555555555'
                    templateId = '11111111-2222-3333-4444-555555555555'
                    displayName = 'Some Hidden Built-In'; isBuiltIn = $true
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '11111111-2222-3333-4444-555555555555'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                    # A second assignment of the same definition must not re-fetch it;
                    # if it did, the mock below would still answer, so assert the count.
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = '11111111-2222-3333-4444-555555555555'
                        principalId = 'u2'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; userPrincipalName = 'sam@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $result = @(Get-MsecEntraPrivilegedPrincipal)
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly `
                -ParameterFilter { $Uri -match 'roleDefinitions/11111111' }
            $result
        }

        $rows.Count | Should -Be 2
        ($rows | Select-Object -Unique RoleName).RoleName | Should -Be 'Some Hidden Built-In'
    }

    It 'flags and counts principals Graph returns as id-only shells instead of emitting blank rows' {
        $result = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            # Exactly what Graph returns when the app may read role assignments but not
            # the directory objects behind them: the full property schema, all null.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; displayName = $null
                            userPrincipalName = $null; accountEnabled = $null
                        }
                    }
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'sp1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.servicePrincipal'
                            id = 'sp1'; displayName = $null
                        }
                    }
                    # A readable one, to prove the flag is per-row and not global.
                    [pscustomobject]@{
                        id = 'ra3'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u2'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; displayName = 'Anton'
                            userPrincipalName = 'anton@example.com'; accountEnabled = $true
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $warnings = @()
            $rows = Get-MsecEntraPrivilegedPrincipal -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # Nothing is dropped - the assignments are real even when the identities are opaque.
        $result.Rows.Count | Should -Be 3

        # An unnameable administrator reads as an unknown, not as a blank cell.
        ($result.Rows | Where-Object PrincipalId -eq 'u1').IsResolved  | Should -BeFalse
        ($result.Rows | Where-Object PrincipalId -eq 'sp1').IsResolved | Should -BeFalse
        ($result.Rows | Where-Object PrincipalId -eq 'u2').IsResolved  | Should -BeTrue
        # IsActiveNow must not claim an unknown identity can use the role.
        ($result.Rows | Where-Object PrincipalId -eq 'u1').IsActiveNow | Should -BeNullOrEmpty
        ($result.Rows | Where-Object PrincipalId -eq 'u2').IsActiveNow | Should -BeTrue

        # And the caller is told, with a count and the permission to grant.
        ($result.Warnings -join ' ') | Should -Match '2 privileged principal'
        ($result.Warnings -join ' ') | Should -Match 'User.Read.All'
    }

    It 'expands a PIM-governed group with no active members into its ELIGIBLE members' {
        # The real-tenant case that motivated this: a group named for the role it
        # carries, with an empty membership and a queue of people eligible to activate
        # into it. /transitiveMembers reports nothing, so without the PIM-for-Groups
        # endpoint the tenant looks like it has nobody in the role.
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        templateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        displayName = 'Global Reader'
                    }
                ) }
            }
            # The group is ACTIVELY assigned the role...
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        principalId = 'g-pim'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g-pim'; displayName = 'pim-group-global-reader'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            # ...and has no actual members at all.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'privilegedAccess/group/eligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'g-pim_member_1'; accessId = 'member'; groupId = 'g-pim'
                        principalId = 'u1'; memberType = 'Direct'; endDateTime = $null
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; displayName = 'Pim-Eligible Pia'
                            userPrincipalName = 'pia@example.com'
                            accountEnabled = $true; userType = 'Member'
                        }
                    }
                    # An OWNER can add themselves as a member and only then hold the
                    # role, so counting them here would overstate the population.
                    [pscustomobject]@{
                        id = 'g-pim_owner_2'; accessId = 'owner'; groupId = 'g-pim'
                        principalId = 'u2'; memberType = 'Direct'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; userPrincipalName = 'owner@example.com'
                        }
                    }
                ) }
            }

            Get-MsecEntraPrivilegedPrincipal
        }

        # The eligible member replaces the group, exactly as an active member would.
        $rows.Count              | Should -Be 1
        $rows[0].EffectiveName   | Should -Be 'pia@example.com'
        $rows[0].EffectiveType   | Should -Be 'user'
        $rows[0].RoleName        | Should -Be 'Global Reader'
        $rows[0].PrincipalName   | Should -Be 'pim-group-global-reader'
        $rows[0].PrincipalType   | Should -Be 'group'
        $rows[0].MembershipType  | Should -Be 'Eligible'
        $rows[0].IsResolved      | Should -BeTrue

        # Each link keeps its own truth: the ASSIGNMENT to the group is active, the
        # MEMBERSHIP is not. Folding them into one column would have to lie about one.
        $rows[0].AssignmentType  | Should -Be 'Active'
        # And the conjunction is the answer to "can they use it right now" - no.
        $rows[0].IsActiveNow     | Should -BeFalse

        # The group has a holder now, so it is not its own row.
        $rows | Where-Object EffectiveType -eq 'group' | Should -BeNullOrEmpty
        # And the owner is not a role holder.
        $rows | Where-Object EffectiveId -eq 'u2' | Should -BeNullOrEmpty
    }

    It 'keeps a role assigned to an EMPTY group as an unresolved row rather than dropping the assignment' {
        $result = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Empty Tier0 group'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            # A group holding only an empty nested group: the per-type casts return no
            # user and no service principal, and PIM knows no eligible members either,
            # so the assignment has nobody at all to stand for.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'eligibilityScheduleInstances' -and $Uri -match 'groupId' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $warnings = @()
            $rows = Get-MsecEntraPrivilegedPrincipal -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # Global Administrator is assigned to a group someone could populate tomorrow.
        # That must not vanish from a privileged-access report. The assignee is known;
        # the holder is not, which is exactly what the row says.
        $result.Rows.Count | Should -Be 1
        $row = $result.Rows[0]
        $row.PrincipalId   | Should -Be 'g1'
        $row.PrincipalType | Should -Be 'group'
        $row.PrincipalName | Should -Be 'Empty Tier0 group'
        $row.EffectiveId   | Should -BeNullOrEmpty
        $row.EffectiveName | Should -BeNullOrEmpty
        $row.EffectiveType | Should -BeNullOrEmpty
        $row.IsResolved    | Should -BeFalse
        $row.IsActiveNow   | Should -BeNullOrEmpty
        $row.RoleName      | Should -Be 'Global Administrator'

        # A blank EffectiveName in a table reads as a broken report, so the run must
        # account for the blanks rather than leave them to be interpreted - and must
        # name the permission that is the usual cause.
        $joined = $result.Warnings -join ' '
        $joined | Should -Match 'UNKNOWN HOLDER'
        $joined | Should -Match 'PrivilegedEligibilitySchedule.Read.AzureADGroup'
    }

    It 'leaves groups unexpanded with -NoGroupExpansion' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Tier0 Admins'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                throw 'group expansion must not happen with -NoGroupExpansion'
            }

            Get-MsecEntraPrivilegedPrincipal -NoGroupExpansion
        }

        # The assignment-level view: assignee named, holders deliberately not looked up.
        $rows.Count            | Should -Be 1
        $rows[0].PrincipalType | Should -Be 'group'
        $rows[0].PrincipalName | Should -Be 'Tier0 Admins'
        $rows[0].EffectiveName | Should -BeNullOrEmpty
        $rows[0].IsResolved    | Should -BeFalse
    }

    It 'warns and keeps the group row when the group cannot be expanded' {
        $result = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Tier0 Admins'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'eligibilityScheduleInstances' -and $Uri -match 'groupId' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $warnings = @()
            $rows = Get-MsecEntraPrivilegedPrincipal -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # An unreadable group is an unknown, not a zero - the assignment stays visible.
        $result.Rows.Count             | Should -Be 1
        $result.Rows[0].PrincipalType  | Should -Be 'group'
        $result.Rows[0].IsResolved     | Should -BeFalse
        ($result.Warnings -join ' ')   | Should -Match 'Group.Read.All'
    }

    It 'falls back to per-role-definition filtering when Graph rejects the unfiltered list' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            # The filtered retry (URI carries an escaped $filter) succeeds...
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' -and $Uri -match 'roleDefinitionId' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                ) }
            }
            # ...while the unfiltered list is rejected the way Graph rejects it.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' -and $Uri -notmatch 'roleDefinitionId' } -MockWith {
                throw 'A $filter query parameter is required for this request.'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraPrivilegedPrincipal -AssignmentType Active
        }

        $rows.Count                 | Should -Be 1
        $rows[0].UserPrincipalName  | Should -Be 'anton@example.com'
    }

    It 'rewrites a 403 on roleDefinitions to name the missing permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraPrivilegedPrincipal } |
                Should -Throw -ExpectedMessage '*RoleManagement.Read.Directory*'
        }
    }
}
